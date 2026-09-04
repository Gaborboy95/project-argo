//! Android Auto framing and the deliberately bounded version-negotiation
//! checkpoint. USB and future Wi-Fi transports implement the same byte-stream
//! contract; no USB detail is allowed into this module.

use std::collections::BTreeMap;
use std::future::Future;
use std::io;
use std::pin::Pin;

pub const FRAME_HEADER_BYTES: usize = 4;
pub const MAX_FRAME_PAYLOAD_BYTES: usize = 32 * 1024;
pub const MAX_BUFFERED_BYTES: usize = 64 * 1024;

const CONTROL_CHANNEL: u8 = 0;
const FLAGS_PLAINTEXT_SINGLE_FRAME: u8 = 0x03;
const VERSION_REQUEST_ID: u16 = 0x0001;
const VERSION_RESPONSE_ID: u16 = 0x0002;
const VERSION_STATUS_MATCH: u16 = 0x0000;
const REQUESTED_VERSION_MAJOR: u16 = 1;
const REQUESTED_VERSION_MINOR: u16 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPhase {
    VersionNegotiation,
    WaitingForTls,
    TlsHandshake,
    ServiceDiscovery,
    Running,
    Closed,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChannelRole {
    Control,
    MainVideo,
    MediaAudio,
    SpeechAudio,
    SystemAudio,
    Input,
    Microphone,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FrameError {
    OversizedBuffer,
    OversizedPayload(usize),
    DisconnectMidFrame(usize),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    pub channel: u8,
    pub flags: u8,
    pub payload: Vec<u8>,
}

pub fn encode_frame(frame: &Frame) -> Result<Vec<u8>, FrameError> {
    if frame.payload.len() > MAX_FRAME_PAYLOAD_BYTES {
        return Err(FrameError::OversizedPayload(frame.payload.len()));
    }
    let mut bytes = Vec::with_capacity(FRAME_HEADER_BYTES + frame.payload.len());
    bytes.push(frame.channel);
    bytes.push(frame.flags);
    bytes.extend_from_slice(&(frame.payload.len() as u16).to_be_bytes());
    bytes.extend_from_slice(&frame.payload);
    Ok(bytes)
}

/// Incrementally splits Android Auto's byte stream. USB transfer boundaries
/// are intentionally ignored: a read may contain a partial frame or several.
#[derive(Default)]
pub struct FrameDecoder {
    buffered: Vec<u8>,
}

impl FrameDecoder {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Frame>, FrameError> {
        if self.buffered.len().saturating_add(bytes.len()) > MAX_BUFFERED_BYTES {
            self.buffered.clear();
            return Err(FrameError::OversizedBuffer);
        }
        self.buffered.extend_from_slice(bytes);

        let mut frames = Vec::new();
        loop {
            if self.buffered.len() < FRAME_HEADER_BYTES {
                break;
            }
            let length = u16::from_be_bytes([self.buffered[2], self.buffered[3]]) as usize;
            if length > MAX_FRAME_PAYLOAD_BYTES {
                self.buffered.clear();
                return Err(FrameError::OversizedPayload(length));
            }
            let frame_length = FRAME_HEADER_BYTES + length;
            if self.buffered.len() < frame_length {
                break;
            }
            frames.push(Frame {
                channel: self.buffered[0],
                flags: self.buffered[1],
                payload: self.buffered[FRAME_HEADER_BYTES..frame_length].to_vec(),
            });
            self.buffered.drain(..frame_length);
        }
        Ok(frames)
    }

    pub fn disconnect(&mut self) -> Result<(), FrameError> {
        if self.buffered.is_empty() {
            return Ok(());
        }
        let buffered = self.buffered.len();
        self.buffered.clear();
        Err(FrameError::DisconnectMidFrame(buffered))
    }
}

pub trait AndroidAutoTransport: Send {
    fn read<'a>(
        &'a mut self,
        bytes: &'a mut [u8],
    ) -> Pin<Box<dyn Future<Output = io::Result<usize>> + Send + 'a>>;

    fn write_all<'a>(
        &'a mut self,
        bytes: &'a [u8],
    ) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + 'a>>;

    fn close(&mut self) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + '_>>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct VersionResponse {
    pub major: u16,
    pub minor: u16,
}

#[derive(Debug)]
pub enum VersionNegotiationError {
    Transport(io::Error),
    Frame(FrameError),
    Disconnected,
    UnexpectedFrame,
    MalformedResponse,
    VersionMismatch { major: u16, minor: u16 },
    RejectedStatus(u16),
}

impl std::fmt::Display for VersionNegotiationError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Transport(error) => write!(formatter, "transport: {error}"),
            Self::Frame(error) => write!(formatter, "frame: {error:?}"),
            Self::Disconnected => {
                write!(formatter, "transport disconnected before VersionResponse")
            }
            Self::UnexpectedFrame => write!(formatter, "unexpected frame before VersionResponse"),
            Self::MalformedResponse => write!(formatter, "malformed Android Auto VersionResponse"),
            Self::VersionMismatch { major, minor } => {
                write!(
                    formatter,
                    "phone rejected Android Auto protocol {major}.{minor}"
                )
            }
            Self::RejectedStatus(status) => {
                write!(formatter, "VersionResponse returned status 0x{status:04x}")
            }
        }
    }
}

