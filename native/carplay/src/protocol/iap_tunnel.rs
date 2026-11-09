// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE
//! Bounded incoming AirPlay iAP DataStream. Package layout follows LIVI
//! 34ae05e14df68f12d06cde0589f27d6d5b449ddb, `livi-cp/src/iap_tunnel.rs`.
//! The session owns this future; it spawns no detached connection tasks.

use super::{Error, pairing::ControlCipher};
use std::{net::SocketAddr, time::Duration};
use tokio::{
    io::AsyncReadExt,
    net::{TcpListener, TcpStream},
    sync::mpsc,
    time::timeout,
};

const HEADER: usize = 32;
const MAX_BODY: usize = 65_535;
const MAX_PACKAGE: usize = HEADER + MAX_BODY;
const MAX_PENDING: usize = 128 * 1024;
const MAX_CIPHER_PLAIN: usize = 16 * 1024;
const COMM: u32 = u32::from_be_bytes(*b"comm");

/// Fixed protocol stages only; diagnostics never contain peer or payload data.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Origin {
    Accept,
    Peer,
    FrameLength,
    FrameRead,
    CipherAuthentication,
    Package,
    RelayQueue,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Fault {
    pub origin: Origin,
    pub reason: Error,
}

impl Fault {
    fn new(origin: Origin, reason: Error) -> Self {
        Self { origin, reason }
    }
}

impl std::fmt::Display for Fault {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "CarPlay iAP {:?} {:?}", self.origin, self.reason)
    }
}
impl std::error::Error for Fault {}

/// Accept only the authenticated AirPlay peer and deliver its iAP link bytes.
/// The supplied key is derived from the negotiated DataStream seed and the
/// already verified AirPlay shared secret by the caller.
pub async fn run(
    listener: TcpListener,
    peer: SocketAddr,
    key: [u8; 32],
    incoming: mpsc::Sender<Vec<u8>>,
) -> Result<(), Error> {
    run_with_diagnostics(listener, peer, key, incoming)
        .await
        .map_err(|fault| fault.reason)
}

/// The compatibility `run` entry point discards these fixed stage diagnostics.
pub async fn run_with_diagnostics(
    listener: TcpListener,
    peer: SocketAddr,
    key: [u8; 32],
    incoming: mpsc::Sender<Vec<u8>>,
) -> Result<(), Fault> {
    let (socket, remote) = timeout(Duration::from_secs(15), listener.accept())
        .await
        .map_err(|_| Fault::new(Origin::Accept, Error::Timeout))?
        .map_err(|_| Fault::new(Origin::Accept, Error::Rejected))?;
    if remote.ip() != peer.ip() {
        return Err(Fault::new(Origin::Peer, Error::Rejected));
    }
    read(socket, key, incoming).await
}

async fn read(
    mut socket: TcpStream,
    key: [u8; 32],
    incoming: mpsc::Sender<Vec<u8>>,
) -> Result<(), Fault> {
    let mut cipher = ControlCipher::new(key);
    let mut pending = Vec::new();
    loop {
        // A clean EOF is valid only between complete encrypted frames/packages.
        let mut length = [0; 2];
        if socket
            .read(&mut length[..1])
            .await
            .map_err(|_| Fault::new(Origin::FrameRead, Error::Rejected))?
            == 0
        {
            return if pending.is_empty() {
                Ok(())
            } else {
                Err(Fault::new(Origin::Package, Error::Malformed))
            };
        }
        socket
            .read_exact(&mut length[1..])
            .await
            .map_err(|_| Fault::new(Origin::FrameRead, Error::Malformed))?;
        let size = usize::from(u16::from_le_bytes(length));
        if size > MAX_CIPHER_PLAIN {
            return Err(Fault::new(Origin::FrameLength, Error::Bounds));
        }
        let mut frame = vec![0; size + 18];
        frame[..2].copy_from_slice(&length);
        socket
            .read_exact(&mut frame[2..])
            .await
            .map_err(|_| Fault::new(Origin::FrameRead, Error::Malformed))?;
        let plain = cipher
            .decrypt(&frame)
            .map_err(|reason| Fault::new(Origin::CipherAuthentication, reason))?;
        if pending.len() + plain.len() > MAX_PENDING {
            return Err(Fault::new(Origin::Package, Error::Bounds));
        }
        pending.extend_from_slice(&plain);
        while let Some(package) =
            next_package(&mut pending).map_err(|reason| Fault::new(Origin::Package, reason))?
        {
            // Empty comm packages are valid tunnel keepalives; consume them
            // without passing an empty iAP chunk to the control-link parser.
            if package.message_type == COMM && !package.body.is_empty() {
                timeout(Duration::from_secs(3), incoming.send(package.body))
                    .await
                    .map_err(|_| Fault::new(Origin::RelayQueue, Error::Timeout))?
                    .map_err(|_| Fault::new(Origin::RelayQueue, Error::State))?;
            }
            // Like LIVI's incoming iAP tunnel, non-comm packages are ignored.
            // This direction does not emit sync acknowledgements or commands.
        }
    }
}

struct Package {
    message_type: u32,
    body: Vec<u8>,
}

