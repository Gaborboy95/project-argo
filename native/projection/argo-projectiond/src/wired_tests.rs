use crate::{
    aa_channels::{Channels, DisplayConfig, Effect, Proto, numbers},
    aa_tls::AaTls,
    aa_wire::{self, Messages, PacketDecoder},
    identity::AndroidAutoIdentity,
    native_playback::VideoFeed,
};
use std::{
    io::{Cursor, Read, Write},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};

struct IdentityFixture {
    root: PathBuf,
    identity: AndroidAutoIdentity,
}
impl IdentityFixture {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "argo-aa-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        let identity = AndroidAutoIdentity {
            certificate: root.join("cert.pem"),
            private_key: root.join("key.pem"),
        };
        let output = std::process::Command::new("openssl")
            .args([
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-sha256",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=Argo test identity",
                "-addext",
                "basicConstraints=critical,CA:FALSE",
                "-keyout",
            ])
            .arg(&identity.private_key)
            .arg("-out")
            .arg(&identity.certificate)
            .output()
            .expect("native TLS tests require openssl");
        assert!(
            output.status.success(),
            "openssl test identity generation failed"
        );
        Self { root, identity }
    }
    fn server(&self) -> rustls::ServerConnection {
        let cert = std::fs::read(&self.identity.certificate).unwrap();
        let key = std::fs::read(&self.identity.private_key).unwrap();
        let certs = rustls_pemfile::certs(&mut cert.as_slice())
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        let key = rustls_pemfile::private_key(&mut key.as_slice())
            .unwrap()
            .unwrap();
        let mut roots = rustls::RootCertStore::empty();
        roots.add(certs[0].clone()).unwrap();
        let verifier = rustls::server::WebPkiClientVerifier::builder_with_provider(
            Arc::new(roots),
            Arc::new(rustls::crypto::ring::default_provider()),
        )
        .build()
        .unwrap();
        let config = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_protocol_versions(&[&rustls::version::TLS12])
        .unwrap()
        .with_client_cert_verifier(verifier)
        .with_single_cert(certs, key)
        .unwrap();
        rustls::ServerConnection::new(Arc::new(config)).unwrap()
    }
}
impl Drop for IdentityFixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn argo_rsa_identity_tls12_memory_handshake_and_encrypted_exchange() {
    let fixture = IdentityFixture::new();
    let mut phone = fixture.server();
    let mut hu = AaTls::new(&fixture.identity).unwrap();
    assert!(hu.encrypt(b"premature discovery").is_err());
    for _ in 0..12 {
        let output = hu.pending().unwrap();
        if !output.is_empty() {
            phone.read_tls(&mut Cursor::new(output)).unwrap();
            phone.process_new_packets().unwrap();
        }
        let mut reply = Vec::new();
        while phone.wants_write() {
            phone.write_tls(&mut reply).unwrap();
        }
        if !reply.is_empty() {
            assert!(hu.receive(&reply).unwrap().is_empty());
        }
        if !hu.handshaking() && !phone.is_handshaking() {
            break;
        }
    }
    assert!(!hu.handshaking());
    assert!(!phone.is_handshaking());
    assert_eq!(phone.peer_certificates().unwrap().len(), 1);
    assert_eq!(
        phone.protocol_version(),
        Some(rustls::ProtocolVersion::TLSv1_2)
    );
    let encrypted = hu.encrypt(&[0, 6, 8, 1]).unwrap();
    phone.read_tls(&mut Cursor::new(encrypted)).unwrap();
    phone.process_new_packets().unwrap();
    let mut bytes = [0; 4];
    phone.reader().read_exact(&mut bytes).unwrap();
    assert_eq!(bytes, [0, 6, 8, 1]);
    phone.writer().write_all(&[0, 5]).unwrap();
    let mut reply = Vec::new();
    phone.write_tls(&mut reply).unwrap();
    assert_eq!(hu.receive(&reply).unwrap(), vec![0, 5]);
    // A replug is a new TLS connection, not a resumed old channel/session.
    let fresh = AaTls::new(&fixture.identity).unwrap();
    assert!(fresh.handshaking());
}

#[test]
fn malformed_tls_and_identity_fail_without_application_data() {
    let fixture = IdentityFixture::new();
    let mut tls = AaTls::new(&fixture.identity).unwrap();
    assert!(tls.receive(&[0xff, 0, 0, 0, 1, 0]).is_err());
    assert!(tls.encrypt(b"discovery").is_err());
    std::fs::write(&fixture.identity.private_key, b"invalid key").unwrap();
    assert!(AaTls::new(&fixture.identity).is_err());
}

