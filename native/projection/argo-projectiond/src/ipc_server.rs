#![cfg(unix)]

use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::watch;
use tokio::task::JoinSet;

use crate::aa_channels::DisplayConfig;
use crate::daemon_state::{IPC_ERROR, IPC_HELLO, ProjectionRuntimeSnapshot, snapshot_messages};
use crate::host_control::{HostControl, SessionConfig};
use crate::identity::AndroidAutoIdentity;
use crate::ipc::{Decoder, Message, PayloadReader, encode, string_payload};

pub fn bind(socket_path: &Path) -> io::Result<UnixListener> {
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    // Never unlink another live daemon's socket (or an arbitrary file).
    // A socket left by a crash must be removed explicitly by the operator.
    let listener = UnixListener::bind(socket_path)?;
    if let Err(error) =
        std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o660))
    {
        remove_socket(socket_path);
        return Err(error);
    }
    crate::daemon_log!(
        Info,
        "ipc-server",
        "argo-projectiond: control socket {}",
        socket_path.display()
    );
    Ok(listener)
}

pub async fn run(
    listener: UnixListener,
    socket_path: PathBuf,
    state: watch::Receiver<ProjectionRuntimeSnapshot>,
    mut shutdown: watch::Receiver<bool>,
    control: HostControl,
) -> io::Result<()> {
    let mut clients = JoinSet::new();
    loop {
        tokio::select! {
            biased;
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() { break; }
            }
            accepted = listener.accept() => {
                match accepted {
                    Ok((client, _)) => {
                        if clients.len() < 4 {
                            clients.spawn(handle_client(client, state.clone(),control.clone()));
                        }
                    }
                    Err(error) => crate::daemon_log!(Error, "ipc-server", "argo-projectiond: IPC accept failed: {error}"),
                }
            }
            _ = clients.join_next(), if !clients.is_empty() => {},
        }
    }

    clients.shutdown().await;
    drop(listener);
    remove_socket(&socket_path);
    Ok(())
}

fn remove_socket(path: &Path) {
    if let Err(error) = std::fs::remove_file(path)
        && error.kind() != io::ErrorKind::NotFound
    {
        crate::daemon_log!(
            Warn,
            "ipc-server",
            "argo-projectiond: could not remove control socket: {error}"
        );
    }
}

async fn handle_client(
    mut client: UnixStream,
    mut state: watch::Receiver<ProjectionRuntimeSnapshot>,
    control: HostControl,
) {
    let mut decoder = Decoder::default();
    let mut buffer = [0_u8; 16 * 1024];
    let mut hello_complete = false;
    let mut sent_state = ProjectionRuntimeSnapshot::default();
    let hello_deadline = tokio::time::Instant::now() + Duration::from_secs(10);

    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(hello_deadline), if !hello_complete => { crate::daemon_log!(Warn, "ipc", "client hello timeout"); return; },
            read = client.read(&mut buffer) => {
                let count = match read {
                    Ok(0) => { crate::daemon_log!(Warn, "ipc", "control client disconnected"); return; },
                    Ok(count) => count,
                    Err(error) => {
                        crate::daemon_log!(Error, "ipc-server", "argo-projectiond: IPC client read failed: {error}");
                        return;
                    }
                };
                let messages = match decoder.push(&buffer[..count]) {
                    Ok(messages) => messages,
                    Err(error) => {
                        crate::daemon_log!(Error, "ipc-server", "argo-projectiond: malformed IPC: {error:?}");
                        return;
                    }
                };
                for message in messages {
                    if hello_complete {
                        if let Err(error)=control.command(&message) {let _=send_error(&mut client,&error).await;}
                        continue;
                    }
                    if message.kind != IPC_HELLO {
                        let _ = send_error(&mut client, "Projection hello required").await;
                        return;
                    }
                    match parse_hello(&message) {
                        Ok(mut config) => {
                            if let Err(error) = config.identity.as_ref().unwrap().validate_files() {
                                let text = format!("Android Auto identity validation failed: {error:?}");
                                let _ = send_error(&mut client, &text).await;
                                return;
                            }
                            if let Err(error)=config.display.validate() {let _=send_error(&mut client,&error).await;return;}
                            config.media_socket=control.configuration.borrow().media_socket.clone();
                            control.configuration.send_replace(config);
                        }
                        Err(error) => {
                            let _ = send_error(&mut client, error).await;
                            return;
                        }
                    }
                    if send(&mut client, &Message { kind: IPC_HELLO, payload: Vec::new() }).await.is_err() {
                        return;
                    }
                    hello_complete = true;
                    let current = state.borrow().clone();
                    if send_state_change(&mut client, &sent_state, &current).await.is_err() {
                        return;
                    }
                    sent_state = current;
                }
            }
            changed = state.changed(), if hello_complete => {
                if changed.is_err() {
                    return;
                }
                let current = state.borrow().clone();
                if send_state_change(&mut client, &sent_state, &current).await.is_err() {
                    return;
                }
                sent_state = current;
            }
        }
    }
}

