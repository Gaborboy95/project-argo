//! Independently implemented bounded wire reader. Public field references and
//! replacement semantics are recorded in tool/projection/README.md.
use crate::ipc::{DecodeError, Message, PayloadWriter};

pub const CHANNEL: u8 = 10;
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Metadata {
    pub media_received: bool,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub playback: u8,
    pub application: Option<String>,
    pub position_ms: Option<u64>,
    pub duration_ms: Option<u64>,
    pub device_name: Option<String>,
    pub manufacturer: Option<String>,
    pub model: Option<String>,
    pub battery: Option<u8>,
    pub critical: Option<bool>,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    pub data: Metadata,
    pub revision: u32,
    pub updated_at_ms: u64,
    last_diagnostic_ms: u64,
}
pub enum Update {
    Track {
        title: Option<String>,
        artist: Option<String>,
        album: Option<String>,
    },
    Playback {
        state: Option<u8>,
        application: Option<String>,
        position_ms: Option<u64>,
    },
    Phone {
        name: Option<String>,
        manufacturer: Option<String>,
    },
    Battery {
        level: Option<u8>,
        critical: Option<bool>,
    },
}
impl Snapshot {
    pub fn apply(&mut self, update: Update) -> bool {
        let before = self.data.clone();
        let d = &mut self.data;
        match update {
            Update::Track {
                title,
                artist,
                album,
            } => {
                // A track message replaces all descriptive fields. Artwork-only
                // refreshes with identical text do not reset the position.
                if (d.title.as_ref(), d.artist.as_ref(), d.album.as_ref())
                    != (title.as_ref(), artist.as_ref(), album.as_ref())
                {
                    d.position_ms = None;
                    d.duration_ms = None;
                }
                d.title = title;
                d.artist = artist;
                d.album = album;
                d.media_received = true;
            }
            Update::Playback {
                state,
                application,
                position_ms,
            } => {
                // Independent status patch. A changed application cannot retain
                // the old application's track while awaiting new metadata.
                if let Some(app) = application {
                    if d.application.as_ref().is_some_and(|old| old != &app) {
                        d.title = None;
                        d.artist = None;
                        d.album = None;
                        d.position_ms = None;
                        d.duration_ms = None;
                    }
                    d.application = Some(app);
                }
                if let Some(state) = state {
                    d.playback = state;
                }
                if let Some(position) = position_ms {
                    d.position_ms = Some(position);
                }
                d.media_received = true;
            }
            Update::Phone { name, manufacturer } => {
                d.device_name = name;
                d.manufacturer = manufacturer;
            }
            Update::Battery { level, critical } => {
                // Notification fields are independent; omission is not zero/false.
                if let Some(level) = level {
                    d.battery = Some(level);
                }
                if let Some(critical) = critical {
                    d.critical = Some(critical);
                }
            }
        }
        if self.data == before {
            return false;
        }
        self.revision = self.revision.saturating_add(1);
        self.updated_at_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;
        if self.updated_at_ms.saturating_sub(self.last_diagnostic_ms) >= 3000 {
            self.last_diagnostic_ms = self.updated_at_ms;
            crate::daemon_log!(
                Debug,
                "metadata",
                "session metadata changed revision={}",
                self.revision
            );
        }
        true
    }
    pub fn message(&self, session: &str, device: &str) -> Result<Message, DecodeError> {
        let mut w = PayloadWriter::default();
        w.string(session)?;
        w.string(device)?;
        w.u32(self.revision);
        w.u64(self.updated_at_ms);
        let d = &self.data;
        w.u8(u8::from(d.media_received));
        for s in [&d.title, &d.artist, &d.album] {
            optional_string(&mut w, s)?;
        }
        w.u8(d.playback);
        optional_string(&mut w, &d.application)?;
        for value in [d.position_ms, d.duration_ms] {
            w.u8(u8::from(value.is_some()));
            if let Some(value) = value {
                w.u64(value);
            }
        }
        for s in [&d.device_name, &d.manufacturer, &d.model] {
            optional_string(&mut w, s)?;
        }
        w.u8(d.battery.unwrap_or(255));
        w.u8(match d.critical {
            None => 0,
            Some(false) => 1,
            Some(true) => 2,
        });
        Ok(Message {
            kind: 11,
            payload: w.finish(),
        })
    }
}
fn optional_string(w: &mut PayloadWriter, value: &Option<String>) -> Result<(), DecodeError> {
    w.u8(u8::from(value.is_some()));
    if let Some(value) = value {
        w.string(value)?;
    }
    Ok(())
}
#[derive(Clone, Copy)]
enum Value<'a> {
    Number(u64),
    Bytes(&'a [u8]),
    Other,
}
fn varint(input: &mut &[u8]) -> Result<u64, String> {
    let mut value = 0;
    for shift in (0..70).step_by(7) {
        let (&b, rest) = input.split_first().ok_or("truncated field")?;
        *input = rest;
        if shift == 63 && b > 1 {
            return Err("integer overflow".into());
        }
        value |= u64::from(b & 127) << shift;
        if b < 128 {
            return Ok(value);
        }
    }
    Err("integer overflow".into())
}
fn fields(mut input: &[u8]) -> Result<std::collections::BTreeMap<u32, Value<'_>>, String> {
    if input.len() > 4 * 1024 * 1024 {
        return Err("metadata size limit".into());
    }
    let mut result = std::collections::BTreeMap::new();
    let mut count = 0;
    while !input.is_empty() {
        count += 1;
        if count > 1024 {
            return Err("field limit".into());
        }
        let tag = varint(&mut input)?;
        if tag >> 3 == 0 || tag >> 3 > 0x1fff_ffff {
            return Err("invalid tag".into());
        }
        let value = match tag & 7 {
            0 => Value::Number(varint(&mut input)?),
            wire @ (1 | 2 | 5) => {
                let size = match wire {
                    1 => 8,
                    5 => 4,
                    _ => usize::try_from(varint(&mut input)?).map_err(|_| "length overflow")?,
                };
                let data = input.get(..size).ok_or("truncated bytes")?;
                input = &input[size..];
                if wire == 2 {
                    Value::Bytes(data)
                } else {
                    Value::Other
                }
            }
            _ => return Err("unsupported wire type".into()),
        };
        // Borrow only: artwork and unknown fields are never copied or decoded.
        result.insert((tag >> 3) as u32, value);
    }
    Ok(result)
}
pub fn parse(channel: u8, id: u16, body: &[u8]) -> Result<Update, String> {
    let f = fields(body)?;
    let text = |key| -> Result<Option<String>, String> {
        match f.get(&key) {
            None => Ok(None),
            Some(Value::Bytes(b)) if b.len() <= 1024 => {
                let s = std::str::from_utf8(b).map_err(|_| "invalid UTF-8")?;
                if s.contains('\0') {
                    return Err("NUL in text".into());
                }
                Ok((!s.trim().is_empty()).then(|| s.trim().to_owned()))
            }
            _ => Err("invalid or oversized text".into()),
        }
    };
    let number = |key| -> Result<Option<u64>, String> {
        match f.get(&key) {
            None => Ok(None),
            Some(Value::Number(n)) => Ok(Some(*n)),
            _ => Err("invalid number".into()),
        }
    };
    match (channel, id) {
        (CHANNEL, 0x8003) => Ok(Update::Track {
            title: text(1)?,
            artist: text(2)?,
            album: text(3)?,
        }),
        (CHANNEL, 0x8001) => {
            let state = number(1)?;
            let position = number(3)?;
            if state.is_some_and(|s| s > 4) || position.is_some_and(|p| p > u64::from(u32::MAX)) {
                return Err("invalid playback value".into());
            }
            Ok(Update::Playback {
                state: state.map(|s| s as u8),
                application: text(2)?,
                position_ms: position.map(|p| p * 1000),
            })
        }
        (0, 5) => Ok(Update::Phone {
            name: text(4)?,
            manufacturer: text(5)?,
        }),
        (0, 23) => {
            let level = number(1)?;
            let critical = number(3)?;
            if level.is_some_and(|v| v > 100) || critical.is_some_and(|v| v > 1) {
                return Err("invalid battery value".into());
            }
            Ok(Update::Battery {
                level: level.map(|v| v as u8),
                critical: critical.map(|v| v == 1),
            })
        }
        _ => Err("unsupported metadata message".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::aa_channels::{Channels, DisplayConfig, Effect, Proto};
    #[test]
    fn bounded_optional_fields_and_track_status_semantics() {
        let mut snapshot = Snapshot::default();
        let track = Proto::default()
            .bytes(1, b"Track A")
            .bytes(2, b"Artist")
            .bytes(3, b"Album")
            .bytes(4, &[0xff; 4096])
            .finish();
        assert!(snapshot.apply(parse(CHANNEL, 0x8003, &track).unwrap()));
        let status = Proto::default()
            .number(1, 2)
            .bytes(2, b"Player")
            .number(3, 42)
            .finish();
        snapshot.apply(parse(CHANNEL, 0x8001, &status).unwrap());
        assert_eq!(snapshot.data.position_ms, Some(42000));
        assert!(!snapshot.apply(parse(CHANNEL, 0x8001, &status).unwrap()));
        snapshot.apply(
            parse(
                CHANNEL,
                0x8003,
                &Proto::default().bytes(1, b"Track B").finish(),
            )
            .unwrap(),
        );
        assert!(snapshot.data.artist.is_none());
        assert!(snapshot.data.album.is_none());
        assert!(snapshot.data.position_ms.is_none());
        assert!(snapshot.data.duration_ms.is_none());
        snapshot.apply(parse(0, 23, &Proto::default().number(1, 70).finish()).unwrap());
        assert_eq!(snapshot.data.critical, None);
        snapshot.apply(parse(0, 23, &Proto::default().number(3, 1).finish()).unwrap());
        assert_eq!(snapshot.data.battery, Some(70));
        assert_eq!(snapshot.data.critical, Some(true));
        assert!(parse(0, 23, &Proto::default().number(1, 101).finish()).is_err());
        assert!(
            parse(
                CHANNEL,
                0x8003,
                &Proto::default().bytes(1, &[b'a'; 1025]).finish()
            )
            .is_err()
        );
        assert!(parse(CHANNEL, 0x8003, &[10, 255]).is_err());
        let mut channels = Channels::new(DisplayConfig::default());
        channels.handle(0, 5, &[]).unwrap();
        channels
            .handle(
                CHANNEL,
                7,
                &Proto::default().number(2, u64::from(CHANNEL)).finish(),
            )
            .unwrap();
        assert!(matches!(
            channels.handle(CHANNEL, 0x8003, &track).unwrap().first(),
            Some(Effect::Metadata(_))
        ));
        assert!(
            channels
                .handle(CHANNEL, 0x8003, &[10, 255])
                .unwrap()
                .is_empty()
        );
        assert!(
            !channels
                .handle(0, 11, &Proto::default().number(1, 1).finish())
                .unwrap()
                .is_empty()
        );
    }
    #[test]
    fn snapshot_fixture_replacement_and_late_update_guard() {
        use crate::daemon_state::ProjectionRuntimeSnapshot;
        let mut current =
            ProjectionRuntimeSnapshot::connecting("device".into(), "Android phone".into());
        let id = current.session.as_ref().unwrap().id.clone();
        current.update_metadata(
            &id,
            parse(
                0,
                5,
                &Proto::default()
                    .bytes(4, b"Test phone")
                    .bytes(5, b"Example")
                    .finish(),
            )
            .unwrap(),
        );
        current.update_metadata(
            &id,
            parse(
                CHANNEL,
                0x8003,
                &Proto::default()
                    .bytes(1, b"Song")
                    .bytes(2, b"Artist")
                    .finish(),
            )
            .unwrap(),
        );
        current.update_metadata(
            &id,
            parse(
                CHANNEL,
                0x8001,
                &Proto::default().number(1, 2).number(3, 12).finish(),
            )
            .unwrap(),
        );
        current.metadata.updated_at_ms = 1700000000000;
        let message = current.metadata.message(&id, "device").unwrap();
        let actual = crate::ipc::encode(&message)
            .unwrap()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        assert_eq!(
            actual,
            include_str!("../../../../test/fixtures/projection/ipc_v3_metadata.hex").trim()
        );
        let initial =
            crate::daemon_state::snapshot_messages(&Default::default(), &current).unwrap();
        assert!(initial.contains(&message));
        assert!(
            crate::daemon_state::snapshot_messages(&current, &current)
                .unwrap()
                .is_empty()
        );
        let old = current.clone();
        current = ProjectionRuntimeSnapshot::connecting("other".into(), "Android phone".into());
        assert!(!current.update_metadata(&id, parse(0, 23, &[8, 50]).unwrap()));
        assert_eq!(current.metadata, Snapshot::default());
        assert!(
            crate::daemon_state::snapshot_messages(&old, &current)
                .unwrap()
                .iter()
                .any(|m| m.kind == 8)
        );
        assert_eq!(old.failed("disconnected").metadata, Snapshot::default());
    }
}
