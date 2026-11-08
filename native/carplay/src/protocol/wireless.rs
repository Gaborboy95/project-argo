//! Bluetooth iAP2 bring-up using LIVI's reliable link engine. The RFCOMM
//! descriptor and AirPlay/AP resources belong to the caller, not this module.
//! Wire research and vendored engine: f-io/LIVI bfbea31e; see vendor notices.
use super::{Error as ProtocolError, csm, now_playing, wired};
use crate::link::LinkClient;
use iap2_link::{CONTROL_SESSION_ID, Event, LinkConfig, LinkEngine, LinkState};
use std::{collections::VecDeque, io, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::watch,
    time::{Instant, timeout},
};

struct Control<S> {
    stream: S,
    engine: LinkEngine,
    started: Instant,
    bytes: Vec<u8>,
    negotiated: bool,
    ready: VecDeque<csm::Message>,
    updates: now_playing::Updates,
}

impl<S: AsyncRead + AsyncWrite + Unpin> Control<S> {
    fn new_with_updates(stream: S, updates: Option<watch::Sender<now_playing::Metadata>>) -> Self {
        Self::new_transport(stream, updates, false)
    }
    fn new_transport(
        stream: S,
        updates: Option<watch::Sender<now_playing::Metadata>>,
        tunnel: bool,
    ) -> Self {
        let updates = now_playing::Updates::new(updates);
        let mut engine = LinkEngine::new(LinkConfig {
            max_outgoing: 4,
            control_version: 2,
            zero_ack: tunnel,
            ..LinkConfig::default()
        });
        // Only implemented sessions are advertised. Artwork remains optional.
        engine.lsp.sessions.retain(|s| {
            s.id == CONTROL_SESSION_ID
                || updates.available() && s.id == now_playing::FILE_TRANSFER_SESSION
        });
        engine.start(tunnel, 0);
        Self {
            stream,
            engine,
            started: Instant::now(),
            bytes: Vec::new(),
            negotiated: false,
            ready: VecDeque::new(),
            updates,
        }
    }

    fn now(&self) -> u64 {
        self.started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64
    }

    async fn flush(&mut self) -> Result<(), wired::Error> {
        let pending = self.engine.take_output();
        timeout(Duration::from_secs(3), self.stream.write_all(&pending))
            .await
            .map_err(|_| ProtocolError::Timeout)??;
        Ok(())
    }

    async fn send(&mut self, message: csm::Message) -> Result<(), wired::Error> {
        let maximum = usize::from(self.engine.lsp.max_len);
        if maximum < 64 {
            return Err(ProtocolError::Bounds.into());
        }
        for part in message.encode()?.chunks(maximum - 10) {
            self.engine
                .send(CONTROL_SESSION_ID, part.to_vec(), self.now());
        }
        self.flush().await
    }

