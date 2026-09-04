//! Native media descriptors. Encoded video and PCM travel over dedicated local
//! channels and bounded queues; they are never represented in Dart IPC.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VideoCodec {
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
