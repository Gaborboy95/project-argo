//! Wireless CarPlay through the Link HCI controller and host BlueZ RFCOMM.
//! The removed dongle-owned iAP handoff is deliberately not used here.
use crate::{
    link::LinkClient,
    mdns_advertisement::Advertisement,
    protocol::{csm, wired},
    runtime_control::SessionTransport,
    session_runtime::{Endpoint, Options, Owner, Progress, Result, TransportEnded, stopped},
    wifi::{LiveAccessPoint, WirelessAccessPointSettings},
    wireless_bluetooth::Controller,
    wireless_network::WirelessNetwork,
};
use std::{
    future::Future,
    io,
    net::{IpAddr, Ipv4Addr, SocketAddr},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::{net::UdpSocket, sync::watch, time::Instant};

/// The supervisor must stop instead of reconnecting after unconfirmed cleanup.
#[derive(Debug)]
pub struct CleanupUnconfirmed(pub String);
impl std::fmt::Display for CleanupUnconfirmed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Wireless CarPlay cleanup is unconfirmed: {}", self.0)
    }
}
impl std::error::Error for CleanupUnconfirmed {}

struct RadioLease {
    link: LinkClient,
    initial_ap: bool,
    initial_bluetooth: bool,
    touched_ap: bool,
    touched_bluetooth: bool,
}
impl RadioLease {
    async fn prepare(
        link: LinkClient,
        network: &WirelessNetwork,
        mut stop: watch::Receiver<bool>,
    ) -> Result<(Self, LiveAccessPoint)> {
        let initial = tokio::select! {
            biased;
            _ = stopped(&mut stop) => return Err(io::Error::new(io::ErrorKind::Interrupted, "Wireless preparation cancelled").into()),
            status = link.wifi_access_point() => status?,
        };
        let country = initial
            .country
            .as_deref()
            .ok_or("LIVI Link regulatory country is unavailable")?;
        let channel = initial
            .channel
            .filter(|channel| *channel > 0)
            .ok_or("LIVI Link AP channel is unavailable")?;
        let settings =
            WirelessAccessPointSettings::new(country, channel, &network.ssid, &network.passphrase)?;
        let mut lease = Self {
            link,
            initial_ap: initial.enabled,
            initial_bluetooth: initial.bluetooth_enabled,
            touched_ap: false,
            touched_bluetooth: false,
        };
        let result = {
            let configure = async {
                // A timed-out write may already have reached the device. Record
                // ownership before sending, and restore power even on failure.
                lease.touched_ap = true;
                if !lease.initial_ap {
                    lease.link.set_access_point_enabled(true).await?;
                }
                lease
                    .link
                    .configure_wireless_access_point(&settings)
                    .await?;
                lease.touched_bluetooth = true;
                lease.link.set_bluetooth_enabled(true).await?;
                let live = lease.link.wifi_access_point().await?;
                if !live.enabled
                    || !live.bluetooth_enabled
                    || live.ssid.as_deref() != Some(network.ssid.as_str())
                    || live.channel != Some(channel)
                {
                    return Err(io::Error::other(
                        "LIVI Link did not apply the selected CarPlay network",
                    )
                    .into());
                }
                Ok::<_, Box<dyn std::error::Error + Send + Sync>>(live)
            };
            tokio::select! {
                biased;
                _ = stopped(&mut stop) => Err(io::Error::new(io::ErrorKind::Interrupted, "Wireless preparation cancelled").into()),
                result = configure => result,
            }
        };
        match result {
            Ok(live) => Ok((lease, live)),
            Err(error) => {
                lease.close().await?;
                Err(error)
            }
        }
    }

    async fn close(self) -> Result<()> {
        let mut errors = Vec::new();
        if self.touched_bluetooth
            && let Err(error) = self
                .link
                .set_bluetooth_enabled(self.initial_bluetooth)
                .await
        {
            errors.push(format!("Bluetooth power: {error}"));
        }
        if self.touched_ap
            && let Err(error) = self.link.set_access_point_enabled(self.initial_ap).await
        {
            errors.push(format!("AP power: {error}"));
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(CleanupUnconfirmed(errors.join("; ")).into())
        }
    }
}