    async fn message(&mut self) -> Result<csm::Message, wired::Error> {
        loop {
            // Also drain ACK/retransmission output before returning buffered CSM.
            self.flush().await?;
            if let Some(message) = self.ready.pop_front() {
                if self.updates.observe(&message) {
                    continue;
                }
                return Ok(message);
            }
            if self.bytes.len() >= 6 {
                if self.bytes[..2] != [0x40, 0x40] {
                    return Err(ProtocolError::Malformed.into());
                }
                let size = usize::from(u16::from_be_bytes([self.bytes[2], self.bytes[3]]));
                if !(6..=65525).contains(&size) {
                    return Err(ProtocolError::Bounds.into());
                }
                if self.bytes.len() >= size {
                    let message = csm::Message::decode(&self.bytes[..size])?;
                    self.bytes.drain(..size);
                    if self.updates.observe(&message) {
                        continue;
                    }
                    return Ok(message);
                }
            }
            let now = self.now();
            let delay = self
                .engine
                .next_deadline()
                .map(|at| Duration::from_millis(at.saturating_sub(now)))
                .unwrap_or(Duration::from_secs(3600));
            let mut input = [0; 8192];
            tokio::select! {
                result = self.stream.read(&mut input) => {
                    let size = result?;
                    if size == 0 { return Err(io::Error::from(io::ErrorKind::UnexpectedEof).into()); }
                    self.engine.feed(&input[..size], self.now());
                }
                _ = tokio::time::sleep(delay) => {}
            }
            self.engine.advance_time(self.now());
            if self.engine.state() == LinkState::Normal
                && (self.engine.lsp.max_len < 64
                    || !(1..=127).contains(&self.engine.lsp.max_outgoing)
                    || !self.engine.lsp.sessions.iter().any(|s| {
                        s.id == CONTROL_SESSION_ID && s.kind == 0 && (1..=2).contains(&s.version)
                    }))
            {
                // Negotiation parameters contain no phone identity, pairing
                // material, certificate, or network credentials.
                eprintln!(
                    "CarPlay unsupported Bluetooth link parameters: frame={}, window={}, session_count={}, sessions={:?}",
                    self.engine.lsp.max_len,
                    self.engine.lsp.max_outgoing,
                    self.engine.lsp.sessions.len(),
                    &self.engine.lsp.sessions[..self.engine.lsp.sessions.len().min(8)],
                );
                return Err(ProtocolError::Unsupported.into());
            }
            if self.engine.state() == LinkState::Normal && !self.negotiated {
                self.negotiated = true;
                eprintln!(
                    "CarPlay Bluetooth link ready: frame={}, window={}, session_count={}, sessions={:?}",
                    self.engine.lsp.max_len,
                    self.engine.lsp.max_outgoing,
                    self.engine.lsp.sessions.len(),
                    &self.engine.lsp.sessions[..self.engine.lsp.sessions.len().min(8)],
                );
            }
            while let Some(event) = self.engine.poll_event() {
                match event {
                    Event::Control(bytes) => {
                        if self.bytes.len() + bytes.len() > 131050 {
                            return Err(ProtocolError::Bounds.into());
                        }
                        self.bytes.extend(bytes);
                        // Consume metadata in wire order before FT events from
                        // the same read; FTID and track identity must be known.
                        while self.bytes.len() >= 6 {
                            if self.bytes[..2] != [0x40, 0x40] {
                                return Err(ProtocolError::Malformed.into());
                            }
                            let size =
                                usize::from(u16::from_be_bytes([self.bytes[2], self.bytes[3]]));
                            if !(6..=65525).contains(&size) {
                                return Err(ProtocolError::Bounds.into());
                            }
                            if self.bytes.len() < size {
                                break;
                            }
                            let message = csm::Message::decode(&self.bytes[..size])?;
                            self.bytes.drain(..size);
                            if !self.updates.observe(&message) {
                                if self.ready.len() >= 64 {
                                    return Err(ProtocolError::Bounds.into());
                                }
                                self.ready.push_back(message);
                            }
                        }
                    }
                    Event::FileTransfer(bytes)
                        if self
                            .engine
                            .lsp
                            .sessions
                            .iter()
                            .any(|s| s.id == now_playing::FILE_TRANSFER_SESSION && s.kind == 1) =>
                    {
                        if let Some(reply) = self.updates.artwork(&bytes) {
                            self.engine
                                .send(now_playing::FILE_TRANSFER_SESSION, reply, self.now());
                        }
                    }
                    Event::Dead { .. } => return Err(ProtocolError::Rejected.into()),
                    _ => {}
                }
            }
        }
    }
}