fn next_package(pending: &mut Vec<u8>) -> Result<Option<Package>, Error> {
    if pending.len() < HEADER {
        return Ok(None);
    }
    let size = u32::from_be_bytes(pending[..4].try_into().unwrap()) as usize;
    if !(HEADER..=MAX_PACKAGE).contains(&size) {
        return Err(Error::Bounds);
    }
    if pending.len() < size {
        return Ok(None);
    }
    let message_type = u32::from_be_bytes(pending[16..20].try_into().unwrap());
    let body = pending[HEADER..size].to_vec();
    pending.drain(..size);
    Ok(Some(Package { message_type, body }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{io::AsyncWriteExt, task::JoinHandle};

    fn package(message_type: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut bytes = vec![0; HEADER];
        bytes[..4].copy_from_slice(&((HEADER + body.len()) as u32).to_be_bytes());
        bytes[4..8].copy_from_slice(b"asyn");
        bytes[16..20].copy_from_slice(message_type);
        bytes.extend_from_slice(body);
        bytes
    }

    async fn fixture() -> (
        TcpStream,
        mpsc::Receiver<Vec<u8>>,
        JoinHandle<Result<(), Error>>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (out, incoming) = mpsc::channel(16);
        let task = tokio::spawn(run(listener, "127.0.0.1:1".parse().unwrap(), [7; 32], out));
        let phone = TcpStream::connect(address).await.unwrap();
        (phone, incoming, task)
    }

    async fn diagnostic_fixture() -> (
        TcpStream,
        mpsc::Receiver<Vec<u8>>,
        JoinHandle<Result<(), Fault>>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (out, incoming) = mpsc::channel(16);
        let task = tokio::spawn(run_with_diagnostics(
            listener,
            "127.0.0.1:1".parse().unwrap(),
            [7; 32],
            out,
        ));
        let phone = TcpStream::connect(address).await.unwrap();
        (phone, incoming, task)
    }

    #[tokio::test]
    async fn an_empty_comm_package_keeps_the_link_and_cipher_counter_alive() {
        let (mut phone, mut incoming, task) = fixture().await;
        let mut cipher = ControlCipher::new([7; 32]);
        phone
            .write_all(&cipher.encrypt(&package(b"comm", &[])).unwrap())
            .await
            .unwrap();
        phone
            .write_all(
                &cipher
                    .encrypt(&package(b"comm", b"next iAP link bytes"))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(incoming.recv().await.unwrap(), b"next iAP link bytes");
        phone.shutdown().await.unwrap();
        assert_eq!(task.await.unwrap(), Ok(()));
        assert!(incoming.recv().await.is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn diagnostic_faults_identify_cipher_package_frame_and_queue_stages() {
        let (mut phone, mut incoming, task) = diagnostic_fixture().await;
        let mut frame = ControlCipher::new([7; 32])
            .encrypt(&package(b"comm", b"not delivered"))
            .unwrap();
        *frame.last_mut().unwrap() ^= 1;
        phone.write_all(&frame).await.unwrap();
        assert_eq!(
            task.await.unwrap().unwrap_err().origin,
            Origin::CipherAuthentication
        );
        assert!(incoming.recv().await.is_none());

        let (mut phone, mut incoming, task) = diagnostic_fixture().await;
        let mut header = vec![0; HEADER];
        header[..4].copy_from_slice(&31u32.to_be_bytes());
        phone
            .write_all(&ControlCipher::new([7; 32]).encrypt(&header).unwrap())
            .await
            .unwrap();
        assert_eq!(
            task.await.unwrap(),
            Err(Fault::new(Origin::Package, Error::Bounds))
        );
        assert!(incoming.recv().await.is_none());

        let (mut phone, mut incoming, task) = diagnostic_fixture().await;
        phone
            .write_all(&((MAX_CIPHER_PLAIN + 1) as u16).to_le_bytes())
            .await
            .unwrap();
        assert_eq!(
            task.await.unwrap(),
            Err(Fault::new(Origin::FrameLength, Error::Bounds))
        );
        assert!(incoming.recv().await.is_none());

        let (mut phone, mut incoming, task) = diagnostic_fixture().await;
        let mut cipher = ControlCipher::new([7; 32]);
        for _ in 0..17 {
            phone
                .write_all(&cipher.encrypt(&package(b"comm", &[1])).unwrap())
                .await
                .unwrap();
        }
        assert_eq!(
            task.await.unwrap(),
            Err(Fault::new(Origin::RelayQueue, Error::Timeout))
        );
        let mut delivered = 0;
        while incoming.recv().await.is_some() {
            delivered += 1;
        }
        assert_eq!(delivered, 16);
    }

    #[tokio::test]
    async fn real_tcp_fragmentation_coalescing_and_cipher_counters_preserve_link_bytes() {
        timeout(Duration::from_secs(3), async {
            let (mut phone, mut incoming, task) = fixture().await;
            let first = package(b"comm", &[0xff, 0x5a, 1, 2, 3]);
            let second = package(b"comm", &[4; 2048]);
            let ignored = package(b"cmnd", &[]);
            let all = [first, ignored, second].concat();
            // Empty authenticated frames advance the shared nonce counter.
            let mut wire = Vec::new();
            // Package boundaries intentionally differ from encrypted boundaries.
            for (counter, chunk) in std::iter::once([].as_slice())
                .chain(all.chunks(997))
                .enumerate()
            {
                let length = (chunk.len() as u16).to_le_bytes();
                let mut nonce = [0; 12];
                nonce[4..].copy_from_slice(&(counter as u64).to_le_bytes());
                wire.extend_from_slice(&length);
                wire.extend(super::super::pairing::seal(&[7; 32], &nonce, &length, chunk).unwrap());
            }
            for chunk in wire.chunks(13) {
                phone.write_all(chunk).await.unwrap();
            }
            assert_eq!(incoming.recv().await.unwrap(), [0xff, 0x5a, 1, 2, 3]);
            assert_eq!(incoming.recv().await.unwrap(), vec![4; 2048]);
            phone.shutdown().await.unwrap();
            assert_eq!(task.await.unwrap(), Ok(()));
            assert!(incoming.recv().await.is_none());
        })
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn authentication_failure_never_delivers_package_bytes() {
        let (mut phone, mut incoming, task) = fixture().await;
        let mut frame = ControlCipher::new([7; 32])
            .encrypt(&package(b"comm", b"secret"))
            .unwrap();
        *frame.last_mut().unwrap() ^= 1;
        phone.write_all(&frame).await.unwrap();
        assert!(task.await.unwrap().is_err());
        assert!(incoming.recv().await.is_none());
    }

    #[tokio::test]
    async fn the_largest_link_payload_is_bounded_and_reassembled() {
        let (mut phone, mut incoming, task) = fixture().await;
        let payload = vec![0x5a; MAX_BODY];
        let mut cipher = ControlCipher::new([7; 32]);
        for chunk in package(b"comm", &payload).chunks(MAX_CIPHER_PLAIN) {
            phone
                .write_all(&cipher.encrypt(chunk).unwrap())
                .await
                .unwrap();
        }
        assert_eq!(incoming.recv().await.unwrap(), payload);
        phone.shutdown().await.unwrap();
        assert_eq!(task.await.unwrap(), Ok(()));
    }

    #[tokio::test(start_paused = true)]
    async fn a_full_session_queue_expires_instead_of_growing() {
        let (mut phone, mut incoming, task) = fixture().await;
        let mut cipher = ControlCipher::new([7; 32]);
        for _ in 0..17 {
            phone
                .write_all(&cipher.encrypt(&package(b"comm", &[1])).unwrap())
                .await
                .unwrap();
        }
        assert_eq!(task.await.unwrap(), Err(Error::Timeout));
        let mut delivered = 0;
        while incoming.recv().await.is_some() {
            delivered += 1;
        }
        assert_eq!(delivered, 16);
    }

    #[tokio::test]
    async fn malformed_lengths_and_truncated_packages_fail_before_delivery() {
        {
            let length = MAX_CIPHER_PLAIN + 1;
            let (mut phone, mut incoming, task) = fixture().await;
            phone
                .write_all(&(length as u16).to_le_bytes())
                .await
                .unwrap();
            assert_eq!(task.await.unwrap(), Err(Error::Bounds));
            assert!(incoming.recv().await.is_none());
        }
        for size in [0, 31, MAX_PACKAGE + 1] {
            let (mut phone, mut incoming, task) = fixture().await;
            let mut header = vec![0; HEADER];
            header[..4].copy_from_slice(&(size as u32).to_be_bytes());
            phone
                .write_all(&ControlCipher::new([7; 32]).encrypt(&header).unwrap())
                .await
                .unwrap();
            assert_eq!(task.await.unwrap(), Err(Error::Bounds));
            assert!(incoming.recv().await.is_none());
        }
        let (mut phone, mut incoming, task) = fixture().await;
        let whole = package(b"comm", &[1; 32]);
        phone
            .write_all(&ControlCipher::new([7; 32]).encrypt(&whole[..40]).unwrap())
            .await
            .unwrap();
        phone.shutdown().await.unwrap();
        assert_eq!(task.await.unwrap(), Err(Error::Malformed));
        assert!(incoming.recv().await.is_none());
    }

    #[tokio::test]
    async fn a_foreign_peer_cannot_replace_the_authenticated_phone() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (out, mut incoming) = mpsc::channel(16);
        let task = tokio::spawn(run(listener, "127.0.0.2:1".parse().unwrap(), [7; 32], out));
        let _phone = TcpStream::connect(address).await.unwrap();
        assert_eq!(task.await.unwrap(), Err(Error::Rejected));
        assert!(incoming.recv().await.is_none());
    }

    #[tokio::test(start_paused = true)]
    async fn an_unused_listener_expires_without_an_unowned_task() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let (out, mut incoming) = mpsc::channel(16);
        assert_eq!(
            run(listener, "127.0.0.1:1".parse().unwrap(), [7; 32], out).await,
            Err(Error::Timeout)
        );
        assert!(incoming.recv().await.is_none());
    }
}