impl std::error::Error for VersionNegotiationError {}

impl From<io::Error> for VersionNegotiationError {
    fn from(value: io::Error) -> Self {
        Self::Transport(value)
    }
}

impl From<FrameError> for VersionNegotiationError {
    fn from(value: FrameError) -> Self {
        Self::Frame(value)
    }
}

pub fn version_request_frame() -> Frame {
    let mut payload = Vec::with_capacity(6);
    payload.extend_from_slice(&VERSION_REQUEST_ID.to_be_bytes());
    payload.extend_from_slice(&REQUESTED_VERSION_MAJOR.to_be_bytes());
    payload.extend_from_slice(&REQUESTED_VERSION_MINOR.to_be_bytes());
    Frame {
        channel: CONTROL_CHANNEL,
        flags: FLAGS_PLAINTEXT_SINGLE_FRAME,
        payload,
    }
}

pub fn parse_version_response(frame: &Frame) -> Result<VersionResponse, VersionNegotiationError> {
    if frame.channel != CONTROL_CHANNEL || frame.flags != FLAGS_PLAINTEXT_SINGLE_FRAME {
        return Err(VersionNegotiationError::UnexpectedFrame);
    }
    if frame.payload.len() < 8 {
        return Err(VersionNegotiationError::MalformedResponse);
    }
    let message_id = u16::from_be_bytes([frame.payload[0], frame.payload[1]]);
    if message_id != VERSION_RESPONSE_ID {
        return Err(VersionNegotiationError::UnexpectedFrame);
    }
    let major = u16::from_be_bytes([frame.payload[2], frame.payload[3]]);
    let minor = u16::from_be_bytes([frame.payload[4], frame.payload[5]]);
    let status = u16::from_be_bytes([frame.payload[6], frame.payload[7]]);
    if status == u16::MAX {
        return Err(VersionNegotiationError::VersionMismatch { major, minor });
    }
    if status != VERSION_STATUS_MATCH {
        return Err(VersionNegotiationError::RejectedStatus(status));
    }
    Ok(VersionResponse { major, minor })
}

/// Sends exactly one VersionRequest and stops after parsing VersionResponse.
/// TLS is intentionally not entered by this Milestone 14.1 checkpoint.
pub async fn negotiate_version(
    transport: &mut impl AndroidAutoTransport,
) -> Result<VersionResponse, VersionNegotiationError> {
    let request = encode_frame(&version_request_frame())?;
    transport.write_all(&request).await?;
    println!("AA VersionRequest sent");

    let mut decoder = FrameDecoder::default();
    let mut input = [0_u8; 16 * 1024];
    loop {
        let count = transport.read(&mut input).await?;
        if count == 0 {
            decoder.disconnect()?;
            return Err(VersionNegotiationError::Disconnected);
        }
        if let Some(frame) = decoder.push(&input[..count])?.into_iter().next() {
            let response = parse_version_response(&frame)?;
            println!("AA VersionResponse received");
            return Ok(response);
        }
    }
}

pub struct AndroidAutoSessionEngine {
    phase: SessionPhase,
    channels: BTreeMap<u8, ChannelRole>,
}

impl Default for AndroidAutoSessionEngine {
    fn default() -> Self {
        Self {
            phase: SessionPhase::VersionNegotiation,
            channels: BTreeMap::new(),
        }
    }
}

impl AndroidAutoSessionEngine {
    pub fn phase(&self) -> SessionPhase {
        self.phase
    }

    pub fn version_accepted(&mut self) {
        if self.phase == SessionPhase::VersionNegotiation {
            self.phase = SessionPhase::WaitingForTls;
        }
    }

    pub fn begin_tls(&mut self) {
        if self.phase == SessionPhase::WaitingForTls {
            self.phase = SessionPhase::TlsHandshake;
        }
    }

    pub fn tls_established(&mut self) {
        if self.phase == SessionPhase::TlsHandshake {
            self.phase = SessionPhase::ServiceDiscovery;
        }
    }

    pub fn services_discovered(&mut self, channels: impl IntoIterator<Item = (u8, ChannelRole)>) {
        if self.phase != SessionPhase::ServiceDiscovery {
            return;
        }
        self.channels.extend(channels);
        self.phase = SessionPhase::Running;
    }

    pub fn channel(&self, id: u8) -> Option<ChannelRole> {
        self.channels.get(&id).copied()
    }