async fn authenticate<S: AsyncRead + AsyncWrite + Unpin>(
    control: &mut Control<S>,
    link: &LinkClient,
    identity: csm::Message,
    state: &watch::Sender<wired::State>,
) -> Result<(), wired::Error> {
    timeout(Duration::from_secs(30), async {
        state.send_replace(wired::State::Synchronizing);
        if control.message().await? != csm::Message::empty(csm::START_IDENTIFICATION) {
            return Err(ProtocolError::State.into());
        }
        state.send_replace(wired::State::Identifying);
        control.send(identity).await?;
        csm::identification_accepted(&control.message().await?)?;
        Ok::<_, wired::Error>(())
    })
    .await
    .map_err(|_| ProtocolError::Timeout)??;
    state.send_replace(wired::State::Authenticating);
    let started = Instant::now();
    let mut auth = csm::Authentication::new(Duration::ZERO);
    timeout(Duration::from_secs(15), async {
        loop {
            let message = control.message().await?;
            let action = auth.receive(&message, started.elapsed())?;
            let reply = match action {
                csm::AuthenticationAction::ReadRealCertificate => {
                    state.send_replace(wired::State::ReadingCertificate);
                    auth.certificate(
                        link.authentication_certificate()
                            .await
                            .map_err(wired::Error::Mfi)?,
                        started.elapsed(),
                    )?
                }
                csm::AuthenticationAction::SignWithRealCoprocessor(challenge) => {
                    state.send_replace(wired::State::SigningChallenge);
                    let reply = auth.signature(
                        link.sign(&challenge).await.map_err(wired::Error::Mfi)?,
                        started.elapsed(),
                    )?;
                    state.send_replace(wired::State::WaitingForAuthenticationResult);
                    reply
                }
                csm::AuthenticationAction::Complete => return Ok(()),
                csm::AuthenticationAction::Send(_) => return Err(ProtocolError::State.into()),
            };
            if let csm::AuthenticationAction::Send(message) = reply {
                control.send(message).await?;
            }
        }
    })
    .await
    .map_err(|_| ProtocolError::Timeout)?
}

async fn session<S: AsyncRead + AsyncWrite + Unpin>(
    control: &mut Control<S>,
    link: &LinkClient,
    config: wired::Configuration,
    controller: [u8; 6],
    state: &watch::Sender<wired::State>,
) -> Result<(), wired::Error> {
    let csm::SessionTransport::Wireless { ssid, .. } = &config.start_session.transport else {
        return Err(ProtocolError::Unsupported.into());
    };
    let identity = config.identity.wireless_message(controller, ssid)?;
    let start = config.start_session.message()?;
    let wifi = config.start_session.wifi_configuration()?;
    authenticate(control, link, identity, state).await?;
    let artwork = control
        .engine
        .lsp
        .sessions
        .iter()
        .any(|s| s.id == now_playing::FILE_TRANSFER_SESSION && s.kind == 1 && s.version == 2);
    for subscription in control.updates.subscribe(artwork)? {
        control.send(subscription).await?;
    }
    state.send_replace(wired::State::WaitingForAvailability);
    // Human approval on iPhone happens after MFi authentication. Keep this
    // separate from silent negotiation/authentication deadlines.
    timeout(Duration::from_secs(90), async {
        for _ in 0..64 {
            let message = control.message().await?;
            eprintln!(
                "CarPlay Bluetooth control after authentication: message={:#06x}, parameter_ids={:?}",
                message.id,
                message.parameters.iter().take(8).map(|p| p.id).collect::<Vec<_>>(),
            );
            match message.id {
                csm::REQUEST_WIFI_CONFIGURATION => {
                    control.send(wifi.clone()).await?;
                    eprintln!("CarPlay Bluetooth: Wi-Fi configuration sent");
                }
                csm::AVAILABILITY => {
                    wireless_available(&message)?;
                    control.send(start.clone()).await?;
                    state.send_replace(wired::State::StartSessionSent);
                    return Ok::<_, wired::Error>(());
                }
                0x4e0d | 0x4e0e => {}
                _ => return Err(ProtocolError::Unsupported.into()),
            }
        }
        Err(ProtocolError::Bounds.into())
    })
    .await
    .map_err(|_| ProtocolError::Timeout)??;
    loop {
        let message = control.message().await?;
        match message.id {
            csm::REQUEST_WIFI_CONFIGURATION => control.send(wifi.clone()).await?,
            csm::AVAILABILITY => {
                wireless_available(&message)?;
                control.send(start.clone()).await?;
            }
            csm::AUTH_FAILED | csm::IDENTIFICATION_REJECTED => {
                return Err(ProtocolError::Rejected.into());
            }
            _ => {}
        }
    }
}

fn wireless_available(message: &csm::Message) -> Result<(), ProtocolError> {
    let fields = csm::decode_parameters(message.one(1)?)?;
    let mut available = fields.iter().filter(|p| p.id == 0);
    if available.next().is_none_or(|p| p.value != [1]) || available.next().is_some() {
        return Err(ProtocolError::Rejected);
    }
    Ok(())
}