/// Host-owned runtime device selection. Empty selection permits the first
/// explicitly paired phone; acceptance binds subsequent retries to that peer.
#[derive(Clone)]
pub struct PhoneSelection {
    current: Arc<dyn Fn() -> Option<[u8; 6]> + Send + Sync>,
    accepted: Arc<dyn Fn([u8; 6]) + Send + Sync>,
}
impl PhoneSelection {
    pub fn new<T, A>(current: T, accepted: A) -> Self
    where
        T: Fn() -> Option<[u8; 6]> + Send + Sync + 'static,
        A: Fn([u8; 6]) + Send + Sync + 'static,
    {
        Self {
            current: Arc::new(current),
            accepted: Arc::new(accepted),
        }
    }
}

/// Compatibility entry point for a standalone receiver without a selected peer.
pub async fn run_with_options<F, R>(
    options: F,
    pairing: PathBuf,
    link: LinkClient,
    network: WirelessNetwork,
    stop: watch::Receiver<bool>,
    should_reconnect: R,
    progress: watch::Sender<Progress>,
) -> Result<bool>
where
    F: Fn() -> io::Result<Options> + Send + Sync + 'static,
    R: Fn() -> bool + Send + Sync,
{
    run_with_selection(
        options,
        pairing,
        link,
        network,
        PhoneSelection::new(|| None, |_| {}),
        stop,
        should_reconnect,
        progress,
    )
    .await
}

/// Keep one controller/AP and advertised AirPlay endpoint across phone sessions.
/// Display options freeze per connection; selection and reconnect policy remain
/// host-owned. Explicit disconnect and transport loss release everything.
#[allow(clippy::too_many_arguments)]
pub async fn run_with_selection<F, R>(
    options: F,
    pairing: PathBuf,
    link: LinkClient,
    network: WirelessNetwork,
    selection: PhoneSelection,
    mut stop: watch::Receiver<bool>,
    should_reconnect: R,
    progress: watch::Sender<Progress>,
) -> Result<bool>
where
    F: Fn() -> io::Result<Options> + Send + Sync + 'static,
    R: Fn() -> bool + Send + Sync,
{
    if *stop.borrow() {
        return Ok(false);
    }
    progress.send_replace(Progress::PreparingNetwork);
    let owner = Owner::claim().await?;
    eprintln!("CarPlay wireless: preparing the selected Link access point");
    let (radios, live) = match RadioLease::prepare(link.clone(), &network, stop.clone()).await {
        Ok(prepared) => prepared,
        Err(error) if *stop.borrow() && error.downcast_ref::<CleanupUnconfirmed>().is_none() => {
            return Ok(false);
        }
        Err(error) => return Err(error),
    };
    let mut controller: Option<Controller> = None;
    let mut advertisement: Option<Advertisement> = None;
    let result = async {
        progress.send_replace(Progress::PreparingController);
        controller = Some(Controller::acquire(&link, "Argo CarPlay", stop.clone()).await?);
        let controller_address = controller.as_ref().unwrap().address;
        let (address, interface) = tokio::select! {
            result = local_endpoint(&link) => result?,
            _ = stopped(&mut stop) => return Ok(false),
        };
        let endpoint = owner
            .listen(SocketAddr::from((address, 0)), pairing)
            .await?
            .with_bluetooth_address(controller_address)?;
        let accessory = endpoint.accessory_identifier()?;
        advertisement = Some(
            Advertisement::publish(
                "Argo",
                interface,
                endpoint.address()?.port(),
                &accessory,
                endpoint.identity_identifier(),
                &endpoint.public_key()?,
            )
            .await?,
        );
        let mut sessions = WirelessSessions {
            endpoint,
            controller: controller.as_mut().unwrap(),
            advertisement: advertisement.as_ref().unwrap(),
            options: Arc::new(options),
            link: link.clone(),
            network,
            selection,
            channel: live
                .channel
                .ok_or("Live CarPlay channel is unavailable")?
                .try_into()?,
            security: live.security,
            stop: stop.clone(),
            progress: progress.clone(),
        };
        serve_phones(&mut sessions, should_reconnect, stop.clone()).await
    }
    .await;
    // Do not return (or release the owner lock) until every cleanup was tried.
    progress.send_replace(Progress::Disconnecting);
    let mut cleanup = Vec::new();
    if let Some(advertisement) = advertisement
        && let Err(error) = advertisement.close().await
    {
        cleanup.push(format!("AirPlay advertisement: {error}"));
    }
    if let Some(controller) = controller
        && let Err(error) = controller.close().await
    {
        cleanup.push(format!("Bluetooth controller: {error}"));
    }
    if let Err(error) = radios.close().await {
        cleanup.push(error.to_string());
    }
    if !cleanup.is_empty() {
        return Err(CleanupUnconfirmed(cleanup.join("; ")).into());
    }
    if *stop.borrow() { Ok(false) } else { result }
}

