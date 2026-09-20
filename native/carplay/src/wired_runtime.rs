//! Foreground wired receiver integration. Argo remains unprivileged.
use crate::{
    link::LinkClient,
    protocol::{
        self, csm, ncm,
        pairing::{Identity, Peers},
        receiver::{AudioOptions, Display, Receiver, Video},
        usb_mux, usbmux, wired,
    },
};
use std::{
    net::{IpAddr, SocketAddr},
    os::unix::fs::{DirBuilderExt, PermissionsExt},
    sync::Arc,
    time::Duration,
};
use tokio::{
    net::{TcpListener, UnixListener},
    sync::{Mutex, mpsc, watch},
    task::JoinSet,
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

#[derive(Clone)]
pub struct Options {
    pub display: Display,
    pub audio: Option<AudioOptions>,
}

pub fn parse_options(args: &[String]) -> Result<Options> {
    if args.len() != 4
        && !(matches!(args.len(), 6 | 8)
            && args[4] == "--audio"
            && (args.len() == 6 || args[6] == "--microphone"))
    {
        return Err("Expected WIDTH HEIGHT WIDTH_MM HEIGHT_MM [--audio PULSE_SINK [--microphone PULSE_SOURCE]]".into());
    }
    let audio = if args.len() >= 6 {
        if !cfg!(feature = "linux-audio")
            || args[5].is_empty()
            || args[5].len() > 128
            || !args[5]
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        {
            return Err(
                "Audio requires linux-audio and a valid selected PulseAudio sink name".into(),
            );
        }
        Some(AudioOptions {
            sink: Some(args[5].clone()),
            input: if args.len() == 8 {
                Some(args[7].clone())
            } else {
                std::env::var("ARGO_CARPLAY_MICROPHONE").ok()
            },
        })
    } else {
        None
    };
    if let Some(source) = audio.as_ref().and_then(|audio| audio.input.as_deref())
        && (source.is_empty()
            || source.len() > 256
            || !source
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)))
    {
        return Err("Invalid CarPlay microphone source".into());
    }
    let display = Display {
        width: args[0].parse()?,
        height: args[1].parse()?,
        width_mm: args[2].parse()?,
        height_mm: args[3].parse()?,
        fps: 30,
        right_hand_drive: false,
    };
    display.validate()?;
    Ok(Options { display, audio })
}

pub async fn stopped(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|value| *value).await;
}