/// No detached tasks: cancellation, EOF and startup timeout release RFCOMM.
pub async fn run<S: AsyncRead + AsyncWrite + Unpin>(
    stream: S,
    link: &LinkClient,
    configuration: wired::Configuration,
    controller: [u8; 6],
    stop: watch::Receiver<bool>,
    state: watch::Sender<wired::State>,
) -> Result<(), wired::Error> {
    run_with_updates(stream, link, configuration, controller, stop, state, None).await
}

pub async fn run_with_updates<S: AsyncRead + AsyncWrite + Unpin>(
    stream: S,
    link: &LinkClient,
    configuration: wired::Configuration,
    controller: [u8; 6],
    mut stop: watch::Receiver<bool>,
    state: watch::Sender<wired::State>,
    updates: Option<watch::Sender<now_playing::Metadata>>,
) -> Result<(), wired::Error> {
    let mut control = Control::new_with_updates(stream, updates);
    let result = tokio::select! {
        biased;
        _ = async { let _ = stop.wait_for(|v| *v).await; } => Err(wired::Error::Cancelled),
        result = session(&mut control, link, configuration, controller, &state) => result,
    };
    if matches!(result, Err(wired::Error::Cancelled)) {
        for stop in control.updates.unsubscribe() {
            let _ = timeout(Duration::from_millis(250), control.send(stop)).await;
        }
    }
    state.send_replace(wired::State::Closed);
    result
}

/// WiFi iAP is independent of the Bluetooth discovery/control link after RECORD.
#[cfg(feature = "airplay")]
#[allow(clippy::too_many_arguments)]
pub async fn run_with_handover<S, D>(
    stream: S,
    link: &LinkClient,
    configuration: wired::Configuration,
    controller: [u8; 6],
    mut stop: watch::Receiver<bool>,
    state: watch::Sender<wired::State>,
    updates: watch::Sender<now_playing::Metadata>,
    handover: super::handover::ControlSide,
    disconnect: D,
) -> Result<(), wired::Error>
where
    S: AsyncRead + AsyncWrite + Unpin,
    D: std::future::Future<Output = std::result::Result<(), String>>,
{
    let super::handover::ControlSide {
        recorded,
        mut disable,
        mut failure,
        failed: failure_sender,
        incoming,
        outgoing,
    } = handover;
    let disable_state = disable.clone();
    let bt_configuration = configuration.clone();
    let bt_updates = updates.clone();
    let mut bluetooth = Some(Box::pin(async {
        let mut control = Control::new_with_updates(stream, Some(bt_updates));
        session(&mut control, link, bt_configuration, controller, &state).await
    }));
    let mut wifi = Some(Box::pin(wifi_control(
        recorded,
        incoming,
        outgoing,
        link,
        configuration,
        controller,
        updates,
    )));
    tokio::pin!(disconnect);
    let mut failed = false;
    let mut disconnecting = false;
    let mut disconnected = false;
    loop {
        tokio::select! {
            biased;
            _=async {let _=stop.wait_for(|value|*value).await;}=>return Err(wired::Error::Cancelled),
            changed=async {disable.wait_for(|value|*value).await.map(|_|())},if !disconnecting && !disconnected=>{
                if changed.is_err(){return Err(ProtocolError::State.into());}
                // Close RFCOMM before awaiting BlueZ, but retain every AirPlay/AP owner.
                bluetooth.take();
                disconnecting=true;
                eprintln!("CarPlay Bluetooth handover: dropping selected peer");
            }
            result=&mut disconnect,if disconnecting=>{
                disconnecting=false;disconnected=true;
                eprintln!("CarPlay Bluetooth handover: selected peer disconnect success={}",result.is_ok());
            }
            result=async {bluetooth.as_mut().unwrap().as_mut().await},if bluetooth.is_some()=>{
                bluetooth.take();
                if !*disable_state.borrow(){return result;}
            }
            changed=async{failure.wait_for(|value|*value).await.map(|_|())},if !failed=>{
                failed=true;
                wifi.take();
                if changed.is_ok(){eprintln!("CarPlay optional Wi-Fi iAP bridge disabled");}
            }
            result=async{wifi.as_mut().unwrap().as_mut().await},if wifi.is_some()=>{
                wifi.take();
                failure_sender.send_replace(true);
                eprintln!("CarPlay optional Wi-Fi iAP control ended: success={}",result.is_ok());
            }
        }
    }
}

