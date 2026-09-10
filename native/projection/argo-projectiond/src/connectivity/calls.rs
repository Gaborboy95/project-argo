//! Call control delegates to WirePlumber's installed native HFP backend.
//! Argo never registers an HFP profile or accesses RFCOMM/SCO itself.
use super::{Request, bluetooth::Bluetooth};
use crate::{
    host_control::HostControl,
    voice::{self, props},
};
use futures_util::StreamExt;
use serde::Serialize;
use serde_json::json;
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    process::Child,
    sync::{mpsc, watch},
    time::Instant,
};
use zbus::zvariant::{OwnedObjectPath, OwnedValue};
const SERVICE: &str = "org.pipewire.Telephony";
const ROOT: &str = "/org/pipewire/Telephony";
const AG: &str = "org.pipewire.Telephony.AudioGateway1";
const CALL: &str = "org.pipewire.Telephony.Call1";
const TRANSPORT: &str = "org.pipewire.Telephony.AudioGatewayTransport1";
const HFP: &str = "0000111f-0000-1000-8000-00805f9b34fb";
type Objects = HashMap<OwnedObjectPath, HashMap<String, HashMap<String, OwnedValue>>>;
#[derive(Clone, Default, Serialize)]
pub struct Snapshot {
    pub available: bool,
    pub device: String,
    pub phase: String,
    pub detail: String,
    pub calls: Vec<Call>,
    pub audio: bool,
    pub operation: u64,
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phonebook: Option<super::phonebook::Snapshot>,
}
#[derive(Clone, Serialize)]
pub struct Call {
    pub id: String,
    pub state: String,
    pub number: Option<String>,
    pub name: Option<String>,
}
// PipeWire 1.4.2 ag_dial returns `o`, despite its introspection XML omitting
// the output argument. Decode the actual wire reply; never repeat a Dial.
async fn dial(
    bus: &zbus::Connection,
    gateway: &str,
    number: &str,
) -> Result<OwnedObjectPath, String> {
    proxy(bus, gateway, AG)
        .await?
        .call("Dial", &(number,))
        .await
        .map_err(|e| format!("Dial result unavailable: {e}. Check the phone before dialing again."))
}
async fn proxy(
    bus: &zbus::Connection,
    path: &str,
    interface: &str,
) -> Result<zbus::Proxy<'static>, String> {
    zbus::Proxy::new_owned(bus.clone(), SERVICE, path.to_owned(), interface.to_owned())
        .await
        .map_err(|e| e.to_string())
}
fn text(p: &HashMap<String, OwnedValue>, key: &str) -> Option<String> {
    p.get(key)
        .and_then(|v| <&str>::try_from(v).ok())
        .map(str::to_owned)
}
async fn objects(bus: &zbus::Connection) -> Result<Objects, String> {
    proxy(bus, ROOT, "org.freedesktop.DBus.ObjectManager")
        .await?
        .call("GetManagedObjects", &())
        .await
        .map_err(|e| e.to_string())
}
fn number(value: &str) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 64
        || !value
            .bytes()
            .enumerate()
            .all(|(i, b)| b.is_ascii_digit() || b == b'*' || b == b'#' || (i == 0 && b == b'+'))
    {
        return Err("Enter a telephone number (digits, leading +, * or #)".into());
    }
    Ok(())
}
struct Duplex {
    children: Vec<Child>,
    _lease: voice::Lease,
    nodes: Vec<u64>,
    muted: bool,
    created: Instant,
    owned_names: Vec<String>,
    host_output: String,
}
impl Drop for Duplex {
    fn drop(&mut self) {
        if self
            .children
            .iter_mut()
            .any(|c| !matches!(c.try_wait(), Ok(Some(_))))
        {
            self._lease.poison();
        }
    }
}
impl Duplex {
    async fn open(host: &HostControl, device: &str, lease: voice::Lease) -> Result<Self, String> {
        let graph = voice::graph().await?;
        let path = format!(
            "/org/bluez/{}/dev_{}",
            device.split_once('/').ok_or("No phone selected")?.0,
            device.split_once('/').unwrap().1.replace(':', "_")
        );
        let cards: Vec<_> = graph
            .iter()
            .filter(|n| props(n)["api.bluez5.path"] == path)
            .filter_map(|n| n["id"].as_u64())
            .collect();
        let nodes: Vec<_> = graph
            .iter()
            .filter(|n| {
                let p = props(n);
                p["factory.name"].as_str().unwrap_or("").contains("sco")
                    && p["device.id"]
                        .as_u64()
                        .or_else(|| p["device.id"].as_str()?.parse().ok())
                        .is_some_and(|id| cards.contains(&id))
            })
            .collect();
        let source = nodes
            .iter()
            .find(|n| {
                props(n)["factory.name"]
                    .as_str()
                    .unwrap_or("")
                    .ends_with("source")
            })
            .ok_or("Phone HFP receive node not ready")?;
        let sink = nodes
            .iter()
            .find(|n| {
                props(n)["factory.name"]
                    .as_str()
                    .unwrap_or("")
                    .ends_with("sink")
            })
            .ok_or("Phone HFP transmit node not ready")?;
        let ids = vec![
            source["id"].as_u64().ok_or("Invalid SCO source")?,
            sink["id"].as_u64().ok_or("Invalid SCO sink")?,
        ];
        if graph.iter().any(|n| {
            n["type"] == "PipeWire:Interface:Link"
                && ["output-node-id", "input-node-id"]
                    .iter()
                    .any(|k| n["info"][k].as_u64().is_some_and(|id| ids.contains(&id)))
        }) {
            return Err("HFP audio already routed by another client; close that call-audio client before enabling Argo call audio".into());
        }

        let output = super::music::default_output(&graph)?;
        if output == props(sink)["node.name"].as_str().unwrap_or("")
            || !graph
                .iter()
                .any(|n| props(n)["node.name"] == output && props(n)["media.class"] == "Audio/Sink")
        {
            return Err("Select a host output other than the phone's HFP transmit sink".into());
        }
        let mut result = Self {
            children: vec![],
            _lease: lease,
            nodes: ids,
            muted: host.voice.state.borrow().muted,
            created: Instant::now(),
            owned_names: vec![],
            host_output: output.clone(),
        };
        let routes = [
            (
                props(source)["node.name"]
                    .as_str()
                    .ok_or("SCO source missing name")?
                    .to_owned(),
                output,
            ),
            (
                result._lease.source.clone(),
                props(sink)["node.name"]
                    .as_str()
                    .ok_or("SCO sink missing name")?
                    .to_owned(),
            ),
        ];
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let owner = format!(
            "argo.hfp.{}.{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        );
        for (i, (from, to)) in routes.iter().enumerate() {
            if i == 1 && result.muted {
                continue;
            }
            let capture_name = format!("{owner}.{i}.capture");
            let playback_name = format!("{owner}.{i}.playback");
            let capture = json!({"media.role":"Communication","node.dont-reconnect":true,"node.name":capture_name});
            let playback = json!({"media.role":"Communication","node.dont-reconnect":true,"node.name":playback_name});
            result.owned_names.extend([capture_name, playback_name]);
            match voice::process("pw-loopback")
                .args([
                    "--name",
                    &format!("argo.hfp.{i}"),
                    "--channels",
                    "1",
                    "--channel-map",
                    "[ MONO ]",
                    "--latency",
                    "20",
                    "--capture",
                    from,
                    "--playback",
                    to,
                    "--capture-props",
                    &capture.to_string(),
                    "--playback-props",
                    &playback.to_string(),
                ])
                .spawn()
            {
                Ok(child) => result.children.push(child),
                Err(e) => {
                    result.close().await?;
                    return Err(format!("Cannot start HFP audio: {e}"));
                }
            }
        }
        Ok(result)
    }
    async fn close(&mut self) -> Result<(), String> {
        for child in &mut self.children {
            if child.try_wait().map_err(|e| e.to_string())?.is_none() {
                child.start_kill().map_err(|e| e.to_string())?;
            }
            child.wait().await.map_err(|e| e.to_string())?;
        }
        self.children.clear();
        Ok(())
    }
}
fn owned_routes_ready(
    graph: &[serde_json::Value],
    sco: &[u64],
    names: &[String],
) -> Result<bool, String> {
    let owned: Vec<_> = graph
        .iter()
        .filter(|n| {
            props(n)["node.name"]
                .as_str()
                .is_some_and(|name| names.iter().any(|v| v == name))
        })
        .filter_map(|n| n["id"].as_u64())
        .collect();
    let links: Vec<_> = graph
        .iter()
        .filter(|n| n["type"] == "PipeWire:Interface:Link")
        .filter_map(|n| {
            Some((
                n["info"]["output-node-id"].as_u64()?,
                n["info"]["input-node-id"].as_u64()?,
            ))
        })
        .collect();
    if links.iter().any(|(a, b)| {
        (sco.contains(a) && !owned.contains(b)) || (sco.contains(b) && !owned.contains(a))
    }) {
        return Err("Another client acquired an HFP route; owned route cleanup required".into());
    }
    let ready: Vec<_> = graph
        .iter()
        .filter(|n| {
            n["type"] == "PipeWire:Interface:Link"
                && matches!(n["info"]["state"].as_str(), Some("active" | "paused"))
        })
        .filter_map(|n| {
            Some((
                n["info"]["output-node-id"].as_u64()?,
                n["info"]["input-node-id"].as_u64()?,
            ))
        })
        .collect();
    Ok(owned.len() == names.len()
        && owned
            .iter()
            .all(|id| ready.iter().any(|(a, b)| a == id || b == id)))
}
struct Controller {
    book: super::phonebook::Book,
    host: HostControl,
    bt: Arc<Bluetooth>,
    bus: zbus::Connection,
    state: Snapshot,
    gateway: String,
    epoch: u64,
    bus_owner: String,
    duplex: Option<Duplex>,
    wanted: bool,
    attempts: u8,
    next: Instant,
    audio_attempts: u8,
}
impl Controller {
    fn publish(&self) {
        let mut snapshot = self.state.clone();
        snapshot.phonebook = Some(self.book.state.clone());
        self.host
            .connectivity
            .state
            .send_modify(|s| s.calls = Some(snapshot));
    }
    async fn silence(&mut self) -> Result<(), String> {
        if let Some(audio) = self.duplex.as_mut() {
            audio.close().await?;
        }
        self.duplex = None;
        self.state.audio = false;
        Ok(())
    }
    fn authorized(&self) -> Result<(), String> {
        let s = self.host.connectivity.state.borrow();
        s.require_selected_adapter(&self.state.device)?;
        if !s
            .devices
            .iter()
            .any(|d| d.id == self.state.device && d.paired)
        {
            return Err("Selected phone is no longer paired".into());
        }
        let address = self
            .state
            .device
            .split_once('/')
            .ok_or("Select a paired phone")?
            .1;
        if s.devices.iter().any(|d| {
            d.connected && d.id != self.state.device && d.id.ends_with(&format!("/{address}"))
        }) {
            return Err("Phone connected through multiple Bluetooth adapters; disconnect the other link before using calls".into());
        }
        Ok(())
    }
    async fn refresh(&mut self) -> Result<(), String> {
        if let Err(e) = self.check_owner().await {
            self.gateway.clear();
            self.state.calls.clear();
            if self.wanted {
                self.attempts = self.attempts.saturating_add(1);
                self.wanted = self.attempts < 3;
            }
            self.state.available = false;
            let _ = self.book.clear().await;
            return Err(e);
        }
        let all = match objects(&self.bus).await {
            Ok(all) => all,
            Err(e) => {
                self.gateway.clear();
                self.state.calls.clear();
                self.epoch += 1;
                self.state.available = false;
                let _ = self.book.clear().await;
                return Err(e);
            }
        };
        self.state.available = true;
        if !self.wanted {
            return Ok(());
        }
        if let Err(e) = self.authorized() {
            self.wanted = false;
            return Err(e);
        }
        let address = self.state.device.split_once('/').unwrap().1;
        let matches: Vec<_> = all
            .iter()
            .filter(|(_, i)| {
                i.get(AG)
                    .and_then(|p| text(p, "Address"))
                    .is_some_and(|a| a.eq_ignore_ascii_case(address))
            })
            .collect();
        if matches.len() != 1 {
            let _ = self.book.clear().await;
            self.silence().await?;
            self.state.calls.clear();
            self.gateway.clear();
            self.state.phase = "connecting".into();
            if self.attempts >= 3 {
                self.wanted = false;
                return Err("HFP connection unavailable after three attempts; press Connect calls to try again".into());
            }
            if Instant::now() >= self.next {
                self.attempts += 1;
                self.next = Instant::now() + Duration::from_secs(5 * self.attempts as u64);
                if let Err(e) = self
                    .bt
                    .device(&self.state.device)?
                    .connect_profile(&HFP.parse().unwrap())
                    .await
                {
                    if matches!(
                        e.kind,
                        bluer::ErrorKind::AuthenticationCanceled
                            | bluer::ErrorKind::AuthenticationFailed
                            | bluer::ErrorKind::AuthenticationRejected
                            | bluer::ErrorKind::NotAuthorized
                            | bluer::ErrorKind::NotPermitted
                            | bluer::ErrorKind::NotSupported
                            | bluer::ErrorKind::InvalidArguments
                    ) {
                        self.wanted = false;
                    }
                    if e.kind != bluer::ErrorKind::AlreadyConnected {
                        return Err(format!("HFP connect: {e}"));
                    }
                }
            }
            return Ok(());
        }
        let (path, _) = matches[0];
        if self.gateway != path.as_str() {
            self.silence().await?;
            self.epoch += 1;
            self.gateway = path.to_string();
            self.audio_attempts = 0;
        }
        self.state.phase = "connected".into();
        let old_active = !self.state.calls.is_empty();
        self.state.calls = all
            .iter()
            .filter_map(|(path, i)| {
                if !path.as_str().starts_with(&format!("{}/", self.gateway)) {
                    return None;
                }
                let p = i.get(CALL)?;
                Some(Call {
                    id: format!("{}:{}", self.epoch, path),
                    state: text(p, "State").unwrap_or_else(|| "unknown".into()),
                    number: text(p, "LineIdentification").filter(|v| !v.is_empty()),
                    name: text(p, "Name").filter(|v| !v.is_empty()),
                })
            })
            .take(8)
            .collect();
        let active = self
            .state
            .calls
            .iter()
            .any(|c| matches!(c.state.as_str(), "active" | "dialing" | "alerting"));
        if !old_active && !self.state.calls.is_empty() {
            self.audio_attempts = 0;
        }
        if !active {
            self.silence().await?;
            self.state.detail = "HFP connected; ready for calls".into();
            return Ok(());
        }
        if self
            .duplex
            .as_ref()
            .is_some_and(|d| d.muted != self.host.voice.state.borrow().muted)
        {
            self.silence().await?;
            self.audio_attempts = 0;
        }
        if let Some(d) = &self.duplex
            && super::music::default_output(&voice::graph().await?)? != d.host_output
        {
            self.silence().await?;
            self.audio_attempts = 0;
        }
        if let Some(d) = self.duplex.as_mut() {
            let graph = voice::graph().await?;
            if d.children
                .iter_mut()
                .any(|c| c.try_wait().ok().flatten().is_some())
                || !d
                    .nodes
                    .iter()
                    .all(|id| graph.iter().any(|n| n["id"].as_u64() == Some(*id)))
            {
                self.silence().await?;
                return Err("HFP audio route disappeared".into());
            }
        }
        if let Some(d) = &self.duplex {
            let graph = voice::graph().await?;
            self.state.audio = owned_routes_ready(&graph, &d.nodes, &d.owned_names)?;
            if !self.state.audio && d.created.elapsed() > Duration::from_secs(3) {
                return Err("PipeWire HFP routes did not become ready".into());
            }
            if !self.state.audio {
                self.state.detail =
                    "Waiting for PipeWire to link the owned HFP audio streams".into();
            }
        }
        if self.duplex.is_none() && self.audio_attempts < 3 {
            self.audio_attempts += 1;
            // Do not deliberately switch the phone to SCO without an available microphone.
            let lease = self.host.voice.claim("bluetoothCall").await?;
            let p = proxy(&self.bus, &self.gateway, TRANSPORT).await?;
            if p.get_property::<String>("State").await.unwrap_or_default() != "active" {
                p.call::<_, _, ()>("Activate", &())
                    .await
                    .map_err(|e| format!("SCO activation: {e}"))?;
            }
            self.duplex = Some(Duplex::open(&self.host, &self.state.device, lease).await?);
            self.state.audio = false;
        }
        if self.state.audio {
            self.state.detail = "Call audio uses the selected microphone and host output".into();
        }
        Ok(())
    }
    async fn check_owner(&mut self) -> Result<(), String> {
        let owner = zbus::fdo::DBusProxy::new(&self.bus)
            .await
            .map_err(|e| e.to_string())?
            .get_name_owner(SERVICE.try_into().unwrap())
            .await
            .map_err(|e| e.to_string())?
            .to_string();
        if owner != self.bus_owner {
            self.epoch += 1;
            self.bus_owner = owner;
            self.gateway.clear();
            self.state.calls.clear();
            self.silence().await?;
        }
        Ok(())
    }
    async fn request(&mut self, r: &Request) -> Result<(), String> {
        match r.action.as_str() {
            "callsConnect" => {
                let _ = self.book.clear().await;
                self.silence().await?;
                self.state.device = r.target.clone();
                self.authorized()?;
                self.wanted = true;
                self.attempts = 0;
                self.audio_attempts = 0;
                self.epoch += 1;
                self.gateway.clear();
                self.next = Instant::now();
                self.refresh().await
            }
            "callsDisconnect" => {
                self.wanted = false;
                let _ = self.book.clear().await;
                self.silence().await?;
                if !self.state.device.is_empty() {
                    let device = self.bt.device(&self.state.device)?;
                    if device.is_connected().await.map_err(|e| e.to_string())?
                        && let Err(e) = device.disconnect_profile(&HFP.parse().unwrap()).await
                    {
                        let all = objects(&self.bus).await?;
                        let address = self.state.device.split_once('/').unwrap().1;
                        if all.values().any(|i| {
                            i.get(AG)
                                .and_then(|p| text(p, "Address"))
                                .is_some_and(|a| a.eq_ignore_ascii_case(address))
                        }) {
                            return Err(e.to_string());
                        }
                    }
                }
                self.state.device.clear();
                self.state.calls.clear();
                self.gateway.clear();
                self.state.phase = "disconnected".into();
                Ok(())
            }
            "callsPhonebook" => {
                self.authorized()?;
                if !self.wanted || self.state.phase != "connected" {
                    return Err("Connect calls before importing phone data".into());
                }
                if !self
                    .bt
                    .device(&self.state.device)?
                    .is_paired()
                    .await
                    .map_err(|e| e.to_string())?
                {
                    return Err("Phone is no longer paired".into());
                }
                let (kind, offset) = r.target.split_once(':').ok_or("Invalid phonebook page")?;
                let offset = offset.parse::<u16>().map_err(|_| "Invalid page offset")?;
                let (adapter, remote) = self
                    .state
                    .device
                    .split_once('/')
                    .ok_or("Select a paired phone")?;
                let local = self
                    .bt
                    .session
                    .adapter(adapter)
                    .map_err(|e| e.to_string())?
                    .address()
                    .await
                    .map_err(|e| e.to_string())?
                    .to_string();
                self.book.start(local, remote.into(), kind, offset).await
            }
            "callsPhonebookClear" => self.book.clear().await,
            "callsAudio" => {
                self.audio_attempts = 0;
                self.refresh().await
            }
            "callsDial" => {
                self.check_owner().await?;
                self.authorized()?;
                number(&r.target)?;
                if self.gateway.is_empty() {
                    return Err("Connect calls first".into());
                }
                let path = dial(&self.bus, &self.gateway, &r.target).await?;
                if !path.as_str().starts_with(&format!("{}/", self.gateway)) {
                    return Err("Dial returned an unexpected call reference. Check the phone before dialing again.".into());
                }
                self.state.detail = "Dial accepted; the phone controls the calling SIM".into();
                Ok(())
            }
            "callsAnswer" | "callsHangup" => {
                self.check_owner().await?;
                self.authorized()?;
                let call = self
                    .state
                    .calls
                    .iter()
                    .find(|c| c.id == r.target)
                    .ok_or("Call ended or was replaced")?;
                let path = call
                    .id
                    .split_once(':')
                    .ok_or("Invalid call identity")?
                    .1
                    .to_owned();
                // Verify against the current ObjectManager view immediately before a command.
                if !objects(&self.bus)
                    .await?
                    .iter()
                    .any(|(p, i)| p.as_str() == path && i.contains_key(CALL))
                {
                    return Err("Call is no longer available".into());
                }
                proxy(&self.bus, &path, CALL)
                    .await?
                    .call::<_, _, ()>(
                        if r.action == "callsAnswer" {
                            "Answer"
                        } else {
                            "Hangup"
                        },
                        &(),
                    )
                    .await
                    .map_err(|e| e.to_string())
            }
            _ => Err("Unsupported call command".into()),
        }
    }
}
pub async fn run(
    bt: Arc<Bluetooth>,
    host: HostControl,
    mut requests: mpsc::Receiver<Request>,
    mut shutdown: watch::Receiver<bool>,
) {
    let bus = match zbus::Connection::session().await {
        Ok(b) => b,
        Err(e) => {
            host.connectivity.state.send_modify(|s| {
                s.calls = Some(Snapshot {
                    detail: format!("PipeWire telephony bus unavailable: {e}"),
                    ..Default::default()
                })
            });
            return;
        }
    };
    let mut c = Controller {
        book: Default::default(),
        host,
        bt,
        bus,
        state: Snapshot {
            phase: "idle".into(),
            ..Default::default()
        },
        gateway: String::new(),
        epoch: 0,
        bus_owner: String::new(),
        duplex: None,
        wanted: false,
        attempts: 0,
        next: Instant::now(),
        audio_attempts: 0,
    };
    let rule = zbus::MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(SERVICE)
        .unwrap()
        .path_namespace(ROOT)
        .unwrap()
        .interface("org.freedesktop.DBus.ObjectManager")
        .unwrap()
        .build();
    let mut signals = zbus::MessageStream::for_match_rule(rule, &c.bus, Some(64))
        .await
        .ok();
    let mut cancel = c.host.connectivity.calls_cancel.subscribe();
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {biased;
            _=shutdown.changed()=>break,
            Some(_) = async {signals.as_mut().unwrap().next().await}, if signals.is_some()=>{c.epoch+=1;c.state.calls.clear();c.publish();},
            _=cancel.changed()=>{
                c.wanted=false;
                if let Err(e)=c.book.clear().await {c.state.detail=e;}
                if let Err(e)=c.silence().await {c.state.detail=format!("Call audio cleanup: {e}");}
                c.publish();
            },
            r=requests.recv()=>{let Some(r)=r else {break};if r.action!="callsDisconnect" && (r.generation!=*cancel.borrow() || c.host.connectivity.stopping.load(std::sync::atomic::Ordering::SeqCst)){continue;}
                let result=tokio::time::timeout(Duration::from_secs(8),c.request(&r)).await.unwrap_or_else(|_|Err("Call operation timed out; check the phone before repeating it".into()));
                let result=if r.action!="callsDisconnect" && r.generation!=*cancel.borrow(){c.wanted=false;let _=c.book.clear().await;c.silence().await.and(Err("Call request cancelled".into()))}else{result};
                crate::daemon_log!(Info,"calls","operation={} action={} result={}",r.prompt,r.action,if result.is_ok(){"accepted"}else{"not confirmed"});
                c.state.operation=r.prompt;c.state.error=result.err();if let Some(e)=&c.state.error {c.state.detail=e.clone();}c.publish();
            },
            _=tick.tick()=>{
                if c.authorized().is_err() {let _=c.book.clear().await;}else{c.book.poll().await;}
                let _=c.host.voice.refresh().await;
                c.host.connectivity.state.send_modify(|s|s.voice=Some(c.host.voice.state.borrow().clone()));
                if let Err(e)=tokio::time::timeout(Duration::from_secs(4),c.refresh()).await.unwrap_or_else(|_|Err("PipeWire telephony did not respond".into())) {
                    if let Err(cleanup)=c.silence().await {c.wanted=false;c.state.detail=format!("{e}; cleanup: {cleanup}");}else{c.state.detail=e;}
                    c.state.phase=if c.wanted && !c.gateway.is_empty() {"connected"} else if c.wanted {"connecting"}else{"unavailable"}.into();
                    if c.state.phase!="connected" {c.state.calls.clear();}
                }
                c.publish();tick.reset();
            }
        }
    }
    c.wanted = false;
    if let Err(e) = c.book.clear().await {
        crate::daemon_log!(Warn, "phonebook", "{e}");
    }
    if c.book.cleanup_uncertain() {
        c.host.connectivity.state.send_modify(|s| {
            s.cleanup_error = "Phonebook worker cleanup unconfirmed".into();
        });
    }
    if let Err(e) = c.silence().await {
        crate::daemon_log!(Warn, "calls", "HFP cleanup: {e}");
        c.host
            .connectivity
            .state
            .send_modify(|s| s.cleanup_error = format!("HFP cleanup: {e}"));
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn route_readiness_requires_owned_nodes_and_rejects_external_sco_edges() {
        let names = vec!["capture".into(), "playback".into()];
        let mut graph = vec![
            json!({"id":2,"info":{"props":{"node.name":"capture"}}}),
            json!({"id":3,"info":{"props":{"node.name":"playback"}}}),
        ];
        assert!(!owned_routes_ready(&graph, &[1], &names).unwrap());
        graph.push(
            json!({"type":"PipeWire:Interface:Link","info":{"state":"active","output-node-id":1,"input-node-id":2}}),
        );
        graph.push(
            json!({"type":"PipeWire:Interface:Link","info":{"state":"active","output-node-id":3,"input-node-id":4}}),
        );
        assert!(owned_routes_ready(&graph, &[1], &names).unwrap());
        graph.push(
            json!({"type":"PipeWire:Interface:Link","info":{"output-node-id":1,"input-node-id":4}}),
        );
        assert!(owned_routes_ready(&graph, &[1], &names).is_err());
    }
    #[test]
    fn telephone_input_is_bounded_and_never_a_shell_command() {
        assert!(number("+361234567").is_ok());
        assert!(number("*123#").is_ok());
        for bad in ["", "12;reboot", "123\n", "++12", "tel:123"] {
            assert!(number(bad).is_err());
        }
        assert!(number(&"1".repeat(65)).is_err());
    }
}

#[cfg(test)]
mod dbus_tests {
    use super::*;
    use tokio::io::{AsyncBufReadExt, BufReader};
    struct Gateway(Arc<std::sync::Mutex<Vec<String>>>);
    #[zbus::interface(name = "org.pipewire.Telephony.AudioGateway1")]
    impl Gateway {
        #[zbus(property)]
        fn address(&self) -> &str {
            "00:11:22:33:44:55"
        }
        fn dial(&self, number: &str) -> OwnedObjectPath {
            self.0.lock().unwrap().push(number.into());
            OwnedObjectPath::try_from(format!("{ROOT}/ag0/call0")).unwrap()
        }
    }
    struct Incoming;
    #[zbus::interface(name = "org.pipewire.Telephony.Call1")]
    impl Incoming {
        #[zbus(property)]
        fn state(&self) -> &str {
            "incoming"
        }
        fn answer(&self) -> zbus::fdo::Result<()> {
            Err(zbus::fdo::Error::NotSupported(
                "Test phone does not support Answer".into(),
            ))
        }
    }
    #[tokio::test]
    async fn installed_contract_discovers_actual_dbus_objects_and_preserves_command_rejection() {
        // A private bus: no names, devices, calls or audio on the desktop bus are changed.
        let mut daemon = tokio::process::Command::new("dbus-daemon")
            .args(["--session", "--nofork", "--print-address=1"])
            .stdout(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let mut address = String::new();
        BufReader::new(daemon.stdout.take().unwrap())
            .read_line(&mut address)
            .await
            .unwrap();
        let log = Arc::new(std::sync::Mutex::new(vec![]));
        let server = zbus::connection::Builder::address(address.trim())
            .unwrap()
            .name(SERVICE)
            .unwrap()
            .serve_at(ROOT, zbus::fdo::ObjectManager)
            .unwrap()
            .serve_at(format!("{ROOT}/ag0"), Gateway(log.clone()))
            .unwrap()
            .serve_at(format!("{ROOT}/ag0/call0"), Incoming)
            .unwrap()
            .build()
            .await
            .unwrap();
        let bus = zbus::connection::Builder::address(address.trim())
            .unwrap()
            .build()
            .await
            .unwrap();
        let all = objects(&bus).await.unwrap();
        assert_eq!(all.len(), 2);
        assert!(
            all.values()
                .any(|i| i.get(AG).and_then(|p| text(p, "Address")).as_deref()
                    == Some("00:11:22:33:44:55"))
        );
        let call = dial(&bus, &format!("{ROOT}/ag0"), "123").await.unwrap();
        assert_eq!(call.as_str(), format!("{ROOT}/ag0/call0"));
        assert_eq!(*log.lock().unwrap(), vec!["123"]);
        assert!(
            proxy(&bus, &format!("{ROOT}/ag0/call0"), CALL)
                .await
                .unwrap()
                .call::<_, _, ()>("Answer", &())
                .await
                .is_err()
        );
        server
            .object_server()
            .remove::<Incoming, _>(format!("{ROOT}/ag0/call0"))
            .await
            .unwrap();
        assert_eq!(objects(&bus).await.unwrap().len(), 1);
        drop(server);
        drop(bus);
        daemon.kill().await.unwrap();
    }
}
