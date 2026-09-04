#![cfg(unix)]

use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::watch;

use crate::daemon_state::{IPC_ERROR, IPC_HELLO, ProjectionRuntimeSnapshot, snapshot_messages};
use crate::identity::AndroidAutoIdentity;
use crate::ipc::{Decoder, Message, PayloadReader, encode, string_payload};

pub async fn run(
    socket_path: PathBuf,
    state: watch::Receiver<ProjectionRuntimeSnapshot>,
    mut shutdown: watch::Receiver<bool>,
) -> io::Result<()> {
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    if socket_path.exists() {
        std::fs::remove_file(&socket_path)?;
    }
    let listener = UnixListener::bind(&socket_path)?;
    std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o660))?;
    println!("argo-projectiond: control socket {}", socket_path.display());

    loop {
        tokio::select! {
            accepted = listener.accept() => {
                match accepted {
                    Ok((client, _)) => {
                        tokio::spawn(handle_client(client, state.clone()));
                    }
                    Err(error) => eprintln!("argo-projectiond: IPC accept failed: {error}"),
                }
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
        }
    }

    drop(listener);
    remove_socket(&socket_path);
    Ok(())
}

fn remove_socket(path: &Path) {
    if let Err(error) = std::fs::remove_file(path)
        && error.kind() != io::ErrorKind::NotFound
    {
        eprintln!("argo-projectiond: could not remove control socket: {error}");
    }
}

async fn handle_client(
    mut client: UnixStream,
    mut state: watch::Receiver<ProjectionRuntimeSnapshot>,
) {
    let mut decoder = Decoder::default();
    let mut buffer = [0_u8; 16 * 1024];
    let mut hello_complete = false;
    let mut sent_state = ProjectionRuntimeSnapshot::default();

    loop {
        tokio::select! {
            read = client.read(&mut buffer) => {
                let count = match read {
                    Ok(0) => return,
                    Ok(count) => count,
                    Err(error) => {
                        eprintln!("argo-projectiond: IPC client read failed: {error}");
                        return;
                    }
                };
                let messages = match decoder.push(&buffer[..count]) {
                    Ok(messages) => messages,
                    Err(error) => {
                        eprintln!("argo-projectiond: malformed IPC: {error:?}");
                        return;
                    }
                };
                for message in messages {
                    if hello_complete || message.kind != IPC_HELLO {
                        continue;
                    }
                    match parse_hello(&message) {
                        Ok(identity) => {
                            if let Err(error) = identity.validate_files() {
                                let text = format!("Android Auto identity validation failed: {error:?}");
                                let _ = send_error(&mut client, &text).await;
                                return;
                            }
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

fn parse_hello(message: &Message) -> Result<AndroidAutoIdentity, &'static str> {
    let mut payload = PayloadReader::new(&message.payload);
    let parsed = (|| {
        let _width = payload.u16()?;
        let _height = payload.u16()?;
        let _dpi = payload.u16()?;
        let _fps = payload.u8()?;
        let _driver_side = payload.u8()?;
        let certificate = payload.string()?;
        let private_key = payload.string()?;
        payload.done().then_some(AndroidAutoIdentity {
            certificate: certificate.into(),
            private_key: private_key.into(),
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
    client.write_all(&bytes).await
}