/// One session, with cleanup completed before the supervisor retries.
pub async fn run(
    options: Options,
    pairing_directory: std::path::PathBuf,
    link: LinkClient,
    mut stop: watch::Receiver<bool>,
) -> Result<bool> {
    let Options { display, audio } = options;
    let _owner = runtime_owner().await?;
    ncm::expose_carplay().await?;
    let prepare = async {
        for attempt in 0..600 {
            let _ = ncm::expose_carplay().await;
            if ncm::select_carplay().await.is_ok() {
                return Ok::<_, protocol::Error>(());
            }
            if attempt == 0 {
                eprintln!(
                    "USB configuration lease required. Owner PID: {}",
                    std::process::id()
                );
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        Err(protocol::Error::Timeout)
    };
    tokio::select! { result = prepare => result?, _=stopped(&mut stop)=>return Ok(false) }
    let mut bridge = tokio::select! {
        result = ncm::Bridge::start() => result?,
        _ = stopped(&mut stop) => return Ok(false),
    };
    eprintln!("Phone USB network ready on {}", bridge.interface);
    let mut session_stop = stop.clone();
    let result = async {
        let listener = TcpListener::bind(SocketAddr::V6(bridge.address)).await?;
        let runtime = std::env::var("XDG_RUNTIME_DIR")?;
        let directory = std::path::PathBuf::from(runtime).join("argo");
        if !directory.exists() {
            std::fs::DirBuilder::new().mode(0o700).create(&directory)?;
        }
        use std::os::unix::fs::MetadataExt;
        let metadata = std::fs::symlink_metadata(&directory)?;
        if !directory.is_absolute()
            || !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
        {
            return Err("CarPlay runtime directory must be private and owned by this user".into());
        }
        let path = directory.join("carplay-video.sock");
        if path.exists() {
            return Err::<bool, Box<dyn std::error::Error + Send + Sync>>(
                "CarPlay media endpoint already exists".into(),
            );
        }
        let media_listener = UnixListener::bind(&path)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        struct Remove(std::path::PathBuf);
        impl Drop for Remove {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
        let _remove = Remove(path);
        if !pairing_directory.is_absolute() {
            return Err("Pairing directory must be absolute".into());
        }
        let identity = Arc::new(Identity::load_or_create(&pairing_directory)?);
        let peers = Peers::load(&pairing_directory)?;
        let key: [u8; 32] = identity.public_key()?.try_into().unwrap();
        let mux = tokio::select! {
            value = usb_mux::UsbMux::start() => value?,
            _ = stopped(&mut session_stop) => return Ok(false),
        };
        eprintln!("Local CarPlay USB multiplexer ready");
        let carkit = tokio::select! {
            value = usbmux::open_local_carkit(&mux) => value?,
            _ = stopped(&mut session_stop) => { mux.close().await; return Ok(false); },
        };
        let configuration = wired::Configuration {
            identity: csm::AccessoryIdentity {
                name: "Argo".into(),
                model: "LattePanda Mu".into(),
                manufacturer: "Argo".into(),
                serial: "argo-development".into(),
                firmware: "0.1.0".into(),
                hardware: "1".into(),
                language: "en".into(),
                usb_interface: bridge.usb_interface,
            },
            start_session: csm::StartSession {
                transport: csm::SessionTransport::Wired {
                    address: IpAddr::V6(*bridge.address.ip()),
                },
                port: listener.local_addr()?.port(),
                device_identifier: identity.identifier.clone(),
                public_key: key,
                source_version: crate::protocol::receiver::SOURCE_VERSION.into(),
            },
        };
        let mut session_bytes = [0u8; 8];
        openssl::rand::rand_bytes(&mut session_bytes)?;
        let session = (u64::from_be_bytes(session_bytes) & ((1u64 << 53) - 1)).max(1);
        let (cancel, cancel_rx) = watch::channel(false);
        let (state, mut state_rx) = watch::channel(wired::State::Synchronizing);
        let control_state = state_rx.clone();
        let (video, mut video_rx) = watch::channel::<Option<Video>>(None);
        let (commands, commands_rx) = mpsc::channel(32);
        let (information, info_rx) = watch::channel(Default::default());
        let mut tasks = JoinSet::new();
        let wired_link = link.clone();
        tasks.spawn(async move {
            wired::run(carkit, &wired_link, configuration, cancel_rx, state)
                .await
                .map_err(|e| e.to_string())
        });
        tasks.spawn(async move {
            while state_rx.changed().await.is_ok() {
                eprintln!("Wired state: {:?}", *state_rx.borrow_and_update());
            }
            Ok(())
        });
        let receiver = Receiver {
            information,
            pairing_directory: Some(pairing_directory),
            audio,
            display,
            identity,
            peers: Arc::new(Mutex::new(peers)),
            link,
        };
        tasks.spawn(async move {
            let (socket, _) = tokio::time::timeout(Duration::from_secs(40), listener.accept())
                .await
                .map_err(|_| "AirPlay connection timeout".to_owned())?
                .map_err(|e| e.to_string())?;
            receiver
                .run(socket, session, video, commands_rx)
                .await
                .map_err(|e| e.to_string())
        });
        let control_path = directory.join("carplay-control.sock");
        let control_listener = UnixListener::bind(&control_path)?;
        std::fs::set_permissions(&control_path, std::fs::Permissions::from_mode(0o600))?;
        let _remove_control = Remove(control_path);
        let digest = openssl::sha::sha256(mux.udid.as_bytes());
        let device_id = digest[..16]
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let control = Arc::new(crate::runtime_control::Control::new(
            session,
            device_id,
            video_rx.clone(),
            info_rx,
            control_state,
            commands,
            cancel.clone(),
        ));
        tasks.spawn(async move {
            control
                .serve(control_listener)
                .await
                .map_err(|e| e.to_string())
        });
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
        let result = tokio::select! {
            _ = stopped(&mut session_stop) => Ok(()),
            result=bridge.ended()=>Err(format!("USB network ended: {result:?}")),
            result=tasks.join_next()=>match result {Some(Ok(result))=>result,Some(Err(e))=>Err(e.to_string()),None=>Err("Session ended".into())},
        };
        let user_disconnected = *cancel.borrow();
        cancel.send_replace(true);
        tasks.abort_all();
        while tasks.join_next().await.is_some() {}
        mux.close().await;
        if user_disconnected {
            Ok(true)
        } else {
            result.map(|_| false).map_err(Into::into)
        }
    };
    let result = result.await;
    bridge.close().await;
    result
}

/// Persistent Argo pairing storage; contains no MFi private material.
pub fn pairing_directory() -> Result<std::path::PathBuf> {
    let base = match std::env::var_os("XDG_STATE_HOME") {
        Some(path) => std::path::PathBuf::from(path),
        None => std::path::PathBuf::from(std::env::var_os("HOME").ok_or("HOME is required")?)
            .join(".local/state"),
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

async fn runtime_owner() -> Result<std::fs::File> {
    let root = std::path::PathBuf::from(
        std::env::var_os("XDG_RUNTIME_DIR").ok_or("XDG_RUNTIME_DIR is required")?,
    );
    if !root.is_absolute() {
        return Err("Runtime directory must be absolute".into());
    }
    claim_runtime(&root.join("argo")).await
}

async fn claim_runtime(directory: &std::path::Path) -> Result<std::fs::File> {
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
        return Err("Wired receiver already running".into());
    }
    for name in ["carplay-control.sock", "carplay-video.sock"] {
        let path = directory.join(name);
        match std::fs::symlink_metadata(&path) {
            Ok(m) if m.file_type().is_socket() => {
                // Older foreground examples did not hold this lock.
                match tokio::time::timeout(
                    Duration::from_millis(300),
                    tokio::net::UnixStream::connect(&path),
                )
                .await
                {
                    Ok(Err(e)) if e.kind() == std::io::ErrorKind::ConnectionRefused => {}
                    _ => return Err("Live foreground receiver already owns the endpoint".into()),
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
    #[tokio::test]
    async fn ownership_refuses_competitors_and_recovers_only_dead_sockets() {
        let root = std::env::temp_dir().join(format!(
            "argo-carplay-owner-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let owner = claim_runtime(&root).await.unwrap();
        assert!(claim_runtime(&root).await.is_err());
        drop(owner);
        let path = root.join("carplay-control.sock");
        let listener = UnixListener::bind(&path).unwrap();
        assert!(claim_runtime(&root).await.is_err());
        assert!(path.exists());
        drop(listener);
        let owner = claim_runtime(&root).await.unwrap();
        assert!(!path.exists());
        drop(owner);
        std::fs::write(&path, b"retain").unwrap();
        assert!(claim_runtime(&root).await.is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"retain");
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn stop_is_observed_even_if_sent_before_waiting() {
        let (send, mut receive) = watch::channel(false);
        send.send_replace(true);
        tokio::time::timeout(Duration::from_millis(50), stopped(&mut receive))
            .await
            .unwrap();
    }
    #[cfg(feature = "linux-audio")]
    #[test]
    fn explicit_microphone_requires_audio_and_valid_source() {
        let args = [
            "1280",
            "720",
            "200",
            "112",
            "--audio",
            "sink",
            "--microphone",
            "source",
        ]
        .map(String::from);
        assert_eq!(
            parse_options(&args)
                .unwrap()
                .audio
                .unwrap()
                .input
                .as_deref(),
            Some("source")
        );
        let mut invalid = args.clone();
        invalid[7] = "source;command".into();
        assert!(parse_options(&invalid).is_err());
        assert!(parse_options(&args[..7]).is_err());
        let no_output = ["1280", "720", "200", "112", "--microphone", "source"].map(String::from);
        assert!(parse_options(&no_output).is_err());
    }

    #[test]
    fn rejects_incomplete_and_invalid_display_options() {
        assert!(parse_options(&[]).is_err());
        let args = ["0", "720", "200", "112"].map(String::from);
        assert!(parse_options(&args).is_err());
        let args = ["1280", "720", "200", "112"].map(String::from);
        assert!(parse_options(&args).is_ok());
    }
}
