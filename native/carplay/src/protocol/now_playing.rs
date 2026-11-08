//! Bounded iAP2 Now Playing and phone-power subscriptions. Wire research:
//! LIVI 34ae05e14df68f12d06cde0589f27d6d5b449ddb,
//! native/crates/iap2-csm/src/messages/{now_playing,power}.rs and
//! native/crates/livi-runtime/src/file_transfer.rs (Lasse Heitgres, GPL-3.0+).
//! Unknown or malformed optional facts never terminate the projection stream.
use super::{
    Error,
    csm::{self, Message, Parameter},
};
use crate::artwork;
use std::{
    collections::BTreeMap,
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::watch;

pub const START: u16 = 0x5000;
pub const UPDATE: u16 = 0x5001;
pub const POWER_START: u16 = 0xae00;
pub const POWER_UPDATE: u16 = 0xae01;
pub const FILE_TRANSFER_SESSION: u8 = 12;

#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct MediaInfo {
    pub revision: u64,
    pub updated_at_ms: u64,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub application: Option<String>,
    pub application_id: Option<String>,
    pub track_id: Option<String>,
    pub playback: Playback,
    pub position_ms: Option<u32>,
    pub duration_ms: Option<u32>,
    pub artwork_path: Option<String>,
    #[serde(skip)]
    artwork: Option<Arc<artwork::Image>>,
    #[serde(skip)]
    artwork_ftid: Option<u8>,
    #[serde(skip)]
    artwork_generation: u64,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Playback {
    #[default]
    Unknown,
    Stopped,
    Playing,
    Paused,
    Seeking,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Metadata {
    pub media: Option<MediaInfo>,
    pub battery_percent: Option<u8>,
    /// External power is a reported fact, not proof that the battery is charging.
    pub external_power: Option<bool>,
}

fn fields(parameters: &[Parameter]) -> Result<BTreeMap<u16, &[u8]>, Error> {
    let mut result = BTreeMap::new();
    for field in parameters {
        if result.insert(field.id, field.value.as_slice()).is_some() {
            return Err(Error::Malformed);
        }
    }
    Ok(result)
}
fn text(bytes: &[u8]) -> Result<Option<String>, Error> {
    // Seven optional strings share a 16 KiB status message with the video and
    // audio descriptors. Leave room even when JSON must escape every byte.
    if bytes.is_empty() || bytes.len() > 513 || bytes.last() != Some(&0) {
        return Err(Error::Bounds);
    }
    let bytes = &bytes[..bytes.len() - 1];
    if bytes.iter().any(|b| *b < 0x20) {
        return Err(Error::Malformed);
    }
    let value = std::str::from_utf8(bytes).map_err(|_| Error::Malformed)?;
    Ok((!value.is_empty()).then(|| value.to_owned()))
}
fn u32_value(bytes: &[u8]) -> Result<u32, Error> {
    Ok(u32::from_be_bytes(
        bytes.try_into().map_err(|_| Error::Malformed)?,
    ))
}
fn byte(bytes: &[u8]) -> Result<u8, Error> {
    if let [value] = bytes {
        Ok(*value)
    } else {
        Err(Error::Malformed)
    }
}
fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u128::from(u64::MAX)) as u64
}