fn parse_hello(message: &Message) -> Result<SessionConfig, &'static str> {
    let mut payload = PayloadReader::new(&message.payload);
    let parsed = (|| {
        let width = payload.u16()?;
        let height = payload.u16()?;
        let dpi = payload.u16()?;
        let fps = payload.u8()?;
        let driver_side = payload.u8()?;
        if driver_side > 1 {
            return None;
        }
        let certificate = payload.string()?;
        let private_key = payload.string()?;
        payload.done().then_some(SessionConfig {
            media_socket: None,
            display: DisplayConfig {
                width,
                height,
                dpi,
                fps,
                right_driver: driver_side == 1,
            },
            identity: Some(AndroidAutoIdentity {
                certificate: certificate.into(),
                private_key: private_key.into(),
            }),
        })
    })();
    parsed.ok_or("Malformed projection hello")
}

async fn send_state_change(
    client: &mut UnixStream,
    previous: &ProjectionRuntimeSnapshot,
    current: &ProjectionRuntimeSnapshot,
) -> io::Result<()> {
    let messages = snapshot_messages(previous, current)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, format!("{error:?}")))?;
    for message in messages {
        send(client, &message).await?;
    }
    Ok(())
}

async fn send_error(client: &mut UnixStream, text: &str) -> io::Result<()> {
    send(
        client,
        &Message {
            kind: IPC_ERROR,
            payload: string_payload(text).unwrap_or_default(),
        },
    )
    .await
}

async fn send(client: &mut UnixStream, message: &Message) -> io::Result<()> {
    let bytes = encode(message)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, format!("{error:?}")))?;
    tokio::time::timeout(Duration::from_secs(5), client.write_all(&bytes))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "IPC write timed out"))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn test_path() -> PathBuf {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        std::env::temp_dir().join(format!(
            "argo-ipc-{}-{}.sock",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[tokio::test]
    async fn shutdown_closes_idle_clients_and_removes_owned_socket() {
        let path = test_path();
        let listener = bind(&path).unwrap();
        let (state, snapshot) = watch::channel(ProjectionRuntimeSnapshot::default());
        let (shutdown, shutdown_rx) = watch::channel(false);
        let server = tokio::spawn(run(
            listener,
            path.clone(),
            snapshot,
            shutdown_rx,
            HostControl::default(),
        ));
        let mut client = UnixStream::connect(&path).await.unwrap();
        // USB state can change without a hello; idle Flutter must not block it.
        state.send_replace(ProjectionRuntimeSnapshot::connecting(
            "phone".into(),
            "Android phone".into(),
        ));
        tokio::task::yield_now().await;
        shutdown.send_replace(true);
        tokio::time::timeout(Duration::from_secs(1), server)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert!(!path.exists());
        let mut buffer = [0; 1];
        let read = tokio::time::timeout(Duration::from_secs(1), client.read(&mut buffer))
            .await
            .unwrap();
        assert!(matches!(read, Ok(0) | Err(_)));
    }

    #[tokio::test]
    async fn bind_never_deletes_an_existing_file_or_live_socket() {
        let path = test_path();
        std::fs::write(&path, "not a socket").unwrap();
        assert!(bind(&path).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "not a socket");
        std::fs::remove_file(&path).unwrap();
        let listener = bind(&path).unwrap();
        assert!(bind(&path).is_err());
        assert!(UnixStream::connect(&path).await.is_ok());
        drop(listener);
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    async fn malformed_hello_is_rejected_without_affecting_runtime_state() {
        let (mut client, server) = UnixStream::pair().unwrap();
        let (state, snapshot) = watch::channel(ProjectionRuntimeSnapshot::default());
        let task = tokio::spawn(handle_client(server, snapshot, HostControl::default()));
        send(
            &mut client,
            &Message {
                kind: IPC_HELLO,
                payload: vec![0],
            },
        )
        .await
        .unwrap();
        let mut bytes = [0; 1024];
        let count = tokio::time::timeout(Duration::from_secs(1), client.read(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        let messages = Decoder::default().push(&bytes[..count]).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].kind, IPC_ERROR);
        assert_eq!(
            PayloadReader::new(&messages[0].payload).string(),
            Some("Malformed projection hello".to_owned())
        );
        tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(*state.borrow(), ProjectionRuntimeSnapshot::default());
    }
}
