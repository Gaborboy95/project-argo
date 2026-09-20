//! iAP2 wire framing and bounded reliability primitives; no transport ownership.
//! Protocol research provenance is recorded in the parent module.

use super::Error;
use std::{collections::VecDeque, time::Duration};

pub const DETECT: [u8; 6] = [0xff, 0x55, 0x02, 0x00, 0xee, 0x10];
pub const SYN: u8 = 0x80;
pub const ACK: u8 = 0x40;
pub const EAK: u8 = 0x20;
pub const RST: u8 = 0x10;
pub const CONTROL_SESSION: u8 = 10;
pub const MAX_FRAME: usize = u16::MAX as usize;
const HEADER: usize = 9;

fn checksum(bytes: &[u8]) -> u8 {
    0u8.wrapping_sub(bytes.iter().copied().fold(0u8, u8::wrapping_add))
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Frame {
    pub flags: u8,
    pub sequence: u8,
    pub acknowledgement: u8,
    pub session: u8,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn encode(&self) -> Result<Vec<u8>, Error> {
        let length = HEADER + self.payload.len() + usize::from(!self.payload.is_empty());
        if length > MAX_FRAME {
            return Err(Error::Bounds);
        }
        if self.flags & 0x0f != 0 {
            return Err(Error::Unsupported);
        }
        let mut bytes = Vec::with_capacity(length);
        bytes.extend_from_slice(&[0xff, 0x5a]);
        bytes.extend_from_slice(&(length as u16).to_be_bytes());
        bytes.extend_from_slice(&[
            self.flags,
            self.sequence,
            self.acknowledgement,
            self.session,
        ]);
        bytes.push(checksum(&bytes));
        if !self.payload.is_empty() {
            bytes.extend_from_slice(&self.payload);
            bytes.push(checksum(&self.payload));
        }
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() < HEADER || bytes.len() > MAX_FRAME {
            return Err(Error::Bounds);
        }
        if bytes[..2] != [0xff, 0x5a]
            || usize::from(u16::from_be_bytes([bytes[2], bytes[3]])) != bytes.len()
            || bytes.len() == HEADER + 1
        {
            return Err(Error::Malformed);
        }
        if checksum(&bytes[..HEADER]) != 0
            || (bytes.len() > HEADER && checksum(&bytes[HEADER..]) != 0)
        {
            return Err(Error::Checksum);
        }
        if bytes[4] & 0x0f != 0 {
            return Err(Error::Unsupported);
        }
        Ok(Self {
            flags: bytes[4],
            sequence: bytes[5],
            acknowledgement: bytes[6],
            session: bytes[7],
            payload: if bytes.len() == HEADER {
                Vec::new()
            } else {
                bytes[HEADER..bytes.len() - 1].to_vec()
            },
        })
    }
}

/// Owns at most one maximum-size frame. Call `next_frame` between chunks when
/// the transport coalesces records. A framing error discards this decoder.
#[derive(Default)]
pub struct Decoder {
    bytes: Vec<u8>,
}

impl Decoder {
    pub fn push(&mut self, bytes: &[u8]) -> Result<(), Error> {
        if self.bytes.len() + bytes.len() > MAX_FRAME {
            return Err(Error::Bounds);
        }
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }

    pub fn next_frame(&mut self) -> Result<Option<Frame>, Error> {
        if self.bytes.len() < 4 {
            return Ok(None);
        }
        if self.bytes[..2] != [0xff, 0x5a] {
            return Err(Error::Malformed);
        }
        let length = usize::from(u16::from_be_bytes([self.bytes[2], self.bytes[3]]));
        if length < HEADER || length == HEADER + 1 {
            return Err(Error::Malformed);
        }
        if self.bytes.len() < length {
            return Ok(None);
        }
        let frame = Frame::decode(&self.bytes[..length])?;
        self.bytes.drain(..length);
        Ok(Some(frame))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Session {
    pub id: u8,
    pub kind: u8,
    pub version: u8,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Synchronization {
    pub window: u8,
    pub max_frame: u16,
    pub retransmit_ms: u16,
    pub ack_ms: u16,
    pub retries: u8,
    pub ack_count: u8,
    pub sessions: Vec<Session>,
}

impl Synchronization {
    pub fn validate(&self) -> Result<(), Error> {
        if self.window == 0
            || self.window > 127
            || self.max_frame < 64
            || self.sessions.is_empty()
            || self.sessions.len() > 8
        {
            return Err(Error::Bounds);
        }
        // Reliable transports (wired carkit TLS) negotiate all-zero ACK/retry
        // parameters; unreliable transports must provide a coherent timer set.
        let zero_ack =
            self.retransmit_ms == 0 && self.ack_ms == 0 && self.retries == 0 && self.ack_count == 0;
        if !zero_ack
            && (self.retransmit_ms == 0
                || self.ack_ms >= self.retransmit_ms
                || self.retries == 0
                || self.ack_count == 0)
        {
            return Err(Error::Bounds);
        }
        let mut seen = [false; 256];
        for s in &self.sessions {
            if s.id == 0 || seen[usize::from(s.id)] || s.kind > 2 || s.version == 0 {
                return Err(Error::Malformed);
            }
            seen[usize::from(s.id)] = true;
        }
        Ok(())
    }

    pub fn encode(&self) -> Result<Vec<u8>, Error> {
        self.validate()?;
        let mut bytes = vec![1, self.window];
        for value in [self.max_frame, self.retransmit_ms, self.ack_ms] {
            bytes.extend_from_slice(&value.to_be_bytes());
        }
        bytes.extend_from_slice(&[self.retries, self.ack_count]);
        for s in &self.sessions {
            bytes.extend_from_slice(&[s.id, s.kind, s.version]);
        }
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() < 13 || bytes.len() > 34 || !(bytes.len() - 10).is_multiple_of(3) {
            return Err(Error::Bounds);
        }
        if bytes[0] != 1 {
            return Err(Error::Unsupported);
        }
        let value = Self {
            window: bytes[1],
            max_frame: u16::from_be_bytes([bytes[2], bytes[3]]),
            retransmit_ms: u16::from_be_bytes([bytes[4], bytes[5]]),
            ack_ms: u16::from_be_bytes([bytes[6], bytes[7]]),
            retries: bytes[8],
            ack_count: bytes[9],
            sessions: bytes[10..]
                .as_chunks::<3>()
                .0
                .iter()
                .map(|s| Session {
                    id: s[0],
                    kind: s[1],
                    version: s[2],
                })
                .collect(),
        };
        value.validate()?;
        Ok(value)
    }
}

struct Pending {
    frame: Frame,
    deadline: Duration,
    retries: u8,
}

/// Bounded outstanding-send window, using cumulative ACKs and modulo-256 PSNs.
/// EAK reordering and transport SYN negotiation are intentionally not implemented.
pub struct SendWindow {
    next: u8,
    last_ack: u8,
    capacity: usize,
    max_payload: usize,
    interval: Duration,
    retry_limit: u8,
    pending: VecDeque<Pending>,
}

impl SendWindow {
    pub fn new(initial_sequence: u8, config: &Synchronization) -> Result<Self, Error> {
        config.validate()?;
        if config.retransmit_ms == 0 {
            return Err(Error::Unsupported);
        }
        Ok(Self {
            next: initial_sequence,
            last_ack: initial_sequence.wrapping_sub(1),
            capacity: usize::from(config.window),
            max_payload: usize::from(config.max_frame) - 10,
            interval: Duration::from_millis(u64::from(config.retransmit_ms)),
            retry_limit: config.retries,
            pending: VecDeque::new(),
        })
    }

    pub fn send(
        &mut self,
        session: u8,
        ack: u8,
        payload: Vec<u8>,
        now: Duration,
    ) -> Result<Frame, Error> {
        if self.pending.len() >= self.capacity
            || payload.is_empty()
            || payload.len() > self.max_payload
        {
            return Err(Error::Bounds);
        }
        let frame = Frame {
            flags: ACK,
            sequence: self.next,
            acknowledgement: ack,
            session,
            payload,
        };
        self.next = self.next.wrapping_add(1);
        self.pending.push_back(Pending {
            frame: frame.clone(),
            deadline: now.saturating_add(self.interval),
            retries: 0,
        });
        Ok(frame)
    }

    pub fn acknowledge(&mut self, ack: u8) -> Result<(), Error> {
        if ack == self.last_ack {
            return Ok(());
        }
        let distance = usize::from(ack.wrapping_sub(self.last_ack));
        if distance > self.pending.len() {
            // An old cumulative ACK is harmless; a future ACK must not release data.
            return if distance >= 128 {
                Ok(())
            } else {
                Err(Error::Sequence)
            };
        }
        self.pending.drain(..distance);
        self.last_ack = ack;
        Ok(())
    }

    pub fn retransmit(&mut self, now: Duration) -> Result<Vec<Frame>, Error> {
        if self
            .pending
            .iter()
            .any(|p| p.deadline <= now && p.retries >= self.retry_limit)
        {
            return Err(Error::Timeout);
        }
        let mut due = Vec::new();
        for p in self.pending.iter_mut().filter(|p| p.deadline <= now) {
            p.retries += 1;
            p.deadline = now.saturating_add(self.interval);
            due.push(p.frame.clone());
        }
        Ok(due)
    }

    pub fn outstanding(&self) -> usize {
        self.pending.len()
    }

    pub fn clear(&mut self) {
        self.pending.clear();
        self.last_ack = self.next.wrapping_sub(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sync() -> Synchronization {
        Synchronization {
            window: 3,
            max_frame: 4096,
            retransmit_ms: 100,
            ack_ms: 20,
            retries: 2,
            ack_count: 1,
            sessions: vec![Session {
                id: CONTROL_SESSION,
                kind: 0,
                version: 1,
            }],
        }
    }

    #[test]
    fn hand_calculated_frame_and_fragmented_stream() {
        // Argo-authored synthetic ACK packet: header checksum is 0x9a.
        let wire = [0xff, 0x5a, 0, 9, ACK, 2, 3, 0xbf, 0x9a];
        let frame = Frame::decode(&wire).unwrap();
        assert_eq!(frame.encode().unwrap(), wire);
        let mut decoder = Decoder::default();
        for byte in &wire[..8] {
            decoder.push(&[*byte]).unwrap();
            assert_eq!(decoder.next_frame(), Ok(None));
        }
        decoder.push(&wire[8..]).unwrap();
        assert_eq!(decoder.next_frame(), Ok(Some(frame)));
    }

    #[test]
    fn rejects_corruption_and_length_abuse() {
        let frame = Frame {
            flags: ACK,
            sequence: 3,
            acknowledgement: 9,
            session: 10,
            payload: vec![1, 4, 9],
        };
        let mut wire = frame.encode().unwrap();
        wire[9] ^= 1;
        assert_eq!(Frame::decode(&wire), Err(Error::Checksum));
        let mut decoder = Decoder::default();
        decoder.push(&[0xff, 0x5a, 0, 8]).unwrap();
        assert_eq!(decoder.next_frame(), Err(Error::Malformed));
        assert_eq!(
            Decoder::default().push(&vec![0; MAX_FRAME + 1]),
            Err(Error::Bounds)
        );
    }

    #[test]
    fn synchronization_rejects_partial_or_duplicate_session() {
        let data = sync().encode().unwrap();
        assert_eq!(Synchronization::decode(&data), Ok(sync()));
        assert_eq!(Synchronization::decode(&data[..12]), Err(Error::Bounds));
        let mut bad = sync();
        bad.sessions.push(bad.sessions[0]);
        assert_eq!(bad.encode(), Err(Error::Malformed));
    }

    #[test]
    fn window_wraparound_duplicate_ack_future_ack_and_retry_exhaustion() {
        let mut w = SendWindow::new(255, &sync()).unwrap();
        for expected in [255, 0, 1] {
            assert_eq!(
                w.send(10, 1, vec![7], Duration::ZERO).unwrap().sequence,
                expected
            );
        }
        assert_eq!(w.send(10, 1, vec![7], Duration::ZERO), Err(Error::Bounds));
        assert_eq!(w.acknowledge(3), Err(Error::Sequence));
        w.acknowledge(0).unwrap();
        w.acknowledge(0).unwrap();
        w.acknowledge(255).unwrap();
        assert_eq!(w.outstanding(), 1);
        assert!(w.retransmit(Duration::from_millis(99)).unwrap().is_empty());
        assert_eq!(
            w.retransmit(Duration::from_millis(100)).unwrap()[0].sequence,
            1
        );
        assert_eq!(
            w.retransmit(Duration::from_millis(200)).unwrap()[0].sequence,
            1
        );
        assert_eq!(
            w.retransmit(Duration::from_millis(300)),
            Err(Error::Timeout)
        );
        w.clear();
        assert_eq!(w.outstanding(), 0);
    }

    #[test]
    fn sender_respects_negotiated_packet_size() {
        let mut config = sync();
        config.max_frame = 64;
        let mut window = SendWindow::new(1, &config).unwrap();
        assert_eq!(
            window.send(10, 0, vec![0; 55], Duration::ZERO),
            Err(Error::Bounds)
        );
        assert_eq!(window.outstanding(), 0);
        assert_eq!(
            window
                .send(10, 0, vec![0; 54], Duration::ZERO)
                .unwrap()
                .encode()
                .unwrap()
                .len(),
            64
        );
    }
}
