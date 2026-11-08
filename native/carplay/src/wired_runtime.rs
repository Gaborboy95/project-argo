//! Foreground wired transport preparation for the shared CarPlay session runtime.
pub use crate::session_runtime::{Options, pairing_directory, stopped};
use crate::{
    link::LinkClient,
    protocol::{
        self, csm, ncm,
        receiver::{AudioOptions, CaptureSource, Display},
        usb_mux, usbmux, wired,
    },
    runtime_control::SessionTransport,
    session_runtime::Owner,
};
use std::{
    net::{IpAddr, SocketAddr},
    time::Duration,
};
use tokio::sync::watch;
type Result<T> = crate::session_runtime::Result<T>;

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
            }
            .map(CaptureSource::Device),
        })
    } else {
        None
    };
    if let Some(source) = audio
        .as_ref()
        .and_then(|audio| audio.input.as_ref())
        .and_then(CaptureSource::device)
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
        view_insets: [0; 4],
        safe_insets: [0; 4],
    };
    display.validate()?;
    Ok(Options { display, audio })
}

/// One session, with cleanup completed before the supervisor retries.
pub async fn run(
    options: Options,
    pairing_directory: std::path::PathBuf,
    link: LinkClient,
    stop: watch::Receiver<bool>,
) -> Result<bool> {
    run_with_options(move || Ok(options.clone()), pairing_directory, link, stop).await
}

/// Read the latest dashboard/preferences only when a phone starts AirPlay.
/// A pending USB preparation must not freeze the preceding window geometry.
pub async fn run_with_options<F>(
    options: F,
    pairing_directory: std::path::PathBuf,
    link: LinkClient,
    mut stop: watch::Receiver<bool>,
) -> Result<bool>
where
    F: Fn() -> std::io::Result<Options> + Send + 'static,
{
    let owner = Owner::claim().await?;
    if *stop.borrow() {
        return Ok(false);
    }
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
    let result = async {
        let session = owner
            .bind(SocketAddr::V6(bridge.address), pairing_directory)
            .await?;
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
                port: session.address()?.port(),
                device_identifier: session.identity_identifier().into(),
                public_key: session.public_key()?,
                source_version: crate::protocol::receiver::SOURCE_VERSION.into(),
            },
        };
        let mux = tokio::select! {
            value = usb_mux::UsbMux::start() => value?,
            _ = stopped(&mut stop) => return Ok(false),
        };
        eprintln!("Local CarPlay USB multiplexer ready");
        let result = async {
            let carkit = tokio::select! {
                value = usbmux::open_local_carkit(&mux) => value?,
                _ = stopped(&mut stop) => return Ok(false),
            };
            let digest = openssl::sha::sha256(mux.udid.as_bytes());
            let device_id = digest[..16].iter().map(|b| format!("{b:02x}")).collect();
            let wired_link = link.clone();
            session
                .run_with_metadata(
                    options,
                    link,
                    device_id,
                    SessionTransport::Usb,
                    stop,
                    move |cancel, state, metadata| async move {
                        wired::run_with_updates(
                            carkit,
                            &wired_link,
                            configuration,
                            cancel,
                            state,
                            Some(metadata),
                        )
                        .await
                        .map_err(|e| e.to_string())
                    },
                    async { format!("USB network ended: {:?}", bridge.ended().await) },
                )
                .await
        }
        .await;
        mux.close().await;
        result
    }
    .await;
    bridge.close().await;
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_runtime::{accept_options, claim_runtime};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::net::{TcpListener, TcpStream, UnixListener};

    #[tokio::test]
    async fn airplay_accept_snapshots_latest_options_and_freezes_the_connected_session() {
        let initial = parse_options(&["1280", "720", "200", "112"].map(String::from)).unwrap();
        let (settings, selection) = watch::channel(initial.clone());
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let requested = calls.clone();
        let accepting = tokio::spawn(accept_options(listener, move || {
            requested.fetch_add(1, Ordering::SeqCst);
            Ok(selection.borrow().clone())
        }));
        tokio::task::yield_now().await;
        assert_eq!(calls.load(Ordering::SeqCst), 0);

        let mut portrait = initial.clone();
        portrait.display = portrait.display.for_viewport(600.0, 680.0, 64.0);
        settings.send_replace(portrait.clone());
        let _phone = TcpStream::connect(address).await.unwrap();
        let (_socket, frozen) = accepting.await.unwrap().unwrap();
        assert_eq!(frozen.display.view_insets, portrait.display.view_insets);
        assert_eq!(frozen.display.safe_insets, portrait.display.safe_insets);
        assert_ne!(frozen.display.view_insets, initial.display.view_insets);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        settings.send_replace(initial);
        assert_eq!(frozen.display.view_insets, portrait.display.view_insets);
        assert_eq!(frozen.display.safe_insets, portrait.display.safe_insets);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test(start_paused = true)]
    async fn absent_phone_times_out_without_reading_or_freezing_options() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let calls = Arc::new(AtomicUsize::new(0));
        let requested = calls.clone();
        let accepting = tokio::spawn(accept_options(listener, move || {
            requested.fetch_add(1, Ordering::SeqCst);
            parse_options(&["1280", "720", "200", "112"].map(String::from))
                .map_err(std::io::Error::other)
        }));
        tokio::task::yield_now().await;
        tokio::time::advance(Duration::from_secs(41)).await;
        assert_eq!(
            accepting.await.unwrap().err().unwrap().kind(),
            std::io::ErrorKind::TimedOut
        );
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

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
                .as_ref()
                .and_then(CaptureSource::device),
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