#[cfg(feature = "airplay")]
#[allow(clippy::too_many_arguments)]
async fn wifi_control(
    mut recorded: watch::Receiver<bool>,
    mut incoming: tokio::sync::mpsc::Receiver<Vec<u8>>,
    outgoing: tokio::sync::mpsc::Sender<Vec<u8>>,
    link: &LinkClient,
    configuration: wired::Configuration,
    controller: [u8; 6],
    updates: watch::Sender<now_playing::Metadata>,
) -> Result<(), wired::Error> {
    recorded
        .wait_for(|value| *value)
        .await
        .map_err(|_| ProtocolError::State)?;
    let (stream, bridge) = tokio::io::duplex(131072);
    let (mut reader, mut writer) = tokio::io::split(bridge);
    let into_link = async {
        while let Some(bytes) = incoming.recv().await {
            if !(1..=super::handover::MAX_CHUNK).contains(&bytes.len()) {
                return Err(ProtocolError::Bounds.into());
            }
            writer.write_all(&bytes).await?;
        }
        Err::<(), wired::Error>(ProtocolError::State.into())
    };
    let from_link = async {
        let mut bytes = [0; 8192];
        loop {
            let size = reader.read(&mut bytes).await?;
            if size == 0 {
                return Err(ProtocolError::State.into());
            }
            outgoing
                .send(bytes[..size].to_vec())
                .await
                .map_err(|_| ProtocolError::State)?;
        }
        #[allow(unreachable_code)]
        Ok::<(), wired::Error>(())
    };
    let (quiet_state, _) = watch::channel(wired::State::Synchronizing);
    let mut control = Control::new_transport(stream, Some(updates), true);
    eprintln!("CarPlay Wi-Fi iAP control: negotiating zero-ACK link");
    tokio::select! {
        result=tunnel_session(&mut control,link,configuration,controller,&quiet_state)=>result,
        result=into_link=>result,
        result=from_link=>result,
    }
}

#[cfg(feature = "airplay")]
async fn tunnel_session<S: AsyncRead + AsyncWrite + Unpin>(
    control: &mut Control<S>,
    link: &LinkClient,
    configuration: wired::Configuration,
    controller: [u8; 6],
    state: &watch::Sender<wired::State>,
) -> Result<(), wired::Error> {
    let csm::SessionTransport::Wireless { ssid, .. } = &configuration.start_session.transport
    else {
        return Err(ProtocolError::Unsupported.into());
    };
    authenticate(
        control,
        link,
        configuration.identity.wireless_message(controller, ssid)?,
        state,
    )
    .await?;
    let artwork = control
        .engine
        .lsp
        .sessions
        .iter()
        .any(|s| s.id == now_playing::FILE_TRANSFER_SESSION && s.kind == 1 && s.version == 2);
    for message in control.updates.subscribe(artwork)? {
        control.send(message).await?;
    }
    eprintln!("CarPlay Wi-Fi iAP control: authenticated and subscribed");
    loop {
        let message = control.message().await?;
        if [csm::AUTH_FAILED, csm::IDENTIFICATION_REJECTED].contains(&message.id) {
            return Err(ProtocolError::Rejected.into());
        }
        // AirPlay is already recorded: never launch another session or resend Wi-Fi credentials.
    }
}

