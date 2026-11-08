//! Unprivileged LIVI Link diagnostics and supervised wired/wireless CarPlay.
use argo_carplay::{
    diagnostic::{self, Health},
    discovery::Discovery,
    link::{LinkClient, LinkConfig},
};
use std::{
    io,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    sync::{RwLock, Semaphore},
    task::JoinSet,
    time::timeout,
};

struct SocketFile(PathBuf);
impl Drop for SocketFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn socket_path() -> io::Result<PathBuf> {
    let root = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::other("XDG_RUNTIME_DIR is required"))?;
    if !root.is_absolute() {
        return Err(io::Error::other("XDG_RUNTIME_DIR must be absolute"));
    }
    let directory = root.join("project-argo");
    use std::os::unix::fs::DirBuilderExt;
    match std::fs::DirBuilder::new().mode(0o700).create(&directory) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    let metadata = std::fs::symlink_metadata(&directory)?;
    // SAFETY: geteuid has no preconditions.
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(io::Error::other(
            "runtime directory must be private and owned by this user",
        ));
    }
    Ok(directory.join("carplay.sock"))
}

async fn bind(path: &Path) -> io::Result<UnixListener> {
    // A held flock prevents a competing restart from unlinking our socket between probes.
    // Main retains the lock until all workers have exited.
    if let Ok(metadata) = std::fs::symlink_metadata(path) {
        use std::os::unix::fs::FileTypeExt;
        if !metadata.file_type().is_socket() {
            return Err(io::Error::other("control path is not a socket"));
        }
        match timeout(Duration::from_millis(300), UnixStream::connect(path)).await {
            Ok(Err(error)) if error.kind() == io::ErrorKind::ConnectionRefused => {
                std::fs::remove_file(path)?
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    "CarPlay control socket has an owner",
                ));
            }
        }
    }
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

fn lock(path: &Path) -> io::Result<std::fs::File> {
    use std::os::{fd::AsRawFd, unix::fs::OpenOptionsExt};
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path.with_extension("lock"))?;
    // SAFETY: descriptor remains owned by File until after daemon shutdown.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            "CarPlay daemon already running",
        ));
    }
    Ok(file)
}

async fn request(mut stream: UnixStream, health: Arc<RwLock<Health>>) -> io::Result<()> {
    let mut line = [0; 16];
    for position in 0..line.len() {
        let byte = stream.read_u8().await?;
        line[position] = byte;
        if byte == b'\n' {
            if &line[..=position] != b"status\n" {
                return Err(io::Error::other("unknown diagnostic request"));
            }
            let mut response = serde_json::to_vec(&*health.read().await)?;
            if response.len() > 4095 {
                return Err(io::Error::other("diagnostic response bounds"));
            }
            response.push(b'\n');
            stream.write_all(&response).await?;
            return Ok(());
        }
    }
    Err(io::Error::other("request size limit"))
}

fn mark_clean() -> io::Result<()> {
    let Some(path) = std::env::var_os("ARGO_MANAGED_RESULT").map(PathBuf::from) else {
        return Ok(());
    };
    let invocation = std::env::var("INVOCATION_ID").map_err(io::Error::other)?;
    if invocation.is_empty()
        || invocation.len() > 128
        || !invocation
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
    {
        return Err(io::Error::other("invalid managed invocation identity"));
    }
    let temporary = path.with_extension(format!(
        "carplay-clean-{}-{invocation}.tmp",
        std::process::id()
    ));
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    use std::io::Write;
    file.write_all(
        serde_json::to_string(&serde_json::json!({"result":"clean", "invocation": invocation}))?
            .as_bytes(),
    )?;
    file.sync_all()?;
    std::fs::rename(temporary, path)
}

async fn wait_stop(stop: &mut tokio::sync::watch::Receiver<bool>) {
    let _ = stop.wait_for(|v| *v).await;
}

