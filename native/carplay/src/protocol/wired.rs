//! Experimental wired iAP2 control over an already-open carkit TLS stream.
//! The caller owns trusted-phone discovery, lockdown and the host USB-NCM
//! interface. This does not listen for or implement authenticated AirPlay.
//! Protocol interoperability research: see `protocol/mod.rs`.

use super::{Error as ProtocolError, csm, iap2};
use crate::link::LinkClient;
use std::time::Duration;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::watch,
    time::{Instant, timeout},
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum State {
    Synchronizing,
    Identifying,
    Authenticating,
    ReadingCertificate,
    SigningChallenge,
    WaitingForAuthenticationResult,
    WaitingForAvailability,
    StartSessionSent,
    Closed,
}

#[derive(Debug)]
pub enum Error {
    Protocol(ProtocolError),
    Io(std::io::ErrorKind),
    Mfi(crate::link::Error),
    Cancelled,
}

impl From<ProtocolError> for Error {
    fn from(error: ProtocolError) -> Self {
        Self::Protocol(error)
    }
}
impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.kind())
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Protocol(e) => e.fmt(f),
            Self::Io(e) => write!(f, "wired connection {e:?}"),
            Self::Mfi(e) => e.fmt(f),
            Self::Cancelled => write!(f, "wired session cancelled"),
        }
    }
}
impl std::error::Error for Error {}

pub struct Configuration {
    pub identity: csm::AccessoryIdentity,
    /// Supply only after a real authenticated AirPlay listener and host network
    /// interface are ready. Sending this message is not projection acceptance.
    pub start_session: csm::StartSession,
}

struct Control<S> {
    stream: S,
    sent: u8,
    received: u8,
    max_frame: usize,
    csm_bytes: Vec<u8>,
}

impl<S: AsyncRead + AsyncWrite + Unpin> Control<S> {
    async fn frame(&mut self) -> Result<iap2::Frame, Error> {
        let mut header = [0; 9];
        self.stream.read_exact(&mut header[..2]).await?;
        if header[..2] == iap2::DETECT[..2] {
            let mut rest = [0; 4];
            self.stream.read_exact(&mut rest).await?;
            if rest != iap2::DETECT[2..] {
                return Err(ProtocolError::Malformed.into());
            }
            self.stream.read_exact(&mut header[..2]).await?;
        }
        self.stream.read_exact(&mut header[2..]).await?;
        let length = usize::from(u16::from_be_bytes([header[2], header[3]]));
        if !(9..=iap2::MAX_FRAME).contains(&length) || length == 10 {
            return Err(ProtocolError::Bounds.into());
        }
        let mut bytes = Vec::with_capacity(length);
        bytes.extend_from_slice(&header);
        bytes.resize(length, 0);
        self.stream.read_exact(&mut bytes[9..]).await?;
        let frame = iap2::Frame::decode(&bytes)?;
        if frame.flags & iap2::RST != 0 {
            return Err(ProtocolError::Rejected.into());
        }
        Ok(frame)
    }

    async fn write_frame(&mut self, frame: &iap2::Frame) -> Result<(), Error> {
        let bytes = frame.encode()?;
        if bytes.len() > self.max_frame {
            return Err(ProtocolError::Bounds.into());
        }
        self.stream.write_all(&bytes).await?;
        Ok(())
    }

    async fn synchronize(&mut self) -> Result<(), Error> {
        let sync = iap2::Synchronization {
            window: 4,
            max_frame: u16::MAX,
            retransmit_ms: 0,
            ack_ms: 0,
            retries: 0,
            ack_count: 0,
            sessions: vec![iap2::Session {
                id: iap2::CONTROL_SESSION,
                kind: 0,
                version: 2,
            }],
        };
        self.stream.write_all(&iap2::DETECT).await?;
        self.write_frame(&iap2::Frame {
            flags: iap2::SYN,
            sequence: self.sent,
            acknowledgement: 0,
            session: 0,
            payload: sync.encode()?,
        })
        .await?;
        let mut got_syn = false;
        for _ in 0..8 {
            let frame = self.frame().await?;
            if frame.session != 0 {
                return Err(ProtocolError::State.into());
            }
            if frame.flags & iap2::SYN != 0 {
                let peer = iap2::Synchronization::decode(&frame.payload)?;
                if peer.retransmit_ms != 0
                    || !peer
                        .sessions
                        .iter()
                        .any(|s| s.id == iap2::CONTROL_SESSION && s.kind == 0 && s.version == 2)
                {
                    return Err(ProtocolError::Unsupported.into());
                }
                self.max_frame = usize::from(peer.max_frame);
                self.received = frame.sequence;
                got_syn = true;
                self.write_frame(&iap2::Frame {
                    flags: iap2::ACK,
                    sequence: self.sent,
                    acknowledgement: self.received,
                    session: 0,
                    payload: vec![],
                })
                .await?;
            }
            if frame.flags & iap2::ACK != 0 && got_syn && frame.acknowledgement == self.sent {
                return Ok(());
            }
        }
        Err(ProtocolError::State.into())
    }

