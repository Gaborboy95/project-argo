//! ARPM/1 native encoded-video producer, separate from AA control IPC7.
//!
//! See native/projection/argo-projection-view/README.md for the wire contract.
//! The CarPlay avcC/hvcC framing distinction was informed by f-io / Lasse
//! Heitgres and LIVI a23dc0c5fcdb6d069c679eddfd73298e58f44783, specifically
//! cp/stack/{screenStream,nalu}.ts. This is Argo-owned code, not imported LIVI.
//! No phone authentication, encryption downgrade, socket discovery, or production
//! synthetic session occurs here. Only an authenticated native transport owner
//! may submit negotiated main-screen video to this boundary.

use std::collections::VecDeque;
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;
use tokio::sync::{Notify, watch};

pub const VERSION: u16 = 1;
pub const HEADER_SIZE: usize = 24;
pub const CONFIG_LIMIT: usize = 64 * 1024;
pub const ACCESS_UNIT_LIMIT: usize = 4 * 1024 * 1024;
pub const QUEUE_LIMIT: usize = 3;
const NAL_LIMIT: usize = 1024;
const WRITE_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Protocol {
    AndroidAuto = 1,
    CarPlay = 2,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Plane {
    Main = 1,
    Cluster = 2,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Codec {
    H264 = 1,
    H265 = 2,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Colorimetry {
    Bt601 = 1,
    Bt709 = 2,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum ColorRange {
    Limited = 1,
    Full = 2,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Framing {
    AnnexB = 1,
    LengthPrefixed = 2,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Description {
    pub protocol: Protocol,
    pub plane: Plane,
    pub codec: Codec,
    pub colorimetry: Colorimetry,
    pub range: ColorRange,
    pub framing: Framing,
    pub width: u16,
    pub height: u16,
    pub fps_num: u16,
    pub fps_den: u16,
    pub session: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Crop {
    pub left: u16,
    pub top: u16,
    pub right: u16,
    pub bottom: u16,
}

#[derive(Debug)]
pub enum Error {
    InvalidDescription,
    InvalidConfiguration,
    InvalidAccessUnit,
    Timestamp,
    Closed,
    AlreadyServing,
    SequenceExhausted,
    Timeout,
    Io(io::Error),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(f, "native projection media I/O: {error}"),
            _ => write!(f, "native projection media {self:?}"),
        }
    }
}
impl std::error::Error for Error {}
impl From<io::Error> for Error {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

impl Description {
    pub fn encode(self) -> Result<[u8; 24], Error> {
        if self.session == 0
            || self.width == 0
            || self.width > 1920
            || self.height == 0
            || self.height > 1080
            || self.fps_den == 0
            || self.fps_den > 1001
            || self.fps_num < self.fps_den
            || u32::from(self.fps_num) > 60 * u32::from(self.fps_den)
        {
            return Err(Error::InvalidDescription);
        }
        let mut bytes = [0_u8; 24];
        bytes[..6].copy_from_slice(&[
            self.protocol as u8,
            self.plane as u8,
            self.codec as u8,
            self.colorimetry as u8,
            self.range as u8,
            self.framing as u8,
        ]);
        for (offset, value) in [
            (6, self.width),
            (8, self.height),
            (10, self.fps_num),
            (12, self.fps_den),
        ] {
            bytes[offset..offset + 2].copy_from_slice(&value.to_be_bytes());
        }
        bytes[16..24].copy_from_slice(&self.session.to_be_bytes());
        Ok(bytes)
    }

    /// Metadata-only native creation parameters; this does not activate a view.
    pub fn view_parameters(self, crop: Crop) -> Result<[u8; 40], Error> {
        if self.plane != Plane::Main
            || u32::from(crop.left) + u32::from(crop.right) >= u32::from(self.width)
            || u32::from(crop.top) + u32::from(crop.bottom) >= u32::from(self.height)
        {
            return Err(Error::InvalidDescription);
        }
        let mut bytes = [0_u8; 40];
        bytes[..4].copy_from_slice(b"ARV2");
        bytes[4..8].copy_from_slice(&1_u32.to_be_bytes());
        bytes[8..32].copy_from_slice(&self.encode()?);
        for (offset, value) in [
            (32, crop.left),
            (34, crop.top),
            (36, crop.right),
            (38, crop.bottom),
        ] {
            bytes[offset..offset + 2].copy_from_slice(&value.to_be_bytes());
        }
        Ok(bytes)
    }
}

fn nal_type(bytes: &[u8], codec: Codec) -> Option<u8> {
    if bytes.is_empty() || bytes[0] & 0x80 != 0 {
        return None;
    }
    match codec {
        Codec::H264 => {
            let kind = bytes[0] & 31;
            (kind > 0 && kind < 24).then_some(kind)
        }
        Codec::H265 if bytes.len() >= 2 && bytes[1] & 7 != 0 => {
            let kind = (bytes[0] >> 1) & 63;
            (kind < 48).then_some(kind)
        }
        _ => None,
    }
}

fn parameter_bit(codec: Codec, kind: u8) -> u8 {
    match (codec, kind) {
        (Codec::H264, 7) | (Codec::H265, 32) => 1,
        (Codec::H264, 8) | (Codec::H265, 33) => 2,
        (Codec::H265, 34) => 4,
        _ => 0,
    }
}

fn start_code(bytes: &[u8]) -> Option<usize> {
    if bytes.starts_with(&[0, 0, 1]) {
        Some(3)
    } else if bytes.starts_with(&[0, 0, 0, 1]) {
        Some(4)
    } else {
        None
    }
}

#[derive(Default)]
struct Nals {
    parameters: u8,
    keyframe: bool,
    picture: bool,
}

fn inspect_nals(
    mut bytes: &[u8],
    codec: Codec,
    framing: Framing,
    length: usize,
    config: bool,
) -> Option<Nals> {
    let mut count = 0;
    let mut result = Nals::default();
    while !bytes.is_empty() {
        count += 1;
        if count > NAL_LIMIT {
            return None;
        }
        let size;
        match framing {
            Framing::AnnexB => {
                bytes = bytes.get(start_code(bytes)?..)?;
                size = (0..bytes.len())
                    .find(|&i| start_code(&bytes[i..]).is_some())
                    .unwrap_or(bytes.len());
            }
            Framing::LengthPrefixed => {
                if ![1, 2, 4].contains(&length) || bytes.len() < length {
                    return None;
                }
                size = bytes[..length]
                    .iter()
                    .fold(0_usize, |v, b| (v << 8) | usize::from(*b));
                bytes = &bytes[length..];
            }
        }
        let nal = bytes.get(..size)?;
        let kind = nal_type(nal, codec)?;
        let bit = parameter_bit(codec, kind);
        if config && bit == 0 {
            return None;
        }
        result.parameters |= bit;
        result.keyframe |= match codec {
            Codec::H264 => kind == 5,
            Codec::H265 => (16..=21).contains(&kind),
        };
        result.picture |= match codec {
            Codec::H264 => (1..=5).contains(&kind),
            Codec::H265 => kind <= 31,
        };
        bytes = &bytes[size..];
    }
    if count == 0 {
        return None;
    }
    if config && result.parameters != if codec == Codec::H264 { 3 } else { 7 } {
        return None;
    }
    Some(result)
}

struct ConfigReader<'a> {
    bytes: &'a [u8],
    offset: usize,
    count: usize,
    parameters: u8,
    codec: Codec,
}
impl ConfigReader<'_> {
    fn byte(&mut self) -> Option<u8> {
        let value = *self.bytes.get(self.offset)?;
        self.offset += 1;
        Some(value)
    }
    fn word(&mut self) -> Option<usize> {
        Some((usize::from(self.byte()?) << 8) | usize::from(self.byte()?))
    }
    fn nals(&mut self, count: usize, expected_type: u8) -> Option<()> {
        for _ in 0..count {
            self.count += 1;
            if self.count > NAL_LIMIT {
                return None;
            }
            let size = self.word()?;
            let nal = self
                .bytes
                .get(self.offset..self.offset.checked_add(size)?)?;
            let kind = nal_type(nal, self.codec)?;
            if kind != expected_type {
                return None;
            }
            self.parameters |= parameter_bit(self.codec, kind);
            self.offset += size;
        }
        Some(())
    }
}

fn configuration(bytes: &[u8], codec: Codec, framing: Framing) -> Option<usize> {
    if bytes.is_empty() || bytes.len() > CONFIG_LIMIT {
        return None;
    }
    if framing == Framing::AnnexB {
        inspect_nals(bytes, codec, framing, 0, true)?;
        return Some(0);
    }
    let minimum = if codec == Codec::H264 { 7 } else { 23 };
    if bytes.len() < minimum || bytes[0] != 1 {
        return None;
    }
    let length = usize::from((bytes[if codec == Codec::H264 { 4 } else { 21 }] & 3) + 1);
    if length == 3 {
        return None;
    }
    let mut reader = ConfigReader {
        bytes,
        offset: if codec == Codec::H264 { 6 } else { 23 },
        count: 0,
        parameters: 0,
        codec,
    };
    if codec == Codec::H264 {
        if bytes[4] & 0xfc != 0xfc || bytes[5] & 0xe0 != 0xe0 {
            return None;
        }
        reader.nals(usize::from(bytes[5] & 31), 7)?;
        let count = usize::from(reader.byte()?);
        reader.nals(count, 8)?;
        if reader.offset < bytes.len() {
            if ![100, 110, 122, 144].contains(&bytes[1])
                || reader.byte()? & 0xfc != 0xfc
                || reader.byte()? & 0xf8 != 0xf8
                || reader.byte()? & 0xf8 != 0xf8
            {
                return None;
            }
            let count = usize::from(reader.byte()?);
            reader.nals(count, 13)?;
        }
    } else {
        for _ in 0..bytes[22] {
            let kind = reader.byte()?;
            if kind & 0x40 != 0 {
                return None;
            }
            let count = reader.word()?;
            reader.nals(count, kind & 63)?;
        }
    }
    (reader.offset == bytes.len() && reader.parameters == if codec == Codec::H264 { 3 } else { 7 })
        .then_some(length)
}

struct AccessUnit {
    payload: Arc<[u8]>,
    timestamp: u64,
    keyframe: bool,
    discontinuity: bool,
}
struct State {
    queue: VecDeque<AccessUnit>,
    need_keyframe: bool,
    serving: bool,
    closed: bool,
    last_timestamp: Option<u64>,
}
struct Inner {
    description: Description,
    encoded_description: [u8; 24],
    configuration: Arc<[u8]>,
    length_bytes: usize,
    state: Mutex<State>,
    changed: Notify,
    stopped: watch::Sender<bool>,
}

/// A bounded, single-consumer stream. Clones share ownership, not frame queues.
#[derive(Clone)]
pub struct VideoStream {
    inner: Arc<Inner>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PublishOutcome {
    Queued,
    /// Delta pictures were discarded after overflow; request a keyframe natively.
    NeedKeyframe,
    /// A new keyframe replaced queued pictures and carries discontinuity.
    Resynchronized,
}

impl VideoStream {
    pub fn new(description: Description, config: &[u8]) -> Result<Self, Error> {
        let encoded_description = description.encode()?;
        if description.plane != Plane::Main {
            return Err(Error::InvalidDescription);
        }
        let length_bytes = configuration(config, description.codec, description.framing)
            .ok_or(Error::InvalidConfiguration)?;
        let (stopped, _) = watch::channel(false);
        Ok(Self {
            inner: Arc::new(Inner {
                description,
                encoded_description,
                configuration: Arc::from(config),
                length_bytes,
                state: Mutex::new(State {
                    queue: VecDeque::new(),
                    need_keyframe: true,
                    serving: false,
                    closed: false,
                    last_timestamp: None,
                }),
                changed: Notify::new(),
                stopped,
            }),
        })
    }

    /// Validates before allocation. Overflow drops the entire queued dependency
    /// chain and admits no more deltas until a fresh IDR/IRAP picture arrives.
    /// Returned NeedKeyframe must be acted on by the native session owner.
    pub fn publish(
        &self,
        payload: &[u8],
        timestamp_ns: u64,
        keyframe: bool,
    ) -> Result<PublishOutcome, Error> {
        if payload.is_empty() || payload.len() > ACCESS_UNIT_LIMIT {
            return Err(Error::InvalidAccessUnit);
        }
        let nals = inspect_nals(
            payload,
            self.inner.description.codec,
            self.inner.description.framing,
            self.inner.length_bytes,
            false,
        )
        .ok_or(Error::InvalidAccessUnit)?;
        if !nals.picture || nals.keyframe != keyframe {
            return Err(Error::InvalidAccessUnit);
        }
        let mut state = self.inner.state.lock().unwrap();
        if state.closed {
            return Err(Error::Closed);
        }
        if timestamp_ns == u64::MAX || state.last_timestamp.is_some_and(|old| timestamp_ns < old) {
            return Err(Error::Timestamp);
        }
        state.last_timestamp = Some(timestamp_ns);
        if state.queue.len() == QUEUE_LIMIT {
            state.queue.clear();
            state.need_keyframe = true;
        }
        if state.need_keyframe && !keyframe {
            return Ok(PublishOutcome::NeedKeyframe);
        }
        let discontinuity = state.need_keyframe;
        state.need_keyframe = false;
        state.queue.push_back(AccessUnit {
            payload: Arc::from(payload),
            timestamp: timestamp_ns,
            keyframe,
            discontinuity,
        });
        drop(state);
        self.inner.changed.notify_one();
        Ok(if discontinuity {
            PublishOutcome::Resynchronized
        } else {
            PublishOutcome::Queued
        })
    }

    /// Idempotent: wakes idle readers and cancels an in-progress timed write.
    /// It never takes ownership of another service's socket path or process.
    pub fn stop(&self) {
        let mut state = self.inner.state.lock().unwrap();
        state.closed = true;
        state.queue.clear();
        drop(state);
        self.inner.stopped.send_replace(true);
        self.inner.changed.notify_waiters();
    }

    /// Serve one already accepted, same-user native socket. The caller owns
    /// binding/permissions/unlinking and must await this future during teardown.
    /// Dropping/canceling it closes this socket and releases its consumer lease.
    pub async fn send_to(&self, mut socket: UnixStream) -> Result<(), Error> {
        if socket.peer_cred()?.uid() != unsafe { libc::geteuid() } {
            return Err(Error::Io(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "media peer is not the service user",
            )));
        }
        let mut stopped = self.inner.stopped.subscribe();
        {
            let mut state = self.inner.state.lock().unwrap();
            if state.closed {
                return Err(Error::Closed);
            }
            if state.serving {
                return Err(Error::AlreadyServing);
            }
            state.serving = true;
        }
        let _lease = ConsumerLease(self.inner.clone());
        let mut sequence = 0_u64;
        write_record(
            &mut socket,
            &mut stopped,
            &mut sequence,
            1,
            0,
            0,
            &self.inner.encoded_description,
        )
        .await?;
        write_record(
            &mut socket,
            &mut stopped,
            &mut sequence,
            2,
            0,
            0,
            &self.inner.configuration,
        )
        .await?;
        loop {
            let changed = self.inner.changed.notified();
            let next = {
                let mut state = self.inner.state.lock().unwrap();
                if state.closed {
                    return Ok(());
                }
                state.queue.pop_front()
            };
            if let Some(frame) = next {
                let flags = u8::from(frame.keyframe) | (u8::from(frame.discontinuity) << 1);
                write_record(
                    &mut socket,
                    &mut stopped,
                    &mut sequence,
                    3,
                    flags,
                    frame.timestamp,
                    &frame.payload,
                )
                .await?;
            } else {
                tokio::select! {
                    _ = changed => {},
                    _ = stopped.changed() => return Ok(()),
                    result = socket.readable() => {
                        result?;
                        let mut byte = [0_u8; 1];
                        match socket.try_read(&mut byte) {
                            Ok(0) => return Err(Error::Io(io::Error::new(io::ErrorKind::UnexpectedEof, "media consumer disconnected"))),
                            Ok(_) => return Err(Error::Io(io::Error::new(io::ErrorKind::InvalidData, "unexpected data from media consumer"))),
                            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {},
                            Err(error) => return Err(Error::Io(error)),
                        }
                    },
                }
            }
        }
    }
}

struct ConsumerLease(Arc<Inner>);
impl Drop for ConsumerLease {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().unwrap();
        state.serving = false;
        state.queue.clear();
        state.need_keyframe = true;
    }
}

async fn write_record(
    socket: &mut UnixStream,
    stopped: &mut watch::Receiver<bool>,
    sequence: &mut u64,
    kind: u8,
    flags: u8,
    timestamp: u64,
    payload: &[u8],
) -> Result<(), Error> {
    if *stopped.borrow() {
        return Err(Error::Closed);
    }
    let serial = u32::try_from(*sequence).map_err(|_| Error::SequenceExhausted)?;
    let mut header = [0_u8; HEADER_SIZE];
    header[..4].copy_from_slice(b"ARPM");
    header[4..6].copy_from_slice(&VERSION.to_be_bytes());
    header[6] = kind;
    header[7] = flags;
    header[8..12].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    header[12..16].copy_from_slice(&serial.to_be_bytes());
    header[16..24].copy_from_slice(&timestamp.to_be_bytes());
    tokio::select! {
        biased;
        _ = stopped.changed() => return Err(Error::Closed),
        result = tokio::time::timeout(WRITE_TIMEOUT, async {
            socket.write_all(&header).await?;
            socket.write_all(payload).await
        }) => result.map_err(|_| Error::Timeout)??,
    }
    *sequence += 1;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    const CONFIG: &[u8] = &[1, 66, 0, 30, 255, 225, 0, 2, 0x67, 1, 1, 0, 2, 0x68, 1];
    const KEY: &[u8] = &[0, 0, 0, 2, 0x65, 1];
    const DELTA: &[u8] = &[0, 0, 0, 2, 0x41, 1];
    fn description() -> Description {
        Description {
            protocol: Protocol::CarPlay,
            plane: Plane::Main,
            codec: Codec::H264,
            colorimetry: Colorimetry::Bt709,
            range: ColorRange::Full,
            framing: Framing::LengthPrefixed,
            width: 1280,
            height: 720,
            fps_num: 60,
            fps_den: 1,
            session: 42,
        }
    }
    fn stream() -> VideoStream {
        VideoStream::new(description(), CONFIG).unwrap()
    }

    #[test]
    fn creation_descriptor_and_bounds() {
        let d = description();
        assert_eq!(
            d.encode().unwrap(),
            [
                2, 1, 1, 2, 2, 2, 5, 0, 2, 208, 0, 60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 42
            ]
        );
        let parameters = d
            .view_parameters(Crop {
                left: 10,
                bottom: 20,
                ..Crop::default()
            })
            .unwrap();
        assert_eq!(&parameters[..8], b"ARV2\0\0\0\x01");
        assert_eq!(&parameters[8..32], &d.encode().unwrap());
        assert_eq!(&parameters[32..], &[0, 10, 0, 0, 0, 0, 0, 20]);
        assert!(Description { width: 1921, ..d }.encode().is_err());
        assert!(Description { height: 0, ..d }.encode().is_err());
        assert!(Description { fps_den: 0, ..d }.encode().is_err());
        assert!(Description { fps_num: 61, ..d }.encode().is_err());
        assert!(Description { session: 0, ..d }.encode().is_err());
        assert!(
            Description {
                plane: Plane::Cluster,
                ..d
            }
            .view_parameters(Crop::default())
            .is_err()
        );
        assert!(
            d.view_parameters(Crop {
                left: u16::MAX,
                ..Crop::default()
            })
            .is_err()
        );
    }

    #[test]
    fn validates_configuration_nals_timestamps_and_keyframe_truth() {
        for length in 0..CONFIG.len() {
            assert!(VideoStream::new(description(), &CONFIG[..length]).is_err());
        }
        assert!(VideoStream::new(description(), &vec![0; CONFIG_LIMIT + 1]).is_err());
        let s = stream();
        assert!(matches!(
            s.publish(DELTA, 0, true),
            Err(Error::InvalidAccessUnit)
        ));
        assert!(matches!(
            s.publish(KEY, 0, false),
            Err(Error::InvalidAccessUnit)
        ));
        assert_eq!(
            s.publish(DELTA, 1, false).unwrap(),
            PublishOutcome::NeedKeyframe
        );
        assert_eq!(
            s.publish(KEY, 2, true).unwrap(),
            PublishOutcome::Resynchronized
        );
        assert!(matches!(s.publish(KEY, 1, true), Err(Error::Timestamp)));
        assert!(matches!(
            s.publish(KEY, u64::MAX, true),
            Err(Error::Timestamp)
        ));
        for length in 0..KEY.len() {
            assert!(matches!(
                s.publish(&KEY[..length], 3, true),
                Err(Error::InvalidAccessUnit)
            ));
        }
        let mut too_many = Vec::new();
        for _ in 0..=NAL_LIMIT {
            too_many.extend_from_slice(KEY);
        }
        assert!(matches!(
            s.publish(&too_many, 3, true),
            Err(Error::InvalidAccessUnit)
        ));
        assert!(matches!(
            s.publish(&vec![0; ACCESS_UNIT_LIMIT + 1], 3, true),
            Err(Error::InvalidAccessUnit)
        ));
    }

    #[test]
    fn bounded_overflow_discards_dependency_chain_and_waits_for_keyframe() {
        let s = stream();
        s.publish(KEY, 1, true).unwrap();
        s.publish(DELTA, 2, false).unwrap();
        s.publish(DELTA, 3, false).unwrap();
        assert_eq!(s.inner.state.lock().unwrap().queue.len(), QUEUE_LIMIT);
        assert_eq!(
            s.publish(DELTA, 4, false).unwrap(),
            PublishOutcome::NeedKeyframe
        );
        assert!(s.inner.state.lock().unwrap().queue.is_empty());
        assert_eq!(
            s.publish(DELTA, 5, false).unwrap(),
            PublishOutcome::NeedKeyframe
        );
        assert_eq!(
            s.publish(KEY, 6, true).unwrap(),
            PublishOutcome::Resynchronized
        );
        let state = s.inner.state.lock().unwrap();
        assert_eq!(state.queue.len(), 1);
        assert!(state.queue[0].discontinuity);
    }

    #[tokio::test]
    async fn synthetic_sender_matches_shared_cpp_wire_fixture_and_stops() {
        let s = stream();
        s.publish(KEY, 100, true).unwrap();
        let (producer, mut receiver) = UnixStream::pair().unwrap();
        let sender = s.clone();
        let task = tokio::spawn(async move { sender.send_to(producer).await });
        let fixture: Vec<u8> =
            include_str!("../../projection/argo-projection-view/test/fixtures/arpm-v1.hex")
                .split_whitespace()
                .map(|word| u8::from_str_radix(word, 16).unwrap())
                .collect();
        let mut actual = vec![0; fixture.len()];
        tokio::time::timeout(Duration::from_secs(1), receiver.read_exact(&mut actual))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(actual, fixture);
        s.stop();
        tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        let mut end = [0];
        assert_eq!(receiver.read(&mut end).await.unwrap(), 0);
        assert!(matches!(s.publish(KEY, 101, true), Err(Error::Closed)));
        s.stop();
    }

    #[tokio::test]
    async fn one_consumer_idle_disconnect_and_reconnect_need_fresh_keyframe() {
        let s = stream();
        let (producer, mut receiver) = UnixStream::pair().unwrap();
        let sender = s.clone();
        let task = tokio::spawn(async move { sender.send_to(producer).await });
        let mut first = vec![0; 24 + 24 + 24 + CONFIG.len()];
        receiver.read_exact(&mut first).await.unwrap();
        let (another, _other) = UnixStream::pair().unwrap();
        assert!(matches!(
            s.send_to(another).await,
            Err(Error::AlreadyServing)
        ));
        drop(receiver);
        assert!(matches!(
            tokio::time::timeout(Duration::from_secs(1), task)
                .await
                .unwrap()
                .unwrap(),
            Err(Error::Io(_))
        ));
        assert_eq!(
            s.publish(DELTA, 1, false).unwrap(),
            PublishOutcome::NeedKeyframe
        );
        let (producer, mut receiver) = UnixStream::pair().unwrap();
        let sender = s.clone();
        let task = tokio::spawn(async move { sender.send_to(producer).await });
        receiver.read_exact(&mut first).await.unwrap();
        assert_eq!(&first[12..16], &[0, 0, 0, 0]);
        s.publish(KEY, 2, true).unwrap();
        let mut frame = [0_u8; 30];
        receiver.read_exact(&mut frame).await.unwrap();
        assert_eq!(frame[7], 3);
        assert_eq!(&frame[12..16], &[0, 0, 0, 2]);
        s.stop();
        task.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn cancellation_releases_consumer_and_stop_cancels_blocked_write() {
        let s = stream();
        let (producer, mut receiver) = UnixStream::pair().unwrap();
        let sender = s.clone();
        let task = tokio::spawn(async move { sender.send_to(producer).await });
        let mut first = vec![0; 24 + 24 + 24 + CONFIG.len()];
        receiver.read_exact(&mut first).await.unwrap();
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert!(!s.inner.state.lock().unwrap().serving);
        let (producer, _receiver) = UnixStream::pair().unwrap();
        let mut payload = vec![1; ACCESS_UNIT_LIMIT];
        payload[..4].copy_from_slice(&((ACCESS_UNIT_LIMIT - 4) as u32).to_be_bytes());
        payload[4] = 0x65;
        s.publish(&payload, 1, true).unwrap();
        let sender = s.clone();
        let task = tokio::spawn(async move { sender.send_to(producer).await });
        tokio::task::yield_now().await;
        s.stop();
        let result = tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
        assert!(result.is_ok() || matches!(result, Err(Error::Closed)));
        assert!(!s.inner.state.lock().unwrap().serving);
    }

    #[tokio::test(start_paused = true)]
    async fn stalled_consumer_has_bounded_write_timeout() {
        let s = stream();
        let (producer, _receiver) = UnixStream::pair().unwrap();
        let mut payload = vec![1; ACCESS_UNIT_LIMIT];
        payload[..4].copy_from_slice(&((ACCESS_UNIT_LIMIT - 4) as u32).to_be_bytes());
        payload[4] = 0x65;
        s.publish(&payload, 1, true).unwrap();
        assert!(matches!(s.send_to(producer).await, Err(Error::Timeout)));
        assert!(!s.inner.state.lock().unwrap().serving);
    }

    #[tokio::test]
    async fn repeated_reconnects_release_the_consumer_and_queued_pictures() {
        let s = stream();
        for attempt in 0..100 {
            let (producer, mut receiver) = UnixStream::pair().unwrap();
            let sender = s.clone();
            let task = tokio::spawn(async move { sender.send_to(producer).await });
            let mut first = vec![0; 24 + 24 + 24 + CONFIG.len()];
            receiver.read_exact(&mut first).await.unwrap();
            assert_eq!(
                s.publish(DELTA, attempt, false).unwrap(),
                PublishOutcome::NeedKeyframe
            );
            s.publish(KEY, attempt, true).unwrap();
            let mut frame = [0; 30];
            receiver.read_exact(&mut frame).await.unwrap();
            assert_eq!(&frame[12..16], &2_u32.to_be_bytes());
            drop(receiver);
            assert!(matches!(
                tokio::time::timeout(Duration::from_secs(1), task)
                    .await
                    .unwrap()
                    .unwrap(),
                Err(Error::Io(_))
            ));
            let state = s.inner.state.lock().unwrap();
            assert!(!state.serving && state.queue.is_empty() && state.need_keyframe);
        }
        s.stop();
    }

    #[test]
    fn hevc_and_annex_b_configuration_and_access_units() {
        let mut hvcc = vec![0; 23];
        hvcc[0] = 1;
        hvcc[21] = 3;
        hvcc[22] = 3;
        for kind in [32_u8, 33, 34] {
            hvcc.extend_from_slice(&[kind, 0, 1, 0, 2, kind << 1, 1]);
        }
        let h265 = Description {
            codec: Codec::H265,
            ..description()
        };
        let s = VideoStream::new(h265, &hvcc).unwrap();
        assert!(s.publish(&[0, 0, 0, 2, 19 << 1, 1], 0, true).is_ok());
        for length in 0..hvcc.len() {
            assert!(VideoStream::new(h265, &hvcc[..length]).is_err());
        }
        let annex = Description {
            framing: Framing::AnnexB,
            ..description()
        };
        let s = VideoStream::new(annex, &[0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 1]).unwrap();
        assert!(s.publish(&[0, 0, 1, 0x65, 1], 0, true).is_ok());
    }
}
