#[cfg(unix)]
#[tokio::main]
async fn main() -> std::io::Result<()> {
    argo_projectiond::logging::init().map_err(std::io::Error::other)?;
    argo_projectiond::daemon_log!(Info, "daemon", "starting");

    use argo_projectiond::daemon_state::ProjectionRuntimeSnapshot;
    use tokio::sync::watch;

    let socket_path =
        argo_projectiond::configuration::endpoint("ARGO_PROJECTION_SOCKET", "projection.sock")
            .map_err(std::io::Error::other)?;
    let listener = argo_projectiond::ipc_server::bind(&socket_path)?;
    let (state_tx, state_rx) = watch::channel(ProjectionRuntimeSnapshot::default());
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let control = argo_projectiond::host_control::HostControl::from_environment();
    if let Some(path) = &control.configuration.borrow().media_socket {
        argo_projectiond::daemon_log!(Info, "daemon", "configured video socket {}", path.display());
    }
    let ipc_control = control.clone();

    let ipc_task = tokio::spawn(async move {
        if let Err(error) = argo_projectiond::ipc_server::run(
            listener,
            socket_path,
            state_rx,
            shutdown_rx,
            ipc_control,
        )
        .await
        {
            argo_projectiond::daemon_log!(
                Error,
                "main",
                "argo-projectiond: IPC listener stopped: {error}"
            );
        }
    });

    #[cfg(all(feature = "linux-usb", target_os = "linux"))]
    let usb_task = {
        let shutdown = shutdown_tx.subscribe();
        tokio::spawn(async move {
            if let Err(error) =
                argo_projectiond::usb_runtime::run(state_tx, shutdown, control).await
            {
                argo_projectiond::daemon_log!(
                    Error,
                    "main",
                    "argo-projectiond: USB runtime stopped: {error}"
                );
            }
        })
    };

    #[cfg(not(all(feature = "linux-usb", target_os = "linux")))]
    {
        let _ = state_tx;
        argo_projectiond::daemon_log!(
            Warn,
            "main",
            "argo-projectiond: built without Linux USB support; rebuild with --features linux-usb"
        );
    }

    let signal_result = wait_for_shutdown().await;
    argo_projectiond::daemon_log!(Info, "main", "argo-projectiond: shutting down");
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
    argo_projectiond::daemon_log!(
        Error,
        "main",
        "argo-projectiond is currently supported only on Unix hosts"
    );
}