enum PhoneSessionEnd {
    Disconnected,
    UserDisconnected,
    Failed(Box<dyn std::error::Error + Send + Sync>),
}

/// A failed phone is retryable; a failed controller/discovery owner is not.
trait PhoneSessions {
    fn serve_next(&mut self) -> impl Future<Output = Result<PhoneSessionEnd>> + Send;
    fn wait_retry(&mut self, delay: Duration) -> impl Future<Output = Result<()>> + Send;
}

async fn serve_phones<S, R>(
    sessions: &mut S,
    should_reconnect: R,
    mut stop: watch::Receiver<bool>,
) -> Result<bool>
where
    S: PhoneSessions,
    R: Fn() -> bool,
{
    let mut delay = 2;
    loop {
        if *stop.borrow() {
            return Ok(false);
        }
        let started = Instant::now();
        let ended = sessions.serve_next().await?;
        if *stop.borrow() {
            return Ok(false);
        }
        if matches!(ended, PhoneSessionEnd::UserDisconnected) {
            return Ok(true);
        }
        if !should_reconnect() {
            return match ended {
                PhoneSessionEnd::Failed(error) => Err(error),
                _ => Ok(false),
            };
        }
        if let PhoneSessionEnd::Failed(error) = ended {
            eprintln!("CarPlay wireless phone session ended: {error}");
        }
        if started.elapsed() >= Duration::from_secs(60) {
            delay = 2;
        }
        tokio::select! {
            biased;
            _ = stopped(&mut stop) => return Ok(false),
            ready = sessions.wait_retry(Duration::from_secs(delay)) => ready?,
        }
        // The policy may have changed while waiting. A manual Connect with
        // auto_connect=false is allowed its first attempt, not another one.
        if !should_reconnect() {
            return Ok(false);
        }
        delay = (delay * 2).min(30);
    }
}

