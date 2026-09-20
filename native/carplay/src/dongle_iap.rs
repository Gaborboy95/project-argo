//! Optional dongle-owned Bluetooth handoff (TCP 5004), distinct from VHCI.
//! Wire facts reviewed in pinned LIVI livi-dongle/src/iap.rs; no implementation
//! bodies imported. Opening this endpoint is an explicit transport acquisition.
use crate::link::{Error, LinkClient};
use std::time::Duration;
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    net::TcpStream,
    time::timeout,
};
pub const PORT: u16 = 5004;
// Deliberately no Debug: the peer address is not diagnostic telemetry.
pub struct Handoff {
    pub peer: [u8; 6],
    pub controller: [u8; 6],
    pub stream: TcpStream,
}
fn mac(text: &str) -> Result<[u8; 6], Error> {
    if text.len() != 17 {
        return Err(Error::Invalid("Bluetooth identity length"));
    }
    let mut output = [0; 6];
    let mut parts = text.split(':');
    for byte in &mut output {
        let part = parts.next().ok_or(Error::Invalid("Bluetooth identity"))?;
        if part.len() != 2 || !part.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(Error::Invalid("Bluetooth identity"));
        }
        *byte = u8::from_str_radix(part, 16).map_err(|_| Error::Invalid("Bluetooth identity"))?;
    }
    if parts.next().is_some() || output == [0; 6] || output == [255; 6] {
        return Err(Error::Invalid("Bluetooth identity"));
    }
    Ok(output)
}
async fn header<R: AsyncRead + Unpin>(stream: &mut R) -> Result<([u8; 6], [u8; 6]), Error> {
    let mut peer = None;
    let mut controller = None;
    for _ in 0..8 {
        let mut line = Vec::with_capacity(64);
        loop {
            let byte = stream.read_u8().await?;
            if byte == b'\n' {
                break;
            }
            if line.len() == 64 {
                return Err(Error::Invalid("Handoff line bounds"));
            }
            line.push(byte);
        }
        if line.is_empty() {
            return Ok((
                peer.ok_or(Error::Invalid("Missing peer"))?,
                controller.ok_or(Error::Invalid("Missing controller"))?,
            ));
        }
        let line = std::str::from_utf8(&line).map_err(|_| Error::Invalid("Handoff encoding"))?;
        if let Some(value) = line.strip_prefix("peer ") {
            if peer.is_some() {
                return Err(Error::Invalid("Duplicate peer"));
            }
            peer = Some(mac(value)?);
        } else if let Some(value) = line.strip_prefix("local ") {
            if controller.is_some() {
                return Err(Error::Invalid("Duplicate controller"));
            }
            controller = Some(mac(value)?);
        } else {
            return Err(Error::Invalid("Unknown handoff field"));
        }
    }
    Err(Error::Invalid("Handoff header bounds"))
}
/// Caller owns the entire returned stream and cancels by dropping this future.
/// Idle wait is finite; credentials, radio settings and firmware are untouched.
pub async fn acquire(link: &LinkClient, wait: Duration) -> Result<Handoff, Error> {
    if wait.is_zero() || wait > Duration::from_secs(120) {
        return Err(Error::Invalid("Handoff wait bounds"));
    }
    timeout(wait, async {
        let mut stream = link.connect(PORT).await?;
        stream.set_nodelay(true)?;
        let (peer, controller) = header(&mut stream).await?;
        Ok(Handoff {
            peer,
            controller,
            stream,
        })
    })
    .await
    .map_err(|_| Error::Timeout)?
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn header_preserves_first_iap_byte_and_rejects_ambiguous_identity() {
        let mut input = &b"peer 02:00:00:00:00:01\nlocal 02:00:00:00:00:02\n\n\xff\x5a"[..];
        let (peer, controller) = header(&mut input).await.unwrap();
        assert_eq!(peer, [2, 0, 0, 0, 0, 1]);
        assert_eq!(controller, [2, 0, 0, 0, 0, 2]);
        assert_eq!(input, &[255, 90]);
        for invalid in [
            &b"peer 02:00:00:00:00:01\npeer 02:00:00:00:00:02\n\n"[..],
            &b"local 02:00:00:00:00:02\n\n"[..],
            &b"peer anything\n\n"[..],
        ] {
            assert!(header(&mut &invalid[..]).await.is_err());
        }
        assert!(header(&mut &[b'x'; 65][..]).await.is_err());
    }
}
