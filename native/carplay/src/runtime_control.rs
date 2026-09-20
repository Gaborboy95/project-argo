//! Private metadata/input IPC. No phone protocol, credentials or media bytes cross this socket.
use crate::protocol::{
    receiver::{Command, SessionInfo, Video},
    wired,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::BTreeMap, io, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    sync::{Mutex, Semaphore, mpsc, watch},
    task::JoinSet,
    time::timeout,
};

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Status,
    Activate {
        session: u64,
    },
    Visibility {
        session: u64,
        visible: bool,
    },
    Touch {
        session: u64,
        pointer: u16,
        phase: Phase,
        x: f64,
        y: f64,
    },
    Gain {
        session: u64,
        connection: String,
        gain: f64,
    },
    Disconnect {
        session: u64,
    },
    MicrophoneSource {
        session: u64,
        source: String,
    },
    MicrophoneMute {
        session: u64,
        muted: bool,
    },
    Siri {
        session: u64,
        #[serde(default)]
        pressed: Option<bool>,
    },
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Down,
    Move,
    Up,
    Cancel,
}
#[derive(Default)]
struct Presentation {
    active: bool,
    revision: u64,
    visible: bool,
    pointers: BTreeMap<u16, u8>,
}
pub struct Control {
    pub session: u64,
    pub device_id: String,
    pub video: watch::Receiver<Option<Video>>,
    pub information: watch::Receiver<SessionInfo>,
    pub wired: watch::Receiver<wired::State>,
    pub commands: mpsc::Sender<Command>,
    pub disconnect: watch::Sender<bool>,
    presentation: Mutex<Presentation>,
}
impl Control {
    pub fn new(
        session: u64,
        device_id: String,
        video: watch::Receiver<Option<Video>>,
        information: watch::Receiver<SessionInfo>,
        wired: watch::Receiver<wired::State>,
        commands: mpsc::Sender<Command>,
        disconnect: watch::Sender<bool>,
    ) -> Self {
        Self {
            session,
            device_id,
            video,
            information,
            wired,
            commands,
            disconnect,
            presentation: Mutex::new(Presentation::default()),
        }
    }
    fn command(&self, command: Command) -> io::Result<()> {
        self.commands
            .try_send(command)
            .map_err(|_| io::Error::other("CarPlay input queue unavailable"))
    }
    async fn request(&self, request: Request) -> io::Result<Value> {
        let mut presentation = self.presentation.lock().await;
        let session = match &request {
            Request::Status => self.session,
            Request::Activate { session }
            | Request::Visibility { session, .. }
            | Request::Touch { session, .. }
            | Request::Gain { session, .. }
            | Request::Disconnect { session }
            | Request::MicrophoneSource { session, .. }
            | Request::MicrophoneMute { session, .. }
            | Request::Siri { session, .. } => *session,
        };
        if session != self.session {
            return Err(io::Error::other("stale session"));
        }
        match request {
            Request::Status => {
                let information = self.information.borrow().clone();
                let video=self.video.borrow().as_ref().map(|video|{
                    let d=video.description;
                    json!({"id":"main","width":d.width,"height":d.height,"fps":d.fps_num/d.fps_den,"codec":if d.codec==crate::media::Codec::H264{"h264"}else{"hevc"},"first_frame":*video.first_frame.borrow(),"presentation_revision":presentation.revision,"native_parameters":d.view_parameters(Default::default()).ok().map(|b|b.to_vec())})
                });
                return Ok(
                    json!({"contract":1,"available":true,"microphone_policy":true,"microphone_source":true,"session":self.session,"device":self.device_id,"name":if information.name.is_empty(){"iPhone"}else{&information.name},"recorded":information.recorded,"stage":format!("{:?}",*self.wired.borrow()),"selected":presentation.active,"visible":presentation.visible,"video":video,"audio":information.audio,"host_return_revision":information.host_return_revision}),
                );
            }
            Request::Activate { .. } => {
                presentation.revision = presentation
                    .revision
                    .checked_add(1)
                    .ok_or_else(|| io::Error::other("presentation revision exhausted"))?;
                presentation.active = true;
                presentation.visible = true;
                self.command(Command::Keyframe)?;
                if self.information.borrow().audio_available {
                    self.command(Command::ReleaseAudio)?;
                }
            }
            Request::Visibility { visible, .. } => {
                presentation.visible = visible;
                if !visible {
                    presentation.pointers.clear();
                    self.command(Command::ReleaseTouches)?;
                } else if presentation.active {
                    self.command(Command::Keyframe)?;
                }
            }
            Request::Touch {
                pointer,
                phase,
                x,
                y,
                ..
            } => {
                if !presentation.active || !presentation.visible {
                    return Err(io::Error::other("projection input is not owned"));
                }
                if !x.is_finite()
                    || !y.is_finite()
                    || !(0.0..=1.0).contains(&x)
                    || !(0.0..=1.0).contains(&y)
                {
                    return Err(io::Error::other("invalid coordinates"));
                }
                if matches!(phase, Phase::Cancel) {
                    presentation.pointers.clear();
                    self.command(Command::ReleaseTouches)?;
                } else {
                    let video = self.video.borrow();
                    let description = video
                        .as_ref()
                        .ok_or_else(|| io::Error::other("video not ready"))?
                        .description;
                    let slot = match phase {
                        Phase::Down => {
                            if presentation.pointers.contains_key(&pointer) {
                                return Err(io::Error::other("duplicate touch"));
                            }
                            let slot = (0..2)
                                .find(|slot| {
                                    !presentation.pointers.values().any(|value| value == slot)
                                })
                                .ok_or_else(|| io::Error::other("touch capacity"))?;
                            presentation.pointers.insert(pointer, slot);
                            slot
                        }
                        _ => *presentation
                            .pointers
                            .get(&pointer)
                            .ok_or_else(|| io::Error::other("unknown touch"))?,
                    };
                    let down = !matches!(phase, Phase::Up);
                    self.command(Command::Touch {
                        slot,
                        down,
                        x: (x * description.width as f64).round() as u16,
                        y: (y * description.height as f64).round() as u16,
                    })?;
                    if !down {
                        presentation.pointers.remove(&pointer);
                    }
                }
            }
            Request::Gain {
                connection, gain, ..
            } => {
                if !gain.is_finite() || !(0.0..=1.0).contains(&gain) {
                    return Err(io::Error::other("invalid gain"));
                }
                let connection = connection
                    .parse()
                    .map_err(|_| io::Error::other("invalid audio stream"))?;
                self.command(Command::AudioGain {
                    connection,
                    gain: if presentation.active { gain } else { 0.0 },
                })?;
            }
            Request::Disconnect { .. } => {
                presentation.active = false;
                presentation.visible = false;
                presentation.pointers.clear();
                self.command(Command::ReleaseTouches)?;
                self.disconnect.send_replace(true);
            }
            Request::MicrophoneSource { source, .. } => {
                if source.is_empty()
                    || source.len() > 256
                    || !source
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
                {
                    return Err(io::Error::other("Invalid input source"));
                }
                self.command(Command::MicrophoneSource(source))?;
            }
            Request::MicrophoneMute { muted, .. } => {
                self.command(Command::MicrophoneMute(muted))?
            }
            Request::Siri { pressed, .. } => {
                if !presentation.active {
                    return Err(io::Error::other("projection is not owned"));
                }
                self.command(pressed.map(Command::SiriButton).unwrap_or(Command::Siri))?;
            }
        }
        Ok(json!({"ok":true}))
    }
    pub async fn serve(self: Arc<Self>, listener: UnixListener) -> io::Result<()> {
        let permits = Arc::new(Semaphore::new(8));
        let mut tasks = JoinSet::new();
        loop {
            tokio::select! {
                accepted=listener.accept()=>{let (socket,_)=accepted?;let Ok(permit)=permits.clone().try_acquire_owned()else{continue;};let owner=self.clone();tasks.spawn(async move{let _permit=permit;let _=timeout(Duration::from_secs(2),handle(socket,owner)).await;});},
                _=tasks.join_next(),if !tasks.is_empty()=>{}
            }
        }
    }
}
async fn handle(mut socket: UnixStream, owner: Arc<Control>) -> io::Result<()> {
    if socket.peer_cred()?.uid() != unsafe { libc::geteuid() } {
        return Err(io::Error::other("wrong user"));
    }
    let mut bytes = Vec::with_capacity(256);
    loop {
        let byte = socket.read_u8().await?;
        if byte == b'\n' {
            break;
        }
        if bytes.len() >= 1024 {
            return Err(io::Error::other("request bounds"));
        }
        bytes.push(byte);
    }
    let request: Request = serde_json::from_slice(&bytes)?;
    let reply = match owner.request(request).await {
        Ok(value) => value,
        Err(_) => json!({"ok":false,"error":"CarPlay operation unavailable"}),
    };
    let mut bytes = serde_json::to_vec(&reply)?;
    if bytes.len() > 16383 {
        return Err(io::Error::other("response bounds"));
    }
    bytes.push(b'\n');
    socket.write_all(&bytes).await
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn activation_advances_presentation_and_hidden_input_is_rejected() {
        let (commands, mut received) = mpsc::channel(8);
        let control = Control::new(
            7,
            "fixture".into(),
            watch::channel(None).1,
            watch::channel(SessionInfo::default()).1,
            watch::channel(wired::State::StartSessionSent).1,
            commands,
            watch::channel(false).0,
        );
        assert!(
            control
                .request(Request::Activate { session: 8 })
                .await
                .is_err()
        );
        assert!(received.try_recv().is_err());
        for expected in 1..=2 {
            control
                .request(Request::Activate { session: 7 })
                .await
                .unwrap();
            assert_eq!(control.presentation.lock().await.revision, expected);
            assert!(matches!(received.recv().await, Some(Command::Keyframe)));
        }
        control
            .request(Request::Visibility {
                session: 7,
                visible: false,
            })
            .await
            .unwrap();
        assert!(matches!(
            received.recv().await,
            Some(Command::ReleaseTouches)
        ));
        assert!(
            control
                .request(Request::Touch {
                    session: 7,
                    pointer: 0,
                    phase: Phase::Down,
                    x: 0.5,
                    y: 0.5
                })
                .await
                .is_err()
        );
        assert!(received.try_recv().is_err());
    }
}
