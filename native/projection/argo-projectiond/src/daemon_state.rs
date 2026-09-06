use crate::ipc::{DecodeError, Message, PayloadWriter};

pub const IPC_HELLO: u16 = 1;
pub const IPC_DEVICE: u16 = 2;
pub const IPC_SESSION: u16 = 3;
pub const IPC_ERROR: u16 = 6;
pub const IPC_DEVICE_REMOVED: u16 = 7;
pub const IPC_SESSION_REMOVED: u16 = 8;

const PROTOCOL_ANDROID_AUTO: u8 = 0;
const TRANSPORT_USB: u8 = 0;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectionDeviceStatus {
    pub id: String,
    pub display_name: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProjectionSessionStatus {
    Connecting,
    Ready,
    Streaming,
    Suspended,
    Failed,
}

impl ProjectionSessionStatus {
    fn wire_value(self) -> u8 {
        match self {
            Self::Connecting => 0,
            Self::Ready => 1,
            Self::Streaming => 2,
            Self::Suspended => 3,
            Self::Failed => 4,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProjectionSessionStatusSnapshot {
    pub id: String,
    pub device_id: String,
    pub state: ProjectionSessionStatus,
    pub failure: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProjectionRuntimeSnapshot {
    pub device: Option<ProjectionDeviceStatus>,
    pub session: Option<ProjectionSessionStatusSnapshot>,
    pub video: Option<(crate::aa_channels::DisplayConfig, bool)>,
    pub audio: [bool; 3],
    pub metadata: crate::metadata::Snapshot,
}

impl ProjectionRuntimeSnapshot {
    pub fn connecting(device_id: String, display_name: String) -> Self {
        Self {
            device: Some(ProjectionDeviceStatus {
                id: device_id.clone(),
                display_name,
            }),
            session: Some(ProjectionSessionStatusSnapshot {
                id: format!("aa-wired:{device_id}"),
                device_id,
                state: ProjectionSessionStatus::Connecting,
                failure: None,
            }),
            video: None,
            audio: [false; 3],
            metadata: Default::default(),
        }
    }

    pub fn update_metadata(&mut self, id: &str, update: crate::metadata::Update) -> bool {
        if !self
            .session
            .as_ref()
            .is_some_and(|s| s.id == id && s.state != ProjectionSessionStatus::Failed)
        {
            return false;
        }
        self.metadata.apply(update)
    }

    pub fn ready(mut self) -> Self {
        if let Some(session) = self.session.as_mut() {
            session.state = ProjectionSessionStatus::Ready;
            session.failure = None;
        }
        self
    }

    pub fn failed(mut self, failure: impl Into<String>) -> Self {
        self.metadata = Default::default();
        self.video = None;
        self.audio = [false; 3];
        if let Some(session) = self.session.as_mut() {
            session.state = ProjectionSessionStatus::Failed;
            session.failure = Some(failure.into());
        }
        self
    }
}

pub fn snapshot_messages(
    previous: &ProjectionRuntimeSnapshot,
    current: &ProjectionRuntimeSnapshot,
) -> Result<Vec<Message>, DecodeError> {
    let mut messages = Vec::new();
    if previous.session.as_ref().map(|value| &value.id)
        != current.session.as_ref().map(|value| &value.id)
        && let Some(session) = previous.session.as_ref()
    {
        messages.push(removed_message(IPC_SESSION_REMOVED, &session.id)?);
    }
    if previous.device.as_ref().map(|value| &value.id)
        != current.device.as_ref().map(|value| &value.id)
        && let Some(device) = previous.device.as_ref()
    {
        messages.push(removed_message(IPC_DEVICE_REMOVED, &device.id)?);
    }
    if previous.device != current.device
        && let Some(device) = current.device.as_ref()
    {
        messages.push(device_message(device)?);
    }
    if previous.session != current.session
        && let Some(session) = current.session.as_ref()
    {
        messages.push(session_message(session)?);
    }
    if let Some(session) = current.session.as_ref() {
        if previous.metadata != current.metadata
            || previous.session.as_ref().map(|s| &s.id) != Some(&session.id)
        {
            messages.push(current.metadata.message(&session.id, &session.device_id)?);
        }
        if let Some((display, visible)) = &current.video
            && (previous.video != current.video || previous.session != current.session)
        {
            let mut writer = PayloadWriter::default();
            writer.string(&session.id)?;
            writer.string(&format!("{}:main", session.id))?;
            writer.u8(0);
            writer.u8(0);
            writer.u16(display.width);
            writer.u16(display.height);
            writer.u8(display.fps);
            for _ in 0..8 {
                writer.u16(0);
            }
            writer.u8(u8::from(*visible));
            writer.u8(u8::from(*visible));
            messages.push(Message {
                kind: 4,
                payload: writer.finish(),
            });
        }
        for i in 0..3 {
            if current.audio[i] != previous.audio[i]
                || (current.audio[i] && previous.session != current.session)
            {
                let mut writer = PayloadWriter::default();
                writer.string(&session.id)?;
                writer.string(["media", "speech", "system"][i])?;
                writer.u8(i as u8);
                writer.u8(u8::from(current.audio[i]));
                writer.u8(u8::from(current.audio[i]));
                let format = crate::configuration::AUDIO[i];
                writer.u16(format.rate);
                writer.u8(format.bits);
                writer.u8(format.channels);
                messages.push(Message {
                    kind: 5,
                    payload: writer.finish(),
                });
            }
        }
    }
    Ok(messages)
}

fn device_message(device: &ProjectionDeviceStatus) -> Result<Message, DecodeError> {
    let mut writer = PayloadWriter::default();
    writer.string(&device.id)?;
    writer.string(&device.display_name)?;
    writer.u8(PROTOCOL_ANDROID_AUTO);
    writer.u8(TRANSPORT_USB);
    Ok(Message {
        kind: IPC_DEVICE,
        payload: writer.finish(),
    })
}

fn session_message(session: &ProjectionSessionStatusSnapshot) -> Result<Message, DecodeError> {
    let mut writer = PayloadWriter::default();
    writer.string(&session.id)?;
    writer.string(&session.device_id)?;
    writer.u8(session.state.wire_value());
    writer.string(session.failure.as_deref().unwrap_or_default())?;
    Ok(Message {
        kind: IPC_SESSION,
        payload: writer.finish(),
    })
}

fn removed_message(kind: u16, id: &str) -> Result<Message, DecodeError> {
    let mut writer = PayloadWriter::default();
    writer.string(id)?;
    Ok(Message {
        kind,
        payload: writer.finish(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projection_state_updates_are_projection_neutral() {
        let empty = ProjectionRuntimeSnapshot::default();
        let connecting = ProjectionRuntimeSnapshot::connecting(
            "usb:phone".to_owned(),
            "Android phone".to_owned(),
        );
        let initial = snapshot_messages(&empty, &connecting).unwrap();
        assert_eq!(
            initial
                .iter()
                .map(|message| message.kind)
                .collect::<Vec<_>>(),
            vec![IPC_DEVICE, IPC_SESSION, 11]
        );

        let ready = connecting.clone().ready();
        let update = snapshot_messages(&connecting, &ready).unwrap();
        assert_eq!(
            update
                .iter()
                .map(|message| message.kind)
                .collect::<Vec<_>>(),
            vec![IPC_SESSION]
        );
    }
}
