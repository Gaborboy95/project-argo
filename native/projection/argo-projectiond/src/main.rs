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
    let mut control = argo_projectiond::host_control::HostControl::from_environment();
    let (connectivity, requests) = argo_projectiond::connectivity::Control::new();
    control.connectivity = connectivity;
    let wireless_task = tokio::spawn(argo_projectiond::wireless::run(
        control.clone(),
        state_tx.clone(),
        requests,
        shutdown_tx.subscribe(),
    ));
    if let Some(path) = &control.configuration.borrow().media_socket {
        argo_projectiond::daemon_log!(Info, "daemon", "configured video socket {}", path.display());
    }
    let ipc_control = control.clone();
    let shutdown_control = control.clone();
    let (fatal_tx, mut fatal_rx) = tokio::sync::mpsc::channel::<String>(2);
    let ipc_fatal = fatal_tx.clone();

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
            let _ = ipc_fatal
                .send(format!("IPC listener stopped: {error}"))
                .await;
            return Err(error);
        }
        Ok::<_, std::io::Error>(())
    });

    #[cfg(all(feature = "linux-usb", target_os = "linux"))]
    let usb_task = {
        let shutdown = shutdown_tx.subscribe();
        let usb_fatal = fatal_tx.clone();
        tokio::spawn(async move {
            if let Err(error) =
                argo_projectiond::usb_runtime::run(state_tx, shutdown, control).await
            {
                let _ = usb_fatal
                    .send(format!("USB runtime stopped: {error}"))
                    .await;
                return Err(std::io::Error::other(error));
            }
            Ok::<_, std::io::Error>(())
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

    let signal_result = tokio::select! {
        result = wait_for_shutdown() => result,
        Some(error) = fatal_rx.recv() => {
            argo_projectiond::daemon_log!(Error, "main", "{error}; beginning owned shutdown");
            Err(std::io::Error::other(error))
        }
    };
    argo_projectiond::daemon_log!(Info, "main", "argo-projectiond: shutting down");
    let _ = shutdown_tx.send(true);
    let ipc_result = ipc_task.await;
    let wireless_result = wireless_task.await;
    #[cfg(all(feature = "linux-usb", target_os = "linux"))]
    let usb_result = usb_task.await;
    // Join all owned workers before reporting any error or acknowledging shutdown.
    let workers_joined = ipc_result.is_ok() && wireless_result.is_ok();
    #[cfg(all(feature = "linux-usb", target_os = "linux"))]
    let workers_joined = workers_joined && usb_result.is_ok();
    let cleanup_error = shutdown_control
        .connectivity
        .state
        .borrow()
        .cleanup_error
        .clone();
    let retained_guard = std::env::var_os("ARGO_MANAGED_RESULT").is_some_and(|path| {
        std::path::PathBuf::from(path)
            .with_file_name("firewall-owned.json")
            .exists()
    });
    if retained_guard
        || !workers_joined
        || !cleanup_error.is_empty()
        || shutdown_control.session_lease.is_closed()
        || shutdown_control.session_lease.available_permits() != 1
        || !shutdown_control.voice.state.borrow().owner.is_empty()
    {
        argo_projectiond::daemon_log!(
            Error,
            "main",
            "Owned cleanup unconfirmed: {cleanup_error}; automatic restart prohibited"
        );
        // All joins have completed. Do not create a replacement after uncertainty.
        std::process::exit(78);
    }
    if let Some(path) = std::env::var_os("ARGO_MANAGED_RESULT") {
        let path = std::path::PathBuf::from(path);
        let temporary = path.with_extension("json.new");
        let result = serde_json::json!({"result": "clean",
            "invocation": std::env::var("INVOCATION_ID").ok(),
            "release": std::env::var("ARGO_WIRELESS_BUNDLE").ok()});
        std::fs::write(&temporary, result.to_string())?;
        std::fs::rename(temporary, path)?;
    }
    argo_projectiond::daemon_log!(Info, "main", "Owned shutdown complete");
    ipc_result.map_err(std::io::Error::other)??;
    #[cfg(all(feature = "linux-usb", target_os = "linux"))]
    usb_result.map_err(std::io::Error::other)??;
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
