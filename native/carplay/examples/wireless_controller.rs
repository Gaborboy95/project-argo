//! Explicit controller lease diagnostic. Does not pair phones or enable an AP.
use argo_carplay::{
    hci,
    link::{LinkClient, LinkConfig},
    vhci,
};
use std::{
    io,
    os::unix::fs::{DirBuilderExt, MetadataExt},
    path::PathBuf,
    time::Duration,
};
use tokio::{net::TcpStream, sync::watch, time::timeout};
#[tokio::main]
async fn main() -> io::Result<()> {
    if std::env::args().nth(1).as_deref() != Some("--controller-only") {
        return Err(io::Error::other(
            "Use --controller-only to explicitly lease LIVI Link Bluetooth; this is not wireless CarPlay",
        ));
    }
    let uid = unsafe { libc::geteuid() };
    let path = PathBuf::from(format!("/run/user/{uid}/argo"));
    match std::fs::DirBuilder::new().mode(0o700).create(&path) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    let metadata = path.symlink_metadata()?;
    if !metadata.is_dir() || metadata.uid() != uid || metadata.mode() & 0o077 != 0 {
        return Err(io::Error::other("Unsafe runtime directory"));
    }
    let link = LinkClient::new(LinkConfig::default()).map_err(io::Error::other)?;
    let address = link.resolve().await.map_err(io::Error::other)?;
    let device = vhci::acquire().await?;
    let socket = timeout(
        Duration::from_secs(3),
        TcpStream::connect((address, hci::PORT)),
    )
    .await
    .map_err(io::Error::other)??;
    let (stop, stopping) = watch::channel(false);
    let (adapter, mut adapters) = watch::channel(None);
    let bridge = hci::bridge(device, socket, stopping, adapter);
    tokio::pin!(bridge);
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    loop {
        tokio::select! {
            result=&mut bridge=>return result,
            changed=adapters.changed()=>{changed.map_err(io::Error::other)?; if let Some(index)=*adapters.borrow_and_update() {eprintln!("LIVI Link controller registered as hci{index}; existing adapters unchanged");}},
            _=tokio::signal::ctrl_c()=>break,
            _=terminate.recv()=>break,
        }
    }
    stop.send_replace(true);
    timeout(Duration::from_secs(3), bridge)
        .await
        .map_err(io::Error::other)?
}
