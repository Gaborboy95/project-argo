//! One transport-independent owner for a CarPlay AirPlay/media/control session.
//! USB and wireless preparation must claim this owner before acquiring resources.
use crate::{
    link::LinkClient,
    protocol::{
        pairing::{Identity, Peers},
        receiver::{AudioOptions, DeviceIdentity, Display, Receiver, Video},
        wired,
    },
    runtime_control::{Control, SessionTransport},
};
use std::{
    borrow::Borrow,
    future::Future,
    net::SocketAddr,
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream, UnixListener},
    sync::{Mutex, mpsc, watch},
    task::JoinSet,
};

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// Transport ownership ended, rather than an individual phone session.
#[derive(Debug)]
pub struct TransportEnded(pub String);
impl std::fmt::Display for TransportEnded {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}
impl std::error::Error for TransportEnded {}

#[derive(Clone)]
pub struct Options {
    pub display: Display,
    pub audio: Option<AudioOptions>,
}

/// Runtime progress has no phone identity or credential payloads.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Progress {
    PreparingNetwork,
    PreparingController,
    WaitingPhone,
    Connecting,
    Authenticating,
    AwaitingPermission,
    ConnectingAirPlay,
    Connected,
    Retrying,
    Disconnecting,
}
impl Progress {
    pub fn label(self) -> &'static str {
        match self {
            Self::PreparingNetwork => "Preparing LIVI Link access point",
            Self::PreparingController => "Preparing wireless Bluetooth controller",
            Self::WaitingPhone => "Waiting for iPhone",
            Self::Connecting => "Connecting to iPhone",
            Self::Authenticating => "Authenticating iPhone",
            Self::AwaitingPermission => "Waiting for Use CarPlay approval on iPhone",
            Self::ConnectingAirPlay => "Connecting CarPlay video",
            Self::Connected => "Connected",
            Self::Retrying => "Retrying wireless CarPlay",
            Self::Disconnecting => "Disconnecting",
        }
    }

    fn from_control(state: wired::State) -> Self {
        match state {
            wired::State::Synchronizing | wired::State::Identifying => Self::Connecting,
            wired::State::Authenticating
            | wired::State::ReadingCertificate
            | wired::State::SigningChallenge
            | wired::State::WaitingForAuthenticationResult => Self::Authenticating,
            wired::State::WaitingForAvailability => Self::AwaitingPermission,
            wired::State::StartSessionSent => Self::ConnectingAirPlay,
            wired::State::Closed => Self::Disconnecting,
        }
    }
}

pub async fn stopped(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|value| *value).await;
}

/// The lock spans transport preparation, the complete session, and cleanup.
#[derive(Clone)]
pub struct Owner {
    directory: PathBuf,
    _lock: Arc<std::fs::File>,
}
impl Owner {
    pub async fn claim() -> Result<Self> {
        let root = PathBuf::from(
            std::env::var_os("XDG_RUNTIME_DIR").ok_or("XDG_RUNTIME_DIR is required")?,
        );
        if !root.is_absolute() {
            return Err("Runtime directory must be absolute".into());
        }
        let directory = root.join("argo");
        let lock = claim_runtime(&directory).await?;
        Ok(Self {
            directory,
            _lock: Arc::new(lock),
        })
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    pub async fn bind(&self, address: SocketAddr, pairing_directory: PathBuf) -> Result<Session> {
        self.listen(address, pairing_directory).await?.session()
    }

    /// Keep a stable AirPlay address/identity across consecutive phone sessions.
    pub async fn listen(
        &self,
        address: SocketAddr,
        pairing_directory: PathBuf,
    ) -> Result<Endpoint> {
        if !pairing_directory.is_absolute() {
            return Err("Pairing directory must be absolute".into());
        }
        let identity = Arc::new(Identity::load_or_create(&pairing_directory)?);
        let peers = Arc::new(Mutex::new(Peers::load(&pairing_directory)?));
        let listener = Arc::new(TcpListener::bind(address).await?);
        Ok(Endpoint {
            listener,
            identity,
            device_identity: DeviceIdentity::Pairing,
            peers,
            pairing_directory,
            owner: self.clone(),
        })
    }
}

/// Transport-owned listener and pairing state. Native IPC and session IDs are
/// created per phone; keeping this endpoint never keeps an old phone's tasks.
#[derive(Clone)]
pub struct Endpoint {
    listener: Arc<TcpListener>,
    identity: Arc<Identity>,
    device_identity: DeviceIdentity,
    peers: Arc<Mutex<Peers>>,
    pairing_directory: PathBuf,
    owner: Owner,
}
impl Endpoint {
    pub fn address(&self) -> std::io::Result<SocketAddr> {
        self.listener.local_addr()
    }
    pub fn identity_identifier(&self) -> &str {
        &self.identity.identifier
    }
    pub fn with_bluetooth_address(mut self, address: [u8; 6]) -> Result<Self> {
        let device_identity = DeviceIdentity::Bluetooth(address);
        device_identity.identifier(&self.identity)?;
        self.device_identity = device_identity;
        Ok(self)
    }
    pub fn accessory_identifier(&self) -> Result<String> {
        Ok(self.device_identity.identifier(&self.identity)?)
    }
    pub fn public_key(&self) -> Result<[u8; 32]> {
        self.identity
            .public_key()?
            .try_into()
            .map_err(|_| "Invalid CarPlay public key length".into())
    }

