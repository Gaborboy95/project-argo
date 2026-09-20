//! Persistent local controls, independent of the lifetime of a phone session.
use crate::{
    protocol::receiver::{AudioOptions, Display},
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
    pub audio_sink: Option<String>,
    pub audio_source: Option<String>,
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
            audio_sink: options.audio.as_ref().and_then(|a| a.sink.clone()),
            audio_source: options.audio.as_ref().and_then(|a| a.input.clone()),
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
        if self.audio_source.is_some() && self.audio_sink.is_none() {
            return Err(io::Error::other("Microphone requires audio output"));
        }
        Ok(Options {
            display,
            audio: self.audio_sink.as_ref().map(|sink| AudioOptions {
                sink: Some(sink.clone()),
                input: self.audio_source.clone(),
            }),
        })
    }
}
#[derive(Clone)]
pub struct State {
    pub settings: Settings,
    pub running: bool,
    pub generation: u64,
    pub authorize: bool,
}
pub struct Manager {
    pub state: watch::Sender<State>,
    path: PathBuf,
    mutation: Mutex<()>,
    pub phase: Mutex<String>,
}
impl Manager {
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
        let running = settings.enabled && settings.auto_connect;
        Ok(Arc::new(Self {
            state: watch::channel(State {
                settings,
                running,
                generation: 0,
                authorize: false,
            })
            .0,
            path,
            mutation: Mutex::new(()),
            phase: Mutex::new("Starting".into()),
        }))
    }
    fn persist(&self, settings: &Settings) -> io::Result<()> {
        use std::io::Write;
        let temp = self
            .path
            .with_extension(format!("{}.tmp", std::process::id()));
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&temp)?;
        let result = (|| {
            f.write_all(&serde_json::to_vec(settings)?)?;
            f.sync_all()?;
            std::fs::rename(&temp, &self.path)
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
                return Ok(
                    json!({"ok":true,"contract":1,"settings":state.settings,"running":state.running,"phase":*self.phase.lock().await,"wireless":false}),
                );
            }
            Some("configure") => {
                let patch = value
                    .get("settings")
                    .and_then(Value::as_object)
                    .ok_or_else(|| io::Error::other("Missing settings"))?;
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
                    state.running = next.enabled;
                    state.generation = state.generation.wrapping_add(1);
                }
                state.settings = next;
            }
            Some("connect") => {
                if !state.settings.enabled {
                    return Err(io::Error::other("Enable CarPlay first"));
                }
                state.running = true;
                state.authorize = true;
                state.generation = state.generation.wrapping_add(1);
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
#[cfg(test)]
mod tests {
    use super::*;
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
}