struct WirelessSessions<'a, F> {
    endpoint: Endpoint,
    controller: &'a mut Controller,
    advertisement: &'a Advertisement,
    options: Arc<F>,
    link: LinkClient,
    network: WirelessNetwork,
    selection: PhoneSelection,
    channel: u8,
    security: csm::WirelessSecurity,
    stop: watch::Receiver<bool>,
    progress: watch::Sender<Progress>,
}
impl<F> PhoneSessions for WirelessSessions<'_, F>
where
    F: Fn() -> io::Result<Options> + Send + Sync + 'static,
{
    async fn serve_next(&mut self) -> Result<PhoneSessionEnd> {
        eprintln!("CarPlay wireless: waiting for iPhone Bluetooth connection");
        self.progress.send_replace(Progress::WaitingPhone);
        let phone = tokio::select! {
            biased;
            _ = stopped(&mut self.stop) => return Ok(PhoneSessionEnd::Disconnected),
            lost = self.advertisement.wait_lost() => return Err(TransportEnded(lost).into()),
            value = self.controller.accept((self.selection.current)()) => value?,
        };
        if *self.stop.borrow() {
            return Ok(PhoneSessionEnd::Disconnected);
        }
        (self.selection.accepted)(phone.peer);
        let discarded = tokio::select! {
            biased;
            _ = stopped(&mut self.stop) => return Ok(PhoneSessionEnd::Disconnected),
            discarded = self.endpoint.discard_idle_connections() => discarded?,
        };
        if discarded != 0 {
            eprintln!("CarPlay wireless: discarded {discarded} idle AirPlay connections");
        }
        self.progress.send_replace(Progress::Connecting);
        let session = self
            .endpoint
            .session()?
            .with_progress(self.progress.clone());
        let controller_address = self.controller.address;
        let configuration = wired::Configuration {
            identity: csm::AccessoryIdentity {
                name: "Argo".into(),
                model: "LattePanda Mu".into(),
                manufacturer: "Argo".into(),
                serial: "argo-development".into(),
                firmware: "0.1.0".into(),
                hardware: "1".into(),
                language: "en".into(),
                usb_interface: 0,
            },
            start_session: csm::StartSession {
                transport: csm::SessionTransport::Wireless {
                    address: self.endpoint.address()?.ip(),
                    ssid: self.network.ssid.clone(),
                    passphrase: self.network.passphrase.clone(),
                    channel: self.channel,
                    security: self.security,
                },
                port: session.address()?.port(),
                device_identifier: session.accessory_identifier()?,
                public_key: session.public_key()?,
                source_version: crate::protocol::receiver::SOURCE_VERSION.into(),
            },
        };
        let digest = openssl::sha::sha256(&phone.peer);
        let device_id = digest[..16].iter().map(|b| format!("{b:02x}")).collect();
        let control_link = self.link.clone();
        let options = self.options.clone();
        let controller = &mut self.controller;
        let advertisement = self.advertisement;
        let result = session
            .run_with_metadata(
                move || options(),
                self.link.clone(),
                device_id,
                SessionTransport::Wireless,
                self.stop.clone(),
                move |cancel, state, metadata| async move {
                    wired::run_wireless_with_updates(
                        phone.stream,
                        &control_link,
                        configuration,
                        controller_address,
                        cancel,
                        state,
                        metadata,
                    )
                    .await
                    .map_err(|error| error.to_string())
                },
                async {
                    tokio::select! {
                        lost = controller.wait_lost() => lost,
                        lost = advertisement.wait_lost() => lost,
                    }
                },
            )
            .await;
        match result {
            Ok(true) => Ok(PhoneSessionEnd::UserDisconnected),
            Ok(false) => Ok(PhoneSessionEnd::Disconnected),
            Err(error) if error.downcast_ref::<TransportEnded>().is_some() => Err(error),
            Err(error) => Ok(PhoneSessionEnd::Failed(error)),
        }
    }

    async fn wait_retry(&mut self, delay: Duration) -> Result<()> {
        self.progress.send_replace(Progress::Retrying);
        tokio::select! {
            _ = tokio::time::sleep(delay) => Ok(()),
            lost = self.controller.wait_lost() => Err(TransportEnded(lost).into()),
            lost = self.advertisement.wait_lost() => Err(TransportEnded(lost).into()),
        }
    }
}

/// Select the host address of the actual route to the trusted Link. No guessed
/// interface names, default-route mutation, or phone-provided bind addresses.
async fn local_endpoint(link: &LinkClient) -> Result<(Ipv4Addr, u32)> {
    let remote = link.resolve().await?;
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).await?;
    socket.connect((remote, crate::link::MFI_PORT)).await?;
    let IpAddr::V4(address) = socket.local_addr()?.ip() else {
        return Err("CarPlay Link route is not IPv4".into());
    };
    if address.is_unspecified()
        || address.is_loopback()
        || address.is_multicast()
        || address.is_broadcast()
    {
        return Err("CarPlay Link route has no usable host address".into());
    }
    Ok((address, interface_index(address)?))
}

