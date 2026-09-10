//! Native media descriptors. Encoded video and PCM travel over dedicated local
//! channels and bounded queues; they are never represented in Dart IPC.

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum VideoCodec {
    #[default]
    H264,
    Hevc,
    Vp9,
    Av1,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AudioRole {
    Media,
    Speech,
    System,
    Communication,
}

pub const VIDEO_QUEUE_DEPTH: usize = 8;
pub const AUDIO_QUEUE_DEPTH: usize = 32;

impl VideoCodec {
    pub fn wire(self) -> u8 {
        match self {
            Self::H264 => 0,
            Self::Hevc => 1,
            Self::Vp9 => 2,
            Self::Av1 => 3,
        }
    }
    pub fn parameter(self, nal: u8) -> bool {
        match self {
            Self::H264 => matches!(nal, 7 | 8),
            Self::Hevc => matches!(nal, 32..=34),
            _ => false,
        }
    }
}