    async fn send(&mut self, message: csm::Message) -> Result<(), Error> {
        let bytes = message.encode()?;
        for part in bytes.chunks(self.max_frame - 10) {
            self.sent = self.sent.wrapping_add(1);
            self.write_frame(&iap2::Frame {
                flags: iap2::ACK,
                sequence: self.sent,
                acknowledgement: self.received,
                session: iap2::CONTROL_SESSION,
                payload: part.to_vec(),
            })
            .await?;
        }
        Ok(())
    }

    async fn message(&mut self) -> Result<csm::Message, Error> {
        loop {
            if self.csm_bytes.len() >= 6 {
                if self.csm_bytes[..2] != [0x40, 0x40] {
                    return Err(ProtocolError::Malformed.into());
                }
                let length =
                    usize::from(u16::from_be_bytes([self.csm_bytes[2], self.csm_bytes[3]]));
                if !(6..=65525).contains(&length) {
                    return Err(ProtocolError::Bounds.into());
                }
                if self.csm_bytes.len() >= length {
                    let message = csm::Message::decode(&self.csm_bytes[..length])?;
                    self.csm_bytes.drain(..length);
                    return Ok(message);
                }
            }
            let frame = self.frame().await?;
            if frame.flags != iap2::ACK {
                return Err(ProtocolError::Unsupported.into());
            }
            if frame.payload.is_empty() {
                continue;
            }
            if frame.session != iap2::CONTROL_SESSION {
                return Err(ProtocolError::Unsupported.into());
            }
            if frame.sequence == self.received {
                continue;
            } // Retransmitted data must not sign twice.
            if frame.sequence != self.received.wrapping_add(1) {
                return Err(ProtocolError::Sequence.into());
            }
            self.received = frame.sequence;
            if self.csm_bytes.len() + frame.payload.len() > 65525 {
                return Err(ProtocolError::Bounds.into());
            }
            self.csm_bytes.extend(frame.payload);
        }
    }
}

/// Owns and drops `stream` on EOF, malformed input, failed MFi operation,
/// cancellation or startup deadline. There are no spawned child tasks or queues.
/// The state channel reports control progress only; no state means video ready.
pub async fn run<S: AsyncRead + AsyncWrite + Unpin>(
    stream: S,
    link: &LinkClient,
    configuration: Configuration,
    mut cancelled: watch::Receiver<bool>,
    state: watch::Sender<State>,
) -> Result<(), Error> {
    let mut control = Control {
        stream,
        sent: 31,
        received: 0,
        max_frame: iap2::MAX_FRAME,
        csm_bytes: Vec::new(),
    };
    let result = tokio::select! {
        biased;
        _ = wait_cancelled(&mut cancelled) => Err(Error::Cancelled),
        result = async {
            timeout(Duration::from_secs(30), bring_up(&mut control, link, &configuration, &state))
                .await.map_err(|_| Error::Protocol(ProtocolError::Timeout))??;
            loop {
                // Maintain link ownership until unplug/EOF or explicit cancellation.
                // Metadata subscriptions are not advertised by this minimal identity.
                let message = control.message().await?;
                if [csm::AUTH_FAILED, csm::IDENTIFICATION_REJECTED].contains(&message.id) {
                    return Err(ProtocolError::Rejected.into());
                }
            }
        } => result,
    };
    state.send_replace(State::Closed);
    result
}

async fn wait_cancelled(receiver: &mut watch::Receiver<bool>) {
    loop {
        if *receiver.borrow_and_update() {
            return;
        }
        if receiver.changed().await.is_err() {
            return;
        }
    }
}

