//! Optional BlueZ 5.82 experimental BIP artwork. No audio/profile registration.
use crate::artwork::{self, Image};
use std::{collections::HashMap, io::Read, sync::Arc, time::Duration};
use tokio::task::JoinHandle;
use zbus::{
    Connection, Proxy,
    zvariant::{OwnedObjectPath, OwnedValue},
};
#[derive(Default)]
pub struct Cover {
    key: String,
    job: Option<JoinHandle<Result<Arc<Image>, String>>>,
    pub image: Option<Arc<Image>>,
    pub status: String,
}
impl Drop for Cover {
    fn drop(&mut self) {
        if let Some(job) = self.job.take() {
            job.abort();
        }
    }
}
impl Cover {
    pub async fn update(&mut self, key: String, player: String, local: String, remote: String) {
        if self.key != key {
            if let Some(job) = self.job.take() {
                job.abort();
                let _ = job.await;
            }
            self.key = key;
            self.image = None;
            self.status = "Loading artwork".into();
            self.job = Some(tokio::spawn(async move {
                tokio::time::timeout(Duration::from_secs(12), fetch(&player, &local, &remote))
                    .await
                    .map_err(|_| "Bluetooth artwork timed out".to_string())?
            }));
        }
        if self.job.as_ref().is_some_and(|j| j.is_finished())
            && let Some(job) = self.job.take()
        {
            match job.await {
                Ok(Ok(image)) => {
                    self.image = Some(image);
                    self.status = "Artwork available".into();
                }
                Ok(Err(error)) => self.status = error,
                Err(_) => self.status = "Artwork cancelled".into(),
            }
        }
    }
}
struct Download(std::path::PathBuf);
impl Drop for Download {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
async fn fetch(player: &str, local: &str, remote: &str) -> Result<Arc<Image>, String> {
    let system = Connection::system().await.map_err(|e| e.to_string())?;
    let player = Proxy::new(&system, "org.bluez", player, "org.bluez.MediaPlayer1")
        .await
        .map_err(|e| e.to_string())?;
    let psm = player.get_property::<u16>("ObexPort").await.map_err(|_| {
        "Bluetooth artwork unavailable: phone/BlueZ exposes no experimental ObexPort".to_string()
    })?;
    if psm == 0 {
        return Err("Phone artwork port unavailable".into());
    }
    // A private client connection scopes all remote session/transfer objects.
    // If a job is cancelled, dropping this connection revokes its OBEX owner.
    let bus = Connection::session().await.map_err(|e| e.to_string())?;
    let client = Proxy::new(
        &bus,
        "org.bluez.obex",
        "/org/bluez/obex",
        "org.bluez.obex.Client1",
    )
    .await
    .map_err(|e| e.to_string())?;
    let args: HashMap<&str, OwnedValue> = HashMap::from([
        ("Target", zbus::zvariant::Str::from("bip-avrcp").into()),
        ("Source", zbus::zvariant::Str::from(local).into()),
        ("PSM", psm.into()),
    ]);
    let session: OwnedObjectPath = client
        .call("CreateSession", &(remote, args))
        .await
        .map_err(|_| "BlueZ BIP artwork connection unavailable".to_string())?;
    let result = async {
        // ImgHandle is valid only for this BIP connection. Never reuse one from
        // a previous track/session, and never treat it as a URL or filename.
        let handle = tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                let track = player
                    .get_property::<HashMap<String, OwnedValue>>("Track")
                    .await
                    .map_err(|e| e.to_string())?;
                if let Some(handle) = track
                    .get("ImgHandle")
                    .and_then(|v| <&str>::try_from(v).ok())
                    && handle.len() == 7
                    && handle.bytes().all(|b| b.is_ascii_digit())
                {
                    return Ok::<_, String>(handle.to_string());
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
        .await
        .map_err(|_| "Phone supplied no current artwork handle".to_string())??;
        let image = Proxy::new(
            &bus,
            "org.bluez.obex",
            session.as_str(),
            "org.bluez.obex.Image1",
        )
        .await
        .map_err(|e| e.to_string())?;
        // Random cache directory is private; a single job owns this download.
        let target =
            Download(artwork::directory()?.join(format!("bip-{}.download", artwork::random()?)));
        let (transfer, _): (OwnedObjectPath, HashMap<String, OwnedValue>) = image
            .call(
                "GetThumbnail",
                &(target.0.to_string_lossy().as_ref(), handle),
            )
            .await
            .map_err(|_| "BlueZ/phone does not provide BIP thumbnails".to_string())?;
        let transfer = Proxy::new(
            &bus,
            "org.bluez.obex",
            transfer.as_str(),
            "org.bluez.obex.Transfer1",
        )
        .await
        .map_err(|e| e.to_string())?;
        loop {
            if std::fs::metadata(&target.0).is_ok_and(|m| m.len() > artwork::MAX_BYTES as u64)
                || transfer.get_property::<u64>("Size").await.unwrap_or(0)
                    > artwork::MAX_BYTES as u64
            {
                let _ = transfer.call::<_, _, ()>("Cancel", &()).await;
                return Err("Bluetooth artwork exceeds 1 MiB".into());
            }
            match transfer
                .get_property::<String>("Status")
                .await
                .map_err(|e| e.to_string())?
                .as_str()
            {
                "complete" => break,
                "error" => return Err("Bluetooth artwork transfer failed".into()),
                _ => {}
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let mut bytes = Vec::new();
        std::fs::File::open(&target.0)
            .and_then(|f| {
                f.take(artwork::MAX_BYTES as u64 + 1)
                    .read_to_end(&mut bytes)
            })
            .map_err(|e| e.to_string())?;
        artwork::store(bytes)
    }
    .await;
    let _ = tokio::time::timeout(
        Duration::from_secs(2),
        client.call::<_, _, ()>("RemoveSession", &(session,)),
    )
    .await;
    result
}
