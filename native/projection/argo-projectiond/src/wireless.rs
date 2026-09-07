//! One connectivity worker; wireless bootstrap and projection consume shared
//! BlueZ state. A single semaphore arbitrates USB/Wi-Fi before resource setup.
use crate::connectivity::network::ApBand;
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
    let network = match Network::open().await {
        Ok(v) => Arc::new(v),
        Err(e) => {
            c.progress("unavailable", format!("NetworkManager: {e}"));
            return;
        }
    };
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
            _ = client_closed.changed() => {
                while requests.try_recv().is_ok() {}
                if let Some(a) = activity.take() { a.stop().await; }
                if let Some(d) = discovery.take() { d.stop().await; }
                if let Some(p) = pairing.take() { p.abort(); let _ = p.await; }
                c.state.send_modify(|s| { s.enabled = false; s.prompt = None; });
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
                match tokio::time::timeout(Duration::from_secs(4), network.interfaces()).await {
                    Ok(Ok(radios)) => { c.state.send_modify(|s| { if s.interface.is_empty() && radios.len() == 1 { s.interface = radios[0].id.clone(); } s.networks = radios; }); },
                    _ => { if let Some(a) = activity.take() { a.stop().await; } c.progress("unavailable", "NetworkManager unavailable; restart daemon after service recovery"); break; }
                }
                if activity.as_ref().is_some_and(|a| a.task.is_finished()) && let Some(a) = activity.take() { let _ = a.task.await; }
                if pairing.as_ref().is_some_and(|p| p.is_finished()) && let Some(p) = pairing.take() { let _ = p.await; }
                if discovery.as_ref().is_some_and(|d| d.task.is_finished()) && let Some(d) = discovery.take() { let _ = d.task.await; }
            }
            Some(r) = requests.recv() => {
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
        "confirm" => bt.respond(r.prompt, r.accept),
        "adapter" | "interface" | "select" | "band" => {
            let band = if r.action == "band" {
                Some(ApBand::parse(&r.target)?)
            } else {
                None
            };
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
                "adapter" => s.adapter = r.target.clone(),
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
                *discovery = Some(Attempt { cancel, task });
            }
        }
        "pair" => {
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
            if r.accept && std::env::var("ARGO_WIRELESS_DEVELOPMENT").as_deref() != Ok("1") {
                return Err(
                    "Wireless requires the documented ARGO_WIRELESS_DEVELOPMENT=1 admission gate"
                        .into(),
                );
            }
            c.state.send_modify(|s| s.enabled = r.accept);
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
            }
            c.progress(
                "disconnected",
                "Reconnect stopped. Press Connect for a new attempt.",
            );
        }
        "connect" => {
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
            let device = bt.device(&config.selected)?;
            if !device.is_paired().await.map_err(|e| e.to_string())? {
                return Err("Selected phone is no longer paired".into());
            }
            let permit = host.session_lease.clone().try_acquire_owned().map_err(|_| "Another projection transport owns the session. Disconnect it explicitly first.")?;
            let (cancel, cancelled) = watch::channel(false);
            let (bt, host, state) = (bt.clone(), host.clone(), state.clone());
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
            *activity = Some(Attempt { cancel, task });
        }
        _ => return Err("Unsupported connectivity action".into()),
    }
    Ok(())
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
            host.connectivity.progress(
                "backoff",
                format!(
                    "Retry {} of 3 in {} seconds",
                    attempt + 1,
                    2u64.pow(attempt)
                ),
            );
            tokio::select! { biased; _ = cancel.changed() => break, _ = tokio::time::sleep(Duration::from_secs(2u64.pow(attempt))) => {} }
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
                host.connectivity.progress("failed", e);
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
) -> Result<(), String> {
    let network = Network::open().await?;
    let c = &host.connectivity;
    c.progress("preparing", "Checking projection network and permissions");
    let mut ap = tokio::select! {
        biased;
        _ = cancel.changed() => return Ok(()),
        result = tokio::time::timeout(Duration::from_secs(10), network.prepare(interface, band)) => result.map_err(|_| "Wireless network preflight timed out")??,
    };
    let mut media = crate::native_playback::SessionMedia::default();
    let operation = async {
        network.activate(&mut ap).await?;
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
        .map_err(|e| e.to_string())?;
        socket
            .bind_device(Some(interface.as_bytes()))
            .map_err(|e| format!("Restrict TCP to projection interface: {e}"))?;
        socket.set_nonblocking(true).map_err(|e| e.to_string())?;
        socket
            .bind(&std::net::SocketAddr::from((ap.address, 5288)).into())
            .map_err(|e| e.to_string())?;
        socket.listen(1).map_err(|e| e.to_string())?;
        let listener =
            tokio::net::TcpListener::from_std(socket.into()).map_err(|e| e.to_string())?;
        let device = bt.device(selected)?;
        if !device.is_paired().await.map_err(|e| e.to_string())? {
            return Err("Selected phone authorization revoked".into());
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
        let mut connections = bt.session.register_profile(profile).await.map_err(|e| {
            format!("AA Bluetooth profile/channel conflict or permission failure: {e}")
        })?;
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
        let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
        let mut rejected = 0;
        let (mut rfcomm, profile_closed) = loop {
            tokio::select! {
                _ = tokio::time::sleep_until(deadline) => return Err("Bluetooth bootstrap timed out. Phone may require a working desktop Hands-Free connection to its Audio Gateway.".into()),
                _ = listener.accept() => return Err("Unsolicited TCP peer before authenticated bootstrap; attempt revoked".into()),
                result = &mut connect, if !connect_done => {
                    connect_done = true;
                    match result {
                        Ok(()) => crate::daemon_log!(Info, "wireless", "Desktop HFP connection to phone Audio Gateway established; awaiting AA RFCOMM"),
                        Err(e) => {
                            crate::daemon_log!(Warn, "wireless", "Desktop HFP bootstrap trigger failed: {e}; still awaiting selected phone RFCOMM");
                            c.progress("bootstrap", format!("Bluetooth startup trigger failed: {e}. Waiting for phone-initiated AA bootstrap until the connection deadline."));
                        }
                    }
                },
                request = connections.next() => {
                    let request = request.ok_or("BlueZ profile disappeared")?;
                    if request.device() != device.address() || !device.is_paired().await.map_err(|e| e.to_string())? {
                        request.reject(bluer::rfcomm::ReqError::Rejected); rejected += 1;
                        if rejected >= 3 { return Err("Unsolicited Bluetooth attempt limit".into()); } continue;
                    }
                    let closed = request.closed();
                    let stream = request.accept().map_err(|e| e.to_string())?;
                    let adapter = selected.split_once('/').unwrap().0;
                    let address = bt.session.adapter(adapter).map_err(|e| e.to_string())?.address().await.map_err(|e| e.to_string())?;
                    if stream.as_ref().local_addr().map_err(|e| e.to_string())?.addr != address { return Err("Bootstrap arrived on a different adapter".into()); }
                    let security = stream.as_ref().security().map_err(|e| e.to_string())?;
                    if security.level < bluer::rfcomm::SecurityLevel::Medium { return Err("Bootstrap link is not authenticated/encrypted".into()); }
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
                _ = profile_closed => Err("BlueZ requested bootstrap disconnection".into()),
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
                        if !*authorized_rx.borrow() || result.as_ref().is_err_and(|e| bootstrap_failure_is_fatal(e)) {
                            return Err(result.err().unwrap_or_else(|| "Bootstrap ended before startup acceptance".into()));
                        }
                    }
                    Some(request) = connections.next() => request.reject(bluer::rfcomm::ReqError::Rejected),
                    result = &mut admission => break result?,
                }
            }
        };
        if !device.is_paired().await.map_err(|e| e.to_string())? {
            return Err("Selected phone authorization revoked before TCP admission".into());
        }
        crate::daemon_log!(
            Info,
            "wireless",
            "Bootstrap-authorized TCP peer admitted; starting AA version handshake"
        );
        drop(listener); // No second projection peer can enter this attempt.
        let mut transport =
            crate::tcp_transport::TcpAaTransport::admitted(stream).map_err(|e| e.to_string())?;
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
        .map_err(|_| "Wi-Fi AA version timeout")?
        .map_err(|e| e.to_string())?;
        c.progress(
            "projecting",
            "Android Auto over Wi-Fi; streaming state comes from the projection engine",
        );
        let session =
            crate::aa_session::run(&mut transport, host.clone(), state.clone(), id, &mut media);
        tokio::pin!(session);
        let mut health = tokio::time::interval(Duration::from_secs(2));
        loop {
            tokio::select! {
                result = &mut session => break result,
                _ = health.tick() => {
                    let streaming = state.borrow().session.as_ref().is_some_and(|s| s.state == crate::daemon_state::ProjectionSessionStatus::Streaming);
                    if streaming { c.progress("streaming", "Android Auto streaming over Wi-Fi"); }

                    if !network.ready(&ap).await? || !device.is_paired().await.map_err(|e| e.to_string())? { break Err("Projection network lost or device authorization revoked".into()); }
                }
                result = &mut bootstrap, if !bootstrap_done => {
                    bootstrap_done = true;
                    if let Err(e) = result && bootstrap_failure_is_fatal(&e) { break Err(e); }
                },
                Some(request) = connections.next() => request.reject(bluer::rfcomm::ReqError::Rejected),
            }
        }
    };
    let setup_bound = async {
        tokio::time::sleep(Duration::from_secs(180)).await;
        let established = state.borrow().session.as_ref().is_some_and(|s| {
            s.id.starts_with("aa-wifi:")
                && s.state == crate::daemon_state::ProjectionSessionStatus::Streaming
        });
        if established {
            std::future::pending::<()>().await;
        }
    };
    let result = tokio::select! { biased; _ = cancel.changed() => Ok(()), _ = setup_bound => Err("Wireless overall setup deadline expired".into()), result = operation => result };
    c.progress("cleanup", "Stopping owned projection resources");
    media.close().await;
    state.send_replace(ProjectionRuntimeSnapshot::default());
    c.state.send_modify(|s| s.wifi_connected = false);
    if let Err(e) = network.stop(&mut ap).await {
        let message = format!("{e}. Retained input guard; inspect the owned AP before retry.");
        c.state.send_modify(|s| s.cleanup_error = message.clone());
        crate::daemon_log!(Warn, "wireless", "{message}");
        return Err(message);
    }
    c.state.send_modify(|s| {
        s.cleanup_error.clear();
        s.ap_frequency_mhz = None;
    });
    result
}