#[derive(Default)]
struct Patch {
    title: Option<Option<String>>,
    artist: Option<Option<String>>,
    album: Option<Option<String>>,
    album_artist: Option<Option<String>>,
    genre: Option<Option<String>>,
    application: Option<Option<String>>,
    application_id: Option<Option<String>>,
    track_id: Option<String>,
    duration_ms: Option<u32>,
    position_ms: Option<u32>,
    playback: Option<Playback>,
    artwork_ftid: Option<u8>,
}
fn parse(message: &Message) -> Result<Patch, Error> {
    if message.id != UPDATE {
        return Err(Error::Unsupported);
    }
    let outer = fields(&message.parameters)?;
    let mut patch = Patch::default();
    if let Some(bytes) = outer.get(&0) {
        let parameters = csm::decode_parameters(bytes)?;
        let media = fields(&parameters)?;
        if let Some(bytes) = media.get(&0) {
            patch.track_id = Some(format!(
                "{:016x}",
                u64::from_be_bytes((*bytes).try_into().map_err(|_| Error::Malformed)?)
            ));
        }
        for (id, target) in [
            (1, &mut patch.title),
            (6, &mut patch.album),
            (12, &mut patch.artist),
            (14, &mut patch.album_artist),
            (16, &mut patch.genre),
        ] {
            if let Some(bytes) = media.get(&id) {
                *target = Some(text(bytes)?);
            }
        }
        if let Some(bytes) = media.get(&4) {
            patch.duration_ms = Some(u32_value(bytes)?);
        }
        if let Some(bytes) = media.get(&26) {
            patch.artwork_ftid = Some(byte(bytes)?);
        }
    }
    if let Some(bytes) = outer.get(&1) {
        let parameters = csm::decode_parameters(bytes)?;
        let playback = fields(&parameters)?;
        if let Some(bytes) = playback.get(&0) {
            patch.playback = Some(match byte(bytes)? {
                0 => Playback::Stopped,
                1 => Playback::Playing,
                2 => Playback::Paused,
                3 | 4 => Playback::Seeking,
                _ => Playback::Unknown,
            });
        }
        if let Some(bytes) = playback.get(&1) {
            patch.position_ms = Some(u32_value(bytes)?);
        }
        if let Some(bytes) = playback.get(&7) {
            patch.application = Some(text(bytes)?);
        }
        if let Some(bytes) = playback.get(&16) {
            patch.application_id = Some(text(bytes)?);
        }
    }
    Ok(patch)
}
impl Metadata {
    fn update(&mut self, message: &Message, received_ms: u64) -> Result<bool, Error> {
        if message.id == POWER_UPDATE {
            let values = fields(&message.parameters)?;
            let battery = values
                .get(&6)
                .map(|b| {
                    let value = u16::from_be_bytes((*b).try_into().map_err(|_| Error::Malformed)?);
                    u8::try_from(value)
                        .ok()
                        .filter(|v| *v <= 100)
                        .ok_or(Error::Bounds)
                })
                .transpose()?;
            let external = values
                .get(&4)
                .map(|b| match byte(b)? {
                    0 => Ok(false),
                    1 => Ok(true),
                    _ => Err(Error::Malformed),
                })
                .transpose()?;
            let old = self.clone();
            if battery.is_some() {
                self.battery_percent = battery;
            }
            if external.is_some() {
                self.external_power = external;
            }
            return Ok(*self != old);
        }
        let patch = parse(message)?;
        let mut next = self.media.clone().unwrap_or_default();
        let old = next.clone();
        let track_changed = patch
            .track_id
            .as_ref()
            .is_some_and(|id| old.track_id.as_ref() != Some(id))
            || patch
                .title
                .as_ref()
                .is_some_and(|title| old.title.is_some() && &old.title != title);
        if track_changed {
            next.title = None;
            next.artist = None;
            next.album = None;
            next.album_artist = None;
            next.genre = None;
            next.track_id = None;
            next.position_ms = None;
            next.duration_ms = None;
            next.playback = Playback::Unknown;
            next.artwork = None;
            next.artwork_path = None;
            next.artwork_ftid = None;
            next.artwork_generation = next.artwork_generation.wrapping_add(1);
        }
        macro_rules! merge {
            ($field:ident) => {
                if let Some(value) = patch.$field {
                    next.$field = value;
                }
            };
        }
        merge!(title);
        merge!(artist);
        merge!(album);
        merge!(album_artist);
        merge!(genre);
        merge!(application);
        merge!(application_id);
        if let Some(value) = patch.track_id {
            next.track_id = Some(value);
        }
        if let Some(value) = patch.duration_ms {
            next.duration_ms = Some(value);
        }
        if let Some(value) = patch.position_ms {
            next.position_ms = Some(value);
        }
        if let Some(value) = patch.playback {
            next.playback = value;
        }
        if let Some(value) = patch.artwork_ftid {
            if next.artwork_ftid != Some(value) {
                next.artwork = None;
                next.artwork_path = None;
                next.artwork_generation = next.artwork_generation.wrapping_add(1);
            }
            next.artwork_ftid = Some(value);
        }
        if next == old {
            return Ok(false);
        }
        next.revision = old.revision.saturating_add(1);
        next.updated_at_ms = received_ms;
        self.media = Some(next);
        Ok(true)
    }
}

