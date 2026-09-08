//! BlueZ owns AVRCP/A2DP. WirePlumber owns codecs; Argo owns only selected links.
use super::{Request, bluetooth::Bluetooth};
use crate::{daemon_state::ProjectionRuntimeSnapshot, host_control::HostControl};
use futures_util::StreamExt;
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{mpsc, watch};
use zbus::zvariant::OwnedValue;

const AUDIO_SOURCE: &str = "0000110a-0000-1000-8000-00805f9b34fb";
#[derive(Clone, Default, Serialize)]
pub struct Snapshot {
    pub selected: String,
    pub device: String,
    pub phase: String,
    pub detail: String,
    pub source: Option<Source>,
    pub operation: u64,
    pub error: Option<String>,
    pub cleanup_error: Option<String>,
}
#[derive(Clone, Serialize)]
pub struct Source {
    pub id: String,
    pub device_id: String,
    pub session_id: String,
    pub revision: u64,
    pub updated_at_ms: u64,
    pub name: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub playback: Option<String>,
    pub position_ms: Option<u32>,
    pub duration_ms: Option<u32>,
    pub commands: Vec<String>,
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
async fn proxy<'a>(
    bus: &'a zbus::Connection,
    path: &str,
    interface: &str,
) -> Result<zbus::Proxy<'a>, String> {
    zbus::Proxy::new_owned(
        bus.clone(),
        "org.bluez",
        path.to_owned(),
        interface.to_owned(),
    )
    .await
    .map_err(|e| e.to_string())
}
async fn command(program: &str, args: &[String]) -> Result<Vec<u8>, String> {
    let output = tokio::time::timeout(
        Duration::from_secs(3),
        tokio::process::Command::new(program)
            .args(args)
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| format!("{program} timed out"))?
    .map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!(
            "{program} failed: {}",
            String::from_utf8_lossy(&output.stderr)
                .chars()
                .take(240)
                .collect::<String>()
        ));
    }
    if output.stdout.len() > 4 * 1024 * 1024 {
        return Err("PipeWire graph exceeds bound".into());
    }
    Ok(output.stdout)
}
async fn graph() -> Result<Vec<Value>, String> {
    serde_json::from_slice(&command("pw-dump", &[]).await?).map_err(|e| e.to_string())
}
fn props(v: &Value) -> &Value {
    &v["info"]["props"]
}
fn numeric(v: &Value) -> Option<u64> {
    v.as_u64().or_else(|| v.as_str()?.parse().ok())
}
fn receiver(v: &Value, address: &str) -> bool {
    props(v)["factory.name"] == "api.bluez5.a2dp.source"
        && props(v)["api.bluez5.address"]
            .as_str()
            .is_some_and(|a| a.eq_ignore_ascii_case(address))
}
#[derive(Debug, PartialEq)]
struct RoutePlan {
    source: u64,
    replace: bool,
    links: Vec<(u64, u64)>,
}
fn route_plan(graph: &[Value], address: &str, owner: &str) -> Result<RoutePlan, String> {
    let sources: Vec<_> = graph.iter().filter(|n| receiver(n, address)).collect();
    if sources.len() != 1 {
        return Err("Waiting for one selected-phone A2DP receiver".into());
    }
    let source = sources[0];
    if props(source)["node.autoconnect"] != false && props(source)["node.autoconnect"] != "false" {
        return Err(
            "WirePlumber reception is not opted in; install routing configuration and log out/in"
                .into(),
        );
    }
    let source_id = numeric(&source["id"]).ok_or("Missing A2DP node identity")?;
    let default = graph
        .iter()
        .filter(|v| v["type"] == "PipeWire:Interface:Metadata")
        .flat_map(|v| v["metadata"].as_array().into_iter().flatten())
        .find(|v| v["key"] == "default.audio.sink")
        .and_then(|v| {
            if let Some(text) = v["value"].as_str() {
                serde_json::from_str::<Value>(text).ok()
            } else {
                Some(v["value"].clone())
            }
        })
        .and_then(|v| v["name"].as_str().map(str::to_owned))
        .ok_or("No selected host output")?;
    let sink = graph
        .iter()
        .find(|n| props(n)["node.name"] == default && props(n)["media.class"] == "Audio/Sink")
        .ok_or("Selected output disappeared")?;
    let sink_id = numeric(&sink["id"]).ok_or("Missing output identity")?;
    for link in graph {
        if props(link)["argo.music.owner"] == owner && link["info"]["state"] == "error" {
            return Err("Owned Bluetooth route failed; cleanup required".into());
        }
        if numeric(&link["info"]["output-node-id"]) == Some(source_id)
            && props(link)["argo.music.owner"] != owner
        {
            return Err("A2DP receiver has an external route; stop it before Argo playback".into());
        }
    }
    let replace = graph.iter().any(|l| {
        props(l)["argo.music.owner"] == owner
            && numeric(&l["info"]["input-node-id"]) != Some(sink_id)
    });
    let outputs: Vec<_> = graph
        .iter()
        .filter(|p| {
            numeric(&props(p)["node.id"]) == Some(source_id)
                && props(p)["port.direction"] == "out"
                && props(p)["audio.channel"].is_string()
        })
        .collect();
    if outputs.is_empty() || outputs.len() > 2 {
        return Err("Waiting for mono/stereo A2DP ports".into());
    }
    let mut links = Vec::new();
    for output in outputs {
        let input = graph
            .iter()
            .find(|p| {
                numeric(&props(p)["node.id"]) == Some(sink_id)
                    && props(p)["port.direction"] == "in"
                    && props(p)["audio.channel"] == props(output)["audio.channel"]
            })
            .ok_or("Host output has no matching audio channel")?;
        let output = numeric(&output["id"]).ok_or("Missing output port")?;
        let input = numeric(&input["id"]).ok_or("Missing input port")?;
        if replace
            || !graph.iter().any(|l| {
                numeric(&l["info"]["output-port-id"]) == Some(output)
                    && numeric(&l["info"]["input-port-id"]) == Some(input)
            })
        {
            links.push((output, input));
        }
    }
    Ok(RoutePlan {
        source: source_id,
        replace,
        links,
    })
}
struct Music {
    bus: zbus::Connection,
    host: HostControl,
    projection: watch::Sender<ProjectionRuntimeSnapshot>,
    snapshot: Snapshot,
    player: String,
    blocked: BTreeSet<String>,
    intent: bool,
    attempts: u8,
    next: tokio::time::Instant,
    owner: String,
    gain: f64,
    links: Vec<tokio::process::Child>,
    next_session: u64,
}
impl Music {
    fn publish(&self) {
        self.host
            .connectivity
            .state
            .send_modify(|s| s.music = Some(self.snapshot.clone()));
    }
    async fn silence(&mut self) -> Result<(), String> {
        let result = self.stop_links().await;
        self.snapshot.cleanup_error = result.as_ref().err().cloned();
        if result.is_err() {
            self.intent = false;
            if self.snapshot.selected == "bluetooth" {
                self.snapshot.selected.clear();
            }
        }
        result
    }
    async fn stop_links(&mut self) -> Result<(), String> {
        // Each non-lingering link belongs to one bounded child client. Its exit
        // releases the link, including daemon parent death via setpriv/prctl.
        let mut retained = Vec::new();
        for mut child in self.links.drain(..) {
            let _ = child.start_kill();
            if !matches!(
                tokio::time::timeout(Duration::from_secs(3), child.wait()).await,
                Ok(Ok(_))
            ) {
                retained.push(child);
            }
        }
        self.links = retained;
        if !self.links.is_empty() {
            return Err("Bluetooth link client cleanup uncertain".into());
        }
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if !graph()
                    .await?
                    .iter()
                    .any(|l| props(l)["argo.music.owner"] == self.owner)
                {
                    return Ok::<_, String>(());
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .map_err(|_| "Bluetooth link retirement not confirmed".to_string())?
    }
    async fn gate_projection(&self, audible: bool) -> Result<(), String> {
        let generation = self.host.entertainment.borrow().0 + 1;
        self.host.entertainment.send_replace((generation, audible));
        let mut acknowledged = self.host.entertainment_ack.subscribe();
        let mut state = self.projection.subscribe();
        tokio::time::timeout(Duration::from_secs(6), async {
            loop {
                if *acknowledged.borrow() >= generation || state.borrow().session.is_none() {
                    return Ok(());
                }
                tokio::select! { _=acknowledged.changed()=>{}, _=state.changed()=>{} }
            }
        })
        .await
        .map_err(|_| {
            "Projection media gate acknowledgement timed out; Bluetooth remains silent".to_string()
        })?
    }
    async fn route(&mut self) -> Result<(), String> {
        let (_, address) = self
            .snapshot
            .device
            .split_once('/')
            .ok_or("Select a phone")?;
        let address = address.to_owned();
        let current_graph = graph().await?;
        let mut plan = route_plan(&current_graph, &address, &self.owner)?;
        let mut alive = Vec::new();
        for mut child in self.links.drain(..) {
            if child.try_wait().map_err(|e| e.to_string())?.is_none() {
                alive.push(child);
            }
        }
        self.links = alive;
        if plan.replace || self.links.len() + plan.links.len() > 2 {
            self.silence().await?;
            plan = route_plan(&graph().await?, &address, &self.owner)?;
        }
        command(
            "wpctl",
            &[
                "set-volume".into(),
                plan.source.to_string(),
                self.gain.to_string(),
            ],
        )
        .await?;
        for (output, input) in plan.links {
            if self.links.len() >= 2 {
                return Err("Bluetooth link client bound reached; cleanup required".into());
            }
            let child = tokio::process::Command::new("/usr/bin/setpriv")
                .args([
                    "--pdeathsig",
                    "TERM",
                    "pw-link",
                    "-m",
                    "-p",
                    &json!({"argo.music.owner":self.owner}).to_string(),
                    &output.to_string(),
                    &input.to_string(),
                ])
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .kill_on_drop(true)
                .spawn()
                .map_err(|e| e.to_string())?;
            self.links.push(child);
            tokio::time::timeout(Duration::from_secs(3), async {
                loop {
                    if graph().await?.iter().any(|l| {
                        props(l)["argo.music.owner"] == self.owner
                            && numeric(&l["info"]["output-port-id"]) == Some(output)
                            && numeric(&l["info"]["input-port-id"]) == Some(input)
                            && matches!(l["info"]["state"].as_str(), Some("active" | "paused"))
                    }) {
                        return Ok::<_, String>(());
                    }
                    if self
                        .links
                        .last_mut()
                        .unwrap()
                        .try_wait()
                        .map_err(|e| e.to_string())?
                        .is_some()
                    {
                        return Err("PipeWire link client rejected the route".into());
                    }
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            })
            .await
            .map_err(|_| "PipeWire link was not established before deadline")??;
        }
        Ok(())
    }
    async fn player_command(&mut self, target: &str, action: &str) -> Result<(), String> {
        if !self
            .snapshot
            .source
            .as_ref()
            .is_some_and(|s| s.id == target && s.commands.iter().any(|c| c == action))
        {
            return Err("Stale source or unsupported playback command".into());
        }
        let method = match action {
            "play" => "Play",
            "pause" => "Pause",
            "previous" => "Previous",
            "next" => "Next",
            _ => return Err("Unsupported playback command".into()),
        };
        let device_path = self
            .player
            .rsplit_once('/')
            .ok_or("Player path disappeared")?
            .0;
        let control = proxy(&self.bus, device_path, "org.bluez.MediaControl1").await?;
        if !control
            .get_property::<bool>("Connected")
            .await
            .unwrap_or(false)
            || control
                .get_property::<zbus::zvariant::OwnedObjectPath>("Player")
                .await
                .map_err(|e| e.to_string())?
                .as_str()
                != self.player
        {
            return Err("Player changed or disconnected".into());
        }
        let player = proxy(&self.bus, &self.player, "org.bluez.MediaPlayer1").await?;
        let result: Result<(), zbus::Error> = player.call(method, &()).await;
        if let Err(error) = result {
            if matches!(&error,zbus::Error::MethodError(name,_,_) if name.as_str()=="org.bluez.Error.NotSupported")
            {
                self.blocked.insert(action.to_owned());
            }
            return Err(error.to_string());
        }
        Ok(())
    }
    async fn refresh(&mut self, bt: &Bluetooth) -> Result<(), String> {
        if self.snapshot.device.is_empty() || !self.intent {
            return Ok(());
        }
        let device = bt.device(&self.snapshot.device)?;
        if !device.is_paired().await.map_err(|e| e.to_string())? {
            self.intent = false;
            return Err("Music pairing revoked".into());
        }
        let (adapter, address) = self
            .snapshot
            .device
            .split_once('/')
            .ok_or("Invalid phone reference")?;
        let path = format!("/org/bluez/{adapter}/dev_{}", address.replace(':', "_"));
        let control = proxy(&self.bus, &path, "org.bluez.MediaControl1").await?;
        let connected = control
            .get_property::<bool>("Connected")
            .await
            .unwrap_or(false);
        if !connected {
            self.snapshot.source = None;
            self.player.clear();
            self.silence().await?;
            if self.intent && self.attempts < 3 && tokio::time::Instant::now() >= self.next {
                self.attempts += 1;
                self.snapshot.phase = "connecting".into();
                self.snapshot.detail = format!("Bluetooth music attempt {} of 3", self.attempts);
                self.publish();
                self.next = tokio::time::Instant::now()
                    + Duration::from_secs(2u64.pow(u32::from(self.attempts)));
                let connected = tokio::time::timeout(
                    Duration::from_secs(8),
                    device.connect_profile(&AUDIO_SOURCE.parse().unwrap()),
                )
                .await
                .map_err(|_| "Bluetooth music connection timed out")?;
                if let Err(error) = connected {
                    use bluer::ErrorKind as K;
                    if !matches!(
                        error.kind,
                        K::ConnectionAttemptFailed | K::NotReady | K::Failed | K::InProgress
                    ) {
                        self.intent = false;
                    }
                    return Err(error.to_string());
                }
            }
            return Err(if self.attempts >= 3 {
                "Bluetooth music retry limit reached; press Connect"
            } else {
                "Waiting for selected phone's Bluetooth audio/player"
            }
            .into());
        }
        if !self.intent {
            return Ok(());
        }
        let player_path = control
            .get_property::<zbus::zvariant::OwnedObjectPath>("Player")
            .await
            .map_err(|_| "Phone has no AVRCP player")?
            .to_string();
        if !player_path.starts_with(&(path + "/")) {
            return Err("Player does not belong to selected phone".into());
        }
        let player = proxy(&self.bus, &player_path, "org.bluez.MediaPlayer1").await?;
        let track = player
            .get_property::<std::collections::HashMap<String, OwnedValue>>("Track")
            .await
            .unwrap_or_default();
        let text = |key: &str| {
            track
                .get(key)
                .and_then(|v| <&str>::try_from(v).ok())
                .map(|s| s.chars().take(512).collect::<String>())
        };
        let number = |key: &str| {
            track
                .get(key)
                .and_then(|v| u32::try_from(v).ok())
                .filter(|v| *v != u32::MAX)
        };
        let changed = self.player != player_path || self.snapshot.source.is_none();
        if changed {
            self.blocked.clear();
        }
        let id = if changed {
            self.next_session += 1;
            format!("bluetooth:{}:{}", self.owner, self.next_session)
        } else {
            self.snapshot.source.as_ref().unwrap().id.clone()
        };
        let revision = self.snapshot.source.as_ref().map_or(1, |s| s.revision + 1);
        self.snapshot.source = Some(Source {
            id: id.clone(),
            session_id: id,
            device_id: self.snapshot.device.clone(),
            revision,
            updated_at_ms: now(),
            name: device
                .alias()
                .await
                .unwrap_or_else(|_| "Bluetooth phone".into()),
            title: text("Title"),
            artist: text("Artist"),
            album: text("Album"),
            duration_ms: number("Duration"),
            position_ms: player
                .get_property::<u32>("Position")
                .await
                .ok()
                .filter(|v| *v != u32::MAX),
            playback: player.get_property::<String>("Status").await.ok(),
            commands: ["play", "pause", "previous", "next"]
                .iter()
                .filter(|c| !self.blocked.contains(**c))
                .map(|s| s.to_string())
                .collect(),
        });
        self.player = player_path;
        if self.snapshot.selected == "bluetooth" {
            let address = self
                .snapshot
                .device
                .split_once('/')
                .ok_or("Missing music phone")?
                .1;
            if !graph().await?.iter().any(|n| receiver(n, address)) {
                self.silence().await?;
                self.snapshot.phase = "waiting-audio".into();
                self.snapshot.detail = "Player connected; waiting for phone A2DP audio".into();
                return Ok(());
            }
            if let Err(error) = self.route().await {
                self.snapshot.selected.clear();
                self.silence().await?;
                self.snapshot.phase = "routing-failed".into();
                self.snapshot.detail = error;
                return Ok(());
            }
        }
        self.snapshot.phase = "connected".into();
        self.snapshot.detail = "Bluetooth music connected".into();
        Ok(())
    }
    async fn request(&mut self, r: Request, bt: &Bluetooth) -> Result<(), String> {
        match r.action.as_str() {
            "musicGain" => {
                let (id, value) = r
                    .target
                    .split_once('|')
                    .ok_or("Invalid music gain target")?;
                let gain: f64 = value.parse().map_err(|_| "Invalid music gain")?;
                if !gain.is_finite()
                    || !(0.0..=1.0).contains(&gain)
                    || !self.snapshot.source.as_ref().is_some_and(|s| s.id == id)
                {
                    return Err("Stale source or invalid gain".into());
                }
                self.gain = gain;
                if self.snapshot.selected == "bluetooth" {
                    self.route().await?;
                }
            }
            "musicConnect" => {
                let config = std::path::PathBuf::from(
                    std::env::var_os("HOME").ok_or("Desktop HOME unavailable")?,
                )
                .join(".config/wireplumber/wireplumber.conf.d/80-argo-a2dp.conf");
                if !config.is_file() {
                    return Err(
                        "Install Bluetooth routing opt-in and log out/in before Connect music"
                            .into(),
                    );
                }
                self.gain = 0.0;
                if !bt
                    .device(&r.target)?
                    .is_paired()
                    .await
                    .map_err(|e| e.to_string())?
                {
                    return Err("Pair the music phone first".into());
                }
                self.silence().await?;
                self.snapshot.source = None;
                self.player.clear();
                if self.snapshot.selected == "bluetooth" {
                    self.snapshot.selected.clear();
                }
                self.snapshot.device = r.target;
                self.intent = true;
                self.attempts = 0;
                self.next = tokio::time::Instant::now();
            }
            "musicDisconnect" => {
                self.intent = false;
                self.snapshot.source = None;
                self.player.clear();
                self.snapshot.phase = "disconnecting".into();
                if self.snapshot.selected == "bluetooth" {
                    self.snapshot.selected.clear();
                }
                self.silence().await?;
                if !self.snapshot.device.is_empty() {
                    let _ = bt
                        .device(&self.snapshot.device)?
                        .disconnect_profile(&AUDIO_SOURCE.parse().unwrap())
                        .await;
                }
                self.snapshot.source = None;
                self.player.clear();
                self.snapshot.phase = "disconnected".into();
                self.snapshot.detail = "Music stopped; Connect starts a new attempt".into();
            }
            "musicSelect" => {
                if r.target == "projection" && self.snapshot.selected == "projection" {
                    return Ok(());
                }
                if self.snapshot.selected == "bluetooth"
                    && self
                        .snapshot
                        .source
                        .as_ref()
                        .is_some_and(|s| s.id == r.target)
                {
                    return Ok(());
                }
                if r.target != "projection"
                    && !self
                        .snapshot
                        .source
                        .as_ref()
                        .is_some_and(|s| s.id == r.target)
                {
                    return Err("Source disappeared before selection".into());
                }
                self.snapshot.selected.clear();
                // Break before make. If pause fails, removing our links is decisive.
                if let Some(source) = self.snapshot.source.clone() {
                    let _ = self.player_command(&source.id, "pause").await;
                }
                self.silence().await?;
                if r.target == "projection" {
                    self.gate_projection(true).await?;
                    self.snapshot.selected = "projection".into();
                } else {
                    self.gate_projection(false).await?;
                    self.gain = 0.0;
                    // Some phones instantiate their receiver only on first Play.
                    let address = self
                        .snapshot
                        .device
                        .split_once('/')
                        .ok_or("Select a phone")?
                        .1
                        .to_owned();
                    if !graph().await?.iter().any(|n| receiver(n, &address)) {
                        self.player_command(&r.target, "play").await?;
                        tokio::time::timeout(Duration::from_secs(4), async {
                            loop {
                                if graph().await?.iter().any(|n| receiver(n, &address)) {
                                    return Ok::<_, String>(());
                                }
                                tokio::time::sleep(Duration::from_millis(100)).await;
                            }
                        })
                        .await
                        .map_err(
                            |_| "Waiting for phone A2DP receiver; start music on the phone",
                        )??;
                    }
                    self.route().await?;
                    self.snapshot.selected = "bluetooth".into();
                }
            }
            "musicPlay" | "musicPause" | "musicPrevious" | "musicNext" => {
                let action = r.action.trim_start_matches("music").to_ascii_lowercase();
                if self.snapshot.selected != "bluetooth" {
                    return Err("Select Bluetooth music before playback control".into());
                }
                self.player_command(&r.target, &action).await?;
            }
            _ => return Err("Unsupported music operation".into()),
        }
        Ok(())
    }
}
pub async fn run(
    bt: Arc<Bluetooth>,
    host: HostControl,
    projection: watch::Sender<ProjectionRuntimeSnapshot>,
    mut requests: mpsc::Receiver<Request>,
    mut shutdown: watch::Receiver<bool>,
    mut cancel: watch::Receiver<u64>,
) {
    let Ok(bus) = zbus::Connection::system().await else {
        return;
    };
    let mut music = Music {
        bus,
        host,
        projection,
        snapshot: Snapshot {
            selected: "projection".into(),
            phase: "disconnected".into(),
            ..Default::default()
        },
        player: String::new(),
        blocked: BTreeSet::new(),
        intent: false,
        attempts: 0,
        next: tokio::time::Instant::now(),
        gain: 0.0,
        links: Vec::new(),
        next_session: 0,
        owner: format!("argo-music-{}-{}", std::process::id(), now()),
    };
    let event_bus = music.bus.clone();
    let manager = zbus::fdo::ObjectManagerProxy::builder(&event_bus)
        .destination("org.bluez")
        .expect("static service")
        .path("/")
        .expect("static path")
        .build()
        .await;
    let Ok(manager) = manager else { return };
    let Ok(mut removed) = manager.receive_interfaces_removed().await else {
        return;
    };
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    music.publish();
    loop {
        tokio::select! { biased;
            _=shutdown.changed()=>break,
            _=cancel.changed()=>{
                music.intent=false; music.snapshot.source=None; music.player.clear();
                music.snapshot.phase="disconnected".into(); music.snapshot.detail="Music stopped; Connect starts a new attempt".into();
                if music.snapshot.selected=="bluetooth" {music.snapshot.selected.clear();}
                if let Err(error)=music.silence().await {music.snapshot.error=Some(error);}
                music.publish();
            },
            Some(event)=removed.next()=>{
                if let Ok(args)=event.args() && !music.player.is_empty() && (args.object_path().as_str()==music.player || music.player.starts_with(&format!("{}/",args.object_path()))) {
                    music.snapshot.source=None; music.player.clear();
                    if let Err(error)=music.silence().await {music.intent=false;music.snapshot.error=Some(error);}
                    music.snapshot.phase="waiting".into(); music.snapshot.detail="Bluetooth player disappeared".into();music.publish();
                }
            },
            r=requests.recv()=>{
                let Some(r)=r else {break}; let operation=r.prompt;
                let routing_action=matches!(r.action.as_str(), "musicSelect"|"musicConnect"|"musicDisconnect");
                if r.action!="musicDisconnect" && r.generation!=*cancel.borrow() {continue;}
                cancel.borrow_and_update();
                let result=tokio::select! { biased;
                    _=cancel.changed()=>{music.intent=false; Err("Music operation cancelled".into())},
                    _=shutdown.changed()=>break,
                    result=tokio::time::timeout(Duration::from_secs(15),music.request(r,&bt))=>result.unwrap_or_else(|_|Err("Music operation timed out; selection not confirmed".into()))
                };
                if result.is_err() && routing_action && music.snapshot.selected.is_empty() && music.silence().await.is_err() {music.intent=false;}
                if operation!=0 {music.snapshot.operation=operation;}
                music.snapshot.error=result.err(); music.publish();
            }
            _=tick.tick()=>{
                if let Err(error)=tokio::select! { biased;
                    _=cancel.changed()=>{music.intent=false; Err("Music connection cancelled".into())},
                    _=shutdown.changed()=>break,
                    result=tokio::time::timeout(Duration::from_secs(12),music.refresh(&bt))=>result.unwrap_or_else(|_|Err("Bluetooth music refresh timed out".into()))
                } {
                    music.snapshot.detail=error; music.snapshot.phase=if music.intent {"waiting"} else {"disconnected"}.into();
                    if let Err(error)=music.silence().await { music.intent=false; music.snapshot.error=Some(error); }
                    music.snapshot.source=None;
                    // A routing failure must not recreate links on every tick.
                    if music.snapshot.selected=="bluetooth" {music.snapshot.selected.clear();}
                }
                music.publish();
            }
        }
    }
    music.intent = false;
    if let Err(e) = music.silence().await {
        crate::daemon_log!(Warn, "bluetooth-music", "Owned route cleanup: {e}");
    }
    music
        .host
        .connectivity
        .state
        .send_modify(|s| s.music = None);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn routing_reuses_owned_links_and_rejects_external_or_unmatched_routes() {
        let address = "00:11:22:33:44:55";
        let mut graph = vec![
            json!({"id":1,"info":{"props":{"factory.name":"api.bluez5.a2dp.source","api.bluez5.address":address,"node.autoconnect":false}}}),
            json!({"id":2,"info":{"props":{"node.name":"selected-output","media.class":"Audio/Sink"}}}),
            json!({"type":"PipeWire:Interface:Metadata","metadata":[{"key":"default.audio.sink","value":{"name":"selected-output"}}]}),
            json!({"id":3,"info":{"props":{"node.id":1,"port.direction":"out","audio.channel":"FL"}}}),
            json!({"id":4,"info":{"props":{"node.id":2,"port.direction":"in","audio.channel":"FL"}}}),
        ];
        assert_eq!(
            route_plan(&graph, address, "test").unwrap().links,
            vec![(3, 4)]
        );
        graph.push(json!({"info":{"output-node-id":1,"input-node-id":2,"output-port-id":3,"input-port-id":4,"props":{"argo.music.owner":"test"}}}));
        assert!(
            route_plan(&graph, address, "test")
                .unwrap()
                .links
                .is_empty()
        );
        graph.last_mut().unwrap()["info"]["props"]["argo.music.owner"] = json!("desktop");
        assert!(route_plan(&graph, address, "test").is_err());
        graph.pop();
        graph[4]["info"]["props"]["audio.channel"] = json!("FR");
        assert!(route_plan(&graph, address, "test").is_err());
        graph[0]["info"]["props"]["node.autoconnect"] = json!(true);
        assert!(route_plan(&graph, address, "test").is_err());
    }
    #[test]
    fn only_actual_selected_a2dp_receiver_matches() {
        let node = json!({"info":{"props":{"factory.name":"api.bluez5.a2dp.source","api.bluez5.address":"00:11:22:33:44:55"}}});
        assert!(receiver(&node, "00:11:22:33:44:55"));
        assert!(!receiver(&node, "00:11:22:33:44:56"));
        let mut call = node;
        call["info"]["props"]["factory.name"] = json!("api.bluez5.sco.source");
        assert!(!receiver(&call, "00:11:22:33:44:55"));
    }
}
