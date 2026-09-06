#![cfg(unix)]

use std::io;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::watch;
use tokio::task::JoinSet;

use crate::daemon_state::{IPC_ERROR, IPC_HELLO, ProjectionRuntimeSnapshot, snapshot_messages};
use crate::host_control::HostControl;
use crate::ipc::{Decoder, Message, PayloadReader, encode, string_payload};

pub fn bind(socket_path: &Path) -> io::Result<UnixListener> {
    if let Some(parent) = socket_path.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)?;
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
    let mut lease = None;
    let mut configuration = control.configuration.subscribe();
    let mut revision = 0;
    let mut accepted = true;
    let mut reason = String::new();
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
                        let detail=format!("Incompatible or malformed projection IPC: {error:?}; use matching Argo/daemon IPC v2 builds.");
                        let _=send_error(&mut client,&detail).await;
                        crate::daemon_log!(Warn, "ipc-server", "{detail}");
                        return;
                    }
                };
                for message in messages {
                    if hello_complete {
                        if message.kind==28 {
                            let mut r=PayloadReader::new(&message.payload);
                            let Some(request)=r.u32() else {let _=send_error(&mut client,"Malformed configuration revision").await;return;};
                            if request<=revision {let _=send_error(&mut client,"Configuration revisions must increase").await;return;}
                            revision=request;
                            let parsed=crate::configuration::read_display(&mut r).filter(|_|r.done());
                            let result=parsed.ok_or_else(||"Malformed display request".to_owned()).and_then(|d|{d.validate()?;Ok(d)});
                            match result {
                                Ok(display)=>{control.configuration.send_modify(|c|c.display=display);accepted=true;reason.clear();},
                                Err(error)=>{accepted=false;reason=error;}
                            }
                            configuration.borrow_and_update();
                            if send(&mut client,&control.configuration_message(revision,accepted,&reason)).await.is_err(){return;}
                        } else if let Err(error)=control.command(&message) {let _=send_error(&mut client,&error).await;}
                        continue;
                    }
                    if message.kind != IPC_HELLO {
                        let _ = send_error(&mut client, "Projection hello required").await;
                        return;
                    }
                    if !message.payload.is_empty() {
                        let _=send_error(&mut client,"Malformed projection hello; IPC v2 hello has no payload or identity paths").await;return;
                    }
                    if lease.is_none() {
                        match control.client_lease.clone().try_acquire_owned(){
                            Ok(permit)=>lease=Some(permit),
                            Err(_)=>{let _=send_error(&mut client,"Another Argo control client owns projection configuration; close it first").await;return;}
                        }
                    }
                    if send(&mut client, &Message { kind: IPC_HELLO, payload: Vec::new() }).await.is_err() {
                        return;
                    }
                    hello_complete = true;
                    if send(&mut client,&crate::configuration::capabilities(control.readiness,&control.readiness_detail)).await.is_err(){return;}
                    if send(&mut client,&control.configuration_message(revision,accepted,&reason)).await.is_err(){return;}
                    configuration.borrow_and_update();
                    let current = state.borrow().clone();
                    if send_state_change(&mut client, &sent_state, &current).await.is_err() {
                        return;
                    }
                    sent_state = current;
                }
            }
            changed = configuration.changed(), if hello_complete => {
                if changed.is_err(){return;}
                configuration.borrow_and_update();
                if send(&mut client,&control.configuration_message(revision,accepted,&reason)).await.is_err(){return;}
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

    async fn receive_kind(client: &mut UnixStream, kind: u16) -> Message {
        let mut decoder = Decoder::default();
        let mut bytes = [0; 4096];
        loop {
            let n = tokio::time::timeout(Duration::from_secs(2), client.read(&mut bytes))
                .await
                .unwrap()
                .unwrap();
            assert!(n > 0);
            for message in decoder.push(&bytes[..n]).unwrap() {
                if message.kind == kind {
                    return message;
                }
            }
        }
    }
    async fn request(
        client: &mut UnixStream,
        revision: u32,
        display: &crate::aa_channels::DisplayConfig,
    ) -> Message {
        let mut w = crate::ipc::PayloadWriter::default();
        w.u32(revision);
        crate::configuration::write_display(&mut w, display);
        send(
            client,
            &Message {
                kind: 28,
                payload: w.finish(),
            },
        )
        .await
        .unwrap();
        loop {
            let message = receive_kind(client, 10).await;
            if PayloadReader::new(&message.payload).u32() == Some(revision) {
                return message;
            }
        }
    }
    #[tokio::test]
    async fn credential_free_configuration_is_validated_frozen_and_single_owner() {
        let control = HostControl::default();
        // A standalone phone can start before Argo attaches. Its selection is immutable.
        let standalone = control.begin_session("standalone");
        let (_state, snapshot) = watch::channel(ProjectionRuntimeSnapshot::default());
        let (mut client, server) = UnixStream::pair().unwrap();
        let task = tokio::spawn(handle_client(server, snapshot.clone(), control.clone()));
        send(
            &mut client,
            &Message {
                kind: IPC_HELLO,
                payload: vec![],
            },
        )
        .await
        .unwrap();
        let initial = receive_kind(&mut client, 9).await;
        assert_eq!(PayloadReader::new(&initial.payload).u8(), Some(1)); // identity missing, control works
        assert!(control.configuration.borrow().identity.is_none());
        let mut display = crate::aa_channels::DisplayConfig {
            dpi: 180,
            ..Default::default()
        };
        let reply = request(&mut client, 1, &display).await;
        let mut r = PayloadReader::new(&reply.payload);
        assert_eq!(r.u32(), Some(1));
        assert_eq!(r.u8(), Some(1));
        assert_eq!(
            control.configuration.borrow().active.as_ref().unwrap().1,
            standalone.config.display
        );
        assert_eq!(standalone.config.display.dpi, 160);
        drop(standalone);
        let first = control.begin_session("first");
        assert_eq!(first.config.display, display);
        display.right_driver = true;
        request(&mut client, 2, &display).await;
        assert_eq!(
            control.configuration.borrow().active.as_ref().unwrap().1,
            first.config.display
        );
        assert!(!first.config.display.right_driver);
        let invalid = crate::aa_channels::DisplayConfig {
            width: 801,
            ..display.clone()
        };
        let reply = request(&mut client, 3, &invalid).await;
        let mut r = PayloadReader::new(&reply.payload);
        assert_eq!(r.u32(), Some(3));
        assert_eq!(r.u8(), Some(0));
        assert_eq!(control.configuration.borrow().display, display);
        let (mut other, server) = UnixStream::pair().unwrap();
        let second = tokio::spawn(handle_client(server, snapshot, control.clone()));
        send(
            &mut other,
            &Message {
                kind: IPC_HELLO,
                payload: vec![],
            },
        )
        .await
        .unwrap();
        assert!(
            PayloadReader::new(&receive_kind(&mut other, IPC_ERROR).await.payload)
                .string()
                .unwrap()
                .contains("Another Argo")
        );
        second.await.unwrap();
        drop(first);
        assert!(control.configuration.borrow().active.is_none());
        let next = control.begin_session("next");
        assert_eq!(next.config.display, display);
        assert!(next.config.identity.is_none());
        drop(next);
        drop(client);
        task.await.unwrap();
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
            Some(
                "Malformed projection hello; IPC v2 hello has no payload or identity paths"
                    .to_owned()
            )
        );
        tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(*state.borrow(), ProjectionRuntimeSnapshot::default());
    }
}