    pub fn disconnect(&mut self) {
        self.channels.clear();
        self.phase = SessionPhase::Closed;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    struct FakeTransport {
        reads: VecDeque<io::Result<Vec<u8>>>,
        writes: Vec<Vec<u8>>,
        closed: bool,
    }

    impl FakeTransport {
        fn with_reads(reads: impl IntoIterator<Item = Vec<u8>>) -> Self {
            Self {
                reads: reads.into_iter().map(Ok).collect(),
                writes: Vec::new(),
                closed: false,
            }
        }
    }

    impl AndroidAutoTransport for FakeTransport {
        fn read<'a>(
            &'a mut self,
            bytes: &'a mut [u8],
        ) -> Pin<Box<dyn Future<Output = io::Result<usize>> + Send + 'a>> {
            Box::pin(async move {
                match self.reads.pop_front() {
                    Some(Ok(value)) => {
                        bytes[..value.len()].copy_from_slice(&value);
                        Ok(value.len())
                    }
                    Some(Err(error)) => Err(error),
                    None => Ok(0),
                }
            })
        }

        fn write_all<'a>(
            &'a mut self,
            bytes: &'a [u8],
        ) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + 'a>> {
            Box::pin(async move {
                self.writes.push(bytes.to_vec());
                Ok(())
            })
        }

        fn close(&mut self) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + '_>> {
            Box::pin(async move {
                self.closed = true;
                Ok(())
            })
        }
    }

    fn response_frame(major: u16, minor: u16) -> Vec<u8> {
        encode_frame(&Frame {
            channel: CONTROL_CHANNEL,
            flags: FLAGS_PLAINTEXT_SINGLE_FRAME,
            payload: [
                VERSION_RESPONSE_ID.to_be_bytes(),
                major.to_be_bytes(),
                minor.to_be_bytes(),
                VERSION_STATUS_MATCH.to_be_bytes(),
            ]
            .concat(),
        })
        .unwrap()
    }

    #[test]
    fn split_version_response_across_reads() {
        let wire = response_frame(1, 7);
        let mut decoder = FrameDecoder::default();
        assert!(decoder.push(&wire[..3]).unwrap().is_empty());
        assert!(decoder.push(&wire[3..8]).unwrap().is_empty());
        let frames = decoder.push(&wire[8..]).unwrap();
        assert_eq!(
            parse_version_response(&frames[0]).unwrap(),
            VersionResponse { major: 1, minor: 7 }
        );
    }

    #[test]
    fn two_frames_in_one_read_are_preserved() {
        let first = response_frame(1, 6);
        let second = response_frame(1, 7);
        let frames = FrameDecoder::default()
            .push(&[first, second].concat())
            .unwrap();
        assert_eq!(frames.len(), 2);
        assert_eq!(parse_version_response(&frames[1]).unwrap().minor, 7);
    }

    #[test]
    fn oversized_declared_length_is_rejected() {
        let length = (MAX_FRAME_PAYLOAD_BYTES + 1) as u16;
        let length_bytes = length.to_be_bytes();
        let wire = [
            0,
            FLAGS_PLAINTEXT_SINGLE_FRAME,
            length_bytes[0],
            length_bytes[1],
        ];
        assert_eq!(
            FrameDecoder::default().push(&wire),
            Err(FrameError::OversizedPayload(length as usize))
        );
    }

    #[test]
    fn disconnect_mid_frame_is_reported() {
        let mut decoder = FrameDecoder::default();
        decoder.push(&[0, 3, 0, 8, 0, 2]).unwrap();
        assert_eq!(decoder.disconnect(), Err(FrameError::DisconnectMidFrame(6)));
    }

    #[test]
    fn version_response_is_parsed() {
        let frames = FrameDecoder::default().push(&response_frame(1, 7)).unwrap();
        assert_eq!(
            parse_version_response(&frames[0]).unwrap(),
            VersionResponse { major: 1, minor: 7 }
        );
    }

    #[tokio::test]
    async fn negotiation_writes_request_and_waits_for_response() {
        let response = response_frame(1, 7);
        let mut transport =
            FakeTransport::with_reads([response[..5].to_vec(), response[5..].to_vec()]);
        assert_eq!(
            negotiate_version(&mut transport).await.unwrap(),
            VersionResponse { major: 1, minor: 7 }
        );
        assert_eq!(transport.writes, vec![vec![0, 3, 0, 6, 0, 1, 0, 1, 0, 1]]);
    }

    #[test]
    fn session_does_not_enter_tls_before_version_response() {
        let mut session = AndroidAutoSessionEngine::default();
        assert_eq!(session.phase(), SessionPhase::VersionNegotiation);
        session.begin_tls();
        assert_eq!(session.phase(), SessionPhase::VersionNegotiation);
        session.version_accepted();
        assert_eq!(session.phase(), SessionPhase::WaitingForTls);
    }

    #[test]
    fn later_session_phases_remain_modular_but_are_not_started() {
        let mut session = AndroidAutoSessionEngine::default();
        session.version_accepted();
        session.begin_tls();
        session.tls_established();
        session.services_discovered([(2, ChannelRole::MainVideo), (3, ChannelRole::Input)]);
        assert_eq!(session.phase(), SessionPhase::Running);
        assert_eq!(session.channel(2), Some(ChannelRole::MainVideo));
        session.disconnect();
        assert_eq!(session.phase(), SessionPhase::Closed);
    }
}