#[cfg(all(test, feature = "airplay"))]
mod handover_tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    };
    use tokio::{
        io::{DuplexStream, duplex},
        task::JoinHandle,
    };
    struct Running {
        receiver: super::super::handover::ReceiverSide,
        phone: DuplexStream,
        cancel: watch::Sender<bool>,
        state: watch::Receiver<wired::State>,
        metadata: watch::Receiver<now_playing::Metadata>,
        disconnected: Arc<AtomicBool>,
        task: JoinHandle<Result<(), wired::Error>>,
    }
    fn config() -> wired::Configuration {
        wired::Configuration {
            identity: csm::AccessoryIdentity {
                name: "Argo".into(),
                model: "Fixture".into(),
                manufacturer: "Argo".into(),
                serial: "synthetic".into(),
                firmware: "1".into(),
                hardware: "1".into(),
                language: "en".into(),
                usb_interface: 0,
            },
            start_session: csm::StartSession {
                transport: csm::SessionTransport::Wireless {
                    address: "192.0.2.1".parse().unwrap(),
                    ssid: "Fixture".into(),
                    passphrase: "synthetic-secret".into(),
                    channel: 36,
                    security: csm::WirelessSecurity::Wpa2,
                },
                port: 7000,
                device_identifier: "02:00:00:00:00:02".into(),
                public_key: [8; 32],
                source_version: "1".into(),
            },
        }
    }
    fn running(start_handover: bool, fail_bridge: bool) -> Running {
        let (receiver, control) =
            super::super::handover::channel([2, 0, 0, 0, 0, 1], [2, 0, 0, 0, 0, 2]);
        if start_handover {
            receiver.recorded.send_replace(true);
            assert!(receiver.request_disable("02:00:00:00:00:01"));
        }
        if fail_bridge {
            assert!(receiver.fail());
        }
        let (host, phone) = duplex(65536);
        let (cancel, stop) = watch::channel(false);
        let (state, observed) = watch::channel(wired::State::StartSessionSent);
        let (updates, metadata) = watch::channel(now_playing::Metadata {
            battery_percent: Some(42),
            ..Default::default()
        });
        let disconnected = Arc::new(AtomicBool::new(false));
        let dropped = disconnected.clone();
        let task = tokio::spawn(async move {
            let link = LinkClient::new(Default::default()).unwrap();
            run_with_handover(
                host,
                &link,
                config(),
                [2, 0, 0, 0, 0, 2],
                stop,
                state,
                updates,
                control,
                async move {
                    dropped.store(true, Ordering::SeqCst);
                    Ok(())
                },
            )
            .await
        });
        Running {
            receiver,
            phone,
            cancel,
            state: observed,
            metadata,
            disconnected,
            task,
        }
    }
    #[tokio::test]
    async fn unrequested_bluetooth_eof_still_ends_the_session() {
        let running = running(false, false);
        drop(running.phone);
        let result = timeout(Duration::from_secs(1), running.task)
            .await
            .unwrap()
            .unwrap();
        assert!(result.is_err());
        assert!(!running.disconnected.load(Ordering::SeqCst));
    }
    #[tokio::test]
    async fn requested_bluetooth_eof_and_optional_iap_failure_preserve_recorded_owner_until_cancel()
    {
        let mut running = running(true, false);
        drop(running.phone);
        let initial = timeout(Duration::from_secs(1), running.receiver.outgoing.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(
            initial
                .windows(6)
                .any(|bytes| bytes == iap2_link::IAP2_MARKER)
        );
        for _ in 0..4 {
            tokio::task::yield_now().await;
        }
        assert!(running.disconnected.load(Ordering::SeqCst));
        assert_eq!(*running.state.borrow(), wired::State::StartSessionSent);
        assert!(!running.task.is_finished());
        assert!(running.receiver.fail());
        assert!(!running.receiver.fail(), "optional failure is latched once");
        for _ in 0..4 {
            tokio::task::yield_now().await;
        }
        assert!(
            !running.task.is_finished(),
            "optional iAP EOF/pressure cannot end AirPlay"
        );
        assert_eq!(running.metadata.borrow().battery_percent, Some(42));
        assert_eq!(*running.state.borrow(), wired::State::StartSessionSent);
        running.cancel.send_replace(true);
        assert!(matches!(
            timeout(Duration::from_secs(1), running.task)
                .await
                .unwrap()
                .unwrap(),
            Err(wired::Error::Cancelled)
        ));
    }
    #[tokio::test]
    async fn failed_optional_bridge_does_not_disconnect_bluetooth_or_end_the_session() {
        let running = running(false, true);
        for _ in 0..4 {
            tokio::task::yield_now().await;
        }
        assert!(!running.receiver.request_disable("02:00:00:00:00:01"));
        assert!(!running.disconnected.load(Ordering::SeqCst));
        assert!(!running.task.is_finished());
        running.cancel.send_replace(true);
        assert!(matches!(
            timeout(Duration::from_secs(1), running.task)
                .await
                .unwrap()
                .unwrap(),
            Err(wired::Error::Cancelled)
        ));
    }
}