    /// Previous/idle TCP connections must not become the next RFCOMM phone's
    /// receiver. The caller drains before sending that phone's StartSession.
    pub async fn discard_idle_connections(&self) -> std::io::Result<usize> {
        for discarded in 0..128 {
            // Give the reactor a turn: an already queued OS connection may not
            // yet have Tokio readiness when the RFCOMM callback first runs.
            match tokio::time::timeout(Duration::from_millis(1), self.listener.accept()).await {
                Ok(Ok((socket, _))) => drop(socket),
                Ok(Err(error)) => return Err(error),
                Err(_) => return Ok(discarded),
            }
        }
        Err(std::io::Error::other("Too many idle AirPlay connections"))
    }

    pub fn session(&self) -> Result<Session> {
        let video_path = self.owner.directory.join("carplay-video.sock");
        let media_listener = UnixListener::bind(&video_path)?;
        let video_path = SocketFile(video_path);
        std::fs::set_permissions(&video_path.0, std::fs::Permissions::from_mode(0o600))?;
        let control_path = self.owner.directory.join("carplay-control.sock");
        let control_listener = UnixListener::bind(&control_path)?;
        let control_path = SocketFile(control_path);
        std::fs::set_permissions(&control_path.0, std::fs::Permissions::from_mode(0o600))?;
        let mut session_bytes = [0; 8];
        openssl::rand::rand_bytes(&mut session_bytes)?;
        let session = (u64::from_be_bytes(session_bytes) & ((1u64 << 53) - 1)).max(1);
        Ok(Session {
            media_listener,
            control_listener,
            session,
            progress: None,
            _paths: [video_path, control_path],
            endpoint: self.clone(),
        })
    }
}

struct SocketFile(PathBuf);
impl Drop for SocketFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

pub struct Session {
    media_listener: UnixListener,
    control_listener: UnixListener,
    session: u64,
    progress: Option<watch::Sender<Progress>>,
    // Drop endpoints before releasing the lock, including pre-session failures.
    _paths: [SocketFile; 2],
    endpoint: Endpoint,
}
impl Session {
    pub fn with_progress(mut self, progress: watch::Sender<Progress>) -> Self {
        self.progress = Some(progress);
        self
    }
    pub fn address(&self) -> std::io::Result<SocketAddr> {
        self.endpoint.address()
    }
    pub fn identity_identifier(&self) -> &str {
        self.endpoint.identity_identifier()
    }
    pub fn with_bluetooth_address(mut self, address: [u8; 6]) -> Result<Self> {
        self.endpoint = self.endpoint.with_bluetooth_address(address)?;
        Ok(self)
    }
    pub fn accessory_identifier(&self) -> Result<String> {
        self.endpoint.accessory_identifier()
    }
    pub fn public_key(&self) -> Result<[u8; 32]> {
        self.endpoint.public_key()
    }

