//! Foreground entry point for the same wired runtime used by the daemon.
use argo_carplay::{
    link::{LinkClient, LinkConfig},
    wired_runtime,
};
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if unsafe { libc::geteuid() } == 0 {
        return Err("Run as the desktop user, not root".into());
    }
    let options = wired_runtime::parse_options(&std::env::args().skip(1).collect::<Vec<_>>())?;
    let directory = std::env::var_os("ARGO_CARPLAY_PAIRING_DIRECTORY")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap_or_default())
                .join("argo/carplay-pairing")
        });
    let (stop, receiver) = tokio::sync::watch::channel(false);
    let signal = tokio::spawn(async move {
        let _ = tokio::signal::ctrl_c().await;
        stop.send_replace(true);
    });
    let result = wired_runtime::run(
        options,
        directory,
        LinkClient::new(LinkConfig::default())?,
        receiver,
    )
    .await;
    signal.abort();
    result.map(|_| ())
}
