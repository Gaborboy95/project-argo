use std::collections::VecDeque;

pub const MAGIC: u32 = 0x4152_474f;
pub const VERSION: u16 = 1;
pub const HEADER_LEN: usize = 12;
pub const MAX_PAYLOAD: usize = 64 * 1024;
pub const MAX_BUFFERED: usize = 256 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    pub kind: u16,
    pub payload: Vec<u8>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    BadMagic,
    UnsupportedVersion(u16),
    OversizedPayload(usize),
    OversizedBuffer,
}

pub fn encode(message: &Message) -> Result<Vec<u8>, DecodeError> {
    if message.payload.len() > MAX_PAYLOAD {
        return Err(DecodeError::OversizedPayload(message.payload.len()));
    }
    let mut result = Vec::with_capacity(HEADER_LEN + message.payload.len());
    result.extend_from_slice(&MAGIC.to_be_bytes());
    result.extend_from_slice(&VERSION.to_be_bytes());
    result.extend_from_slice(&message.kind.to_be_bytes());
    result.extend_from_slice(&(message.payload.len() as u32).to_be_bytes());
    result.extend_from_slice(&message.payload);
    Ok(result)
}

#[derive(Default)]
pub struct Decoder {
    buffered: Vec<u8>,
}

impl Decoder {
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Message>, DecodeError> {
        if self.buffered.len().saturating_add(bytes.len()) > MAX_BUFFERED {
            self.buffered.clear();
            return Err(DecodeError::OversizedBuffer);
        }
        self.buffered.extend_from_slice(bytes);
        let mut messages = Vec::new();
        loop {
            if self.buffered.len() < HEADER_LEN {
                break;
            }
            let magic = u32::from_be_bytes(self.buffered[0..4].try_into().unwrap());
            if magic != MAGIC {
                self.buffered.clear();
                return Err(DecodeError::BadMagic);
            }
            let version = u16::from_be_bytes(self.buffered[4..6].try_into().unwrap());
            if version != VERSION {
                self.buffered.clear();
                return Err(DecodeError::UnsupportedVersion(version));
            }
            let kind = u16::from_be_bytes(self.buffered[6..8].try_into().unwrap());
            let length = u32::from_be_bytes(self.buffered[8..12].try_into().unwrap()) as usize;
            if length > MAX_PAYLOAD {
                self.buffered.clear();
                return Err(DecodeError::OversizedPayload(length));
            }
            let frame_len = HEADER_LEN + length;
            if self.buffered.len() < frame_len {
                break;
            }
            messages.push(Message {
                kind,
                payload: self.buffered[HEADER_LEN..frame_len].to_vec(),
            });
            self.buffered.drain(..frame_len);
        }
        Ok(messages)
    }
}

/// A fixed-capacity queue. Media producers cannot allocate one task or an
/// unbounded backlog per frame. Video callers normally use `push_latest`, while
/// control callers use `try_push` and apply backpressure.
pub struct BoundedQueue<T> {
    values: VecDeque<T>,
    capacity: usize,
}

pub struct PayloadReader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

#[derive(Default)]
pub struct PayloadWriter {
    bytes: Vec<u8>,
}

impl PayloadWriter {
    pub fn u8(&mut self, value: u8) {
        self.bytes.push(value);
    }

    pub fn u16(&mut self, value: u16) {
        self.bytes.extend_from_slice(&value.to_be_bytes());
    }

    pub fn string(&mut self, value: &str) -> Result<(), DecodeError> {
        let bytes = value.as_bytes();
        if bytes.len() > 4096 {
            return Err(DecodeError::OversizedPayload(bytes.len()));
        }
        self.u16(bytes.len() as u16);
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }

    pub fn finish(self) -> Vec<u8> {
        self.bytes
    }
}

