//! One connectivity worker; wireless bootstrap and projection consume shared
//! BlueZ state. A single semaphore arbitrates USB/Wi-Fi before resource setup.
use crate::connectivity::network::ApBand;
use crate::failure::{Failure, Kind};
use crate::{
    connectivity::{Request, bluetooth::Bluetooth, network::Network},
    daemon_state::ProjectionRuntimeSnapshot,
    host_control::HostControl,
};
use futures_util::StreamExt;
use std::{sync::Arc, time::Duration};
use tokio::{
    sync::{mpsc, watch},
    task::JoinHandle,
};
const UUID: &str = "4de17a00-52cb-11e6-bdf4-0800200c9a66";
struct Attempt {
    peer: String,
    cancel: watch::Sender<bool>,
    task: JoinHandle<()>,
}
impl Attempt {
    async fn stop(self) {
        self.cancel.send_replace(true);
        let _ = self.task.await;
    }
}

pub async fn run(
    host: HostControl,
    state: watch::Sender<ProjectionRuntimeSnapshot>,
    mut requests: mpsc::Receiver<Request>,
    mut shutdown: watch::Receiver<bool>,
) {
    let c = host.connectivity.clone();
    let bt = match Bluetooth::open(c.clone()).await {
        Ok(v) => Arc::new(v),
        Err(e) => {
            c.progress("unavailable", format!("BlueZ: {e}"));
            return;
        }
    };
    // NetworkManager availability must not govern BlueZ pairing or music.
    let network = Network::open().await.ok();
    let (music_requests, music_rx) = mpsc::channel(16);
    let music_cancel = c.music_cancel.clone();
    let music_cancelled = music_cancel.subscribe();
    let music_task = tokio::spawn(crate::connectivity::music::run(
        bt.clone(),
        host.clone(),
        state.clone(),
        music_rx,
        shutdown.clone(),
        music_cancelled,
    ));
    let (call_requests, call_rx) = mpsc::channel(16);
    let call_task = tokio::spawn(crate::connectivity::calls::run(
        bt.clone(),
        host.clone(),
        call_rx,
        shutdown.clone(),
    ));
    let inventory = async {
        loop {
            if let Some(network) = &network {
                let band = c.state.borrow().band;
                let radios = async {
                    let mut radios = network.interfaces().await?;
                    for radio in &mut radios {
                        let checked = network.eligible(&radio.id, band).await;
                        radio.usable = Some(checked.is_ok());
                        radio.detail = checked.err();
                    }
                    Ok::<_, String>(radios)
                };
                match tokio::time::timeout(Duration::from_secs(8), radios).await {
                    Ok(Ok(radios)) => {
                        c.state.send_modify(|s| {
                            s.update_networks(radios, *host.projection_enabled.borrow());
                        });
                    }
                    _ => {
                        c.state.send_modify(|s| {
                            s.networks.clear();
                            s.wireless_available = Some(false);
                            if !s.wifi_connected {
                                s.enabled = false;
                            }
                            s.detail =
                                "NetworkManager unavailable; Bluetooth remains available".into();
                        });
                    }
                }
            }
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    };
    tokio::pin!(inventory);
    let mut activity: Option<Attempt> = None;
    let mut discovery: Option<Attempt> = None;
    let mut pairing: Option<JoinHandle<()>> = None;
    let mut commands = host.commands.subscribe();
    let mut client_closed = c.client_closed.subscribe();
    let mut tick = tokio::time::interval(Duration::from_secs(2));
    loop {
        tokio::select! {
            biased;
            _ = shutdown.changed() => break,
            _ = &mut inventory => {},
            _ = client_closed.changed() => {
                host.projection_enabled.send_replace(false);
                c.calls_cancel.send_modify(|g|*g+=1);
                let _=call_requests.try_send(Request{generation:0,action:"callsDisconnect".into(),target:String::new(),accept:false,prompt:0});
                music_cancel.send_modify(|v|*v+=1);
                let _ = music_requests.try_send(Request { generation:0, action:"musicDisconnect".into(), target:String::new(), accept:false, prompt:0 });
                while requests.try_recv().is_ok() {}
                if let Some(a) = activity.take() { a.stop().await; }
                if let Some(d) = discovery.take() { d.stop().await; }
                if let Some(p) = pairing.take() { p.abort(); let _ = p.await; }
                c.state.send_modify(|s| { s.enabled = false; s.wireless_disabled=true; s.prompt = None; });
                c.progress("disabled", "Application disconnected; wireless stopped");
            },
            Ok(crate::host_control::Command::Disconnect(id)) = commands.recv() => {
                if state.borrow().session.as_ref().is_some_and(|s| s.id == id && id.starts_with("aa-wifi:")) {
                    if let Some(a) = activity.take() { a.stop().await; }
                    c.progress("disconnected", "Disconnected. Press Connect for a new attempt.");
                }
            }
            _ = tick.tick() => {
                if let Err(e) = tokio::time::timeout(Duration::from_secs(4), bt.refresh()).await.unwrap_or_else(|_| Err("Bluetooth refresh timed out".into())) {
                    if let Some(a) = activity.take() { a.stop().await; }
                    c.progress("unavailable", format!("{e}; restart daemon after Bluetooth recovery"));
                    break;
                }
                tick.reset();
                if activity.as_ref().is_some_and(|a| a.task.is_finished()) && let Some(a) = activity.take() { let _ = a.task.await; }
                if pairing.as_ref().is_some_and(|p| p.is_finished()) && let Some(p) = pairing.take() { let _ = p.await; }
                if discovery.as_ref().is_some_and(|d| d.task.is_finished()) && let Some(d) = discovery.take() { let _ = d.task.await; }
            }
            Some(r) = requests.recv() => {
                if c.stopping.load(std::sync::atomic::Ordering::SeqCst) && r.action!="stopAll" {continue;}

                if r.action.starts_with("calls") {
                    if call_requests.try_send(r).is_err() {c.state.send_modify(|s|s.detail="Call controller busy".into());}
                    continue;
                }
                if r.action=="microphone" || r.action=="microphoneMute" {
                    let result=if r.action=="microphone" {host.voice.select(&r.target)}else {host.voice.state.send_modify(|s|s.muted=r.accept);Ok(())};
                    if let Err(e)=result {host.voice.state.send_modify(|s|s.detail=e);}
                    c.state.send_modify(|s|s.voice=Some(host.voice.state.borrow().clone()));continue;
                }
                if r.action=="stopAll" {
                    let mut owned_phones=vec![];
                    if let Some(a)=&activity {owned_phones.push(a.peer.clone());}
                    {let s=c.state.borrow();if let Some(m)=&s.music {owned_phones.push(m.device.clone());}
                    if let Some(calls)=&s.calls {owned_phones.push(calls.device.clone());}}
                    owned_phones.retain(|s|!s.is_empty());owned_phones.sort();owned_phones.dedup();
                    host.projection_enabled.send_replace(false);
                    c.state.send_modify(|s|{s.enabled=false;s.wireless_disabled=true;s.stopped=None;});
                    c.progress("cleanup","Stopping projection, Bluetooth and audio before application exit");
                    if let Some(a)=activity.take(){a.stop().await;}
                    if let Some(d)=discovery.take(){d.stop().await;}
                    if let Some(p)=pairing.take(){p.abort();let _=p.await;}
                    bt.respond(c.state.borrow().prompt.as_ref().map_or(0,|p|p.id),false);
                    let stop = async {
                        music_requests.send(Request{generation:0,action:"musicDisconnect".into(),target:String::new(),accept:false,prompt:r.prompt}).await.map_err(|_|"Music controller unavailable")?;
                        call_requests.send(Request{generation:0,action:"callsDisconnect".into(),target:String::new(),accept:false,prompt:r.prompt}).await.map_err(|_|"Call controller unavailable")?;
                        let mut changes=c.state.subscribe();
                        loop {
                            let snapshot=changes.borrow_and_update().clone();
                            let music=snapshot.music.as_ref().filter(|m|m.operation==r.prompt);
                            let calls=snapshot.calls.as_ref().filter(|m|m.operation==r.prompt);
                            if let Some(error)=music.and_then(|m|m.error.as_ref()).or_else(||calls.and_then(|m|m.error.as_ref())) {return Err(error.clone());}
                            if !snapshot.cleanup_error.is_empty(){return Err(snapshot.cleanup_error);}
                            if music.is_some() && calls.is_some(){break;}
                            changes.changed().await.map_err(|_|"Connectivity closed")?;
                        }
                        // USB releases this only after native media cleanup finishes.
                        let lease=host.session_lease.acquire().await.map_err(|_|"Session owner unavailable")?;
                        // Only phones used by Argo; unrelated keyboards/headsets retain their links.
                        for id in owned_phones {let device=bt.device(&id)?;if device.is_connected().await.map_err(|e|e.to_string())? {device.disconnect().await.map_err(|e|e.to_string())?;}}
                        drop(lease);Ok::<_,String>(())
                    }.await;
                    match stop {Ok(())=>{c.state.send_modify(|s|s.stopped=Some(r.prompt));c.progress("disabled","Connections stopped; application may exit");},Err(e)=>c.state.send_modify(|s|s.cleanup_error=e)}
                    continue;
                }
                if r.action=="forget" {let _=call_requests.try_send(Request{generation:0,action:"callsDisconnect".into(),target:String::new(),accept:false,prompt:0});}

                if r.action.starts_with("music") {
                    if music_requests.try_send(r).is_err() { c.state.send_modify(|s|s.detail="Bluetooth music controller busy".into()); }
                    continue;
                }
                if r.action=="forget" && c.state.borrow().music.as_ref().is_some_and(|m|m.device==r.target) {
                    let _=music_requests.try_send(Request{generation:0, action:"musicDisconnect".into(),target:r.target.clone(),accept:false,prompt:0});
                }
                let result = process_request(r, &bt, &host, &state, &mut activity, &mut discovery, &mut pairing).await;
                if let Err(e) = result { c.state.send_modify(|s| s.detail = e); }
            }
        }
    }
    if let Some(a) = activity {
        a.stop().await;
    }
    if let Some(d) = discovery {
        d.stop().await;
    }
    if let Some(p) = pairing {
        p.abort();
        let _ = p.await;
    }
    drop(call_requests);
    if call_task.await.is_err() {
        c.state
            .send_modify(|s| s.cleanup_error = "Call worker failed; cleanup unconfirmed".into());
    }
    drop(music_requests);
    music_cancel.send_modify(|v| *v += 1);
    if music_task.await.is_err() {
        c.state
            .send_modify(|s| s.cleanup_error = "Music worker failed; cleanup unconfirmed".into());
    }
    bt.respond(c.state.borrow().prompt.as_ref().map_or(0, |p| p.id), false);
}

#[allow(clippy::too_many_arguments)] // One loop owns these three bounded activities.
async fn process_request(
    r: Request,
    bt: &Arc<Bluetooth>,
    host: &HostControl,
    state: &watch::Sender<ProjectionRuntimeSnapshot>,
    activity: &mut Option<Attempt>,
    discovery: &mut Option<Attempt>,
    pairing: &mut Option<JoinHandle<()>>,
) -> Result<(), String> {
    let c = &host.connectivity;

    match r.action.as_str() {
        "projectionEnabled" => {
            if !r.accept && state.borrow().session.is_some() {
                return Err("Disconnect projection before disabling it".into());
            }
            host.projection_enabled.send_replace(r.accept);
            c.state.send_modify(|s| {
                s.wireless_disabled = false;
                s.enabled = r.accept && s.wireless_available == Some(true);
            });
        }
        "confirm" => bt.respond(r.prompt, r.accept),
        "adapter" => {
            let radio = c
                .state
                .borrow()
                .adapters
                .iter()
                .find(|a| a.id == r.target || a.address.as_deref() == Some(r.target.as_str()))
                .cloned();
            let radio = match radio {
                Some(radio) => radio,
                None if r.target.parse::<bluer::Address>().is_ok() => crate::connectivity::Radio {
                    id: String::new(),
                    name: String::new(),
                    address: Some(r.target.clone()),
                    usable: None,
                    detail: None,
                },
                None => return Err("Selected Bluetooth adapter is unavailable".into()),
            };
            if c.state.borrow().adapter == radio.id
                && c.state.borrow().adapter_address == radio.address.clone().unwrap_or_default()
            {
                return Ok(());
            }
            if c.state
                .borrow()
                .calls
                .as_ref()
                .is_some_and(|c| !c.device.is_empty())
                || activity.is_some()
                || discovery.is_some()
                || pairing.is_some()
                || c.state.borrow().music.as_ref().is_some_and(|m| {
                    m.busy
                        || (!matches!(m.phase.as_str(), "disconnected" | "idle")
                            && !m.device.is_empty())
                })
            {
                return Err("Stop discovery and disconnect wireless AA/music before changing the shared Bluetooth adapter".into());
            }
            c.state.send_modify(|s| {
                s.adapter = radio.id.clone();
                s.adapter_address = radio.address.clone().unwrap_or_default();
                if !s.selected.starts_with(&format!("{}/", radio.id)) {
                    s.selected.clear();
                }
                s.detail = if radio.id.is_empty() {
                    "Preferred Bluetooth adapter is unavailable; no fallback radio selected"
                } else {
                    "Bluetooth adapter selected for pairing, wireless AA and music"
                }
                .into();
            });
        }
        "interface" | "select" | "band" => {
            let band = if r.action == "band" {
                Some(ApBand::parse(&r.target)?)
            } else {
                None
            };
            if r.action == "select" {
                c.state.borrow().require_selected_adapter(&r.target)?;
            }
            if r.action == "select"
                && !bt
                    .device(&r.target)?
                    .is_paired()
                    .await
                    .map_err(|e| e.to_string())?
            {
                return Err("Pair this device before selecting projection".into());
            }
            c.state.send_modify(|s| match r.action.as_str() {
                "interface" => s.interface = r.target.clone(),
                "band" => s.band = band.expect("validated band"),
                _ => s.selected = r.target.clone(),
            });
            if activity.is_some() {
                c.state.send_modify(|s| s.detail = "Selection saved for the next connection; current session retains its settings".into());
            }
        }
        "discover" => {
            if let Some(d) = discovery.take() {
                d.stop().await;
            }
            if r.accept {
                let adapter = bt
                    .session
                    .adapter(&c.state.borrow().adapter)
                    .map_err(|e| e.to_string())?;
                if !adapter.is_powered().await.map_err(|e| e.to_string())? {
                    return Err("Bluetooth adapter is off; enable it in desktop settings".into());
                }
                let (cancel, mut cancelled) = watch::channel(false);
                let ctl = c.clone();
                let task = tokio::spawn(async move {
                    let result = async {
                                        let stream = adapter.discover_devices().await.map_err(|e| e.to_string())?;
                                        futures_util::pin_mut!(stream);
                                        ctl.state.send_modify(|s| s.discovering = true);
                                        let deadline = tokio::time::sleep(Duration::from_secs(60)); tokio::pin!(deadline);
                                        loop { tokio::select! { _ = &mut deadline => break, _ = cancelled.changed() => break, event = stream.next() => if event.is_none() { break; } } }
                                        Ok::<_, String>(())
                                    }.await;
                    ctl.state.send_modify(|s| s.discovering = false);
                    if let Err(e) = result {
                        ctl.progress("failed", e);
                    }
                });
                *discovery = Some(Attempt {
                    peer: String::new(),
                    cancel,
                    task,
                });
            }
        }
        "pair" => {
            c.state.borrow().require_selected_adapter(&r.target)?;
            if !c.state.borrow().discovering {
                return Err("Start the discovery window first".into());
            }
            if pairing.is_some() {
                return Err("A pairing request is already in progress".into());
            }
            let device = bt.device(&r.target)?;
            let ctl = c.clone();
            *pairing = Some(tokio::spawn(async move {
                let result = tokio::time::timeout(Duration::from_secs(45), device.pair()).await;
                match result {
                    Ok(Ok(())) => ctl.progress(
                        "paired",
                        "Bluetooth paired; select this phone for projection",
                    ),
                    _ => {
                        ctl.progress(
                            "failed",
                            "Pairing rejected, cancelled or timed out. Check both screens.",
                        );
                    }
                }
            }));
        }
        "enable" => {
            if r.accept && c.state.borrow().wireless_available != Some(true) {
                return Err("No viable projection Wi-Fi interface/channel selected; inspect the Wi-Fi controls".into());
            }
            c.state.send_modify(|s| {
                s.enabled = r.accept;
                s.wireless_disabled = !r.accept;
            });
            if !r.accept {
                if let Some(a) = activity.take() {
                    a.stop().await;
                }
                c.progress(
                    "disabled",
                    "Wireless disabled; wired projection remains available",
                );
            } else {
                c.progress("idle", "Wireless enabled. Press Connect to authorize AP creation and this phone's bootstrap.");
            }
        }
        "disconnect" | "forget" => {
            if let Some(a) = activity.take() {
                a.stop().await;
            }
            if r.action == "forget" {
                let device = bt.device(&r.target)?;
                let (adapter, _) = r.target.split_once('/').ok_or("Invalid device reference")?;
                bt.session
                    .adapter(adapter)
                    .map_err(|e| e.to_string())?
                    .remove_device(device.address())
                    .await
                    .map_err(|e| e.to_string())?;
                c.state.send_modify(|s| {
                    if s.selected == r.target {
                        s.selected.clear();
                    }
                });
                tokio::time::timeout(Duration::from_secs(8), async {
                    Network::open().await?.forget_credentials(&r.target).await
                })
                .await
                .map_err(|_| "Bond removed; AP credential removal timed out".to_string())??;
            }
            c.progress(
                "disconnected",
                "Reconnect stopped. Press Connect for a new attempt.",
            );
        }
        "connect" => {
            if !*host.projection_enabled.borrow() {
                return Err("Projection is disabled; Bluetooth music remains available".into());
            }

            if activity.is_some() {
                return Err("A connection attempt/session already owns wireless".into());
            }
            let config = c.state.borrow().clone();
            if !config.enabled {
                return Err("Enable wireless first".into());
            }
            if host.readiness != 0 {
                return Err(
                    "Projection identity/native engine is not ready; pairing remains available"
                        .into(),
                );
            }
            config.require_selected_adapter(&config.selected)?;
            let device = bt.device(&config.selected)?;
            if !device.is_paired().await.map_err(|e| e.to_string())? {
                return Err("Selected phone is no longer paired".into());
            }
            let permit = host.session_lease.clone().try_acquire_owned().map_err(|_| "Another projection transport owns the session. Disconnect it explicitly first.")?;
            let (cancel, cancelled) = watch::channel(false);
            let (bt, host, state) = (bt.clone(), host.clone(), state.clone());
            let peer = config.selected.clone();
            let task = tokio::spawn(async move {
                // Hold across reconnect backoff; only this explicit attempt owns resources.
                let _permit = permit;
                reconnect(
                    bt,
                    host,
                    state,
                    config.selected,
                    config.interface,
                    config.band,
                    cancelled,
                )
                .await;
            });
            *activity = Some(Attempt { peer, cancel, task });
        }
        _ => return Err("Unsupported connectivity action".into()),
    }
    Ok(())
}

pub(crate) async fn run_until_end(
    readiness: &crate::readiness::Readiness,
    cancel: &mut watch::Receiver<bool>,
    operation: impl std::future::Future<Output = Result<(), Failure>>,
) -> Result<(), Failure> {
    if *cancel.borrow() {
        return Err(Failure::cancelled());
    }
    tokio::select! { biased;
        _ = cancel.changed() => Err(Failure::cancelled()),
        _ = readiness.setup_deadline() => Err(Failure::timeout("Wireless overall setup deadline expired")),
        result = operation => result,
    }
}

pub(crate) async fn retry_backoff(cancel: &mut watch::Receiver<bool>, attempt: u32) -> bool {
    if *cancel.borrow() {
        return false;
    }
    tokio::select! { biased; _ = cancel.changed() => false, _ = tokio::time::sleep(Duration::from_secs(2u64.pow(attempt))) => !*cancel.borrow() }
}
fn cleanup_failure(result: Result<(), Failure>, message: String) -> Failure {
    let mut failure = result
        .err()
        .unwrap_or_else(|| Failure::new(Kind::Cleanup, "Session ended; resource cleanup failed"));
    failure.cleanup = Some(message);
    failure
}

async fn reconnect(
    bt: Arc<Bluetooth>,
    host: HostControl,
    state: watch::Sender<ProjectionRuntimeSnapshot>,
    selected: String,
    interface: String,
    band: ApBand,
    mut cancel: watch::Receiver<bool>,
) {
    for attempt in 0..3 {
        if *cancel.borrow() {
            break;
        }
        if attempt > 0 {
            crate::daemon_log!(
                Info,
                "wireless",
                "Owned cleanup finished; retry {} of 3 after {} seconds backoff",
                attempt + 1,
                2u64.pow(attempt)
            );
            host.connectivity.progress(
                "backoff",
                format!(
                    "Retry {} of 3 in {} seconds",
                    attempt + 1,
                    2u64.pow(attempt)
                ),
            );
            if !retry_backoff(&mut cancel, attempt).await {
                break;
            }
        }
        let result = attempt_connection(
            &bt,
            &host,
            &state,
            &selected,
            &interface,
            band,
            cancel.clone(),
        )
        .await;
        match result {
            Ok(()) => {
                host.connectivity.progress(
                    "disconnected",
                    "Disconnected. Press Connect for a new attempt.",
                );
                break;
            }
            Err(e) => {
                let retry = retry_allowed(&e, *cancel.borrow(), attempt);
                crate::daemon_log!(
                    Warn,
                    "wireless",
                    "Connection attempt {} failed: {e}",
                    attempt + 1
                );
                host.connectivity.progress(
                    if e.kind == Kind::Cancelled && e.cleanup.is_none() {
                        "disconnected"
                    } else {
                        "failed"
                    },
                    e.to_string(),
                );
                if *cancel.borrow() || !retry {
                    break;
                }
            }
        }
    }
}
async fn attempt_connection(
    bt: &Bluetooth,
    host: &HostControl,
    state: &watch::Sender<ProjectionRuntimeSnapshot>,
    selected: &str,
    interface: &str,
    band: ApBand,
    mut cancel: watch::Receiver<bool>,
) -> Result<(), Failure> {
    if *cancel.borrow() {
        return Err(Failure::cancelled());
    }
    if !bt
        .device(selected)
        .map_err(Failure::configuration)?
        .is_paired()
        .await
        .map_err(Failure::configuration)?
    {
        return Err(Failure::new(
            Kind::Authorization,
            "Selected phone pairing revoked before setup",
        ));
    }
    let network = Network::open().await.map_err(Failure::configuration)?;
    let c = &host.connectivity;
    let started = tokio::time::Instant::now();
    crate::daemon_log!(
        Info,
        "wireless-timing",
        "Connect requested; checking network"
    );
    c.progress("preparing", "Checking projection network and permissions");
    let mut ap = tokio::select! {
        biased;
        _ = cancel.changed() => return Err(Failure::cancelled()),
        result = tokio::time::timeout(Duration::from_secs(10), network.prepare(interface, band, selected)) => result.map_err(|_| Failure::timeout("Wireless network preflight timed out"))?.map_err(Failure::configuration)?,
    };
    let readiness = crate::readiness::Readiness::default();
    let mut media = crate::native_playback::SessionMedia::default();
    let operation = async {
        crate::daemon_log!(
            Info,
            "wireless-timing",
            "Network preflight complete after {} ms",
            started.elapsed().as_millis()
        );
        network.activate(&mut ap).await?;
        crate::daemon_log!(
            Info,
            "wireless-timing",
            "AP/DHCP ready after {} ms",
            started.elapsed().as_millis()
        );
        crate::daemon_log!(
            Info,
            "wireless",
            "Projection AP and DHCP ready on {} MHz",
            ap.band.frequency(ap.channel)
        );
        c.state
            .send_modify(|s| s.ap_frequency_mhz = Some(ap.band.frequency(ap.channel)));
        c.progress("bootstrap", "AP and DHCP ready; waiting for selected phone's Bluetooth bootstrap. Check phone prompts / desktop HFP connection.");
        let socket = socket2::Socket::new(
            socket2::Domain::IPV4,
            socket2::Type::STREAM,
            Some(socket2::Protocol::TCP),
        )
        .map_err(Failure::configuration)?;
        socket
            .bind_device(Some(interface.as_bytes()))
            .map_err(|e| format!("Restrict TCP to projection interface: {e}"))
            .map_err(Failure::configuration)?;
        socket
            .set_nonblocking(true)
            .map_err(Failure::configuration)?;
        socket
            .bind(&std::net::SocketAddr::from((ap.address, 5288)).into())
            .map_err(Failure::configuration)?;
        socket.listen(1).map_err(Failure::configuration)?;
        let listener =
            tokio::net::TcpListener::from_std(socket.into()).map_err(Failure::configuration)?;
        let device = bt.device(selected)?;
        if !device.is_paired().await.map_err(Failure::configuration)? {
            return Err(Failure::new(
                Kind::Authorization,
                "Selected phone authorization revoked",
            ));
        }
        let uuid = UUID.parse().unwrap();
        let profile = bluer::rfcomm::Profile {
            uuid,
            name: Some("Argo Android Auto Wireless".into()),
            role: Some(bluer::rfcomm::Role::Server),
            channel: Some(8),
            require_authentication: Some(true),
            require_authorization: Some(false),
            auto_connect: Some(false),
            service_record: Some(format!(
                r#"<record><attribute id="0x0001"><sequence><uuid value="{UUID}"/></sequence></attribute><attribute id="0x0004"><sequence><sequence><uuid value="0x0100"/></sequence><sequence><uuid value="0x0003"/><uint8 value="8"/></sequence></sequence></attribute><attribute id="0x0005"><sequence><uuid value="0x1002"/></sequence></attribute><attribute id="0x0100"><text value="Argo Android Auto Wireless"/></attribute></record>"#
            )),
            ..Default::default()
        };
        let mut connections = bt
            .session
            .register_profile(profile)
            .await
            .map_err(|e| {
                format!("AA Bluetooth profile/channel conflict or permission failure: {e}")
            })
            .map_err(Failure::configuration)?;
        // Existing desktop HFP implementation owns signaling. Connect only the
        // selected paired device; do not implement/advertise competing profiles.
        // Ask the desktop-owned HFP implementation only; do not connect all
        // media profiles or redirect the system sink through A2DP.
        // Device1.ConnectProfile takes the REMOTE service UUID: the phone is
        // Audio Gateway (111f), while desktop PipeWire supplies Hands-Free (111e).
        let hfp = "0000111f-0000-1000-8000-00805f9b34fb".parse().unwrap();
        let connect = device.connect_profile(&hfp);
        tokio::pin!(connect);
        let mut connect_done = false;
        let mut trigger_failure: Option<Failure> = None;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
        let mut rejected = 0;
        let (mut rfcomm, profile_closed) = loop {
            tokio::select! {
                _ = tokio::time::sleep_until(deadline) => return Err(trigger_failure.take().unwrap_or_else(|| Failure::timeout("Bluetooth bootstrap timed out. Phone may require a working desktop Hands-Free connection to its Audio Gateway."))),
                _ = listener.accept() => return Err(Failure::new(Kind::Authorization, "Unsolicited TCP peer before authenticated bootstrap; attempt revoked")),
                result = &mut connect, if !connect_done => {
                    connect_done = true;
                    match result {
                        Ok(()) => crate::daemon_log!(Info, "wireless", "Desktop HFP connection to phone Audio Gateway established; awaiting AA RFCOMM"),
                        Err(e) => {
                            if e.kind == bluer::ErrorKind::AlreadyConnected { continue; }
                            let failure = Failure::from(e.clone());
                            if failure.kind == Kind::Authorization { return Err(failure); }
                            trigger_failure = Some(failure);
                            crate::daemon_log!(Warn, "wireless", "Desktop HFP bootstrap trigger failed: {e}; still awaiting selected phone RFCOMM");
                            c.progress("bootstrap", format!("Bluetooth startup trigger failed: {e}. Waiting for phone-initiated AA bootstrap until the connection deadline."));
                        }
                    }
                },
                request = connections.next() => {
                    let request = request.ok_or("BlueZ profile disappeared")?;
                    if request.device() != device.address() || !device.is_paired().await.map_err(Failure::configuration)? {
                        request.reject(bluer::rfcomm::ReqError::Rejected); rejected += 1;
                        if rejected >= 3 { return Err(Failure::new(Kind::Authorization, "Unsolicited Bluetooth attempt limit")); } continue;
                    }
                    let closed = request.closed();
                    let stream = request.accept().map_err(Failure::configuration)?;
                    let adapter = selected.split_once('/').unwrap().0;
                    let address = bt.session.adapter(adapter).map_err(Failure::configuration)?.address().await.map_err(Failure::configuration)?;
                    if stream.as_ref().local_addr().map_err(Failure::configuration)?.addr != address { return Err(Failure::new(Kind::Authorization, "Bootstrap arrived on a different adapter")); }
                    let security = stream.as_ref().security().map_err(Failure::configuration)?;
                    if security.level < bluer::rfcomm::SecurityLevel::Medium { return Err(Failure::new(Kind::Authorization, "Bootstrap link is not authenticated/encrypted")); }
                    break (stream, closed);
                }
            }
        };
        c.progress(
            "bootstrap",
            "Bluetooth bootstrap connected; negotiating wireless startup",
        );
        let (authorized, authorized_rx) = watch::channel(false);
        let bootstrap = async {
            let result = tokio::select! {
                result = crate::wireless_bootstrap::run(&mut rfcomm, &ap, authorized) => result,
                _ = profile_closed => Err(Failure::new(Kind::BootstrapClosed, "BlueZ requested bootstrap disconnection")),
            };
            use tokio::io::AsyncWriteExt;
            let _ = rfcomm.shutdown().await;
            result
        };
        tokio::pin!(bootstrap);
        let mut bootstrap_done = false;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(65);
        let stream = {
            let admission = admit_tcp(&listener, ap.address, authorized_rx.clone(), deadline, c);
            tokio::pin!(admission);
            loop {
                tokio::select! {
                    biased;
                    result = &mut bootstrap, if !bootstrap_done => {
                        bootstrap_done = true;
                        if !*authorized_rx.borrow() || result.as_ref().is_err_and(bootstrap_failure_is_fatal) {
                            return Err(result.err().unwrap_or_else(|| Failure::new(Kind::TransportLoss, "Bootstrap ended before startup acceptance")));
                        }
                    }
                    Some(request) = connections.next() => request.reject(bluer::rfcomm::ReqError::Rejected),
                    result = &mut admission => break result?,
                }
            }
        };
        if !device.is_paired().await.map_err(Failure::configuration)? {
            return Err(Failure::new(
                Kind::Authorization,
                "Selected phone authorization revoked before TCP admission",
            ));
        }
        crate::daemon_log!(
            Info,
            "wireless",
            "Bootstrap-authorized TCP peer admitted after {} ms; starting AA version handshake",
            started.elapsed().as_millis()
        );
        drop(listener); // No second projection peer can enter this attempt.
        let mut transport = crate::tcp_transport::TcpAaTransport::admitted(stream)
            .map_err(Failure::configuration)?;
        let epoch = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        // Public projection IDs are opaque session-local IDs, not radio addresses.
        let mut snapshot = ProjectionRuntimeSnapshot::connecting(
            format!("wireless-device:{epoch}"),
            device
                .alias()
                .await
                .unwrap_or_else(|_| "Android phone".into()),
        );
        let id = format!("aa-wifi:{epoch}");
        snapshot.session.as_mut().unwrap().id = id.clone();
        snapshot.device.as_mut().unwrap().transport = 1;
        state.send_replace(snapshot);
        let _selection = host.begin_session(&id);
        tokio::time::timeout(
            Duration::from_secs(10),
            crate::session::negotiate_version(&mut transport),
        )
        .await
        .map_err(|_| Failure::timeout("Wi-Fi AA version timeout"))?
        .map_err(Failure::from)?;
        c.progress(
            "projecting",
            "Android Auto over Wi-Fi; streaming state comes from the projection engine",
        );
        let session = crate::aa_session::run(
            &mut transport,
            host.clone(),
            state.clone(),
            id,
            &mut media,
            Some(&readiness),
        );
        tokio::pin!(session);
        let health = async {
            let mut interval = tokio::time::interval(Duration::from_secs(2));
            loop {
                interval.tick().await;
                let streaming = state.borrow().session.as_ref().is_some_and(|s| {
                    s.state == crate::daemon_state::ProjectionSessionStatus::Streaming
                });
                if streaming {
                    c.progress("streaming", "Android Auto streaming over Wi-Fi");
                }
                if !device.is_paired().await.map_err(Failure::configuration)? {
                    return Err(Failure::new(
                        Kind::Authorization,
                        "Selected phone pairing revoked",
                    ));
                }
                if !network.ready(&ap).await? {
                    return Err(Failure::network(
                        "Projection AP address/DHCP readiness lost",
                    ));
                }
            }
        };
        tokio::pin!(health);
        loop {
            tokio::select! {
                result = &mut session => break result,
                result = &mut health => break result,
                result = &mut bootstrap, if !bootstrap_done => {
                    bootstrap_done = true;
                    if let Err(e) = result && bootstrap_failure_is_fatal(&e) { break Err(e); }
                },
                Some(request) = connections.next() => request.reject(bluer::rfcomm::ReqError::Rejected),
            }
        }
    };
    let result = run_until_end(&readiness, &mut cancel, operation).await;
    if let Err(error) = &result {
        crate::daemon_log!(
            Warn,
            "wireless",
            "Initiating failure before media cleanup: {error}"
        );
        // Publish failure immediately; this is not a claim that owned resources
        // have stopped. The connectivity phase remains cleanup until teardown ends.
        state.send_modify(|snapshot| {
            *snapshot = snapshot.clone().failed(error.to_string());
        });
        c.state
            .send_modify(|s| s.detail = format!("{error}; stopping owned resources"));
    }
    c.state.send_modify(|s| {
        s.phase = "cleanup".into();
        if result.is_ok() {
            s.detail = "Stopping owned projection resources".into();
        }
    });
    let cleanup_started = tokio::time::Instant::now();
    media.close().await;
    crate::daemon_log!(
        Debug,
        "wireless",
        "Media cleanup complete after {} ms; stopping owned AP/firewall (authorization may wait)",
        cleanup_started.elapsed().as_millis()
    );
    state.send_replace(ProjectionRuntimeSnapshot::default());
    c.state.send_modify(|s| s.wifi_connected = false);
    if let Err(e) = network.stop(&mut ap).await {
        let message = format!("{e}. Retained input guard; inspect the owned AP before retry.");
        c.state.send_modify(|s| s.cleanup_error = message.clone());
        crate::daemon_log!(Warn, "wireless", "{message}");
        return Err(cleanup_failure(result, message));
    }
    crate::daemon_log!(
        Debug,
        "wireless",
        "Owned resource cleanup complete after {} ms; retry policy follows",
        cleanup_started.elapsed().as_millis()
    );
    c.state.send_modify(|s| {
        s.cleanup_error.clear();
        s.ap_frequency_mhz = None;
    });
    result
}

// RFCOMM lifetime is independent after accepted bootstrap. Explicit protocol
// errors still fail the attempt/session; only link closure/idle expiry is benign.
fn bootstrap_failure_is_fatal(error: &Failure) -> bool {
    !matches!(error.kind, Kind::TransportLoss | Kind::BootstrapClosed)
}

/// TCP and Bluetooth startup acceptance travel independently. Retain at most one candidate,
/// without reading AA bytes or allocating session media until the selected authenticated peer has received credentials and accepted Start.
/// Dropping this future (Disconnect, shutdown, bootstrap error) closes the candidate.
async fn admit_tcp(
    listener: &tokio::net::TcpListener,
    ap_address: std::net::Ipv4Addr,
    mut authorized: watch::Receiver<bool>,
    deadline: tokio::time::Instant,
    control: &crate::connectivity::Control,
) -> Result<tokio::net::TcpStream, Failure> {
    let mut pending = None;
    let mut reported_authorization = false;
    loop {
        if tokio::time::Instant::now() >= deadline {
            return Err(Failure::timeout(if pending.is_some() {
                "Projection TCP arrived, but authenticated Bluetooth startup acceptance did not arrive before the admission deadline".into()
            } else {
                "Phone did not establish projection TCP within admission window".to_owned()
            }));
        }
        if *authorized.borrow() {
            if !reported_authorization {
                reported_authorization = true;

                control.progress(
                    "connecting",
                    "Phone accepted wireless startup; waiting for projection TCP",
                );
            }
            if let Some(stream) = pending.take() {
                control.state.send_modify(|s| s.wifi_connected = true);
                return Ok(stream);
            }
        }
        tokio::select! {
            biased;
            _ = tokio::time::sleep_until(deadline) => {},
            changed = authorized.changed(), if !reported_authorization => {
                if changed.is_err() && !*authorized.borrow() { return Err(Failure::new(Kind::TransportLoss, "Bootstrap ended before startup acceptance")); }
            }
            accepted = listener.accept() => {
                let (stream, peer) = accepted.map_err(Failure::from)?;
                let ip = match peer.ip() { std::net::IpAddr::V4(ip) => ip, _ => return Err("Unexpected projection address family".into()) };
                if ip.octets()[..3] != ap_address.octets()[..3] || ip == ap_address {
                    return Err(Failure::new(Kind::Authorization, "TCP peer outside projection subnet; attempt revoked"));
                }
                if pending.is_some() { return Err(Failure::new(Kind::Authorization, "Second TCP candidate before bootstrap admission; attempt revoked")); }
                pending = Some(stream);
                if !*authorized.borrow() {
                    crate::daemon_log!(Info, "wireless", "Projection TCP candidate waiting for authenticated Bluetooth startup acceptance");
                    control.progress("connecting", "TCP connected; waiting for phone's Bluetooth bootstrap acceptance confirmation");
                }
            }
        }
    }
}

pub(crate) fn retry_allowed(error: &Failure, explicitly_stopped: bool, attempt: u32) -> bool {
    !explicitly_stopped && attempt < 2 && error.retryable()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test(start_paused = true)]
    async fn deadline_cancellation_cleanup_and_fresh_attempt_are_independent() {
        let (cancel, _) = watch::channel(false);
        let mut stale = crate::readiness::Readiness::default();
        for stop in [false, true] {
            let ready = crate::readiness::Readiness::default();
            stale = ready.clone();
            let mut cancelled = cancel.subscribe();
            let path = std::env::temp_dir()
                .join(format!("argo-deadline-{}-{stop}.sock", std::process::id()));
            let mut media = crate::native_playback::SessionMedia {
                video: Some(crate::native_playback::VideoFeed::open(path.clone()).unwrap()),
                ..Default::default()
            };
            let task = tokio::spawn(async move {
                let result = run_until_end(&ready, &mut cancelled, std::future::pending()).await;
                media.close().await;
                result.unwrap_err()
            });
            tokio::task::yield_now().await;
            assert!(path.exists());
            if stop {
                cancel.send_replace(true);
            } else {
                tokio::time::advance(Duration::from_secs(180)).await;
            }
            assert_eq!(
                task.await.unwrap().kind,
                if stop {
                    Kind::Cancelled
                } else {
                    Kind::SetupTimeout
                }
            );
            assert!(
                !path.exists(),
                "deadline/cancellation must complete real feed cleanup"
            );
        }
        cancel.send_replace(false);
        let fresh = crate::readiness::Readiness::default();
        stale.establish(); // An earlier session cannot establish its replacement.
        let deadline = tokio::spawn(async move { fresh.setup_deadline().await });
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(179)).await;
        assert!(!deadline.is_finished());
        tokio::time::advance(Duration::from_secs(1)).await;
        deadline.await.unwrap();
        let mut cancelled = cancel.subscribe();
        let backoff = tokio::spawn(async move { retry_backoff(&mut cancelled, 2).await });
        tokio::task::yield_now().await;
        cancel.send_replace(true);
        assert!(!backoff.await.unwrap());
        assert!(!retry_allowed(
            &Failure::network("wording independent"),
            true,
            0
        ));
        let initiating = Failure::network("original AP loss");
        let blocked = cleanup_failure(Err(initiating), "activation result unknown".into());
        assert_eq!(blocked.detail, "original AP loss");
        assert!(blocked.cleanup.is_some());
        assert!(!retry_allowed(&blocked, false, 0));
    }
    async fn candidate(
        authorize_first: bool,
        limit: Duration,
    ) -> (
        tokio::task::JoinHandle<Result<tokio::net::TcpStream, Failure>>,
        tokio::net::TcpStream,
        watch::Sender<bool>,
        crate::connectivity::Control,
        std::net::SocketAddr,
    ) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (authorized, rx) = watch::channel(authorize_first);
        let (control, _) = crate::connectivity::Control::new();
        let c = control.clone();
        let task = tokio::spawn(async move {
            admit_tcp(
                &listener,
                "127.0.0.2".parse().unwrap(),
                rx,
                tokio::time::Instant::now() + limit,
                &c,
            )
            .await
        });
        let phone = tokio::net::TcpStream::connect(address).await.unwrap();
        if !authorize_first {
            let mut state = control.state.subscribe();
            tokio::time::timeout(
                Duration::from_secs(1),
                state.wait_for(|s| s.detail.starts_with("TCP connected;")),
            )
            .await
            .unwrap()
            .unwrap();
        }
        (task, phone, authorized, control, address)
    }
    #[tokio::test]
    async fn tcp_before_or_after_start_acceptance_is_admitted_without_consuming_aa_bytes() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        for first in [false, true] {
            let (task, mut phone, authorized, control, _) =
                candidate(first, Duration::from_secs(2)).await;
            phone.write_all(b"AA version bytes").await.unwrap();
            if !first {
                assert!(!task.is_finished());
                assert!(!control.state.borrow().wifi_connected);
                authorized.send_replace(true);
            }
            let mut admitted = tokio::time::timeout(Duration::from_secs(1), task)
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            let mut bytes = [0; 16];
            admitted.read_exact(&mut bytes).await.unwrap();
            assert_eq!(&bytes, b"AA version bytes");
            assert!(control.state.borrow().wifi_connected);
        }
    }
    #[tokio::test]
    async fn pending_candidate_requires_start_acceptance_and_closes_on_cancel_or_second_peer() {
        use tokio::io::AsyncReadExt;
        for case in ["deadline", "cancel", "second", "bootstrap-ended"] {
            let limit = if case == "deadline" {
                Duration::from_millis(200)
            } else {
                Duration::from_secs(2)
            };
            let (task, mut phone, authorized, _, address) = candidate(false, limit).await;
            match case {
                "cancel" => {
                    task.abort();
                    assert!(task.await.unwrap_err().is_cancelled());
                }
                "second" => {
                    let _second = tokio::net::TcpStream::connect(address).await.unwrap();
                    assert!(
                        task.await
                            .unwrap()
                            .unwrap_err()
                            .detail
                            .contains("Second TCP candidate")
                    );
                }
                "bootstrap-ended" => {
                    drop(authorized);
                    assert!(
                        task.await
                            .unwrap()
                            .unwrap_err()
                            .detail
                            .contains("Bootstrap ended")
                    );
                }
                _ => assert!(
                    task.await
                        .unwrap()
                        .unwrap_err()
                        .detail
                        .contains("startup acceptance did not arrive")
                ),
            }
            let mut byte = [0];
            assert_eq!(
                tokio::time::timeout(Duration::from_secs(1), phone.read(&mut byte))
                    .await
                    .unwrap()
                    .unwrap(),
                0
            );
        }
    }
    #[test]
    fn session_admission_precedes_resources_and_reconnect_requires_intent() {
        assert!(bootstrap_failure_is_fatal(&Failure::new(
            Kind::Protocol,
            "WPP ConnectionStatus: Phone wireless status -3"
        )));
        assert!(bootstrap_failure_is_fatal(&Failure::new(
            Kind::Protocol,
            "Unexpected WPP message 99"
        )));
        assert!(!bootstrap_failure_is_fatal(&Failure::new(
            Kind::TransportLoss,
            "WPP read: connection reset"
        )));
        assert!(!bootstrap_failure_is_fatal(&Failure::new(
            Kind::BootstrapClosed,
            "WPP idle timeout"
        )));
        let host = HostControl::default();
        let wired = host.session_lease.clone().try_acquire_owned().unwrap();
        assert!(host.session_lease.clone().try_acquire_owned().is_err());
        // A frozen live config cannot be overwritten by an unadmitted worker.
        let selection = host.begin_session("wired");
        assert_eq!(
            host.configuration.borrow().active.as_ref().unwrap().0,
            "wired"
        );
        drop(selection);
        drop(wired);
        let wireless = host.session_lease.clone().try_acquire_owned().unwrap();
        assert!(host.session_lease.clone().try_acquire_owned().is_err());
        drop(wireless);
        assert!(retry_allowed(
            &Failure::new(Kind::NetworkLoss, "network lost"),
            false,
            0
        ));
        assert!(!retry_allowed(
            &Failure::new(Kind::NetworkLoss, "network lost"),
            true,
            0
        ));
        assert!(!retry_allowed(
            &Failure::new(Kind::NetworkLoss, "network lost"),
            false,
            2
        ));
        assert!(!retry_allowed(
            &Failure::new(Kind::Cancelled, "AA Exit"),
            false,
            0
        ));
        assert!(!retry_allowed(
            &Failure::new(Kind::Cleanup, "AP cleanup failed"),
            false,
            0
        ));
    }
}