#[tokio::main]
async fn main() -> io::Result<()> {
    if std::env::args().nth(1).as_deref() == Some("--version") {
        println!(
            "argo-carplayd 0.1.0 control=1 wired={} wireless={}",
            cfg!(all(feature = "airplay", feature = "linux-usb")),
            cfg!(all(
                target_os = "linux",
                feature = "airplay",
                feature = "linux-usb"
            ))
        );
        return Ok(());
    }
    let mut args: Vec<_> = std::env::args().skip(1).collect();
    let automatic_usb = args.last().map(String::as_str) == Some("--usb-lease");
    if automatic_usb {
        args.pop();
    }
    let receiver_mode = matches!(
        args.first().map(String::as_str),
        Some("--wired" | "--receiver")
    );
    if automatic_usb && !receiver_mode {
        return Err(io::Error::other("USB lease requires receiver mode"));
    }
    #[cfg(all(feature = "airplay", feature = "linux-usb"))]
    let wired = if receiver_mode {
        Some(argo_carplay::wired_runtime::parse_options(&args[1..]).map_err(io::Error::other)?)
    } else if args.is_empty() {
        None
    } else {
        return Err(io::Error::other("Unknown arguments"));
    };
    #[cfg(not(all(feature = "airplay", feature = "linux-usb")))]
    if !args.is_empty() {
        return Err(io::Error::other(
            "Wired mode requires airplay and linux-usb features",
        ));
    }
    // SAFETY: geteuid has no preconditions. Media/USB privilege is never obtained here.
    if unsafe { libc::geteuid() } == 0 {
        return Err(io::Error::other("run as the desktop user, never root"));
    }
    let mut config = LinkConfig::default();
    if let Ok(value) = std::env::var("ARGO_LIVI_LINK_ADDRESS") {
        config.discovery = Discovery::Address(
            value
                .parse()
                .map_err(|_| io::Error::other("invalid trusted LIVI Link IPv4 override"))?,
        );
    }
    let client = LinkClient::new(config.clone()).map_err(io::Error::other)?;
    let network_client = LinkClient::new(config).map_err(io::Error::other)?;
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let path = socket_path()?;
    let _lock = lock(&path)?;
    let listener = bind(&path).await?;
    let _socket = SocketFile(path);
    let health = Arc::new(RwLock::new(Health::default()));
    let latest = health.clone();
    let (stop, mut stopping) = tokio::sync::watch::channel(false);
    let monitored = health.clone();
    let mut network_stop = stopping.clone();
    let mut network_monitor = tokio::spawn(async move {
        loop {
            let update = tokio::select! {
                update = diagnostic::probe_network(&network_client) => update,
                _ = wait_stop(&mut network_stop) => return,
            };
            update.apply(&mut *monitored.write().await);
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(5)) => {},
                _ = wait_stop(&mut network_stop) => return,
            }
        }
    });
    let mut poll = tokio::spawn(async move {
        #[cfg(all(feature = "airplay", feature = "linux-usb"))]
        if let Some(options) = wired {
            let pairing =
                argo_carplay::wired_runtime::pairing_directory().map_err(io::Error::other)?;
            let manager = argo_carplay::management::Manager::load(&pairing, &options)?;
            let mut changes = manager.state.subscribe();
            let endpoint = socket_path()?.with_file_name("carplay-settings.sock");
            let mut server = tokio::spawn(manager.clone().serve(endpoint));
            let mut lease: Option<argo_carplay::usb_lease::UsbLease> = None;
            let result = async {
                tokio::select! {
                    value = diagnostic::probe(&client) => *latest.write().await = value,
                    _ = wait_stop(&mut stopping) => return Ok::<(), io::Error>(()),
                }
                let mut delay = 2u64;
                loop {
                    if *stopping.borrow() { return Ok(()); }
                    let current = changes.borrow_and_update().clone();
                    if !current.running || !current.settings.enabled {
                        if let Some(mut active) = lease.take() { active.release().await?; }
                        *manager.phase.lock().await = "Disconnected".into();
                        tokio::select! {
                            value=changes.changed()=>{value.map_err(io::Error::other)?;},
                            _=wait_stop(&mut stopping)=>return Ok(()),
                            result=&mut server=>return Err(io::Error::other(format!("Settings service stopped: {result:?}"))),
                        }
                        continue;
                    }
                    let wireless = current.transport == argo_carplay::runtime_control::SessionTransport::Wireless;
                    if wireless && let Some(mut active) = lease.take() { active.release().await?; }
                    if !wireless && automatic_usb && lease.is_none() {
                        if !current.authorize && !argo_carplay::usb_lease::UsbLease::authorized().await? {
                            *manager.phase.lock().await = "USB permission required — select Connect to authorize".into();
                            tokio::select! {
                                _=changes.changed()=>{},
                                _=tokio::time::sleep(Duration::from_secs(10))=>{},
                                _=wait_stop(&mut stopping)=>return Ok(()),
                            }
                            continue;
                        }
                        lease = Some(argo_carplay::usb_lease::UsbLease::start()?);
                    }
                    tokio::select! {
                        value = diagnostic::probe(&client) => *latest.write().await = value,
                        _ = wait_stop(&mut stopping) => return Ok(()),
                    }
                    *manager.phase.lock().await = if wireless {
                        "Preparing LIVI Link wireless CarPlay"
                    } else { "Waiting for iPhone over USB" }.into();
                    let started=tokio::time::Instant::now();
                    let (session_stop, session_stopping)=tokio::sync::watch::channel(false);
                    let (progress,mut phases)=tokio::sync::watch::channel(argo_carplay::session_runtime::Progress::PreparingNetwork);
                    let mut progress_open=wireless;
                    let selection=manager.state.subscribe();
                    let session_pairing=pairing.clone();
                    let session_link=client.clone();
                    let device_manager=manager.clone();
                    let session=async move {
                        if wireless {
                            let network=argo_carplay::wireless_network::WirelessNetwork::load_or_create(&session_pairing)?;
                            let reconnect_selection=selection.clone();
                            let phone_selection=selection.clone();
                            let device_selection=argo_carplay::wireless_runtime::PhoneSelection::new(move ||phone_selection.borrow().target,move |peer|device_manager.bind_phone(current.generation,peer));
                            argo_carplay::wireless_runtime::run_with_selection(move || selection.borrow().options(),session_pairing,session_link,network,device_selection,session_stopping,move || reconnect_selection.borrow().settings.auto_connect,progress).await
                        } else {
                            argo_carplay::wired_runtime::run_with_options(move || selection.borrow().options(),session_pairing,session_link,session_stopping).await
                        }
                    };
                    tokio::pin!(session);
                    let outcome=loop {
                        tokio::select! {
                            result=&mut session=>break result,
                            changed=phases.changed(), if progress_open=>{
                                if changed.is_ok() {
                                    let label=phases.borrow_and_update().label();
                                    *manager.phase.lock().await=label.into();
                                } else {progress_open=false;}
                            },
                            _=wait_stop(&mut stopping)=>{session_stop.send_replace(true);break session.await;},
                            change=changes.changed()=>{
                                change.map_err(io::Error::other)?;
                                let next=changes.borrow_and_update().clone();
                                if !next.running || next.generation!=current.generation {session_stop.send_replace(true);break session.await;}
                            },
                            ended=async {match &mut lease {Some(l)=>l.ended().await,None=>std::future::pending().await}}=>{
                                session_stop.send_replace(true);
                                let cleanup = session.await;
                                if let Err(error) = cleanup { return Err(io::Error::other(format!("USB lease ended: {ended:?}; receiver: {error}"))); }
                                return Err(io::Error::other(format!("USB lease ended: {ended:?}")));
                            },
                            result=&mut server=>{
                                session_stop.send_replace(true);
                                let cleanup = session.await;
                                if let Err(error) = cleanup { return Err(io::Error::other(format!("Settings service stopped: {result:?}; receiver: {error}"))); }
                                return Err(io::Error::other(format!("Settings service stopped: {result:?}")));
                            },
                        }
                    };
                    if let Err(error) = &outcome
                        && (error.downcast_ref::<argo_carplay::wireless_runtime::CleanupUnconfirmed>().is_some()
                            || error.downcast_ref::<argo_carplay::wireless_bluetooth::ControllerCleanupUnconfirmed>().is_some())
                    {return Err(io::Error::other(error.to_string()));}
                    if *stopping.borrow() {return Ok(());}
                    if changes.borrow().generation!=current.generation {continue;}
                    match outcome {
                        Ok(true)=>{manager.state.send_modify(|s|s.running=false);continue;},
                        Ok(false)=>*manager.phase.lock().await="Reconnecting".into(),
                        Err(error)=>{eprintln!("CarPlay session ended: {error}"); *manager.phase.lock().await="Waiting for iPhone or LIVI Link".into();},
                    }
                    let auto_connect=changes.borrow().settings.auto_connect;
                    if !auto_connect {manager.state.send_modify(|s|s.running=false);continue;}
                    if started.elapsed()>=Duration::from_secs(60){delay=2;}
                    tokio::select! {
                        _=tokio::time::sleep(Duration::from_secs(delay))=>{},
                        _=changes.changed()=>{},
                        _=wait_stop(&mut stopping)=>return Ok(()),
                    }
                    delay=(delay*2).min(30);
                }
            }.await;
            server.abort();
            let _ = server.await;
            if let Some(mut active) = lease {
                active.release().await?;
            }
            return result;
        }
        loop {
            tokio::select! {
                value = diagnostic::probe(&client) => *latest.write().await = value,
                _ = wait_stop(&mut stopping) => return Ok::<(), io::Error>(()),
            }
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(5)) => {},
                _ = wait_stop(&mut stopping) => return Ok(()),
            }
        }
    });
    let permits = Arc::new(Semaphore::new(8));
    let mut workers = JoinSet::new();
    let result = loop {
        tokio::select! {
            result = tokio::signal::ctrl_c() => break result,
            _ = terminate.recv() => break Ok(()),
            outcome = &mut poll => break Err(io::Error::other(format!("health worker stopped: {outcome:?}"))),
            outcome = &mut network_monitor => break Err(io::Error::other(format!("Link network monitor stopped: {outcome:?}"))),
            Some(_) = workers.join_next(), if !workers.is_empty() => {},
            incoming = listener.accept() => {
                let (stream, _) = match incoming { Ok(stream) => stream, Err(error) => break Err(error) };
                let Ok(permit) = permits.clone().try_acquire_owned() else { continue; };
                let health = health.clone();
                workers.spawn(async move {
                    let _permit = permit;
                    let _ = timeout(Duration::from_secs(2), request(stream, health)).await;
                });
            }
        }
    };
    stop.send_replace(true);
    if !poll.is_finished() {
        // Controller/profile, owned AP state and media cleanup must finish before
        // another receiver can acquire the shared session lock.
        timeout(Duration::from_secs(28), &mut poll)
            .await
            .map_err(|_| io::Error::other("CarPlay cleanup timed out"))?
            .map_err(io::Error::other)??;
    }
    if !network_monitor.is_finished() {
        timeout(Duration::from_secs(2), &mut network_monitor)
            .await
            .map_err(|_| io::Error::other("Link monitor cleanup timed out"))?
            .map_err(io::Error::other)?;
    }
    workers.abort_all();
    while workers.join_next().await.is_some() {}
    drop(listener);
    drop(_socket);
    result?;
    mark_clean()
}
