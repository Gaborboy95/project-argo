//! Android Auto session state. Transport framing, TLS, service discovery and
//! media channels are represented independently; no credential is bundled.

use std::collections::BTreeMap;

pub const MAX_FRAME_BYTES: usize = 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionPhase {
    VersionNegotiation,
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

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    TooShort,
    TooLarge(usize),
    Truncated,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    pub channel: u8,
    pub flags: u8,
    pub payload: Vec<u8>,
}

pub fn decode_frame(bytes: &[u8]) -> Result<Frame, FrameError> {
    if bytes.len() < 4 {
        return Err(FrameError::TooShort);
    }
    let length = u16::from_be_bytes([bytes[2], bytes[3]]) as usize;
    if length > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(length));
    }
    if bytes.len() != 4 + length {
        return Err(FrameError::Truncated);
    }
    Ok(Frame {
        channel: bytes[0],
        flags: bytes[1],
        payload: bytes[4..].to_vec(),
    })
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

    #[test]
    fn session_phases_and_channels_are_modular() {
        let mut session = AndroidAutoSessionEngine::default();
        session.version_accepted();
        assert_eq!(session.phase(), SessionPhase::TlsHandshake);
        session.tls_established();
        session.services_discovered([
            (1, ChannelRole::Control),
            (2, ChannelRole::MainVideo),
            (3, ChannelRole::Input),
        ]);
        assert_eq!(session.phase(), SessionPhase::Running);
        assert_eq!(session.channel(2), Some(ChannelRole::MainVideo));
        session.disconnect();
        assert_eq!(session.phase(), SessionPhase::Closed);
    }

    #[test]
    fn truncated_frame_is_rejected() {
        assert_eq!(decode_frame(&[1, 0, 0, 3, 9]), Err(FrameError::Truncated));
    }
}