// RFCOMM lifetime is independent after accepted bootstrap. Explicit protocol
// errors still fail the attempt/session; only link closure/idle expiry is benign.
fn bootstrap_failure_is_fatal(error: &str) -> bool {
    !(error.starts_with("WPP read:")
        || error == "BlueZ requested bootstrap disconnection"
        || error == "WPP idle timeout")
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
) -> Result<tokio::net::TcpStream, String> {
    let mut pending = None;
    let mut reported_authorization = false;
    loop {
        if tokio::time::Instant::now() >= deadline {
            return Err(if pending.is_some() {
                "Projection TCP arrived, but authenticated Bluetooth startup acceptance did not arrive before the admission deadline".into()
            } else {
                "Phone did not establish projection TCP within admission window".into()
            });
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
                if changed.is_err() && !*authorized.borrow() { return Err("Bootstrap ended before startup acceptance".into()); }
            }
            accepted = listener.accept() => {
                let (stream, peer) = accepted.map_err(|e| e.to_string())?;
                let ip = match peer.ip() { std::net::IpAddr::V4(ip) => ip, _ => return Err("Unexpected projection address family".into()) };
                if ip.octets()[..3] != ap_address.octets()[..3] || ip == ap_address {
                    return Err("TCP peer outside projection subnet; attempt revoked".into());
                }
                if pending.is_some() { return Err("Second TCP candidate before bootstrap admission; attempt revoked".into()); }
                pending = Some(stream);
                if !*authorized.borrow() {
                    crate::daemon_log!(Info, "wireless", "Projection TCP candidate waiting for authenticated Bluetooth startup acceptance");
                    control.progress("connecting", "TCP connected; waiting for phone's Bluetooth bootstrap acceptance confirmation");
                }
            }
        }
    }
}