    /// The callback is read once, only after an actual AirPlay connection. The
    /// transport completion future is not spawned and may borrow an owned USB
    /// bridge/controller; it is released before the caller restores that lease.
    #[allow(clippy::too_many_arguments)]
    pub async fn run_with_options<F, C, CFut, L>(
        self,
        options: F,
        link: LinkClient,
        device_id: String,
        transport: SessionTransport,
        stop: watch::Receiver<bool>,
        control: C,
        transport_ended: L,
    ) -> Result<bool>
    where
        F: Fn() -> std::io::Result<Options> + Send + 'static,
        C: FnOnce(watch::Receiver<bool>, watch::Sender<wired::State>) -> CFut + Send,
        CFut: Future<Output = std::result::Result<(), String>> + Send + 'static,
        L: Future<Output = String>,
    {
        self.run_with_metadata(
            options,
            link,
            device_id,
            transport,
            stop,
            move |cancel, state, _| control(cancel, state),
            transport_ended,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn run_with_metadata<F, C, CFut, L>(
        self,
        options: F,
        link: LinkClient,
        device_id: String,
        transport: SessionTransport,
        mut stop: watch::Receiver<bool>,
        control: C,
        transport_ended: L,
    ) -> Result<bool>
    where
        F: Fn() -> std::io::Result<Options> + Send + 'static,
        C: FnOnce(
                watch::Receiver<bool>,
                watch::Sender<wired::State>,
                watch::Sender<crate::protocol::now_playing::Metadata>,
            ) -> CFut
            + Send,
        CFut: Future<Output = std::result::Result<(), String>> + Send + 'static,
        L: Future<Output = String>,
    {
        if *stop.borrow() {
            return Ok(false);
        }
        let session = self.session;
        let (cancel, cancel_rx) = watch::channel(false);
        let (state, mut state_rx) = watch::channel(wired::State::Synchronizing);
        let control_state = state_rx.clone();
        let (video, mut video_rx) = watch::channel::<Option<Video>>(None);
        let (commands, commands_rx) = mpsc::channel(32);
        let (information, info_rx) = watch::channel(Default::default());
        let (metadata, mut metadata_rx) =
            watch::channel(crate::protocol::now_playing::Metadata::default());
        let mut tasks = JoinSet::new();
        tasks.spawn(control(cancel_rx, state, metadata));
        let metadata_information = information.clone();
        tasks.spawn(async move {
            while metadata_rx.changed().await.is_ok() {
                let metadata = metadata_rx.borrow_and_update().clone();
                metadata_information.send_modify(
                    |info: &mut crate::protocol::receiver::SessionInfo| {
                        info.media = metadata.media.clone();
                        info.battery_percent = metadata.battery_percent;
                        info.external_power = metadata.external_power;
                    },
                );
            }
            std::future::pending::<std::result::Result<(), String>>().await
        });
        let progress = self.progress;
        let mut video_progress = video_rx.clone();
        tasks.spawn(async move {
            let mut connected = false;
            let mut control_open = true;
            let mut video_open = true;
            loop {
                tokio::select! {
                    changed = state_rx.changed(), if control_open => {
                        if changed.is_err() { control_open = false; continue; }
                        let state = *state_rx.borrow_and_update();
                        eprintln!("CarPlay control state: {state:?}");
                        if (!connected || state == wired::State::Closed)
                            && let Some(progress) = &progress
                        {
                            progress.send_replace(Progress::from_control(state));
                        }
                    },
                    changed = video_progress.changed(), if !connected && video_open => {
                        if changed.is_err() { video_open = false; continue; }
                        if video_progress.borrow_and_update().is_some() {
                            connected = true;
                            if let Some(progress) = &progress { progress.send_replace(Progress::Connected); }
                        }
                    },
                    else => std::future::pending::<()>().await,
                }
            }
        });
        let identity = self.endpoint.identity.clone();
        let device_identity = self.endpoint.device_identity;
        let peers = self.endpoint.peers.clone();
        let pairing_directory = self.endpoint.pairing_directory.clone();
        let listener = self.endpoint.listener.clone();
        tasks.spawn(async move {
            let (socket, Options { display, audio }) =
                accept_transport_options(listener, options, transport)
                    .await
                    .map_err(|e| e.to_string())?;
            let receiver = Receiver {
                information,
                pairing_directory: Some(pairing_directory),
                audio,
                display,
                identity,
                device_identity,
                peers,
                link,
            };
            receiver
                .run(socket, session, video, commands_rx)
                .await
                .map_err(|e| e.to_string())
        });
        let control_listener = self.control_listener;
        let control = Arc::new(Control::new_with_transport(
            session,
            device_id,
            video_rx.clone(),
            info_rx,
            control_state,
            commands,
            cancel.clone(),
            transport,
        ));
        tasks.spawn(async move {
            control
                .serve(control_listener)
                .await
                .map_err(|e| e.to_string())
        });
        let media_listener = self.media_listener;
        tasks.spawn(async move {
            loop {
                let (socket, _) = media_listener.accept().await.map_err(|e| e.to_string())?;
                let video = video_rx
                    .wait_for(|v| v.is_some())
                    .await
                    .map_err(|e| e.to_string())?
                    .clone()
                    .unwrap();
                eprintln!(
                    "Serving negotiated CarPlay video {}x{}",
                    video.description.width, video.description.height
                );
                if let Err(error) = video.stream.send_to(socket).await {
                    eprintln!("Native video consumer disconnected: {error}");
                }
            }
        });
        let result: Result<()> = tokio::select! {
            _ = stopped(&mut stop) => Ok(()),
            ended = transport_ended => Err(TransportEnded(ended).into()),
            result = tasks.join_next() => match result {
                Some(Ok(result)) => result.map_err(Into::into),
                Some(Err(error)) => Err(error.to_string().into()),
                None => Err("CarPlay session ended".into()),
            },
        };
        let user_disconnected = *cancel.borrow();
        cancel.send_replace(true);
        tasks.abort_all();
        while tasks.join_next().await.is_some() {}
        if user_disconnected {
            Ok(true)
        } else {
            result.map(|_| false)
        }
    }
}

#[cfg(test)]
pub(crate) async fn accept_options(
    listener: impl Borrow<TcpListener>,
    options: impl FnOnce() -> std::io::Result<Options>,
) -> std::io::Result<(TcpStream, Options)> {
    accept_transport_options(listener, options, SessionTransport::Usb).await
}

async fn accept_transport_options(
    listener: impl Borrow<TcpListener>,
    options: impl FnOnce() -> std::io::Result<Options>,
    transport: SessionTransport,
) -> std::io::Result<(TcpStream, Options)> {
    let budget = match transport {
        SessionTransport::Usb => Duration::from_secs(40),
        SessionTransport::Wireless => Duration::from_secs(120),
    };
    let (socket, _) = tokio::time::timeout(budget, listener.borrow().accept())
        .await
        .map_err(|_| {
            std::io::Error::new(std::io::ErrorKind::TimedOut, "AirPlay connection timeout")
        })??;
    Ok((socket, options()?))
}

/// Persistent Argo pairing storage shared by wired and wireless transports.
pub fn pairing_directory() -> Result<PathBuf> {
    let base = match std::env::var_os("XDG_STATE_HOME") {
        Some(path) => PathBuf::from(path),
        None => {
            PathBuf::from(std::env::var_os("HOME").ok_or("HOME is required")?).join(".local/state")
        }
    };
    if !base.is_absolute() {
        return Err("State directory must be absolute".into());
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&base)?;
    let directory = base.join("argo-carplay");
    Identity::load_or_create(&directory)?;
    Ok(directory)
}

pub(crate) async fn claim_runtime(directory: &Path) -> Result<std::fs::File> {
    use std::os::{
        fd::AsRawFd,
        unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt},
    };
    match std::fs::DirBuilder::new().mode(0o700).create(directory) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.into()),
    }
    let metadata = std::fs::symlink_metadata(directory)?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err("Unsafe runtime directory".into());
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(directory.join("carplay-session.lock"))?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("CarPlay receiver already running".into());
    }
    for name in ["carplay-control.sock", "carplay-video.sock"] {
        let path = directory.join(name);
        match std::fs::symlink_metadata(&path) {
            Ok(m) if m.file_type().is_socket() => {
                match tokio::time::timeout(
                    Duration::from_millis(300),
                    tokio::net::UnixStream::connect(&path),
                )
                .await
                {
                    Ok(Err(e)) if e.kind() == std::io::ErrorKind::ConnectionRefused => {}
                    _ => return Err("Live receiver already owns the endpoint".into()),
                }
                std::fs::remove_file(path)?;
            }
            Ok(_) => return Err("Runtime endpoint is not a socket".into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
    }
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    struct Fixture(PathBuf);
    impl Fixture {
        async fn owner() -> (Self, Owner) {
            let root = std::env::temp_dir().join(format!(
                "argo-shared-session-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::DirBuilder::new()
                .mode(0o700)
                .create(&root)
                .unwrap();
            let directory = root.join("runtime");
            let lock = claim_runtime(&directory).await.unwrap();
            (
                Self(root),
                Owner {
                    directory,
                    _lock: Arc::new(lock),
                },
            )
        }
        fn pairing(&self) -> PathBuf {
            self.0.join("pairing")
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    struct Released(Arc<AtomicBool>);
    impl Drop for Released {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }
    fn options() -> Options {
        Options {
            display: Display {
                width: 1280,
                height: 720,
                width_mm: 200,
                height_mm: 112,
                fps: 30,
                right_hand_drive: false,
                view_insets: [0; 4],
                safe_insets: [0; 4],
            },
            audio: None,
        }
    }

    #[tokio::test]
    async fn endpoints_drop_before_transport_owner_can_be_replaced() {
        let (fixture, owner) = Fixture::owner().await;
        let session = owner
            .bind("127.0.0.1:0".parse().unwrap(), fixture.pairing())
            .await
            .unwrap();
        assert!(owner.directory().join("carplay-video.sock").exists());
        assert!(claim_runtime(owner.directory()).await.is_err());
        drop(session);
        assert!(!owner.directory().join("carplay-video.sock").exists());
        assert!(!owner.directory().join("carplay-control.sock").exists());
        // The caller still owns transport restoration after the session ends.
        assert!(claim_runtime(owner.directory()).await.is_err());
        let directory = owner.directory().to_owned();
        drop(owner);
        assert!(claim_runtime(&directory).await.is_ok());
    }

    #[tokio::test]
    async fn partial_endpoint_bind_failure_releases_only_its_own_socket() {
        let (fixture, owner) = Fixture::owner().await;
        let path = owner.directory().join("carplay-control.sock");
        std::fs::write(&path, b"retain").unwrap();
        assert!(
            owner
                .bind("127.0.0.1:0".parse().unwrap(), fixture.pairing())
                .await
                .is_err()
        );
        assert!(!owner.directory().join("carplay-video.sock").exists());
        assert_eq!(std::fs::read(path).unwrap(), b"retain");
        assert!(claim_runtime(owner.directory()).await.is_err());
    }

    #[tokio::test]
    async fn stop_and_transport_loss_join_control_without_freezing_options() {
        for transport_loss in [false, true] {
            let (fixture, owner) = Fixture::owner().await;
            let session = owner
                .bind("127.0.0.1:0".parse().unwrap(), fixture.pairing())
                .await
                .unwrap();
            let (stop, stopping) = watch::channel(false);
            let (lost, loss) = tokio::sync::oneshot::channel();
            let (started, starting) = tokio::sync::oneshot::channel();
            let released = Arc::new(AtomicBool::new(false));
            let release = released.clone();
            let calls = Arc::new(AtomicUsize::new(0));
            let requested = calls.clone();
            let running = tokio::spawn(session.run_with_options(
                move || {
                    requested.fetch_add(1, Ordering::SeqCst);
                    Ok(options())
                },
                LinkClient::new(Default::default()).unwrap(),
                "synthetic".into(),
                SessionTransport::Wireless,
                stopping,
                move |_, state| async move {
                    let _state = state;
                    let _release = Released(release);
                    let _ = started.send(());
                    std::future::pending::<std::result::Result<(), String>>().await
                },
                async move {
                    let _ = loss.await;
                    "synthetic transport lost".into()
                },
            ));
            starting.await.unwrap();
            if transport_loss {
                lost.send(()).unwrap();
            } else {
                stop.send_replace(true);
            }
            let result = tokio::time::timeout(Duration::from_secs(1), running)
                .await
                .unwrap()
                .unwrap();
            if transport_loss {
                assert!(
                    result
                        .unwrap_err()
                        .downcast_ref::<TransportEnded>()
                        .is_some()
                );
            } else {
                assert!(!result.unwrap());
            }
            assert!(released.load(Ordering::SeqCst));
            assert_eq!(calls.load(Ordering::SeqCst), 0);
            assert!(!owner.directory().join("carplay-control.sock").exists());
            assert!(!owner.directory().join("carplay-video.sock").exists());
            assert!(claim_runtime(owner.directory()).await.is_err());
        }
    }

    #[tokio::test]
    async fn retained_endpoint_serves_fresh_sessions_options_and_discards_old_backlog() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (fixture, owner) = Fixture::owner().await;
        let endpoint = owner
            .listen("127.0.0.1:0".parse().unwrap(), fixture.pairing())
            .await
            .unwrap()
            .with_bluetooth_address([2, 0, 0, 0, 0, 7])
            .unwrap();
        let address = endpoint.address().unwrap();
        let identity = endpoint.identity_identifier().to_owned();
        let key = endpoint.public_key().unwrap();
        let mut portrait = options();
        portrait.display = portrait.display.for_viewport(600.0, 680.0, 96.0);
        let (settings, selected) = watch::channel(options());
        let (frozen, observed) = watch::channel(None::<Options>);
        let calls = Arc::new(AtomicUsize::new(0));
        let mut previous_id = 0;
        for index in 0..2 {
            if index != 0 {
                let mut old_phone = TcpStream::connect(address).await.unwrap();
                assert_eq!(endpoint.discard_idle_connections().await.unwrap(), 1);
                assert_eq!(old_phone.read(&mut [0; 1]).await.unwrap(), 0);
                settings.send_replace(portrait.clone());
            }
            let session = endpoint.session().unwrap();
            assert_ne!(session.session, previous_id);
            previous_id = session.session;
            assert_eq!(session.address().unwrap(), address);
            assert_eq!(session.identity_identifier(), identity);
            assert_eq!(session.public_key().unwrap(), key);
            assert_eq!(session.accessory_identifier().unwrap(), "02:00:00:00:00:07");
            let release = Arc::new(AtomicBool::new(false));
            let released = release.clone();
            let (started, starting) = tokio::sync::oneshot::channel();
            let (_stop, stopping) = watch::channel(false);
            let selected = selected.clone();
            let frozen = frozen.clone();
            let requested = calls.clone();
            let running = tokio::spawn(session.run_with_options(
                move || {
                    requested.fetch_add(1, Ordering::SeqCst);
                    let options = selected.borrow().clone();
                    frozen.send_replace(Some(options.clone()));
                    Ok(options)
                },
                LinkClient::new(Default::default()).unwrap(),
                format!("phone-{index}"),
                SessionTransport::Wireless,
                stopping,
                move |_, state| async move {
                    let _state = state;
                    let _release = Released(release);
                    let _ = started.send(());
                    std::future::pending::<std::result::Result<(), String>>().await
                },
                std::future::pending::<String>(),
            ));
            starting.await.unwrap();
            assert_eq!(calls.load(Ordering::SeqCst), index);
            let mut phone = TcpStream::connect(address).await.unwrap();
            // The real receiver rejects unpaired SETUP. This ends just this
            // phone's tasks, without needing MFi, Bluetooth or actual media.
            phone
                .write_all(b"SETUP /session RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n")
                .await
                .unwrap();
            let result = tokio::time::timeout(Duration::from_secs(1), running)
                .await
                .unwrap()
                .unwrap();
            assert!(result.is_err());
            assert!(released.load(Ordering::SeqCst));
            assert_eq!(calls.load(Ordering::SeqCst), index + 1);
            let snapshot = observed.borrow().clone().unwrap();
            assert_eq!(
                snapshot.display.view_insets,
                settings.borrow().display.view_insets
            );
            assert_eq!(
                snapshot.display.safe_insets,
                settings.borrow().display.safe_insets
            );
            assert!(!owner.directory().join("carplay-video.sock").exists());
            assert!(!owner.directory().join("carplay-control.sock").exists());
            assert!(TcpListener::bind(address).await.is_err());
            assert!(claim_runtime(owner.directory()).await.is_err());
        }
    }

    #[tokio::test(start_paused = true)]
    async fn permission_wait_extends_only_wireless_airplay_accept_and_never_reads_options_early() {
        for transport in [SessionTransport::Usb, SessionTransport::Wireless] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let calls = Arc::new(AtomicUsize::new(0));
            let requested = calls.clone();
            let accepting = tokio::spawn(accept_transport_options(
                listener,
                move || {
                    requested.fetch_add(1, Ordering::SeqCst);
                    Ok(options())
                },
                transport,
            ));
            tokio::task::yield_now().await;
            tokio::time::advance(Duration::from_secs(41)).await;
            tokio::task::yield_now().await;
            if transport == SessionTransport::Wireless {
                assert!(
                    !accepting.is_finished(),
                    "human approval must survive the old 40s ceiling"
                );
                tokio::time::advance(Duration::from_secs(80)).await;
            }
            assert_eq!(
                accepting.await.unwrap().err().unwrap().kind(),
                std::io::ErrorKind::TimedOut
            );
            assert_eq!(calls.load(Ordering::SeqCst), 0);
        }
    }

    #[tokio::test]
    async fn runtime_watch_reports_authentication_and_human_approval_before_any_airplay_connection()
    {
        let (fixture, owner) = Fixture::owner().await;
        let (progress, mut observed) = watch::channel(Progress::WaitingPhone);
        let session = owner
            .bind("127.0.0.1:0".parse().unwrap(), fixture.pairing())
            .await
            .unwrap()
            .with_progress(progress);
        let (stop, stopping) = watch::channel(false);
        let (updates, mut requested) = mpsc::channel(2);
        let running = tokio::spawn(session.run_with_options(
            || Ok(options()),
            LinkClient::new(Default::default()).unwrap(),
            "synthetic".into(),
            SessionTransport::Wireless,
            stopping,
            move |_, state| async move {
                while let Some(update) = requested.recv().await {
                    state.send_replace(update);
                }
                std::future::pending::<std::result::Result<(), String>>().await
            },
            std::future::pending::<String>(),
        ));
        for (state, expected) in [
            (wired::State::ReadingCertificate, Progress::Authenticating),
            (
                wired::State::WaitingForAvailability,
                Progress::AwaitingPermission,
            ),
            (wired::State::StartSessionSent, Progress::ConnectingAirPlay),
        ] {
            updates.send(state).await.unwrap();
            tokio::time::timeout(
                Duration::from_secs(1),
                observed.wait_for(|value| *value == expected),
            )
            .await
            .unwrap()
            .unwrap();
        }
        stop.send_replace(true);
        assert!(!running.await.unwrap().unwrap());
        assert!(!owner.directory().join("carplay-control.sock").exists());
    }
}