async fn bring_up<S: AsyncRead + AsyncWrite + Unpin>(
    control: &mut Control<S>,
    link: &LinkClient,
    config: &Configuration,
    state: &watch::Sender<State>,
) -> Result<(), Error> {
    // Validate host-supplied settings before sending any bytes to the phone.
    if !matches!(
        config.start_session.transport,
        csm::SessionTransport::Wired { .. }
    ) {
        return Err(ProtocolError::Unsupported.into());
    }
    let identity = config.identity.wired_message()?;
    let start = config.start_session.message()?;
    authenticate(control, link, identity, state).await?;
    state.send_replace(State::WaitingForAvailability);
    for _ in 0..16 {
        let message = control.message().await?;
        if message.id == csm::AVAILABILITY {
            let parameters = csm::decode_parameters(message.one(0)?)?;
            if parameters.iter().filter(|p| p.id == 0).count() != 1
                || !parameters.iter().any(|p| p.id == 0 && p.value == [1])
            {
                return Err(ProtocolError::Rejected.into());
            }
            control.send(start).await?;
            state.send_replace(State::StartSessionSent);
            return Ok(());
        }
        // Transport-identifier notifications may precede availability.
        if message.id != 0x4e0e {
            return Err(ProtocolError::Unsupported.into());
        }
    }
    Err(ProtocolError::Bounds.into())
}

async fn authenticate<S: AsyncRead + AsyncWrite + Unpin>(
    control: &mut Control<S>,
    link: &LinkClient,
    identity: csm::Message,
    state: &watch::Sender<State>,
) -> Result<(), Error> {
    state.send_replace(State::Synchronizing);
    control.synchronize().await?;
    state.send_replace(State::Identifying);
    if control.message().await? != csm::Message::empty(csm::START_IDENTIFICATION) {
        return Err(ProtocolError::State.into());
    }
    control.send(identity).await?;
    if control.message().await? != csm::Message::empty(csm::IDENTIFICATION_ACCEPTED) {
        return Err(ProtocolError::Rejected.into());
    }
    state.send_replace(State::Authenticating);
    let started = Instant::now();
    let mut auth = csm::Authentication::new(Duration::ZERO);
    loop {
        let message = timeout(
            Duration::from_secs(15).saturating_sub(started.elapsed()),
            control.message(),
        )
        .await
        .map_err(|_| Error::Protocol(ProtocolError::Timeout))??;
        let action = auth.receive(&message, started.elapsed())?;
        let reply = match action {
            csm::AuthenticationAction::ReadRealCertificate => {
                state.send_replace(State::ReadingCertificate);
                auth.certificate(
                    link.authentication_certificate()
                        .await
                        .map_err(Error::Mfi)?,
                    started.elapsed(),
                )?
            }
            csm::AuthenticationAction::SignWithRealCoprocessor(challenge) => {
                state.send_replace(State::SigningChallenge);
                let reply = auth.signature(
                    link.sign(&challenge).await.map_err(Error::Mfi)?,
                    started.elapsed(),
                )?;
                state.send_replace(State::WaitingForAuthenticationResult);
                reply
            }
            csm::AuthenticationAction::Complete => break,
            csm::AuthenticationAction::Send(_) => return Err(ProtocolError::State.into()),
        };
        if let csm::AuthenticationAction::Send(reply) = reply {
            control.send(reply).await?;
        }
    }
    Ok(())
}

/// Authenticate the actual phone with the actual Link, then close without StartSession.
/// This is the physical bring-up check before enabling a network listener.
pub async fn authenticate_only<S: AsyncRead + AsyncWrite + Unpin>(
    stream: S,
    link: &LinkClient,
    identity: csm::AccessoryIdentity,
    state: watch::Sender<State>,
) -> Result<(), Error> {
    let identity = identity.wired_message()?;
    let mut control = Control {
        stream,
        sent: 31,
        received: 0,
        max_frame: iap2::MAX_FRAME,
        csm_bytes: Vec::new(),
    };
    let result = timeout(
        Duration::from_secs(30),
        authenticate(&mut control, link, identity, &state),
    )
    .await
    .map_err(|_| Error::Protocol(ProtocolError::Timeout))
    .and_then(|result| result);
    state.send_replace(State::Closed);
    result
}