impl<'a> PayloadReader<'a> {
    pub fn f32(&mut self) -> Option<f32> {
        let value = f32::from_be_bytes(
            self.bytes
                .get(self.offset..self.offset + 4)?
                .try_into()
                .ok()?,
        );
        self.offset += 4;
        Some(value)
    }
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    pub fn u8(&mut self) -> Option<u8> {
        let value = *self.bytes.get(self.offset)?;
        self.offset += 1;
        Some(value)
    }

    pub fn u16(&mut self) -> Option<u16> {
        let value = u16::from_be_bytes(
            self.bytes
                .get(self.offset..self.offset + 2)?
                .try_into()
                .ok()?,
        );
        self.offset += 2;
        Some(value)
    }

    pub fn string(&mut self) -> Option<String> {
        let length = self.u16()? as usize;
        let value =
            String::from_utf8(self.bytes.get(self.offset..self.offset + length)?.to_vec()).ok()?;
        self.offset += length;
        Some(value)
    }

    pub fn done(&self) -> bool {
        self.offset == self.bytes.len()
    }
}

pub fn string_payload(value: &str) -> Result<Vec<u8>, DecodeError> {
    let bytes = value.as_bytes();
    if bytes.len() > u16::MAX as usize {
        return Err(DecodeError::OversizedPayload(bytes.len()));
    }
    let mut result = Vec::with_capacity(2 + bytes.len());
    result.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
    result.extend_from_slice(bytes);
    Ok(result)
}

impl<T> BoundedQueue<T> {
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0);
        Self {
            values: VecDeque::with_capacity(capacity),
            capacity,
        }
    }

    pub fn try_push(&mut self, value: T) -> Result<(), T> {
        if self.values.len() == self.capacity {
            return Err(value);
        }
        self.values.push_back(value);
        Ok(())
    }

    pub fn push_latest(&mut self, value: T) {
        if self.values.len() == self.capacity {
            self.values.pop_front();
        }
        self.values.push_back(value);
    }

    pub fn pop(&mut self) -> Option<T> {
        self.values.pop_front()
    }

    pub fn len(&self) -> usize {
        self.values.len()
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fragmented_frames_round_trip() {
        let encoded = encode(&Message {
            kind: 9,
            payload: vec![1, 2, 3],
        })
        .unwrap();
        let mut decoder = Decoder::default();
        assert!(decoder.push(&encoded[..5]).unwrap().is_empty());
        assert_eq!(
            decoder.push(&encoded[5..]).unwrap(),
            vec![Message {
                kind: 9,
                payload: vec![1, 2, 3]
            }]
        );
    }

    #[test]
    fn malformed_and_oversized_ipc_is_rejected() {
        let mut decoder = Decoder::default();
        assert_eq!(decoder.push(&[0; HEADER_LEN]), Err(DecodeError::BadMagic));

        let mut header = Vec::new();
        header.extend_from_slice(&MAGIC.to_be_bytes());
        header.extend_from_slice(&VERSION.to_be_bytes());
        header.extend_from_slice(&1_u16.to_be_bytes());
        header.extend_from_slice(&((MAX_PAYLOAD + 1) as u32).to_be_bytes());
        assert_eq!(
            decoder.push(&header),
            Err(DecodeError::OversizedPayload(MAX_PAYLOAD + 1))
        );
    }

    #[test]
    fn bounded_queue_rejects_or_drops_predictably() {
        let mut queue = BoundedQueue::new(2);
        queue.try_push(1).unwrap();
        queue.try_push(2).unwrap();
        assert_eq!(queue.try_push(3), Err(3));
        queue.push_latest(4);
        assert_eq!(queue.pop(), Some(2));
        assert_eq!(queue.pop(), Some(4));
    }

    #[test]
    fn payload_writer_matches_reader() {
        let mut writer = PayloadWriter::default();
        writer.u8(3);
        writer.u16(42);
        writer.string("phone").unwrap();
        let payload = writer.finish();
        let mut reader = PayloadReader::new(&payload);
        assert_eq!(reader.u8(), Some(3));
        assert_eq!(reader.u16(), Some(42));
        assert_eq!(reader.string().as_deref(), Some("phone"));
        assert!(reader.done());
    }
}
