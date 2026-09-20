//! Unencrypted AirPlay envelope validation, not an AirPlay server. Pairing,
//! authentication, key derivation and media decryption are deliberately required
//! before any caller may forward media. Research provenance: `protocol/mod.rs`.

use super::Error;
use std::collections::BTreeMap;

const MAX_HEADERS: usize = 16 * 1024;
const MAX_BODY: usize = 1024 * 1024;
pub const SCREEN_HEADER_BYTES: usize = 128;
pub const MAX_SCREEN_BODY: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Request {
    pub method: String,
    pub target: String,
    pub protocol: String,
    pub headers: BTreeMap<String, String>,
    pub body: Vec<u8>,
}

/// Bounded control framing. There is no implicit encryption downgrade: bytes
/// arriving after pair verification must be authenticated by the future runtime.
#[derive(Default)]
pub struct ControlDecoder {
    pending: Vec<u8>,
}

impl ControlDecoder {
    pub fn push(&mut self, bytes: &[u8]) -> Result<(), Error> {
        if self.pending.len() + bytes.len() > MAX_HEADERS + MAX_BODY {
            return Err(Error::Bounds);
        }
        self.pending.extend_from_slice(bytes);
        Ok(())
    }

    pub fn next_request(&mut self) -> Result<Option<Request>, Error> {
        let Some(split) = self.pending.windows(4).position(|b| b == b"\r\n\r\n") else {
            return if self.pending.len() > MAX_HEADERS {
                Err(Error::Bounds)
            } else {
                Ok(None)
            };
        };
        if split + 4 > MAX_HEADERS {
            return Err(Error::Bounds);
        }
        let text = std::str::from_utf8(&self.pending[..split]).map_err(|_| Error::Malformed)?;
        if !text.is_ascii() {
            return Err(Error::Malformed);
        }
        let mut lines = text.split("\r\n");
        let words: Vec<_> = lines
            .next()
            .ok_or(Error::Malformed)?
            .splitn(3, ' ')
            .collect();
        if words.len() != 3 {
            return Err(Error::Malformed);
        }
        let response = ["RTSP/1.0", "HTTP/1.1"].contains(&words[0]);
        if response {
            if words[1].len() != 3
                || !words[1].bytes().all(|b| b.is_ascii_digit())
                || words[2].bytes().any(|b| b.is_ascii_control())
            {
                return Err(Error::Malformed);
            }
        } else if words[0].is_empty()
            || words[0].len() > 32
            || !words[0]
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b == b'_')
            || words[1].is_empty()
            || words[1].len() > 2048
            || words[1].bytes().any(|b| b.is_ascii_control())
            || !["RTSP/1.0", "HTTP/1.1"].contains(&words[2])
        {
            return Err(Error::Malformed);
        }
        let mut headers = BTreeMap::new();
        for line in lines {
            if headers.len() >= 64 {
                return Err(Error::Bounds);
            }
            let (name, value) = line.split_once(':').ok_or(Error::Malformed)?;
            if name.is_empty()
                || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                || value.bytes().any(|b| b.is_ascii_control() && b != b'\t')
            {
                return Err(Error::Malformed);
            }
            // Even duplicate equal Content-Length is rejected to avoid ambiguity.
            if headers
                .insert(name.to_ascii_lowercase(), value.trim().to_owned())
                .is_some()
            {
                return Err(Error::Malformed);
            }
        }
        if headers.contains_key("transfer-encoding") {
            return Err(Error::Unsupported);
        }
        let length = match headers.get("content-length") {
            None => 0,
            Some(value) if !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()) => {
                value.parse::<usize>().map_err(|_| Error::Bounds)?
            }
            Some(_) => return Err(Error::Malformed),
        };
        if length > MAX_BODY {
            return Err(Error::Bounds);
        }
        let end = split + 4 + length;
        if self.pending.len() < end {
            return Ok(None);
        }
        let request = Request {
            method: words[0].into(),
            target: words[1].into(),
            protocol: words[2].into(),
            headers,
            body: self.pending[split + 4..end].to_vec(),
        };
        self.pending.drain(..end);
        Ok(Some(request))
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ScreenKind {
    EncryptedAccessUnit,
    CodecConfiguration,
    Ignore,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ScreenHeader {
    pub kind: ScreenKind,
    pub body_length: usize,
}

impl ScreenHeader {
    /// Call before allocation or reading the body. Configuration is cleartext;
    /// video is ChaCha20-Poly1305 with this exact header as associated data.
    pub fn parse(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() != SCREEN_HEADER_BYTES {
            return Err(Error::Bounds);
        }
        let body_length = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
        let kind = match bytes[4] {
            0 => ScreenKind::EncryptedAccessUnit,
            // Observed during iOS reconnect: an empty cleartext configuration
            // carries no codec data. Ignore it without advancing the frame nonce;
            // a real validated configuration is still required before video.
            1 if body_length == 0 => ScreenKind::Ignore,
            1 => ScreenKind::CodecConfiguration,
            // Non-display screen control traffic; never publish or advance AEAD.
            2..=5 => ScreenKind::Ignore,
            _ => return Err(Error::Unsupported),
        };
        if body_length > MAX_SCREEN_BODY
            || (body_length == 0 && kind != ScreenKind::Ignore)
            || (kind == ScreenKind::EncryptedAccessUnit && body_length < 16)
            || (kind == ScreenKind::CodecConfiguration && body_length > 65536)
            || (kind == ScreenKind::Ignore && body_length > 65536)
        {
            return Err(Error::Bounds);
        }
        Ok(Self { kind, body_length })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AudioCodec {
    SignedPcm16,
    AacLc,
    Opus,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AudioFormat {
    pub codec: AudioCodec,
    pub sample_rate: u32,
    pub channels: u8,
}

impl AudioFormat {
    /// A SETUP must select exactly one supported format, not a capabilities mask.
    /// Format validation does not claim that a decoder/capture path is available.
    pub fn selected(bit: u64) -> Result<Self, Error> {
        if !bit.is_power_of_two() {
            return Err(Error::Malformed);
        }
        let (codec, sample_rate, channels) = match bit {
            0x4..=0x800 if bit <= 0x800 => {
                let index = bit.trailing_zeros() - 2;
                let rates = [8000, 16000, 24000, 32000, 44100];
                let rate = *rates.get((index / 2) as usize).ok_or(Error::Unsupported)?;
                (AudioCodec::SignedPcm16, rate, 1 + (index % 2) as u8)
            }
            0x4000 => (AudioCodec::SignedPcm16, 48000, 1),
            0x8000 => (AudioCodec::SignedPcm16, 48000, 2),
            0x400000 => (AudioCodec::AacLc, 44100, 2),
            0x800000 => (AudioCodec::AacLc, 48000, 2),
            0x10000000 => (AudioCodec::Opus, 16000, 1),
            0x20000000 => (AudioCodec::Opus, 24000, 1),
            0x40000000 => (AudioCodec::Opus, 48000, 1),
            _ => return Err(Error::Unsupported),
        };
        Ok(Self {
            codec,
            sample_rate,
            channels,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_configuration_does_not_authorize_an_unencrypted_frame() {
        let mut header = [0; SCREEN_HEADER_BYTES];
        header[4] = 1;
        assert_eq!(
            ScreenHeader::parse(&header).unwrap().kind,
            ScreenKind::Ignore
        );
        header[4] = 0;
        assert_eq!(ScreenHeader::parse(&header), Err(Error::Bounds));
        header[4] = 1;
        header[..4].copy_from_slice(&39u32.to_le_bytes());
        assert_eq!(
            ScreenHeader::parse(&header).unwrap().kind,
            ScreenKind::CodecConfiguration
        );
    }

    #[test]
    fn setup_fragmentation_and_multiple_messages_remain_separate() {
        let mut decoder = ControlDecoder::default();
        decoder
            .push(b"SETUP /stream RTSP/1.0\r\nCSeq: 4\r\nContent-Length: 3\r\n\r\n\0")
            .unwrap();
        assert_eq!(decoder.next_request(), Ok(None));
        decoder
            .push(b"\x01\xffGET /info RTSP/1.0\r\nCSeq: 5\r\n\r\n")
            .unwrap();
        let request = decoder.next_request().unwrap().unwrap();
        assert_eq!(request.method, "SETUP");
        assert_eq!(request.headers.get("cseq").map(String::as_str), Some("4"));
        assert_eq!(request.body, [0, 1, 255]);
        assert_eq!(decoder.next_request().unwrap().unwrap().target, "/info");
        assert_eq!(decoder.next_request(), Ok(None));
    }

    #[test]
    fn control_rejects_request_smuggling_and_allocation_abuse() {
        for headers in [
            "Content-Length: -1",
            "Content-Length: 1x",
            "Content-Length: 1\r\nContent-Length: 1",
            "Transfer-Encoding: chunked",
            "Content-Length: 99999999999999999",
            " Content-Length: 3",
        ] {
            let mut decoder = ControlDecoder::default();
            decoder
                .push(format!("SETUP / RTSP/1.0\r\n{headers}\r\n\r\n").as_bytes())
                .unwrap();
            assert!(decoder.next_request().is_err(), "{headers}");
        }
        let mut decoder = ControlDecoder::default();
        decoder.push(&vec![b'A'; MAX_HEADERS + 1]).unwrap();
        assert_eq!(decoder.next_request(), Err(Error::Bounds));
    }

    #[test]
    fn screen_rejects_oversize_and_unauthenticated_short_video() {
        let mut header = [0; SCREEN_HEADER_BYTES];
        header[..4].copy_from_slice(&15u32.to_le_bytes());
        assert_eq!(ScreenHeader::parse(&header), Err(Error::Bounds));
        header[..4].copy_from_slice(&4096u32.to_le_bytes());
        assert_eq!(
            ScreenHeader::parse(&header).unwrap().kind,
            ScreenKind::EncryptedAccessUnit
        );
        header[..4].copy_from_slice(&((MAX_SCREEN_BODY + 1) as u32).to_le_bytes());
        assert_eq!(ScreenHeader::parse(&header), Err(Error::Bounds));
        header[4] = 1;
        header[..4].copy_from_slice(&40u32.to_le_bytes());
        assert_eq!(
            ScreenHeader::parse(&header).unwrap().kind,
            ScreenKind::CodecConfiguration
        );
    }

    #[test]
    fn non_display_screen_records_are_bounded_and_never_video() {
        let mut header = [0; SCREEN_HEADER_BYTES];
        for opcode in 2..=5 {
            header[4] = opcode;
            for length in [0u32, 194, 65536] {
                header[..4].copy_from_slice(&length.to_le_bytes());
                assert_eq!(
                    ScreenHeader::parse(&header).unwrap().kind,
                    ScreenKind::Ignore
                );
            }
            header[..4].copy_from_slice(&65537u32.to_le_bytes());
            assert_eq!(ScreenHeader::parse(&header), Err(Error::Bounds));
        }
        header[4] = 6;
        assert_eq!(ScreenHeader::parse(&header), Err(Error::Unsupported));
    }

    #[test]
    fn negotiated_audio_rejects_multi_format_or_unknown_capability_masks() {
        assert_eq!(
            AudioFormat::selected(0x8000).unwrap(),
            AudioFormat {
                codec: AudioCodec::SignedPcm16,
                sample_rate: 48000,
                channels: 2
            }
        );
        assert_eq!(
            AudioFormat::selected(0x400000).unwrap().codec,
            AudioCodec::AacLc
        );
        assert_eq!(
            AudioFormat::selected(0x20000000).unwrap().sample_rate,
            24000
        );
        assert_eq!(AudioFormat::selected(0xc00000), Err(Error::Malformed));
        assert_eq!(AudioFormat::selected(0x1000), Err(Error::Unsupported));
    }
}