/// One transfer for the track's explicitly reported FTID, at most 1 MiB/10s.
#[derive(Default)]
struct Transfer {
    active: Option<(u8, Instant, Vec<u8>)>,
    generation: Option<u64>,
}
impl Transfer {
    fn feed(
        &mut self,
        media: Option<&MediaInfo>,
        data: &[u8],
    ) -> (Option<Vec<u8>>, Option<Vec<u8>>) {
        let Some((&id, rest)) = data.split_first() else {
            return (None, None);
        };
        let Some((&control, body)) = rest.split_first() else {
            return (None, None);
        };
        let generation = media.map(|m| m.artwork_generation);
        if self.generation != generation {
            self.active = None;
            self.generation = generation;
        }
        if media.and_then(|m| m.artwork_ftid) != Some(id) {
            return (Some(vec![id, 2]), None);
        }
        if self
            .active
            .as_ref()
            .is_some_and(|(_, start, _)| start.elapsed() > Duration::from_secs(10))
        {
            self.active = None;
        }
        match control {
            4 => {
                self.active = Some((id, Instant::now(), Vec::new()));
                (Some(vec![id, 1]), None)
            }
            2 => {
                self.active = None;
                (None, None)
            }
            0x80 | 0xc0 => {
                if body.len() > artwork::MAX_BYTES {
                    return (Some(vec![id, 2]), None);
                }
                self.active = Some((id, Instant::now(), body.to_vec()));
                if control == 0xc0 {
                    self.finish(id)
                } else {
                    (None, None)
                }
            }
            0 | 0x40 => {
                let Some((active, _, bytes)) = &mut self.active else {
                    return (Some(vec![id, 2]), None);
                };
                if *active != id || bytes.len() + body.len() > artwork::MAX_BYTES {
                    self.active = None;
                    return (Some(vec![id, 2]), None);
                }
                bytes.extend_from_slice(body);
                if control == 0x40 {
                    self.finish(id)
                } else {
                    (None, None)
                }
            }
            _ => (Some(vec![id, 2]), None),
        }
    }
    fn finish(&mut self, id: u8) -> (Option<Vec<u8>>, Option<Vec<u8>>) {
        let Some((_, _, bytes)) = self.active.take() else {
            return (Some(vec![id, 2]), None);
        };
        if artwork::validate(&bytes).is_err() {
            return (Some(vec![id, 2]), None);
        }
        (Some(vec![id, 5]), Some(bytes))
    }
}