#[test]
fn fragmented_encrypted_frames_preserve_channels_and_reject_overflow() {
    let record = |byte: u8| vec![23, 3, 3, 0, 3, byte, byte, byte];
    let wire = aa_wire::encrypted_frames(3, false, &[record(4), record(5)].concat()).unwrap();
    let mut decoder = PacketDecoder::default();
    let mut messages = Messages::default();
    let mut result = None;
    for byte in &wire {
        decoder.push(&[*byte]).unwrap();
        while let Some(packet) = decoder.packet().unwrap() {
            result = messages
                .accept(packet.channel, packet.flags, packet.bytes[5..].to_vec())
                .unwrap();
        }
    }
    assert_eq!(result, Some(vec![4, 4, 4, 5, 5, 5]));
    assert!(decoder.disconnect().is_ok());
    decoder.push(&[0, 1, 0, 1, 0xff, 0xff, 0xff, 0xff]).unwrap();
    assert!(decoder.packet().is_err());
}

fn opened() -> Channels {
    let mut channels = Channels::new(DisplayConfig::default());
    channels.handle(0, 5, &[]).unwrap();
    for channel in [1, 3, 4, 5, 6, 8] {
        channels
            .handle(
                channel,
                7,
                &Proto::default()
                    .number(1, 0)
                    .number(2, channel as u64)
                    .finish(),
            )
            .unwrap();
    }
    channels
}
#[test]
fn discovery_video_setup_and_native_stream_lifecycle() {
    use crate::logging::Level;
    assert_eq!(Level::parse("info").unwrap(), Level::Info);
    assert_eq!(Level::parse("trace").unwrap(), Level::Trace);
    assert!(Level::parse("verbose").is_err());
    let mut channels = Channels::new(DisplayConfig::default());
    let effects = channels.handle(0, 5, &[]).unwrap();
    let Effect::Reply(reply) = &effects[0] else {
        panic!("no discovery")
    };
    assert_eq!(reply.id, 6);
    assert!(numbers(&reply.body).is_ok());
    let mut channels = opened();
    let setup = channels
        .handle(3, 0x8000, &Proto::default().number(1, 3).finish())
        .unwrap();
    let Effect::Reply(reply) = &setup[0] else {
        panic!("no setup")
    };
    assert_eq!(numbers(&reply.body).unwrap().get(&1), Some(&2));
    let start = channels
        .handle(
            3,
            0x8001,
            &Proto::default().number(1, 42).number(2, 0).finish(),
        )
        .unwrap();
    assert!(matches!(start[0], Effect::Video(true)));
    let media = channels.handle(3, 1, &[0, 0, 0, 1, 0x67, 1]).unwrap();
    assert!(matches!(media[0], Effect::Media(3, _)));
    let Effect::Reply(ack) = &media[1] else {
        panic!("no ack")
    };
    assert_eq!(numbers(&ack.body).unwrap().get(&1), Some(&42));
    let focus = channels
        .handle(3, 0x8007, &Proto::default().number(2, 2).finish())
        .unwrap();
    assert!(matches!(focus[1], Effect::Video(false)));
}
#[test]
fn touch_uses_negotiated_pixels_and_tracks_pointer_lifecycle() {
    let mut channels = opened();
    let touch = channels.touch(9, 0, 0.5, 0.5, 123).unwrap().unwrap();
    assert_eq!(touch.channel, 8);
    assert_eq!(touch.id, 0x8001);
    assert_eq!(numbers(&touch.body).unwrap().get(&1), Some(&123));
    assert!(channels.touch(9, 1, f32::NAN, 0.5, 124).is_err());
    assert!(channels.touch(9, 2, 0.5, 0.5, 125).unwrap().is_some());
    assert!(channels.touch(9, 1, 0.5, 0.5, 126).unwrap().is_none());
    channels.touch(9, 0, 0.5, 0.5, 127).unwrap();
    channels.touch(10, 0, 0.5, 0.5, 128).unwrap();
    channels.touch(9, 3, 0.5, 0.5, 129).unwrap();
    assert!(channels.touch(10, 2, 0.5, 0.5, 130).unwrap().is_none());
    assert!(channels.touch(9, 0, 0.5, 0.5, 131).unwrap().is_some());
    channels.touch(10, 0, 0.5, 0.5, 132).unwrap();
    channels.touch(9, 2, 0.5, 0.5, 133).unwrap();
    assert!(channels.touch(10, 2, 0.5, 0.5, 134).unwrap().is_some());
}
#[test]
fn audio_roles_start_stop_ack_and_fresh_session_are_independent() {
    let mut channels = opened();
    for channel in 4..=6 {
        assert!(channels.handle(channel, 0x8000, &[]).is_err());
        channels
            .handle(channel, 0x8000, &Proto::default().number(1, 1).finish())
            .unwrap();
        let start = channels
            .handle(
                channel,
                0x8001,
                &Proto::default().number(1, 7).number(2, 0).finish(),
            )
            .unwrap();
        assert!(matches!(start[0],Effect::Audio(c,true) if c==channel));
        assert!(
            matches!(channels.handle(channel,1,&[0,0]).unwrap()[0],Effect::Media(c,_) if c==channel)
        );
        assert!(
            matches!(channels.handle(channel,0x8002,&[]).unwrap()[0],Effect::Audio(c,false) if c==channel)
        );
        assert!(channels.handle(channel, 1, &[0, 0]).is_err());
    }
    let mut fresh = Channels::new(DisplayConfig::default());
    assert!(fresh.handle(4, 1, &[0, 0]).is_err());
}
#[tokio::test]
async fn native_feed_disconnect_recreation_has_no_stale_session_bytes() {
    use tokio::io::AsyncReadExt;
    let fixture = IdentityFixture::new();
    let path = fixture.root.join("video.sock");
    let feed = VideoFeed::open(path.clone()).unwrap();
    let mut client = tokio::net::UnixStream::connect(&path).await.unwrap();
    tokio::task::yield_now().await;
    feed.push(vec![0, 0, 0, 1, 0x67, 2]).unwrap();
    let mut bytes = [0; 6];
    tokio::time::timeout(
        std::time::Duration::from_secs(1),
        client.read_exact(&mut bytes),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(bytes, [0, 0, 0, 1, 0x67, 2]);
    drop(feed);
    assert!(!path.exists());
    let fresh = VideoFeed::open(path.clone()).unwrap();
    drop(fresh);
    assert!(!path.exists());
}

// Runs the actual post-version engine, not a second test-only implementation.
struct MemoryUsb {
    input: tokio::sync::mpsc::Receiver<Vec<u8>>,
    output: tokio::sync::mpsc::Sender<Vec<u8>>,
}
impl crate::session::AndroidAutoTransport for MemoryUsb {
    fn read<'a>(
        &'a mut self,
        buffer: &'a mut [u8],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = std::io::Result<usize>> + Send + 'a>>
    {
        Box::pin(async move {
            let Some(bytes) = self.input.recv().await else {
                return Ok(0);
            };
            assert!(bytes.len() <= buffer.len());
            buffer[..bytes.len()].copy_from_slice(&bytes);
            Ok(bytes.len())
        })
    }
    fn write_all<'a>(
        &'a mut self,
        bytes: &'a [u8],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = std::io::Result<()>> + Send + 'a>> {
        Box::pin(async move {
            self.output
                .send(bytes.to_vec())
                .await
                .map_err(|_| std::io::ErrorKind::BrokenPipe.into())
        })
    }
    fn close(
        &mut self,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = std::io::Result<()>> + Send + '_>> {
        Box::pin(async { Ok(()) })
    }
}
async fn phone_send(
    phone: &mut rustls::ServerConnection,
    tx: &tokio::sync::mpsc::Sender<Vec<u8>>,
    channel: u8,
    id: u16,
    body: Vec<u8>,
) {
    phone.writer().write_all(&id.to_be_bytes()).unwrap();
    phone.writer().write_all(&body).unwrap();
    let mut wire = Vec::new();
    while phone.wants_write() {
        phone.write_tls(&mut wire).unwrap();
    }
    tx.send(aa_wire::encrypted_frames(channel, false, &wire).unwrap())
        .await
        .unwrap();
}
async fn phone_receive(
    phone: &mut rustls::ServerConnection,
    rx: &mut tokio::sync::mpsc::Receiver<Vec<u8>>,
) -> (u8, u16, Vec<u8>) {
    let mut decoder = PacketDecoder::default();
    let mut messages = Messages::default();
    loop {
        let wire = rx.recv().await.expect("head unit disconnected early");
        decoder.push(&wire).unwrap();
        while let Some(packet) = decoder.packet().unwrap() {
            if packet.flags & 8 == 0 {
                // The working session sends routine ping requests in plaintext.
                assert_eq!(packet.channel, 0);
                assert_eq!(&packet.bytes[..2], &[0, 11]);
                continue;
            }
            phone.read_tls(&mut Cursor::new(packet.bytes)).unwrap();
            phone.process_new_packets().unwrap();
            let mut plain = Vec::new();
            let _ = phone.reader().read_to_end(&mut plain);
            if let Some(body) = messages
                .accept(packet.channel, packet.flags, plain)
                .unwrap()
            {
                return (
                    packet.channel,
                    u16::from_be_bytes([body[0], body[1]]),
                    body[2..].to_vec(),
                );
            }
        }
    }
}
#[tokio::test]
async fn full_memory_wire_session_reaches_video_touch_and_graceful_disconnect() {
    crate::logging::init().unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        let fixture = IdentityFixture::new();
        let mut phone = fixture.server();
        let control = crate::host_control::HostControl::default();
        let path = fixture.root.join("live-video.sock");
        control
            .configuration
            .send_replace(crate::host_control::SessionConfig {
                active: None,
                display: DisplayConfig::default(),
                identity: Some(fixture.identity.clone()),
                media_socket: Some(path.clone()),
            });
        let initial = crate::daemon_state::ProjectionRuntimeSnapshot::connecting(
            "fake-phone".into(),
            "Android phone".into(),
        );
        let id = initial.session.as_ref().unwrap().id.clone();
        let (state, _) = tokio::sync::watch::channel(initial);
        let (phone_tx, input) = tokio::sync::mpsc::channel(32);
        let (output, mut phone_rx) = tokio::sync::mpsc::channel(32);
        let engine_control = control.clone();
        let engine_id = id.clone();
        let task = tokio::spawn(async move {
            let mut transport = MemoryUsb { input, output };
            let mut media = crate::native_playback::SessionMedia::default();
            let result = crate::aa_session::run(
                &mut transport,
                engine_control,
                state,
                engine_id,
                &mut media,
            )
            .await;
            media.close().await;
            result
        });
        // Transport SSL_HANDSHAKE wrappers carry the in-memory mutual TLS.
        while phone.is_handshaking() {
            let bytes = phone_rx.recv().await.unwrap();
            let mut decoder = PacketDecoder::default();
            decoder.push(&bytes).unwrap();
            let packet = decoder.packet().unwrap().unwrap();
            assert!(packet.bytes.starts_with(&[0, 3]));
            phone
                .read_tls(&mut Cursor::new(&packet.bytes[2..]))
                .unwrap();
            phone.process_new_packets().unwrap();
            let mut reply = vec![0, 3];
            while phone.wants_write() {
                phone.write_tls(&mut reply).unwrap();
            }
            if reply.len() > 2 {
                phone_tx
                    .send(aa_wire::frame(0, 3, &reply).unwrap())
                    .await
                    .unwrap();
            }
        }
        let auth = phone_rx.recv().await.unwrap();
        assert_eq!(&auth[4..], [0, 4, 8, 0]);
        phone_send(&mut phone, &phone_tx, 0, 5, vec![]).await;
        assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 6);
        for channel in [3, 8] {
            phone_send(
                &mut phone,
                &phone_tx,
                channel,
                7,
                Proto::default()
                    .number(1, 0)
                    .number(2, channel as u64)
                    .finish(),
            )
            .await;
            assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 8);
        }
        phone_send(
            &mut phone,
            &phone_tx,
            3,
            0x8000,
            Proto::default().number(1, 3).finish(),
        )
        .await;
        assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 0x8003);
        phone_send(
            &mut phone,
            &phone_tx,
            3,
            0x8001,
            Proto::default().number(1, 1).number(2, 0).finish(),
        )
        .await;
        assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 0x8008);
        control
            .commands
            .send(crate::host_control::Command::Touch(id, 1, 0, 0.5, 0.5))
            .unwrap();
        let (channel, message, _) = phone_receive(&mut phone, &mut phone_rx).await;
        assert_eq!((channel, message), (8, 0x8001));
        phone_send(
            &mut phone,
            &phone_tx,
            0,
            15,
            Proto::default().number(1, 1).finish(),
        )
        .await;
        assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 16);
        assert!(task.await.unwrap().is_ok());
        assert!(!path.exists());
    })
    .await
    .expect("memory AA session must complete within its bound");
}
