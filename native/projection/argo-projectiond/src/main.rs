#[cfg(unix)]
#[tokio::main]
async fn main() -> std::io::Result<()> {
    use std::path::PathBuf;

    use argo_projectiond::daemon_state::ProjectionRuntimeSnapshot;
    use tokio::sync::watch;

    let socket_path = PathBuf::from(std::env::var("ARGO_PROJECTION_SOCKET").unwrap_or_else(|_| {
        std::env::var("XDG_RUNTIME_DIR")
            .map(|path| format!("{path}/argo/projection.sock"))
            .unwrap_or_else(|_| "/run/argo/projection.sock".to_owned())
    }));
    let listener = argo_projectiond::ipc_server::bind(&socket_path)?;
    let (state_tx, state_rx) = watch::channel(ProjectionRuntimeSnapshot::default());
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    let ipc_task = tokio::spawn(async move {
        if let Err(error) =
            argo_projectiond::ipc_server::run(listener, socket_path, state_rx, shutdown_rx).await
        {
            eprintln!("argo-projectiond: IPC listener stopped: {error}");
        }
    });

    #[cfg(all(feature = "linux-usb", target_os = "linux"))]
    let usb_task = {
        let shutdown = shutdown_tx.subscribe();
        tokio::spawn(async move {
            if let Err(error) = argo_projectiond::usb_runtime::run(state_tx, shutdown).await {
                eprintln!("argo-projectiond: USB runtime stopped: {error}");
            }
        })
    };

    #[cfg(not(all(feature = "linux-usb", target_os = "linux")))]
    {
        let _ = state_tx;
        eprintln!(
            "argo-projectiond: built without Linux USB support; rebuild with --features linux-usb"
        );
    }

    let signal_result = wait_for_shutdown().await;
    println!("argo-projectiond: shutting down");
    let _ = shutdown_tx.send(true);
    let _ = ipc_task.await;
    #[cfg(all(feature = "linux-usb", target_os = "linux"))]
    let _ = usb_task.await;
    signal_result
}

#[cfg(unix)]
async fn wait_for_shutdown() -> std::io::Result<()> {
    use tokio::signal::unix::{SignalKind, signal};

    let mut terminate = signal(SignalKind::terminate())?;
    tokio::select! {
        result = tokio::signal::ctrl_c() => result,
        _ = terminate.recv() => Ok(()),
    }
}

#[cfg(not(unix))]
fn main() {
    eprintln!("argo-projectiond is currently supported only on Unix hosts");
}
