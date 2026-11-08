//! Bluetooth iAP2 bring-up using LIVI's reliable link engine. The RFCOMM
//! descriptor and AirPlay/AP resources belong to the caller, not this module.
//! Wire research and vendored engine: f-io/LIVI bfbea31e; see vendor notices.
use super::{Error as ProtocolError, csm, wired};
use crate::link::LinkClient;
use iap2_link::{CONTROL_SESSION_ID, Event, LinkConfig, LinkEngine, LinkState};
use std::{io, time::Duration};
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
}

impl<S: AsyncRead + AsyncWrite + Unpin> Control<S> {
    fn new(stream: S) -> Self {
        let mut engine = LinkEngine::new(LinkConfig {
            max_outgoing: 4,
            control_version: 2,
            ..LinkConfig::default()
        });
        // Argo advertises neither EA nor file-transfer/artwork support here.
        engine.lsp.sessions.retain(|s| s.id == CONTROL_SESSION_ID);
        engine.start(false, 0);
        Self {
            stream,
            engine,
            started: Instant::now(),
            bytes: Vec::new(),
            negotiated: false,
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
        if control.message().await? != csm::Message::empty(csm::IDENTIFICATION_ACCEPTED) {
            return Err(ProtocolError::Rejected.into());
        }
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
    mut stop: watch::Receiver<bool>,
    state: watch::Sender<wired::State>,
) -> Result<(), wired::Error> {
    let mut control = Control::new(stream);
    let result = tokio::select! {
        biased;
        _ = async { let _ = stop.wait_for(|v| *v).await; } => Err(wired::Error::Cancelled),
        result = session(&mut control, link, configuration, controller, &state) => result,
    };
    state.send_replace(wired::State::Closed);
    result
}
