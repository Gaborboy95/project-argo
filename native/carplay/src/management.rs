//! Persistent local controls, independent of the lifetime of a phone session.
use crate::{
    protocol::receiver::{AudioOptions, CaptureSource, Display},
    runtime_control::SessionTransport,
    wired_runtime::Options,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    io,
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    sync::{Mutex, Semaphore, watch},
    task::JoinSet,
    time::timeout,
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Settings {
    pub enabled: bool,
    pub auto_connect: bool,
    pub width: u16,
    pub height: u16,
    pub width_mm: u16,
    pub height_mm: u16,
    pub fps: u16,
    pub right_hand_drive: bool,
    #[serde(default, skip_serializing_if = "zero_insets")]
    pub view_insets: [u16; 4],
    #[serde(default, skip_serializing_if = "zero_insets")]
    pub safe_insets: [u16; 4],
    pub audio_sink: Option<String>,
    pub audio_source: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub silent_input: bool,
}
fn is_false(value: &bool) -> bool {
    !*value
}
fn zero_insets(insets: &[u16; 4]) -> bool {
    *insets == [0; 4]
}
impl Settings {
    pub fn from_options(options: &Options) -> Self {
        Self {
            enabled: true,
            auto_connect: true,
            width: options.display.width,
            height: options.display.height,
            width_mm: options.display.width_mm,
            height_mm: options.display.height_mm,
            fps: options.display.fps,
            right_hand_drive: options.display.right_hand_drive,
            view_insets: options.display.view_insets,
            safe_insets: options.display.safe_insets,
            audio_sink: options.audio.as_ref().and_then(|a| a.sink.clone()),
            audio_source: options
                .audio
                .as_ref()
                .and_then(|a| a.input.as_ref())
                .and_then(CaptureSource::device)
                .map(str::to_owned),
            silent_input: options
                .audio
                .as_ref()
                .is_some_and(|a| a.input == Some(CaptureSource::Silence)),
        }
    }
    pub fn options(&self) -> io::Result<Options> {
        let display = Display {
            width: self.width,
            height: self.height,
            width_mm: self.width_mm,
            height_mm: self.height_mm,
            fps: self.fps,
            right_hand_drive: self.right_hand_drive,
            view_insets: self.view_insets,
            safe_insets: self.safe_insets,
        };
        display.validate().map_err(io::Error::other)?;
        for (name, limit) in [(&self.audio_sink, 128), (&self.audio_source, 256)] {
            if let Some(name) = name
                && (name.is_empty()
                    || name.len() > limit
                    || !name
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)))
            {
                return Err(io::Error::other("Invalid audio device"));
            }
        }
        if (self.audio_source.is_some() || self.silent_input) && self.audio_sink.is_none() {
            return Err(io::Error::other("Microphone requires audio output"));
        }
        Ok(Options {
            display,
            audio: self.audio_sink.as_ref().map(|sink| AudioOptions {
                sink: Some(sink.clone()),
                input: self
                    .audio_source
                    .clone()
                    .map(CaptureSource::Device)
                    .or_else(|| self.silent_input.then_some(CaptureSource::Silence)),
            }),
        })
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Viewport {
    pub width: f64,
    pub height: f64,
    pub overlay_height: f64,
}
impl Viewport {
    fn validate(&self) -> io::Result<()> {
        if !self.width.is_finite()
            || !self.height.is_finite()
            || !self.overlay_height.is_finite()
            || !(1.0..=65536.0).contains(&self.width)
            || !(1.0..=65536.0).contains(&self.height)
            || !(0.0..self.height).contains(&self.overlay_height)
        {
            return Err(io::Error::other("Invalid dashboard viewport"));
        }
        Ok(())
    }
}
#[derive(Clone)]
pub struct State {
    pub settings: Settings,
    pub running: bool,
    pub generation: u64,
    pub authorize: bool,
    pub viewport: Option<Viewport>,
    pub transport: SessionTransport,
    /// Runtime device intent owned by the host's shared device coordinator.
    /// None opens pairing; a specific peer never falls back to another phone.
    pub target: Option<[u8; 6]>,
}
impl State {
    pub fn options(&self) -> io::Result<Options> {
        let mut options = self.settings.options()?;
        if let Some(v) = self.viewport {
            options.display = options
                .display
                .for_viewport(v.width, v.height, v.overlay_height);
        }
        options.display.validate().map_err(io::Error::other)?;
        Ok(options)
    }
}
pub struct Manager {
    pub state: watch::Sender<State>,
    path: PathBuf,
    transport_path: PathBuf,
    mutation: Mutex<()>,
    pub phase: Mutex<String>,
}
impl Manager {
    pub fn bind_phone(&self, generation: u64, peer: [u8; 6]) {
        self.state.send_if_modified(|state| {
            if state.running && state.generation == generation && state.target.is_none() {
                state.target = Some(peer);
                true
            } else {
                false
            }
        });
    }

    pub fn load(directory: &std::path::Path, options: &Options) -> io::Result<Arc<Self>> {
        let path = directory.join("settings.json");
        let settings = match path.symlink_metadata() {
            Ok(m) => {
                if !m.is_file()
                    || m.uid() != unsafe { libc::geteuid() }
                    || m.mode() & 0o077 != 0
                    || m.len() > 4096
                {
                    return Err(io::Error::other("Unsafe CarPlay settings"));
                }
                serde_json::from_slice::<Settings>(&std::fs::read(&path)?)?
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Settings::from_options(options),
            Err(e) => return Err(e),
        };
        settings.options()?;
        let transport_path = directory.join("connection.json");
        let transport = match transport_path.symlink_metadata() {
            Ok(m) => {
                if !m.is_file()
                    || m.uid() != unsafe { libc::geteuid() }
                    || m.mode() & 0o077 != 0
                    || m.len() > 1024
                {
                    return Err(io::Error::other("Unsafe CarPlay connection settings"));
                }
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Connection {
                    transport: SessionTransport,
                }
                serde_json::from_slice::<Connection>(&std::fs::read(&transport_path)?)?.transport
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => SessionTransport::Usb,
            Err(e) => return Err(e),
        };
        Ok(Arc::new(Self {
            state: watch::channel(State {
                settings,
                // Service availability and reconnect policy are not a request
                // to connect. Only the shared device coordinator starts a phone.
                running: false,
                generation: 0,
                authorize: false,
                viewport: None,
                transport,
                target: None,
            })
            .0,
            path,
            transport_path,
            mutation: Mutex::new(()),
            phase: Mutex::new("Disconnected".into()),
        }))
    }
    fn persist(&self, settings: &Settings) -> io::Result<()> {
        let mut legacy = serde_json::to_value(settings)?;
        // This opt-in diagnostic is runtime-only. Legacy releases reject
        // unknown settings keys, so even true must never reach settings.json.
        legacy.as_object_mut().unwrap().remove("silent_input");
        self.persist_json(&self.path, &serde_json::to_vec(&legacy)?)
    }

    fn persist_json(&self, path: &std::path::Path, bytes: &[u8]) -> io::Result<()> {
        use std::io::Write;
        let temp = path.with_extension(format!("{}.tmp", std::process::id()));
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temp)?;
        let result = (|| {
            f.write_all(bytes)?;
            f.sync_all()?;
            std::fs::rename(&temp, path)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(temp);
        }
        result
    }
    async fn request(&self, value: Value) -> io::Result<Value> {
        let _guard = self.mutation.lock().await;
        let mut state = self.state.borrow().clone();
        match value.get("action").and_then(Value::as_str) {
            Some("status") => {
                let mut settings = serde_json::to_value(&state.settings)?;
                settings["transport"] = serde_json::to_value(state.transport)?;
                settings["silent_input"] = Value::Bool(state.settings.silent_input);
                return Ok(
                    json!({"ok":true,"contract":1,"settings":settings,"running":state.running,"target":state.target.map(|address| address.iter().map(|byte|format!("{byte:02X}")).collect::<Vec<_>>().join(":" )).unwrap_or_default(),"phase":*self.phase.lock().await,"wireless":cfg!(target_os="linux"),"microphone_ownership":microphone_ownership(),"silent_input_supported":true,"viewport_supported":true,"viewport":state.viewport,"next_view_insets":state.options()?.display.view_insets,"next_safe_insets":state.options()?.display.safe_insets}),
                );
            }
            Some("viewport") => {
                let viewport: Viewport = serde_json::from_value(
                    value
                        .get("viewport")
                        .cloned()
                        .ok_or_else(|| io::Error::other("Missing dashboard viewport"))?,
                )?;
                viewport.validate()?;
                // Presentation measurements are runtime hints, never persisted
                // preferences or a reason to disconnect the active phone.
                if state.viewport == Some(viewport) {
                    return Ok(json!({"ok":true}));
                }
                state.viewport = Some(viewport);
                state.options()?;
            }
            Some("configure") => {
                let patch = value
                    .get("settings")
                    .and_then(Value::as_object)
                    .ok_or_else(|| io::Error::other("Missing settings"))?;
                if let Some(transport) = patch.get("transport") {
                    if patch.len() != 1 {
                        return Err(io::Error::other("Change the connection method separately"));
                    }
                    let transport: SessionTransport = serde_json::from_value(transport.clone())?;
                    if transport == SessionTransport::Wireless && !cfg!(target_os = "linux") {
                        return Err(io::Error::other("Wireless CarPlay requires Linux"));
                    }
                    if transport != state.transport {
                        self.persist_json(
                            &self.transport_path,
                            &serde_json::to_vec(&json!({"transport":transport}))?,
                        )?;
                        state.transport = transport;
                        // A transport preference cannot choose a different
                        // physical phone. Connect is the device owner's action.
                        state.running = false;
                        state.generation = state.generation.wrapping_add(1);
                    }
                    self.state.send_replace(state);
                    return Ok(json!({"ok":true}));
                }
                let mut merged = serde_json::to_value(&state.settings)?;
                for (key, value) in patch {
                    merged
                        .as_object_mut()
                        .unwrap()
                        .insert(key.clone(), value.clone());
                }
                let next: Settings = serde_json::from_value(merged)?;
                next.options()?;
                self.persist(&next)?;
                if next.enabled != state.settings.enabled {
                    state.running &= next.enabled;
                    state.generation = state.generation.wrapping_add(1);
                }
                state.settings = next;
            }
            Some("connect") => {
                if !state.settings.enabled {
                    return Err(io::Error::other("Enable CarPlay first"));
                }
                let target = match value.get("target") {
                    None => None,
                    Some(Value::String(target)) if target.is_empty() => None,
                    Some(Value::String(target)) => {
                        Some(crate::wifi::parse_mac(target).map_err(io::Error::other)?)
                    }
                    _ => return Err(io::Error::other("Invalid CarPlay device target")),
                };
                if target.is_some() && state.transport != SessionTransport::Wireless {
                    return Err(io::Error::other(
                        "Bluetooth device selection requires wireless CarPlay",
                    ));
                }
                if !state.running || state.target != target {
                    state.generation = state.generation.wrapping_add(1);
                }
                state.running = true;
                state.target = target;
                state.authorize = true;
            }
            Some("disconnect") => {
                state.running = false;
                state.generation = state.generation.wrapping_add(1);
            }
            _ => return Err(io::Error::other("Unknown operation")),
        }
        self.state.send_replace(state);
        Ok(json!({"ok":true}))
    }
    pub async fn serve(self: Arc<Self>, path: PathBuf) -> io::Result<()> {
        if let Ok(m) = path.symlink_metadata() {
            use std::os::unix::fs::FileTypeExt;
            if !m.file_type().is_socket() || m.uid() != unsafe { libc::geteuid() } {
                return Err(io::Error::other("Unsafe management endpoint"));
            }
            if UnixStream::connect(&path).await.is_ok() {
                return Err(io::Error::other("Management endpoint already owned"));
            }
            std::fs::remove_file(&path)?;
        }
        let listener = UnixListener::bind(&path)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        struct Remove(PathBuf);
        impl Drop for Remove {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
        let _remove = Remove(path);
        let permits = Arc::new(Semaphore::new(8));
        let mut tasks = JoinSet::new();
        loop {
            tokio::select! {
                accepted=listener.accept()=>{let (socket,_)=accepted?;let Ok(permit)=permits.clone().try_acquire_owned() else {continue;};let owner=self.clone(); tasks.spawn(async move {let _permit=permit;let _=timeout(Duration::from_secs(2),owner.handle(socket)).await;});},
                _=tasks.join_next(),if !tasks.is_empty()=>{},
            }
        }
    }
    async fn handle(&self, mut socket: UnixStream) -> io::Result<()> {
        if socket.peer_cred()?.uid() != unsafe { libc::geteuid() } {
            return Err(io::Error::other("Wrong user"));
        }
        let mut bytes = Vec::new();
        loop {
            let b = socket.read_u8().await?;
            if b == b'\n' {
                break;
            }
            if bytes.len() >= 4096 {
                return Err(io::Error::other("Request bounds"));
            }
            bytes.push(b);
        }
        let result = match serde_json::from_slice(&bytes) {
            Ok(value) => self.request(value).await,
            Err(e) => Err(e.into()),
        };
        let reply = match result {
            Ok(v) => v,
            Err(e) => json!({"ok":false,"error":e.to_string()}),
        };
        let mut bytes = serde_json::to_vec(&reply)?;
        bytes.push(b'\n');
        socket.write_all(&bytes).await
    }
}

fn microphone_ownership() -> &'static str {
    #[cfg(feature = "linux-audio")]
    {
        argo_audio_ownership::state()
    }
    #[cfg(not(feature = "linux-audio"))]
    {
        "unavailable"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn silent_input_never_enters_legacy_settings_and_resets_after_restart() {
        let path = std::env::temp_dir().join(format!(
            "argo-management-silent-input-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&path).unwrap();
        let options =
            crate::wired_runtime::parse_options(&["1280", "720", "200", "112"].map(String::from))
                .unwrap();
        let manager = Manager::load(&path, &options).unwrap();
        manager
            .request(json!({"action":"configure","settings":{
                "audio_sink":"chosen.output", "silent_input":true
            }}))
            .await
            .unwrap();
        assert!(manager.state.borrow().settings.silent_input);
        assert_eq!(
            manager.request(json!({"action":"status"})).await.unwrap()["settings"]["silent_input"],
            true
        );
        manager
            .request(json!({"action":"configure","settings":{"fps":60}}))
            .await
            .unwrap();
        assert!(manager.state.borrow().settings.silent_input);
        let persisted: Value =
            serde_json::from_slice(&std::fs::read(path.join("settings.json")).unwrap()).unwrap();
        assert!(persisted.get("silent_input").is_none());
        // The on-disk contract contains only the original legacy keys.
        let legacy_keys = [
            "enabled",
            "auto_connect",
            "width",
            "height",
            "width_mm",
            "height_mm",
            "fps",
            "right_hand_drive",
            "audio_sink",
            "audio_source",
        ];
        assert!(
            persisted
                .as_object()
                .unwrap()
                .keys()
                .all(|key| legacy_keys.contains(&key.as_str()))
        );
        let reloaded = Manager::load(&path, &options).unwrap();
        assert!(!reloaded.state.borrow().settings.silent_input);
        assert!(
            reloaded
                .state
                .borrow()
                .options()
                .unwrap()
                .audio
                .unwrap()
                .input
                .is_none()
        );
        std::fs::remove_dir_all(path).unwrap();
    }

    #[test]
    fn silent_input_is_explicit_default_off_and_never_replaces_a_device() {
        let options =
            crate::wired_runtime::parse_options(&["1280", "720", "200", "112"].map(String::from))
                .unwrap();
        let mut settings = Settings::from_options(&options);
        assert!(!settings.silent_input);
        let legacy = serde_json::to_value(&settings).unwrap();
        assert!(legacy.get("silent_input").is_none());
        assert!(
            !serde_json::from_value::<Settings>(legacy.clone())
                .unwrap()
                .silent_input
        );
        for value in [json!("true"), json!(1), Value::Null] {
            let mut malformed = legacy.clone();
            malformed["silent_input"] = value;
            assert!(serde_json::from_value::<Settings>(malformed).is_err());
        }
        settings.silent_input = true;
        assert!(
            settings.options().is_err(),
            "silent input requires an output"
        );
        settings.audio_sink = Some("chosen.output".into());
        assert_eq!(
            settings.options().unwrap().audio.unwrap().input,
            Some(CaptureSource::Silence)
        );
        settings.audio_source = Some("chosen.microphone".into());
        assert_eq!(
            settings.options().unwrap().audio.unwrap().input,
            Some(CaptureSource::Device("chosen.microphone".into()))
        );
        settings.audio_source = Some("invalid microphone".into());
        assert!(
            settings.options().is_err(),
            "invalid devices cannot fall back to silence"
        );
        settings.audio_source = None;
        settings.silent_input = false;
        assert!(settings.options().unwrap().audio.unwrap().input.is_none());
    }

    #[tokio::test]
    async fn connection_method_survives_restart_without_breaking_legacy_preferences() {
        let path =
            std::env::temp_dir().join(format!("argo-management-transport-{}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        let options =
            crate::wired_runtime::parse_options(&["1280", "720", "200", "112"].map(String::from))
                .unwrap();
        let manager = Manager::load(&path, &options).unwrap();
        manager
            .request(json!({"action":"configure","settings":{"fps":60}}))
            .await
            .unwrap();
        let legacy = std::fs::read(path.join("settings.json")).unwrap();
        manager
            .request(json!({"action":"configure","settings":{"transport":"wireless"}}))
            .await
            .unwrap();
        assert_eq!(manager.state.borrow().transport, SessionTransport::Wireless);
        assert_eq!(manager.state.borrow().generation, 1);
        assert_eq!(std::fs::read(path.join("settings.json")).unwrap(), legacy);
        serde_json::from_slice::<Settings>(&legacy)
            .unwrap()
            .options()
            .unwrap();
        let reloaded = Manager::load(&path, &options).unwrap();
        assert_eq!(
            reloaded.state.borrow().transport,
            SessionTransport::Wireless
        );
        let status = reloaded.request(json!({"action":"status"})).await.unwrap();
        assert_eq!(status["settings"]["transport"], "wireless");
        assert!(status["wireless"].as_bool().unwrap());
        assert!(
            reloaded
                .request(json!({"action":"configure","settings":{"transport":"bad"}}))
                .await
                .is_err()
        );
        assert_eq!(
            reloaded.state.borrow().transport,
            SessionTransport::Wireless
        );
        reloaded
            .request(json!({"action":"configure","settings":{"transport":"usb"}}))
            .await
            .unwrap();
        assert_eq!(
            Manager::load(&path, &options)
                .unwrap()
                .state
                .borrow()
                .transport,
            SessionTransport::Usb
        );
        std::fs::remove_dir_all(path).unwrap();
    }
    #[tokio::test]
    async fn viewport_is_runtime_only_and_never_restarts_an_active_session() {
        let path =
            std::env::temp_dir().join(format!("argo-management-viewport-{}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        let options =
            crate::wired_runtime::parse_options(&["1280", "720", "200", "112"].map(String::from))
                .unwrap();
        let manager = Manager::load(&path, &options).unwrap();
        manager.request(json!({"action":"connect"})).await.unwrap();
        manager
            .request(json!({"action":"configure","settings":{"fps":60}}))
            .await
            .unwrap();
        let persisted = std::fs::read(path.join("settings.json")).unwrap();
        let saved: Value = serde_json::from_slice(&persisted).unwrap();
        // Runtime fitting must not make legacy releases reject default settings
        // after rollback: new manual-margin keys are written only if nonzero.
        assert!(saved.get("view_insets").is_none());
        assert!(saved.get("safe_insets").is_none());
        manager.request(json!({"action":"viewport","viewport":{"width":600,"height":680,"overlay_height":64}})).await.unwrap();
        let state = manager.state.borrow().clone();
        assert!(state.running);
        assert_eq!(state.generation, 1);
        assert_eq!(state.settings.view_insets, [0; 4]);
        assert_eq!(
            state.options().unwrap().display.view_insets,
            [323, 0, 323, 0]
        );
        assert_eq!(state.options().unwrap().display.safe_insets, [0, 0, 0, 68]);
        assert_eq!(
            std::fs::read(path.join("settings.json")).unwrap(),
            persisted
        );
        for viewport in [
            json!({"width":0,"height":680,"overlay_height":64}),
            json!({"width":600,"height":680,"overlay_height":680}),
            json!({"width":600,"height":680,"overlay_height":-1}),
            json!({"width":1e100,"height":680,"overlay_height":64}),
        ] {
            assert!(
                manager
                    .request(json!({"action":"viewport","viewport":viewport}))
                    .await
                    .is_err()
            );
        }
        assert_eq!(manager.state.borrow().viewport, state.viewport);
        // Older settings files (before View/Safe Area fields) remain valid.
        let mut old = serde_json::to_value(state.settings).unwrap();
        old.as_object_mut().unwrap().remove("view_insets");
        old.as_object_mut().unwrap().remove("safe_insets");
        let old: Settings = serde_json::from_value(old).unwrap();
        old.options().unwrap();
        assert_eq!(old.view_insets, [0; 4]);
        assert_eq!(old.safe_insets, [0; 4]);
        std::fs::remove_dir_all(path).unwrap();
    }

    #[tokio::test]
    async fn settings_survive_restart_and_disconnect_requires_explicit_connect() {
        let path = std::env::temp_dir().join(format!("argo-management-{}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        let options =
            crate::wired_runtime::parse_options(&["1280", "720", "200", "112"].map(String::from))
                .unwrap();
        let manager = Manager::load(&path, &options).unwrap();
        assert!(
            manager
                .request(json!({"action":"configure","settings":{"width":0}}))
                .await
                .is_err()
        );
        assert!(
            manager
                .request(json!({"action":"configure","settings":{"shell":"anything"}}))
                .await
                .is_err()
        );
        manager.request(json!({"action":"configure","settings":{"right_hand_drive":true,"auto_connect":false}})).await.unwrap();
        manager
            .request(json!({"action":"disconnect"}))
            .await
            .unwrap();
        assert!(!manager.state.borrow().running);
        manager.request(json!({"action":"connect"})).await.unwrap();
        assert!(manager.state.borrow().running);
        let reloaded = Manager::load(&path, &options).unwrap();
        assert!(!reloaded.state.borrow().running);
        assert!(reloaded.state.borrow().settings.right_hand_drive);
        std::fs::remove_dir_all(path).unwrap();
    }

    #[tokio::test]
    async fn service_restart_and_enabling_never_create_a_phone_connection_request() {
        let path =
            std::env::temp_dir().join(format!("argo-management-passive-{}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        let options =
            crate::wired_runtime::parse_options(&["1280", "720", "200", "112"].map(String::from))
                .unwrap();
        let manager = Manager::load(&path, &options).unwrap();
        assert!(manager.state.borrow().settings.auto_connect);
        assert!(!manager.state.borrow().running);
        assert_eq!(
            manager.request(json!({"action":"status"})).await.unwrap()["phase"],
            "Disconnected"
        );
        manager
            .request(json!({"action":"configure","settings":{"enabled":false}}))
            .await
            .unwrap();
        manager
            .request(json!({"action":"configure","settings":{"enabled":true,"auto_connect":true}}))
            .await
            .unwrap();
        assert!(!manager.state.borrow().running);
        manager.request(json!({"action":"connect"})).await.unwrap();
        assert!(manager.state.borrow().running);
        let reloaded = Manager::load(&path, &options).unwrap();
        assert!(reloaded.state.borrow().settings.enabled);
        assert!(reloaded.state.borrow().settings.auto_connect);
        assert!(!reloaded.state.borrow().running);
        manager
            .request(json!({"action":"configure","settings":{"enabled":false}}))
            .await
            .unwrap();
        assert!(!manager.state.borrow().running);
        std::fs::remove_dir_all(path).unwrap();
    }

    #[tokio::test]
    async fn selected_bluetooth_phone_is_runtime_only_and_connect_is_idempotent() {
        let path =
            std::env::temp_dir().join(format!("argo-management-target-{}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        let options =
            crate::wired_runtime::parse_options(&["1280", "720", "200", "112"].map(String::from))
                .unwrap();
        let manager = Manager::load(&path, &options).unwrap();
        let request = json!({"action":"connect","target":"02:ab:cd:00:00:01"});
        assert!(manager.request(request.clone()).await.is_err());
        assert!(!manager.state.borrow().running);
        manager
            .request(json!({"action":"configure","settings":{"transport":"wireless"}}))
            .await
            .unwrap();
        let persisted = std::fs::read(path.join("connection.json")).unwrap();
        manager.request(request.clone()).await.unwrap();
        assert_eq!(manager.state.borrow().target, Some([2, 171, 205, 0, 0, 1]));
        let generation = manager.state.borrow().generation;
        assert_eq!(
            manager.request(json!({"action":"status"})).await.unwrap()["target"],
            "02:AB:CD:00:00:01"
        );
        manager.request(request).await.unwrap();
        assert_eq!(manager.state.borrow().generation, generation);
        for invalid in [
            json!("not-a-phone"),
            json!("hci0/02:AB:CD:00:00:01"),
            json!("00:00:00:00:00:00"),
            json!("FF:FF:FF:FF:FF:FF"),
            json!(42),
            Value::Null,
        ] {
            assert!(
                manager
                    .request(json!({"action":"connect","target":invalid}))
                    .await
                    .is_err()
            );
            assert_eq!(manager.state.borrow().generation, generation);
            assert_eq!(manager.state.borrow().target, Some([2, 171, 205, 0, 0, 1]));
        }
        manager
            .request(json!({"action":"connect","target":"02:AB:CD:00:00:02"}))
            .await
            .unwrap();
        assert_eq!(manager.state.borrow().generation, generation + 1);
        assert_eq!(
            std::fs::read(path.join("connection.json")).unwrap(),
            persisted
        );
        let reloaded = Manager::load(&path, &options).unwrap();
        assert!(!reloaded.state.borrow().running);
        assert_eq!(reloaded.state.borrow().target, None);
        manager
            .request(json!({"action":"disconnect"}))
            .await
            .unwrap();
        manager
            .request(json!({"action":"connect","target":""}))
            .await
            .unwrap();
        assert_eq!(manager.state.borrow().target, None);
        assert!(manager.state.borrow().running);
        let pairing_generation = manager.state.borrow().generation;
        manager.bind_phone(pairing_generation, [2, 0, 0, 0, 0, 3]);
        assert_eq!(manager.state.borrow().target, Some([2, 0, 0, 0, 0, 3]));
        assert_eq!(manager.state.borrow().generation, pairing_generation);
        manager.bind_phone(pairing_generation, [2, 0, 0, 0, 0, 4]);
        assert_eq!(manager.state.borrow().target, Some([2, 0, 0, 0, 0, 3]));
        manager
            .request(json!({"action":"disconnect"}))
            .await
            .unwrap();
        manager.request(json!({"action":"connect"})).await.unwrap();
        manager.bind_phone(pairing_generation, [2, 0, 0, 0, 0, 5]);
        assert_eq!(manager.state.borrow().target, None);
        let next_generation = manager.state.borrow().generation;
        manager.bind_phone(next_generation, [2, 0, 0, 0, 0, 6]);
        assert_eq!(manager.state.borrow().target, Some([2, 0, 0, 0, 0, 6]));
        manager
            .request(json!({"action":"configure","settings":{"transport":"usb"}}))
            .await
            .unwrap();
        assert!(!manager.state.borrow().running);
        std::fs::remove_dir_all(path).unwrap();
    }
}