fn retry_allowed(error: &str, explicitly_stopped: bool, attempt: u32) -> bool {
    !explicitly_stopped
        && attempt < 2
        && (error.contains("network lost")
            || error.contains("phone disconnected")
            || error.contains("Phone did not establish")
            || error.contains("bootstrap timed out"))
}
#[cfg(test)]
mod tests {
    use super::*;
    async fn candidate(
        authorize_first: bool,
        limit: Duration,
    ) -> (
        tokio::task::JoinHandle<Result<tokio::net::TcpStream, String>>,
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
                            .contains("Second TCP candidate")
                    );
                }
                "bootstrap-ended" => {
                    drop(authorized);
                    assert!(task.await.unwrap().unwrap_err().contains("Bootstrap ended"));
                }
                _ => assert!(
                    task.await
                        .unwrap()
                        .unwrap_err()
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
        assert!(bootstrap_failure_is_fatal(
            "WPP ConnectionStatus: Phone wireless status -3"
        ));
        assert!(bootstrap_failure_is_fatal("Unexpected WPP message 99"));
        assert!(!bootstrap_failure_is_fatal("WPP read: connection reset"));
        assert!(!bootstrap_failure_is_fatal("WPP idle timeout"));
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
        assert!(retry_allowed("network lost", false, 0));
        assert!(!retry_allowed("network lost", true, 0));
        assert!(!retry_allowed("network lost", false, 2));
        assert!(!retry_allowed("AA Exit", false, 0));
        assert!(!retry_allowed("AP cleanup failed", false, 0));
    }
}
