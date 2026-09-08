//! Independently implemented WPP framing, separate from AA/USB framing.
//! Reference revisions and admission limitations: docs/wireless.md.
use crate::failure::{Failure, Kind};
use crate::{
    aa_channels::{Proto, numbers},
    connectivity::network::AccessPoint,
};
use std::{io, time::Duration};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    sync::watch,
};
const LIMIT: usize = 4096;
async fn send<S: AsyncWrite + Unpin>(s: &mut S, id: u16, body: &[u8]) -> Result<(), Failure> {
    if body.len() > LIMIT {
        return Err("WPP message exceeds bound".into());
    }
    let mut wire = Vec::with_capacity(body.len() + 4);
    wire.extend_from_slice(&(body.len() as u16).to_be_bytes());
    wire.extend_from_slice(&id.to_be_bytes());
    wire.extend_from_slice(body);
    tokio::time::timeout(Duration::from_secs(5), s.write_all(&wire))
        .await
        .map_err(|_| {
            Failure::from(io::Error::new(
                io::ErrorKind::TimedOut,
                "WPP write timed out",
            ))
        })?
        .map_err(Failure::from)
}
async fn receive<S: AsyncRead + Unpin>(s: &mut S) -> Result<(u16, Vec<u8>), Failure> {
    let mut h = [0; 4];
    s.read_exact(&mut h).await.map_err(read_error)?;
    let length = u16::from_be_bytes([h[0], h[1]]) as usize;
    if length > LIMIT {
        return Err("WPP frame exceeds bound".into());
    }
    let mut body = vec![0; length];
    s.read_exact(&mut body).await.map_err(read_error)?;
    Ok((u16::from_be_bytes([h[2], h[3]]), body))
}
fn read_error(e: io::Error) -> Failure {
    Failure::from(e)
}
fn success(body: &[u8], field: u32) -> Result<(), Failure> {
    let values = numbers(body)?;
    match values.get(&field) {
        Some(0) => Ok(()),
        Some(code) => Err(format!(
            "Phone wireless status {} ({})",
            *code as i64,
            status_label(*code as i64)
        )
        .into()),
        None => Err("Missing WPP status".into()),
    }
}
fn status_label(code: i64) -> &'static str {
    match code {
        0 => "success",
        1 => "unsolicited message",
        -1 => "no compatible version",
        -2 => "Wi-Fi channel inaccessible",
        -3 => "incorrect Wi-Fi credentials",
        -4 => "projection already started",
        -5 => "Wi-Fi disabled",
        -6 => "Wi-Fi not yet started",
        -7 => "invalid host endpoint",
        -8 => "no supported Wi-Fi channels",
        -9 => "check the phone for a prompt",
        -10 => "phone Wi-Fi disabled",
        -11 => "Wi-Fi network unavailable",
        _ => "unknown status",
    }
}
/// Only called on an authenticated, selected BlueZ profile connection, with a
/// ready AP and network-restricted listening socket already held by the owner.
pub async fn run<S: AsyncRead + AsyncWrite + Unpin>(
    socket: &mut S,
    ap: &AccessPoint,
    authorized: watch::Sender<bool>,
) -> Result<(), Failure> {
    crate::daemon_log!(
        Info,
        "wireless-bootstrap",
        "Authenticated RFCOMM accepted; sending WPP version offer"
    );
    let frequency = u64::from(ap.band.frequency(ap.channel));
    let mut packed = Vec::new();
    let mut n = frequency;
    while n >= 128 {
        packed.push(n as u8 | 128);
        n >>= 7;
    }
    packed.push(n as u8);
    send(
        socket,
        4,
        &Proto::default()
            .number(1, 6)
            .number(2, 0)
            .bytes(4, &packed)
            .finish(),
    )
    .await?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    let (id, body) = tokio::time::timeout(Duration::from_secs(10), receive(socket))
        .await
        .map_err(|_| Failure::timeout("WPP version timed out"))??;
    let version = numbers(&body)?;
    // Log only protocol scalars, never identity fields or raw payloads.
    crate::daemon_log!(
        Info,
        "wireless-bootstrap",
        "Version response message={id} major={:?} minor={:?} status={:?}",
        version.get(&1),
        version.get(&2),
        version.get(&4).map(|v| *v as i64)
    );
    if id != 5 || version.get(&1) != Some(&6) || version.get(&4) != Some(&0) {
        return Err(format!(
            "WPP version rejected: message={id}, major={:?}, minor={:?}, status={:?}",
            version.get(&1),
            version.get(&2),
            version.get(&4).map(|v| *v as i64)
        )
        .into());
    }
    crate::daemon_log!(
        Info,
        "wireless-bootstrap",
        "WPP version accepted; offering ready projection endpoint"
    );
    send(
        socket,
        1,
        &Proto::default()
            .bytes(1, ap.address.to_string().as_bytes())
            .number(2, 5288)
            .finish(),
    )
    .await?;
    let mut offered = false;
    let mut started = false;
    let mut messages = 0u32;
    loop {
        // After accepted startup, RFCOMM is independent of Wi-Fi transport.
        let frame = if *authorized.borrow() {
            tokio::time::timeout(Duration::from_secs(30), receive(socket))
                .await
                .map_err(|_| Failure::new(Kind::BootstrapClosed, "WPP idle timeout"))?
        } else {
            tokio::time::timeout_at(deadline, receive(socket))
                .await
                .map_err(|_| Failure::timeout("WPP join deadline expired"))?
        };
        let (id, body) = frame?;
        messages += 1;
        if !*authorized.borrow() && messages > 64 {
            return Err("WPP message budget exhausted".into());
        }
        match id {
            7 => {
                success(&body, 3).map_err(|e| format!("WPP StartResponse: {e}"))?;
                crate::daemon_log!(
                    Info,
                    "wireless-bootstrap",
                    "Phone accepted projection start"
                );
                started = true;
            }
            2 if !offered => {
                // Some phones request credentials before sending StartResponse.
                numbers(&body)?;
                send(
                    socket,
                    3,
                    &Proto::default()
                        .bytes(1, ap.ssid.as_bytes())
                        .bytes(2, ap.password.as_bytes())
                        .bytes(3, ap.bssid.as_bytes())
                        .number(4, 8)
                        .number(5, 1)
                        .finish(),
                )
                .await?;
                offered = true;
                crate::daemon_log!(
                    Info,
                    "wireless-bootstrap",
                    "Wi-Fi information delivered to authorized bootstrap peer"
                );
            }
            6 if offered && started => {
                success(&body, 1).map_err(|e| format!("WPP ConnectionStatus: {e}"))?;
                crate::daemon_log!(
                    Info,
                    "wireless-bootstrap",
                    "Phone reports successful AP association"
                );
            }
            8 => send(socket, 9, &body).await?,
            9 => {}
            _ => return Err(format!("Unexpected WPP message {id}").into()),
        }
        // Start acceptance plus credential delivery authorizes this bounded
        // development admission attempt. ConnectionStatus may be delayed until
        // AA begins, so it is telemetry/error reporting, not a prerequisite.
        if offered && started && !*authorized.borrow() {
            authorized.send_replace(true);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn split_and_coalesced_frames_and_oversize_rejection() {
        let (mut a, mut b) = tokio::io::duplex(128);
        let task = tokio::spawn(async move {
            a.write_all(&[0]).await.unwrap();
            tokio::task::yield_now().await;
            a.write_all(&[2, 0, 7, 24, 0, 0, 0, 0, 2, 0xff, 0xff, 0, 5])
                .await
                .unwrap();
        });
        assert_eq!(receive(&mut b).await.unwrap(), (7, vec![24, 0]));
        assert_eq!(receive(&mut b).await.unwrap(), (2, vec![]));
        assert!(receive(&mut b).await.unwrap_err().detail.contains("bound"));
        task.await.unwrap();
        assert!(success(&[], 3).is_err());
        assert!(success(&[24, 1], 3).is_err());
        assert!(success(&[24, 0], 3).is_ok());
    }
}

#[cfg(test)]
mod exchange_tests {
    use super::*;
    #[tokio::test]
    async fn version_offer_uses_selected_ap_frequency_in_both_bands() {
        use crate::connectivity::network::ApBand;
        for (band, channel, expected) in [
            (ApBand::Ghz2, 6, vec![8, 6, 16, 0, 34, 2, 0x85, 0x13]),
            (ApBand::Ghz5, 149, vec![8, 6, 16, 0, 34, 2, 0xf1, 0x2c]),
        ] {
            let mut ap = crate::connectivity::network::tests::ap();
            ap.band = band;
            ap.channel = channel;
            let (mut hu, mut phone) = tokio::io::duplex(8192);
            let (authorized, _) = watch::channel(false);
            let task = tokio::spawn(async move { run(&mut hu, &ap, authorized).await });
            assert_eq!(receive(&mut phone).await.unwrap(), (4, expected));
            drop(phone);
            assert!(task.await.unwrap().is_err());
        }
    }
    #[tokio::test(start_paused = true)]
    async fn version_deadline_and_real_exchange_keepalive_are_bounded() {
        let ap = crate::connectivity::network::tests::ap();
        let (mut hu, mut phone) = tokio::io::duplex(8192);
        let (authorized, rx) = watch::channel(false);
        let task = tokio::spawn(async move { run(&mut hu, &ap, authorized).await });
        assert_eq!(receive(&mut phone).await.unwrap().0, 4);
        send(
            &mut phone,
            5,
            &Proto::default()
                .number(1, 6)
                .number(2, 0)
                .number(4, 0)
                .finish(),
        )
        .await
        .unwrap();
        assert_eq!(receive(&mut phone).await.unwrap().0, 1);
        // Neither acceptance alone nor TCP presence authorizes an attempt.
        send(&mut phone, 7, &[24, 0]).await.unwrap();
        send(&mut phone, 8, &[8, 1]).await.unwrap();
        assert_eq!(receive(&mut phone).await.unwrap().0, 9);
        assert!(!*rx.borrow());
        send(&mut phone, 2, &[]).await.unwrap();
        let info = receive(&mut phone).await.unwrap();
        assert_eq!(info.0, 3);
        assert_eq!(numbers(&info.1).unwrap().get(&4), Some(&8));
        // A phone can omit ConnectionStatus until TCP AA begins. The accepted
        // authenticated bootstrap must already authorize TCP at this point.
        send(&mut phone, 8, &[8, 2]).await.unwrap();
        assert_eq!(receive(&mut phone).await.unwrap().0, 9);
        assert!(*rx.borrow());
        send(&mut phone, 6, &[8, 0]).await.unwrap();
        send(&mut phone, 8, &[8, 42]).await.unwrap();
        assert_eq!(receive(&mut phone).await.unwrap(), (9, vec![8, 42]));
        assert!(*rx.borrow());
        drop(phone);
        assert!(task.await.unwrap().is_err());
        assert!(*rx.borrow()); // RFCOMM EOF does not revoke accepted bootstrap.
        let ap = crate::connectivity::network::tests::ap();
        let (mut hu, _phone) = tokio::io::duplex(8192);
        let (authorized, _) = watch::channel(false);
        assert!(
            run(&mut hu, &ap, authorized)
                .await
                .unwrap_err()
                .detail
                .contains("version timed out")
        );
    }
}
