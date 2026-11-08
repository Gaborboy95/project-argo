//! Private metadata/input IPC. No phone protocol, credentials or media bytes cross this socket.
use crate::protocol::{
    receiver::{Command, MediaButton, MicrophoneMode, SessionInfo, Video},
    wired,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{collections::BTreeMap, io, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    sync::{Mutex, Semaphore, mpsc, watch},
    task::JoinSet,
    time::timeout,
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionTransport {
    #[default]
    Usb,
    Wireless,
}

impl SessionTransport {
    pub fn is_usb(&self) -> bool {
        *self == Self::Usb
    }
}

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
    Media {
        session: u64,
        command: MediaButton,
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
    pub transport: SessionTransport,
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
        Self::new_with_transport(
            session,
            device_id,
            video,
            information,
            wired,
            commands,
            disconnect,
            SessionTransport::Usb,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn new_with_transport(
        session: u64,
        device_id: String,
        video: watch::Receiver<Option<Video>>,
        information: watch::Receiver<SessionInfo>,
        wired: watch::Receiver<wired::State>,
        commands: mpsc::Sender<Command>,
        disconnect: watch::Sender<bool>,
        transport: SessionTransport,
    ) -> Self {
        Self {
            session,
            device_id,
            video,
            information,
            wired,
            commands,
            disconnect,
            transport,
            presentation: Mutex::new(Presentation::default()),
        }
    }
    fn command(&self, command: Command) -> io::Result<()> {
        self.commands
            .try_send(command)
            .map_err(|_| io::Error::other("CarPlay input queue unavailable"))
    }
    // Cancellation has its own watch channel and never needs queue capacity.
    fn end_session(&self, presentation: &mut Presentation) {
        presentation.active = false;
        presentation.visible = false;
        presentation.pointers.clear();
        self.disconnect.send_replace(true);
    }

    fn terminal_command(
        &self,
        presentation: &mut Presentation,
        command: Command,
    ) -> io::Result<()> {
        self.command(command)
            .inspect_err(|_| self.end_session(presentation))
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
            | Request::Siri { session, .. }
            | Request::Media { session, .. } => *session,
        };
        if session != self.session {
            return Err(io::Error::other("stale session"));
        }
        if *self.disconnect.borrow()
            && !matches!(request, Request::Status | Request::Disconnect { .. })
        {
            return Err(io::Error::other("session ended; reconnect required"));
        }
        match request {
            Request::Status => {
                let information = self.information.borrow().clone();
                let video=self.video.borrow().as_ref().map(|video|{
                    let d=video.description;
                    json!({"id":"main","width":d.width,"height":d.height,"fps":d.fps_num/d.fps_den,"codec":if d.codec==crate::media::Codec::H264{"h264"}else{"hevc"},"first_frame":*video.first_frame.borrow(),"presentation_revision":presentation.revision,"native_parameters":d.view_parameters(video.crop).ok().map(|b|b.to_vec())})
                });
                return Ok(
                    json!({"contract":1,"available":true,"microphone_policy":true,"microphone_source":information.microphone_mode != MicrophoneMode::Silence,"microphone_mode":information.microphone_mode,"microphone_available":information.microphone_available,"microphone_muted":information.microphone_muted,"session":self.session,"device":self.device_id,"transport":self.transport,"name":if information.name.is_empty(){"iPhone"}else{&information.name},"recorded":information.recorded,"stage":format!("{:?}",*self.wired.borrow()),"selected":presentation.active,"visible":presentation.visible,"video":video,"audio":information.audio,"host_return_revision":information.host_return_revision,"phone_duck":information.phone_duck,"media":information.media,"phone":{"battery_percent":information.battery_percent,"external_power":information.external_power},"media_commands":if information.recorded && information.media_commands {vec!["previous","play","pause","playPause","next"]} else {vec![]}}),
                );
            }
            Request::Activate { .. } => {
                let revision = presentation
                    .revision
                    .checked_add(1)
                    .ok_or_else(|| io::Error::other("presentation revision exhausted"))?;
                let release_audio = self.information.borrow().audio_available;
                // Reserve the entire operation before any observable mutation or send.
                let permits = self
                    .commands
                    .try_reserve_many(if release_audio { 2 } else { 1 })
                    .map_err(|_| io::Error::other("CarPlay input queue unavailable"))?;
                for (index, permit) in permits.enumerate() {
                    permit.send(if index == 0 {
                        Command::Keyframe
                    } else {
                        Command::ReleaseAudio
                    });
                }
                presentation.revision = revision;
                presentation.active = true;
                presentation.visible = true;
            }
            Request::Visibility { visible, .. } => {
                if !visible {
                    self.terminal_command(&mut presentation, Command::ReleaseTouches)?;
                    presentation.pointers.clear();
                } else if presentation.active {
                    self.command(Command::Keyframe)?;
                }
                presentation.visible = visible;
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
                    self.terminal_command(&mut presentation, Command::ReleaseTouches)?;
                    presentation.pointers.clear();
                } else {
                    let video = self.video.borrow();
                    let video = video
                        .as_ref()
                        .ok_or_else(|| io::Error::other("video not ready"))?;
                    let description = video.description;
                    let crop = video.crop;
                    let slot = match phase {
                        Phase::Down => {
                            if presentation.pointers.contains_key(&pointer) {
                                return Err(io::Error::other("duplicate touch"));
                            }
                            (0..2)
                                .find(|slot| {
                                    !presentation.pointers.values().any(|value| value == slot)
                                })
                                .ok_or_else(|| io::Error::other("touch capacity"))?
                        }
                        _ => *presentation
                            .pointers
                            .get(&pointer)
                            .ok_or_else(|| io::Error::other("unknown touch"))?,
                    };
                    let down = !matches!(phase, Phase::Up);
                    let command = Command::Touch {
                        slot,
                        down,
                        x: crop.left
                            + (x * f64::from(description.width - crop.left - crop.right)).round()
                                as u16,
                        y: crop.top
                            + (y * f64::from(description.height - crop.top - crop.bottom)).round()
                                as u16,
                    };
                    if down {
                        self.command(command)?;
                        presentation.pointers.insert(pointer, slot);
                    } else {
                        self.terminal_command(&mut presentation, command)?;
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
                let information = self.information.borrow();
                let stream = information
                    .audio
                    .iter()
                    .find(|stream| stream.connection == connection)
                    .ok_or_else(|| io::Error::other("unknown audio stream"))?;
                // Entertainment selection owns media gain independently of
                // the displayed projection. Other audio keeps its existing
                // presentation policy; a numeric connection alone cannot
                // claim the media exception.
                let allowed = presentation.active || stream.category == "media";
                let connection = connection
                    .parse()
                    .map_err(|_| io::Error::other("invalid audio stream"))?;
                self.command(Command::AudioGain {
                    connection,
                    gain: if allowed { gain } else { 0.0 },
                })?;
            }
            Request::Disconnect { .. } => {
                self.end_session(&mut presentation);
                // Best effort only: teardown must survive a full/closed input queue.
                let _ = self.command(Command::ReleaseTouches);
            }
            Request::MicrophoneSource { source, .. } => {
                if self.information.borrow().microphone_mode == MicrophoneMode::Silence {
                    return Err(io::Error::other(
                        "Silent input cannot become a microphone; reconnect required",
                    ));
                }
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
                let silent = self.information.borrow().microphone_mode == MicrophoneMode::Silence;
                self.command(Command::MicrophoneMute(muted || silent))?
            }
            Request::Media { command, .. } => {
                let information = self.information.borrow();
                if !information.recorded || !information.media_commands {
                    return Err(io::Error::other("unsupported media controls"));
                }
                // Media source selection owns these controls; video visibility
                // is independent and must not prevent native Now Playing use.
                self.command(Command::Media(command))?;
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
        Err(error) => {
            let detail = error.to_string();
            let code = match detail.as_str() {
                "stale session" | "session ended; reconnect required" => "stale_session",
                "CarPlay input queue unavailable" => "busy",
                _ => "rejected",
            };
            json!({"ok":false,"code":code,"error":detail})
        }
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
    fn fixture(capacity: usize) -> (Control, mpsc::Receiver<Command>) {
        use crate::media::*;
        let description = Description {
            protocol: Protocol::CarPlay,
            plane: Plane::Main,
            codec: Codec::H264,
            colorimetry: Colorimetry::Bt709,
            range: ColorRange::Limited,
            framing: Framing::AnnexB,
            width: 800,
            height: 480,
            fps_num: 30,
            fps_den: 1,
            session: 7,
        };
        let video = Video {
            description,
            crop: Default::default(),
            first_frame: watch::channel(true).1,
            stream: VideoStream::new(description, &[0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 1])
                .unwrap(),
        };
        let (commands, received) = mpsc::channel(capacity);
        (
            Control::new(
                7,
                "fixture".into(),
                watch::channel(Some(video)).1,
                watch::channel(SessionInfo::default()).1,
                watch::channel(wired::State::StartSessionSent).1,
                commands,
                watch::channel(false).0,
            ),
            received,
        )
    }

    fn touch(phase: Phase) -> Request {
        Request::Touch {
            session: 7,
            pointer: 42,
            phase,
            x: 0.5,
            y: 0.5,
        }
    }

    fn audio_stream(connection: &str, category: &str) -> crate::protocol::receiver::AudioInfo {
        crate::protocol::receiver::AudioInfo {
            connection: connection.into(),
            category: category.into(),
            rate: 48000,
            channels: 2,
            active: true,
            #[cfg(feature = "linux-audio")]
            metrics: Default::default(),
        }
    }

    fn gain(session: u64, connection: &str, gain: f64) -> Request {
        Request::Gain {
            session,
            connection: connection.into(),
            gain,
        }
    }

    #[tokio::test]
    async fn silent_input_status_is_truthful_and_rejects_a_live_device_switch() {
        let (mut control, mut commands) = fixture(2);
        control.information = watch::channel(SessionInfo {
            microphone_mode: MicrophoneMode::Silence,
            microphone_available: false,
            microphone_muted: true,
            ..Default::default()
        })
        .1;
        let status = control.request(Request::Status).await.unwrap();
        assert_eq!(status["microphone_mode"], "silence");
        assert_eq!(status["microphone_available"], false);
        assert_eq!(status["microphone_muted"], true);
        assert_eq!(status["microphone_source"], false);
        let error = control
            .request(Request::MicrophoneSource {
                session: 7,
                source: "real.microphone".into(),
            })
            .await
            .unwrap_err();
        assert!(error.to_string().contains("reconnect required"));
        assert!(commands.try_recv().is_err());
        control
            .request(Request::MicrophoneMute {
                session: 7,
                muted: false,
            })
            .await
            .unwrap();
        assert!(matches!(
            commands.recv().await,
            Some(Command::MicrophoneMute(true))
        ));
        assert_eq!(
            control.request(Request::Status).await.unwrap()["microphone_muted"],
            true
        );
        assert!(!*control.disconnect.borrow());
    }

    #[tokio::test]
    async fn reported_media_gain_does_not_require_video_ownership() {
        let (mut control, mut commands) = fixture(4);
        control.information = watch::channel(SessionInfo {
            recorded: true,
            audio_available: true,
            audio: vec![audio_stream("41", "media")],
            ..Default::default()
        })
        .1;
        control.request(gain(7, "41", 0.625)).await.unwrap();
        assert!(matches!(
            commands.recv().await,
            Some(Command::AudioGain {
                connection: 41,
                gain: 0.625
            })
        ));
        let state = control.presentation.lock().await;
        assert!(!state.active && !state.visible);
        assert_eq!(state.revision, 0);
        assert!(state.pointers.is_empty());
        drop(state);
        assert!(control.request(touch(Phase::Down)).await.is_err());
        assert!(commands.try_recv().is_err());
        assert!(!*control.disconnect.borrow());
    }

    #[tokio::test]
    async fn non_media_gain_keeps_presentation_policy_and_uses_current_category() {
        let (mut control, mut commands) = fixture(4);
        let (information, _) = watch::channel(SessionInfo {
            recorded: true,
            audio: vec![audio_stream("41", "media")],
            ..Default::default()
        });
        control.information = information.subscribe();
        for category in [
            "default",
            "telephony",
            "speechRecognition",
            "alert",
            "compatibility",
        ] {
            information.send_modify(|info| info.audio[0].category = category.into());
            control.request(gain(7, "41", 0.75)).await.unwrap();
            assert!(matches!(
                commands.recv().await,
                Some(Command::AudioGain {
                    connection: 41,
                    gain: 0.0
                })
            ));
        }
        control
            .request(Request::Activate { session: 7 })
            .await
            .unwrap();
        assert!(matches!(commands.recv().await, Some(Command::Keyframe)));
        control.request(gain(7, "41", 0.75)).await.unwrap();
        assert!(matches!(
            commands.recv().await,
            Some(Command::AudioGain {
                connection: 41,
                gain: 0.75
            })
        ));
        control
            .request(Request::Visibility {
                session: 7,
                visible: false,
            })
            .await
            .unwrap();
        assert!(matches!(
            commands.recv().await,
            Some(Command::ReleaseTouches)
        ));
        information.send_modify(|info| info.audio[0].category = "media".into());
        control.request(gain(7, "41", 1.0)).await.unwrap();
        assert!(matches!(
            commands.recv().await,
            Some(Command::AudioGain {
                connection: 41,
                gain: 1.0
            })
        ));
        assert!(control.request(touch(Phase::Down)).await.is_err());
        assert!(commands.try_recv().is_err());
    }

    #[tokio::test]
    async fn gain_rejects_stale_ended_unknown_and_invalid_requests() {
        let (mut control, mut commands) = fixture(4);
        let (information, _) = watch::channel(SessionInfo {
            recorded: true,
            audio: vec![audio_stream("41", "media")],
            ..Default::default()
        });
        control.information = information.subscribe();
        for request in [
            gain(6, "41", 1.0),
            gain(7, "42", 1.0),
            gain(7, "+41", 1.0),
            gain(7, "41", -0.1),
            gain(7, "41", 1.1),
            gain(7, "41", f64::NAN),
            gain(7, "41", f64::INFINITY),
        ] {
            assert!(control.request(request).await.is_err());
            assert!(commands.try_recv().is_err());
            assert!(!*control.disconnect.borrow());
        }
        information.send_modify(|info| info.audio.clear());
        assert!(control.request(gain(7, "41", 1.0)).await.is_err());
        assert!(commands.try_recv().is_err());
        information.send_modify(|info| info.audio.push(audio_stream("41", "media")));
        control
            .request(Request::Disconnect { session: 7 })
            .await
            .unwrap();
        assert!(matches!(
            commands.recv().await,
            Some(Command::ReleaseTouches)
        ));
        assert!(control.request(gain(7, "41", 1.0)).await.is_err());
        assert!(commands.try_recv().is_err());
    }

    #[tokio::test]
    async fn rejected_media_gain_does_not_mutate_presentation_or_end_session() {
        for closed in [false, true] {
            let (mut control, mut commands) = fixture(1);
            control.information = watch::channel(SessionInfo {
                audio: vec![audio_stream("41", "media")],
                ..Default::default()
            })
            .1;
            control.commands.try_send(Command::Night(false)).unwrap();
            if closed {
                commands.close();
            }
            assert!(control.request(gain(7, "41", 1.0)).await.is_err());
            assert!(!*control.disconnect.borrow());
            let state = control.presentation.lock().await;
            assert!(!state.active && !state.visible);
            assert_eq!(state.revision, 0);
            drop(state);
            assert!(matches!(commands.recv().await, Some(Command::Night(false))));
            assert!(commands.try_recv().is_err());
            if !closed {
                control.request(gain(7, "41", 1.0)).await.unwrap();
                assert!(matches!(
                    commands.recv().await,
                    Some(Command::AudioGain {
                        connection: 41,
                        gain: 1.0
                    })
                ));
            }
        }
    }

    #[tokio::test]
    async fn portrait_crop_matches_native_metadata_and_full_display_touch_axes() {
        let (mut control, mut received) = fixture(8);
        let mut video = control.video.borrow().clone().unwrap();
        video.crop = crate::media::Crop {
            left: 50,
            top: 20,
            right: 40,
            bottom: 30,
        };
        control.video = watch::channel(Some(video)).1;
        control
            .request(Request::Activate { session: 7 })
            .await
            .unwrap();
        assert!(matches!(received.recv().await, Some(Command::Keyframe)));
        let status = control.request(Request::Status).await.unwrap();
        let params = status["video"]["native_parameters"].as_array().unwrap();
        assert_eq!(
            params[32..40],
            [0, 50, 0, 20, 0, 40, 0, 30].map(Value::from)
        );
        for (phase, x, y, expected) in [
            (Phase::Down, 0.0, 0.0, (50, 20)),
            (Phase::Up, 1.0, 1.0, (760, 450)),
        ] {
            control
                .request(Request::Touch {
                    session: 7,
                    pointer: 42,
                    phase,
                    x,
                    y,
                })
                .await
                .unwrap();
            match received.recv().await.unwrap() {
                Command::Touch { x, y, .. } => assert_eq!((x, y), expected),
                _ => panic!("expected cropped display touch"),
            }
        }
    }

    #[tokio::test]
    async fn disconnect_bypasses_full_and_closed_input_queues() {
        for closed in [false, true] {
            let (control, mut received) = fixture(1);
            control
                .request(Request::Activate { session: 7 })
                .await
                .unwrap();
            if closed {
                received.close();
            }
            control
                .request(Request::Disconnect { session: 7 })
                .await
                .unwrap();
            assert!(*control.disconnect.borrow());
            let state = control.presentation.lock().await;
            assert!(!state.active && !state.visible && state.pointers.is_empty());
            drop(state);
            assert!(
                control
                    .request(Request::Activate { session: 7 })
                    .await
                    .is_err()
            );
        }
    }

    #[tokio::test]
    async fn activation_reserves_all_commands_before_committing() {
        let (control, mut received) = fixture(2);
        // Keyframe would fit, but the accompanying audio command would not.
        let info = SessionInfo {
            audio_available: true,
            ..Default::default()
        };
        let mut control = control;
        control.information = watch::channel(info).1;
        control.commands.try_send(Command::Night(false)).unwrap();
        assert!(
            control
                .request(Request::Activate { session: 7 })
                .await
                .is_err()
        );
        let state = control.presentation.lock().await;
        assert!(!state.active && !state.visible);
        assert_eq!(state.revision, 0);
        drop(state);
        assert!(matches!(received.try_recv(), Ok(Command::Night(false))));
        assert!(received.try_recv().is_err());
        received.close();
        assert!(
            control
                .request(Request::Activate { session: 7 })
                .await
                .is_err()
        );
        assert_eq!(control.presentation.lock().await.revision, 0);
    }

    #[tokio::test]
    async fn rejected_down_does_not_allocate_a_pointer() {
        let (control, _received) = fixture(1);
        control
            .request(Request::Activate { session: 7 })
            .await
            .unwrap();
        assert!(control.request(touch(Phase::Down)).await.is_err());
        assert!(control.presentation.lock().await.pointers.is_empty());
        assert!(!*control.disconnect.borrow());
    }

    #[tokio::test]
    async fn terminal_input_failure_ends_session_instead_of_losing_release() {
        for terminal in [
            touch(Phase::Up),
            touch(Phase::Cancel),
            Request::Visibility {
                session: 7,
                visible: false,
            },
        ] {
            for closed in [false, true] {
                let (control, mut received) = fixture(1);
                control
                    .request(Request::Activate { session: 7 })
                    .await
                    .unwrap();
                received.recv().await.unwrap();
                control.request(touch(Phase::Down)).await.unwrap();
                if closed {
                    received.close();
                }
                // Build a fresh request for each queue mode.
                let request = match terminal {
                    Request::Touch {
                        phase: Phase::Up, ..
                    } => touch(Phase::Up),
                    Request::Touch { .. } => touch(Phase::Cancel),
                    _ => Request::Visibility {
                        session: 7,
                        visible: false,
                    },
                };
                assert!(control.request(request).await.is_err());
                assert!(*control.disconnect.borrow());
                let state = control.presentation.lock().await;
                assert!(!state.active && !state.visible && state.pointers.is_empty());
            }
        }
    }

    #[tokio::test]
    async fn stale_disconnect_cannot_end_current_input() {
        let (control, mut received) = fixture(2);
        control
            .request(Request::Activate { session: 7 })
            .await
            .unwrap();
        received.recv().await.unwrap();
        control.request(touch(Phase::Down)).await.unwrap();
        assert!(
            control
                .request(Request::Disconnect { session: 6 })
                .await
                .is_err()
        );
        assert!(!*control.disconnect.borrow());
        assert_eq!(control.presentation.lock().await.pointers.len(), 1);
        control
            .request(Request::Disconnect { session: 7 })
            .await
            .unwrap();
        assert!(*control.disconnect.borrow());
    }

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

    #[tokio::test]
    async fn media_controls_require_real_event_capability_and_session_but_not_video_visibility() {
        let (mut control, mut commands) = fixture(4);
        let status = control.request(Request::Status).await.unwrap();
        assert_eq!(status["media_commands"], json!([]));
        assert!(
            control
                .request(Request::Media {
                    session: 7,
                    command: MediaButton::PlayPause
                })
                .await
                .is_err()
        );
        assert!(commands.try_recv().is_err());
        let (information, _) = watch::channel(SessionInfo {
            recorded: true,
            media_commands: true,
            battery_percent: Some(61),
            external_power: Some(true),
            ..Default::default()
        });
        control.information = information.subscribe();
        assert!(
            control
                .request(Request::Media {
                    session: 6,
                    command: MediaButton::Next
                })
                .await
                .is_err()
        );
        assert!(commands.try_recv().is_err());
        let status = control.request(Request::Status).await.unwrap();
        assert_eq!(
            status["media_commands"],
            json!(["previous", "play", "pause", "playPause", "next"])
        );
        assert_eq!(status["phone"]["battery_percent"], 61);
        assert!(status["phone"].get("charging").is_none());
        // The native Media page intentionally hides the projection layer.
        assert!(!control.presentation.lock().await.visible);
        for button in [
            MediaButton::Play,
            MediaButton::Pause,
            MediaButton::PlayPause,
            MediaButton::Next,
            MediaButton::Previous,
        ] {
            control
                .request(Request::Media {
                    session: 7,
                    command: button,
                })
                .await
                .unwrap();
            assert!(matches!(commands.recv().await, Some(Command::Media(_))));
        }
        information.send_modify(|s| s.media_commands = false);
        assert!(
            control
                .request(Request::Media {
                    session: 7,
                    command: MediaButton::Pause
                })
                .await
                .is_err()
        );
        assert!(commands.try_recv().is_err());
        assert!(
            serde_json::from_value::<Request>(
                json!({"action":"media","session":7,"command":"seek"})
            )
            .is_err()
        );
    }
}