fn interface_index(address: Ipv4Addr) -> io::Result<u32> {
    let mut addresses = std::ptr::null_mut();
    // SAFETY: getifaddrs initializes the list; the guard owns it through traversal.
    if unsafe { libc::getifaddrs(&mut addresses) } != 0 {
        return Err(io::Error::last_os_error());
    }
    struct Free(*mut libc::ifaddrs);
    impl Drop for Free {
        fn drop(&mut self) {
            unsafe { libc::freeifaddrs(self.0) }
        }
    }
    let _free = Free(addresses);
    let mut current = addresses;
    let mut selected = None;
    while !current.is_null() {
        // SAFETY: each next pointer belongs to the still-owned getifaddrs list.
        let entry = unsafe { &*current };
        if !entry.ifa_addr.is_null()
            && !entry.ifa_name.is_null()
            && entry.ifa_flags & libc::IFF_UP as u32 != 0
            && unsafe { (*entry.ifa_addr).sa_family as i32 } == libc::AF_INET
        {
            let socket = unsafe { &*entry.ifa_addr.cast::<libc::sockaddr_in>() };
            if Ipv4Addr::from(socket.sin_addr.s_addr.to_ne_bytes()) == address {
                let index = unsafe { libc::if_nametoindex(entry.ifa_name) };
                if index == 0 {
                    return Err(io::Error::last_os_error());
                }
                if selected.is_some_and(|prior| prior != index) {
                    return Err(io::Error::other("Ambiguous CarPlay Link interface"));
                }
                selected = Some(index);
            }
        }
        current = entry.ifa_next;
    }
    selected.ok_or_else(|| io::Error::other("CarPlay Link interface disappeared"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{discovery::Discovery, link::LinkConfig};
    use std::time::Duration;
    use std::{
        collections::VecDeque,
        sync::atomic::{AtomicBool, Ordering},
    };
    use tokio::{
        io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
        net::TcpListener,
        sync::oneshot,
        task::JoinHandle,
        time::timeout,
    };

    type Transaction = Vec<(&'static str, String)>;

    fn network() -> WirelessNetwork {
        WirelessNetwork {
            ssid: "Synthetic CarPlay".into(),
            passphrase: "synthetic-private-network".into(),
        }
    }

    fn status(ap: bool, bluetooth: bool, selected: bool) -> String {
        format!(
            "state {}\nbt {}\ncountry_code DE\nchannel 36\nssid {}\nsecurity wpa2\nok\n",
            if ap { "on" } else { "off" },
            if bluetooth { "on" } else { "off" },
            if selected {
                "Synthetic CarPlay"
            } else {
                "Existing AP"
            },
        )
    }

    fn command(value: &'static str) -> Transaction {
        vec![(value, "ok\n".into())]
    }

    fn configure(apply_response: &str) -> Transaction {
        vec![
            ("set country DE\n", "ok\n".into()),
            ("set channel 36\n", "ok\n".into()),
            ("set ssid Synthetic CarPlay\n", "ok\n".into()),
            ("set passphrase synthetic-private-network\n", "ok\n".into()),
            ("apply\n", apply_response.into()),
        ]
    }

    async fn server(
        transactions: Vec<Transaction>,
    ) -> (LinkClient, JoinHandle<()>, oneshot::Receiver<()>) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let link = LinkClient::new(LinkConfig {
            discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
            wifi_port: listener.local_addr().unwrap().port(),
            deadline: Duration::from_secs(1),
            ..LinkConfig::default()
        })
        .unwrap();
        let (held, waiting) = oneshot::channel();
        let task = tokio::spawn(async move {
            let mut held = Some(held);
            for transaction in transactions {
                let (stream, _) = listener.accept().await.unwrap();
                let mut stream = BufReader::new(stream);
                for (expected, response) in transaction {
                    let mut request = String::new();
                    stream.read_line(&mut request).await.unwrap();
                    assert_eq!(request, expected);
                    if response == "hold" {
                        held.take().unwrap().send(()).unwrap();
                        request.clear();
                        assert_eq!(stream.read_line(&mut request).await.unwrap(), 0);
                    } else {
                        stream
                            .get_mut()
                            .write_all(response.as_bytes())
                            .await
                            .unwrap();
                    }
                }
                let mut extra = String::new();
                assert_eq!(stream.read_line(&mut extra).await.unwrap(), 0);
            }
        });
        (link, task, waiting)
    }

    async fn finished(task: JoinHandle<()>) {
        timeout(Duration::from_secs(2), task)
            .await
            .unwrap()
            .unwrap();
    }

    #[tokio::test]
    async fn prepare_turns_on_an_initially_disabled_ap_and_restores_each_original_power_state() {
        for (ap, bluetooth) in [(false, false), (true, true), (true, false)] {
            let mut script = vec![vec![("status\n", status(ap, bluetooth, false))]];
            if !ap {
                script.push(command("on\n"));
            }
            script.extend([
                configure("ok\n"),
                command("bt on\n"),
                vec![("status\n", status(true, true, true))],
                command(if bluetooth { "bt on\n" } else { "bt off\n" }),
                command(if ap { "on\n" } else { "off\n" }),
            ]);
            let (link, task, _) = server(script).await;
            let (_stop, cancel) = watch::channel(false);
            let (lease, live) = RadioLease::prepare(link, &network(), cancel).await.unwrap();
            assert!(live.enabled && live.bluetooth_enabled);
            assert_eq!(live.country.as_deref(), Some("DE"));
            lease.close().await.unwrap();
            finished(task).await;
        }
    }

    #[tokio::test]
    async fn rejected_or_cancelled_apply_restores_ap_before_returning() {
        for cancelled in [false, true] {
            let (link, task, waiting) = server(vec![
                vec![("status\n", status(false, false, false))],
                command("on\n"),
                configure(if cancelled {
                    "hold"
                } else {
                    "error apply failed\n"
                }),
                command("off\n"),
            ])
            .await;
            let (stop, cancel) = watch::channel(false);
            let preparing =
                tokio::spawn(async move { RadioLease::prepare(link, &network(), cancel).await });
            if cancelled {
                waiting.await.unwrap();
                stop.send_replace(true);
            }
            let error = preparing.await.unwrap().err().unwrap();
            assert!(error.downcast_ref::<CleanupUnconfirmed>().is_none());
            finished(task).await;
        }
    }

    #[tokio::test]
    async fn both_restorations_are_attempted_and_cleanup_failure_is_typed_for_the_supervisor() {
        let (link, task, _) = server(vec![
            vec![("status\n", status(true, false, false))],
            configure("ok\n"),
            command("bt on\n"),
            vec![("status\n", status(true, true, true))],
            vec![("bt off\n", "error bluetooth\n".into())],
            vec![("on\n", "error wifi\n".into())],
        ])
        .await;
        let (_stop, cancel) = watch::channel(false);
        let (lease, _) = RadioLease::prepare(link, &network(), cancel).await.unwrap();
        let error = lease.close().await.unwrap_err();
        let cleanup = error.downcast_ref::<CleanupUnconfirmed>().unwrap();
        assert!(cleanup.0.contains("Bluetooth power"));
        assert!(cleanup.0.contains("AP power"));
        finished(task).await;
    }

    #[tokio::test]
    async fn missing_regulatory_country_refuses_mutation_instead_of_guessing() {
        let (link, task, _) = server(vec![vec![(
            "status\n",
            "state off\nbt off\nchannel 36\nok\n".into(),
        )]])
        .await;
        let (_stop, cancel) = watch::channel(false);
        let error = RadioLease::prepare(link, &network(), cancel)
            .await
            .err()
            .unwrap();
        assert!(error.to_string().contains("regulatory country"));
        finished(task).await;
    }

    struct FakePhones {
        endings: VecDeque<Result<PhoneSessionEnd>>,
        accepted: usize,
        delays: Vec<Duration>,
        turn_off_on_wait: Option<Arc<AtomicBool>>,
        stop_on_wait: Option<watch::Sender<bool>>,
        lose_transport_on_wait: bool,
    }
    impl FakePhones {
        fn new(endings: Vec<Result<PhoneSessionEnd>>) -> Self {
            Self {
                endings: endings.into(),
                accepted: 0,
                delays: Vec::new(),
                turn_off_on_wait: None,
                stop_on_wait: None,
                lose_transport_on_wait: false,
            }
        }
    }
    impl PhoneSessions for FakePhones {
        async fn serve_next(&mut self) -> Result<PhoneSessionEnd> {
            self.accepted += 1;
            self.endings
                .pop_front()
                .expect("unexpected extra phone attempt")
        }
        async fn wait_retry(&mut self, delay: Duration) -> Result<()> {
            self.delays.push(delay);
            if let Some(policy) = &self.turn_off_on_wait {
                policy.store(false, Ordering::SeqCst);
            }
            if let Some(stop) = &self.stop_on_wait {
                stop.send_replace(true);
                return std::future::pending().await;
            }
            if self.lose_transport_on_wait {
                return Err(TransportEnded("synthetic HCI loss".into()).into());
            }
            tokio::time::sleep(delay).await;
            Ok(())
        }
    }

    fn failed_phone() -> Result<PhoneSessionEnd> {
        Ok(PhoneSessionEnd::Failed(
            io::Error::other("phone EOF").into(),
        ))
    }

    #[tokio::test(start_paused = true)]
    async fn same_wireless_owner_retries_phones_with_bounded_backoff_until_explicit_disconnect() {
        let mut endings = (0..7).map(|_| failed_phone()).collect::<Vec<_>>();
        endings.push(Ok(PhoneSessionEnd::UserDisconnected));
        let mut phones = FakePhones::new(endings);
        let (_stop, cancel) = watch::channel(false);
        assert!(serve_phones(&mut phones, || true, cancel).await.unwrap());
        assert_eq!(phones.accepted, 8);
        assert_eq!(
            phones
                .delays
                .iter()
                .map(Duration::as_secs)
                .collect::<Vec<_>>(),
            [2, 4, 8, 16, 30, 30, 30],
        );
    }

    #[tokio::test(start_paused = true)]
    async fn manual_connection_and_live_auto_connect_off_never_accept_another_phone() {
        for ending in [Ok(PhoneSessionEnd::Disconnected), failed_phone()] {
            let mut phones = FakePhones::new(vec![ending]);
            let (_stop, cancel) = watch::channel(false);
            let _ = serve_phones(&mut phones, || false, cancel).await;
            assert_eq!(phones.accepted, 1);
            assert!(phones.delays.is_empty());
        }
        let enabled = Arc::new(AtomicBool::new(true));
        let mut phones = FakePhones::new(vec![failed_phone()]);
        phones.turn_off_on_wait = Some(enabled.clone());
        let (_stop, cancel) = watch::channel(false);
        assert!(
            !serve_phones(&mut phones, || enabled.load(Ordering::SeqCst), cancel)
                .await
                .unwrap()
        );
        assert_eq!(phones.accepted, 1);
    }

    #[tokio::test(start_paused = true)]
    async fn stop_cancels_retry_delay_and_transport_loss_exits_without_reaccepting() {
        for transport_loss in [false, true] {
            let mut phones = FakePhones::new(vec![failed_phone()]);
            let (stop, cancel) = watch::channel(false);
            if transport_loss {
                phones.lose_transport_on_wait = true;
            } else {
                phones.stop_on_wait = Some(stop);
            }
            let result = serve_phones(&mut phones, || true, cancel).await;
            if transport_loss {
                assert!(
                    result
                        .unwrap_err()
                        .downcast_ref::<TransportEnded>()
                        .is_some()
                );
            } else {
                assert!(!result.unwrap());
            }
            assert_eq!(phones.accepted, 1);
            assert_eq!(phones.delays.len(), 1);
        }
    }

    #[tokio::test]
    async fn owner_failure_keeps_fatal_cleanup_classification_without_retry() {
        let mut phones = FakePhones::new(vec![Err(CleanupUnconfirmed("synthetic".into()).into())]);
        let (_stop, cancel) = watch::channel(false);
        let result = serve_phones(&mut phones, || true, cancel).await;
        assert!(
            result
                .unwrap_err()
                .downcast_ref::<CleanupUnconfirmed>()
                .is_some()
        );
        assert_eq!(phones.accepted, 1);
        assert!(phones.delays.is_empty());
    }
}