pub struct Updates {
    sender: Option<watch::Sender<Metadata>>,
    enabled: bool,
    transfer: Transfer,
}
impl Updates {
    pub fn new(sender: Option<watch::Sender<Metadata>>) -> Self {
        Self {
            sender,
            enabled: false,
            transfer: Transfer::default(),
        }
    }
    pub fn available(&self) -> bool {
        self.sender.is_some()
    }
    pub fn subscribe(&mut self, artwork: bool) -> Result<Vec<Message>, Error> {
        if self.sender.is_none() {
            return Ok(vec![]);
        }
        self.enabled = true;
        let item: Vec<_> = [0, 1, 4, 6, 12, 14, 16]
            .into_iter()
            .chain(artwork.then_some(26))
            .map(|id| Parameter::new(id, []))
            .collect();
        Ok(vec![
            Message {
                id: START,
                parameters: vec![
                    Parameter::group(0, &item)?,
                    Parameter::group(1, &[0, 1, 7, 16].map(|id| Parameter::new(id, [])))?,
                ],
            },
            Message {
                id: POWER_START,
                parameters: [4, 6].map(|id| Parameter::new(id, [])).into(),
            },
        ])
    }
    pub fn observe(&mut self, message: &Message) -> bool {
        if !self.enabled || ![UPDATE, POWER_UPDATE].contains(&message.id) {
            return false;
        }
        if let Some(sender) = &self.sender {
            sender.send_if_modified(|state| state.update(message, now_ms()).unwrap_or(false));
        }
        true
    }
    pub fn artwork(&mut self, data: &[u8]) -> Option<Vec<u8>> {
        if !self.enabled {
            return data.first().map(|id| vec![*id, 2]);
        }
        let sender = self.sender.as_ref()?;
        let (reply, complete) = self.transfer.feed(sender.borrow().media.as_ref(), data);
        if let Some(bytes) = complete {
            sender.send_if_modified(|state| {
                let Some(media) = &mut state.media else {
                    return false;
                };
                if media
                    .artwork
                    .as_ref()
                    .is_some_and(|image| image.matches(&bytes))
                {
                    return false;
                }
                if let Ok(image) = artwork::store(bytes) {
                    media.artwork_path = Some(image.path());
                    media.artwork = Some(image);
                    media.revision = media.revision.saturating_add(1);
                    media.updated_at_ms = now_ms();
                    true
                } else {
                    false
                }
            });
        }
        reply
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn update(item: Vec<Parameter>, playback: Vec<Parameter>) -> Message {
        Message {
            id: UPDATE,
            parameters: vec![
                Parameter::group(0, &item).unwrap(),
                Parameter::group(1, &playback).unwrap(),
            ],
        }
    }
    fn png() -> Vec<u8> {
        let mut data = vec![0; 33];
        data[..8].copy_from_slice(b"\x89PNG\r\n\x1a\n");
        data[12..16].copy_from_slice(b"IHDR");
        data[16..20].copy_from_slice(&1u32.to_be_bytes());
        data[20..24].copy_from_slice(&1u32.to_be_bytes());
        data
    }
    #[test]
    fn subscriptions_request_only_implemented_fields_and_negotiated_artwork() {
        let (sender, _) = watch::channel(Metadata::default());
        let mut updates = Updates::new(Some(sender));
        let messages = updates.subscribe(false).unwrap();
        assert_eq!(
            messages.iter().map(|m| m.id).collect::<Vec<_>>(),
            [START, POWER_START]
        );
        let fields = csm::decode_parameters(messages[0].one(0).unwrap()).unwrap();
        assert!(fields.iter().any(|p| p.id == 0));
        assert!(!fields.iter().any(|p| p.id == 26));
        let messages = updates.subscribe(true).unwrap();
        assert!(
            csm::decode_parameters(messages[0].one(0).unwrap())
                .unwrap()
                .iter()
                .any(|p| p.id == 26)
        );
        assert!(Updates::new(None).subscribe(true).unwrap().is_empty());
    }

    #[test]
    fn escaped_metadata_leaves_room_in_the_private_status_response() {
        let text = "\"".repeat(512);
        let item = [1, 6, 12, 14, 16]
            .map(|id| {
                let mut data = text.as_bytes().to_vec();
                data.push(0);
                Parameter::new(id, data)
            })
            .to_vec();
        let playback = [7, 16]
            .map(|id| {
                let mut data = text.as_bytes().to_vec();
                data.push(0);
                Parameter::new(id, data)
            })
            .to_vec();
        let mut state = Metadata::default();
        assert!(state.update(&update(item, playback), 1).unwrap());
        assert!(serde_json::to_vec(&state.media).unwrap().len() < 8192);
        let mut too_long = vec![b'X'; 513];
        too_long.push(0);
        assert!(
            state
                .update(&update(vec![Parameter::new(1, too_long)], vec![]), 2)
                .is_err()
        );
    }
    #[test]
    fn metadata_merges_partial_playback_without_retaining_old_track_facts() {
        let mut state = Metadata::default();
        assert!(
            state
                .update(
                    &update(
                        vec![
                            Parameter::new(0, 1u64.to_be_bytes()),
                            Parameter::string(1, "First").unwrap(),
                            Parameter::string(12, "Artist").unwrap(),
                            Parameter::string(6, "Album").unwrap(),
                            Parameter::new(4, 123000u32.to_be_bytes()),
                            Parameter::new(26, [7])
                        ],
                        vec![
                            Parameter::new(0, [1]),
                            Parameter::new(1, 1200u32.to_be_bytes()),
                            Parameter::string(7, "Music").unwrap(),
                            Parameter::string(16, "com.example.player").unwrap()
                        ]
                    ),
                    1000
                )
                .unwrap()
        );
        let first = state.media.clone().unwrap();
        assert_eq!(first.revision, 1);
        assert_eq!(first.playback, Playback::Playing);
        assert!(
            state
                .update(
                    &update(vec![], vec![Parameter::new(1, 2500u32.to_be_bytes())]),
                    2000
                )
                .unwrap()
        );
        let partial = state.media.as_ref().unwrap();
        assert_eq!(partial.title.as_deref(), Some("First"));
        assert_eq!(partial.position_ms, Some(2500));
        assert_eq!(partial.revision, 2);
        assert!(
            state
                .update(
                    &update(
                        vec![
                            Parameter::new(0, 2u64.to_be_bytes()),
                            Parameter::string(1, "Second").unwrap()
                        ],
                        vec![]
                    ),
                    3000
                )
                .unwrap()
        );
        let next = state.media.unwrap();
        assert_eq!(next.title.as_deref(), Some("Second"));
        assert_eq!(next.artist, None);
        assert_eq!(next.album, None);
        assert_eq!(next.duration_ms, None);
        assert_eq!(next.position_ms, None);
        assert_eq!(next.artwork_ftid, None);
        assert_eq!(next.application.as_deref(), Some("Music"));
        assert_eq!(next.playback, Playback::Unknown);
        assert_eq!(next.updated_at_ms, 3000);
    }
    #[test]
    fn malformed_optional_updates_are_atomic_and_do_not_publish() {
        let (sender, mut observed) = watch::channel(Metadata::default());
        let mut updates = Updates::new(Some(sender));
        updates.subscribe(true).unwrap();
        assert!(updates.observe(&update(
            vec![Parameter::string(1, "First").unwrap()],
            vec![]
        )));
        observed.borrow_and_update();
        let original = observed.borrow().clone();
        for bad in [
            update(
                vec![Parameter::string(1, "Bad").unwrap(), Parameter::new(4, [0])],
                vec![],
            ),
            update(vec![], vec![Parameter::new(0, [1]), Parameter::new(0, [2])]),
            Message {
                id: POWER_UPDATE,
                parameters: vec![Parameter::new(6, 101u16.to_be_bytes())],
            },
        ] {
            assert!(updates.observe(&bad));
            assert_eq!(*observed.borrow(), original);
            assert!(!observed.has_changed().unwrap());
        }
        let mut malformed = Parameter::string(1, "Bad").unwrap();
        malformed.value.push(0);
        assert!(updates.observe(&update(vec![malformed], vec![])));
        assert_eq!(*observed.borrow(), original);
    }
    #[test]
    fn no_change_does_not_increment_revision_and_empty_text_explicitly_clears() {
        let mut state = Metadata::default();
        let message = update(vec![Parameter::string(1, "Song").unwrap()], vec![]);
        assert!(state.update(&message, 1).unwrap());
        assert!(!state.update(&message, 2).unwrap());
        assert_eq!(state.media.as_ref().unwrap().revision, 1);
        assert!(
            state
                .update(&update(vec![Parameter::new(1, [0])], vec![]), 3)
                .unwrap()
        );
        assert_eq!(state.media.unwrap().title, None);
    }
    #[test]
    fn battery_and_external_power_are_distinct_from_charging_and_media_clock() {
        let mut state = Metadata::default();
        let message = Message {
            id: POWER_UPDATE,
            parameters: vec![
                Parameter::new(6, 73u16.to_be_bytes()),
                Parameter::new(4, [1]),
            ],
        };
        assert!(state.update(&message, 1).unwrap());
        assert_eq!(state.battery_percent, Some(73));
        assert_eq!(state.external_power, Some(true));
        assert!(state.media.is_none());
        assert!(
            state
                .update(
                    &Message {
                        id: POWER_UPDATE,
                        parameters: vec![Parameter::new(6, 0u16.to_be_bytes())]
                    },
                    2
                )
                .unwrap()
        );
        assert_eq!(state.battery_percent, Some(0));
        assert_eq!(state.external_power, Some(true));
    }
    #[test]
    fn artwork_matches_ftid_and_retires_with_track_and_session() {
        let (sender, observed) = watch::channel(Metadata::default());
        let mut updates = Updates::new(Some(sender));
        updates.subscribe(true).unwrap();
        updates.observe(&update(
            vec![
                Parameter::new(0, 1u64.to_be_bytes()),
                Parameter::new(26, [7]),
            ],
            vec![],
        ));
        assert_eq!(updates.artwork(&[8, 4]), Some(vec![8, 2]));
        assert_eq!(updates.artwork(&[7, 4]), Some(vec![7, 1]));
        let data = png();
        let mut first = vec![7, 0x80];
        first.extend(&data[..20]);
        assert_eq!(updates.artwork(&first), None);
        let mut last = vec![7, 0x40];
        last.extend(&data[20..]);
        assert_eq!(updates.artwork(&last), Some(vec![7, 5]));
        let old = observed.borrow().media.clone().unwrap();
        let path = old.artwork_path.clone().unwrap();
        assert!(std::path::Path::new(&path).exists());
        assert!(
            serde_json::to_string(&old)
                .unwrap()
                .contains("artwork_path")
        );
        updates.observe(&update(
            vec![
                Parameter::new(0, 2u64.to_be_bytes()),
                Parameter::new(26, [7]),
            ],
            vec![],
        ));
        assert_eq!(observed.borrow().media.as_ref().unwrap().artwork_path, None);
        assert_eq!(updates.artwork(&last), Some(vec![7, 2]));
        assert!(std::path::Path::new(&path).exists());
        drop(old);
        assert!(!std::path::Path::new(&path).exists());
        let mut whole = vec![7, 0xc0];
        whole.extend(data);
        assert_eq!(updates.artwork(&whole), Some(vec![7, 5]));
        let path = observed
            .borrow()
            .media
            .as_ref()
            .unwrap()
            .artwork_path
            .clone()
            .unwrap();
        drop(updates);
        drop(observed);
        assert!(!std::path::Path::new(&path).exists());
    }
    #[test]
    fn artwork_transfer_bounds_and_optional_failures_do_not_change_metadata() {
        let (sender, observed) = watch::channel(Metadata::default());
        let mut updates = Updates::new(Some(sender));
        updates.subscribe(true).unwrap();
        updates.observe(&update(vec![Parameter::new(26, [2])], vec![]));
        let before = observed.borrow().clone();
        let mut huge = vec![2, 0x80];
        huge.resize(artwork::MAX_BYTES + 3, 1);
        assert_eq!(updates.artwork(&huge), Some(vec![2, 2]));
        assert_eq!(updates.artwork(&[2, 0xc0, 0, 1, 2]), Some(vec![2, 2]));
        assert_eq!(*observed.borrow(), before);
    }
}
