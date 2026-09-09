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
    assert!(
        start
            .iter()
            .any(|effect| matches!(effect, Effect::Video(true)))
    );
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
    assert!(matches!(focus[2], Effect::HostReturn));
    for (message, body) in [
        (0x8002, vec![]),
        (0x8007, vec![]),
        (0x8007, Proto::default().number(2, 1).finish()),
    ] {
        assert!(
            !channels
                .handle(3, message, &body)
                .unwrap()
                .iter()
                .any(|e| matches!(e, Effect::HostReturn))
        );
    }
}
#[test]
fn repeated_phone_exit_requires_explicit_host_resume() {
    let mut channels = opened();
    channels
        .handle(3, 0x8000, &Proto::default().number(1, 3).finish())
        .unwrap();
    for cycle in 0..3 {
        let exit = channels
            .handle(3, 0x8007, &Proto::default().number(2, 2).finish())
            .unwrap();
        assert!(exit.iter().any(|e| matches!(e, Effect::HostReturn)));
        // A delayed start or phone re-request cannot override the user's Exit.
        let start = channels
            .handle(
                3,
                0x8001,
                &Proto::default().number(1, cycle + 1).number(2, 0).finish(),
            )
            .unwrap();
        assert!(
            start
                .iter()
                .any(|effect| matches!(effect, Effect::Video(false)))
        );
        let regain = channels
            .handle(3, 0x8007, &Proto::default().number(2, 1).finish())
            .unwrap();
        assert!(matches!(regain[1], Effect::Video(false)));
        let Effect::Reply(reply) = &regain[0] else {
            panic!("focus reply missing")
        };
        assert_eq!(numbers(&reply.body).unwrap().get(&1), Some(&2));
        // Home resumes the same channel/session; map dragging only emits input.
        channels.set_video_requested(true);
        let resumed = channels
            .handle(3, 0x8007, &Proto::default().number(2, 1).finish())
            .unwrap();
        assert!(matches!(resumed[1], Effect::Video(true)));
        for (phase, x) in [(0, 0.3), (1, 0.4), (1, 0.5), (2, 0.5)] {
            let touch = channels.touch(1, phase, x, 0.5, 100).unwrap().unwrap();
            assert_eq!((touch.channel, touch.id), (8, 0x8001));
        }
    }
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
fn android_touch_ids_stay_bounded_across_many_gestures_and_overlapping_contacts() {
    // Assert the actual input-channel wire message, including action index.
    fn expected(ids: &[u8], index: u64, action: u64) -> Vec<u8> {
        let mut touch = Proto::default();
        for id in ids {
            touch = touch.nested(
                1,
                Proto::default()
                    .number(1, 0)
                    .number(2, 0)
                    .number(3, u64::from(*id)),
            );
        }
        Proto::default()
            .number(1, 123)
            .nested(3, touch.number(2, index).number(3, action))
            .finish()
    }
    let mut channels = opened();
    for host in 32..=100 {
        for (phase, action) in [(0, 0), (1, 2), (2, 1)] {
            let event = channels.touch(host, phase, 0.0, 0.0, 123).unwrap().unwrap();
            assert_eq!((event.channel, event.id), (8, 0x8001));
            assert_eq!(event.body, expected(&[0], 0, action));
        }
    }
    // Host IDs differing by 32 must not collide. Insertion of a lower host ID
    // changes indices but must preserve the existing contact's Android ID.
    channels.touch(65535, 0, 0.0, 0.0, 123).unwrap();
    let second = channels.touch(65503, 0, 0.0, 0.0, 123).unwrap().unwrap();
    assert_eq!(second.body, expected(&[1, 0], 0, 5));
    let up = channels.touch(65535, 2, 0.0, 0.0, 123).unwrap().unwrap();
    assert_eq!(up.body, expected(&[1, 0], 1, 6));
    let replacement = channels.touch(60000, 0, 0.0, 0.0, 123).unwrap().unwrap();
    assert_eq!(replacement.body, expected(&[0, 1], 0, 5));
    let cancel = channels.touch(65503, 3, 0.0, 0.0, 123).unwrap().unwrap();
    assert_eq!(cancel.body, expected(&[0, 1], 1, 3));
    assert!(channels.touch(60000, 2, 0.0, 0.0, 123).unwrap().is_none());
    for host in 100..110 {
        assert!(channels.touch(host, 0, 0.0, 0.0, 123).unwrap().is_some());
    }
    assert!(channels.touch(110, 0, 0.0, 0.0, 123).unwrap().is_none());
    channels.touch(100, 3, 0.0, 0.0, 123).unwrap();
    assert_eq!(
        channels
            .touch(65535, 0, 0.0, 0.0, 123)
            .unwrap()
            .unwrap()
            .body,
        expected(&[0], 0, 0)
    );
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
    wireless: bool,
    tcp: Option<crate::tcp_transport::TcpAaTransport>,
    input: tokio::sync::mpsc::Receiver<Vec<u8>>,
    output: tokio::sync::mpsc::Sender<Vec<u8>>,
}
impl crate::session::AndroidAutoTransport for MemoryUsb {
    fn wireless(&self) -> bool {
        self.wireless
    }
    fn read<'a>(
        &'a mut self,
        buffer: &'a mut [u8],
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = std::io::Result<usize>> + Send + 'a>>
    {
        Box::pin(async move {
            if let Some(tcp) = &mut self.tcp {
                return tcp.read(buffer).await;
            }
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
            if let Some(tcp) = &mut self.tcp {
                return tcp.write_all(bytes).await;
            }
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
#[tokio::test(start_paused = true)]
async fn full_memory_wire_session_reaches_video_touch_and_graceful_disconnect() {
    exercise_live_session(0, Vec::new()).await;
}
#[tokio::test(start_paused = true)]
async fn wireless_silent_open_transport_reaches_typed_recovery() {
    exercise_live_session(1, Vec::new()).await;
}
#[tokio::test(start_paused = true)]
async fn wireless_hidden_heartbeat_only_survives_then_rejects_stale_activity() {
    exercise_live_session(2, Vec::new()).await;
}
#[tokio::test(start_paused = true)]
async fn wireless_cancellation_and_fresh_replacement() {
    let old_response = exercise_live_session(3, Vec::new()).await;
    exercise_live_session(2, old_response).await;
}
async fn exercise_live_session(mode: u8, old_response: Vec<u8>) -> Vec<u8> {
    crate::logging::init().unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(500), async {
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
        let (state, mut observed) = tokio::sync::watch::channel(initial);
        let (phone_tx, input) = tokio::sync::mpsc::channel::<Vec<u8>>(32);
        let (output, mut phone_rx) = tokio::sync::mpsc::channel(32);
        // A real admitted loopback TCP socket exercises successful kernel writes
        // while the phone application drains requests without answering them.
        let (tcp, input, output, bridge) = if mode == 1 {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let peer = tokio::net::TcpStream::connect(listener.local_addr().unwrap())
                .await
                .unwrap();
            peer.set_nodelay(true).unwrap();
            let (stream, _) = listener.accept().await.unwrap();
            let probe = socket2::SockRef::from(&stream).try_clone().unwrap();
            let transport = crate::tcp_transport::TcpAaTransport::admitted(stream).unwrap();
            assert!(probe.keepalive().unwrap());
            #[cfg(target_os = "linux")]
            assert_eq!(
                probe.tcp_user_timeout().unwrap(),
                Some(std::time::Duration::from_secs(15))
            );
            drop(probe);
            let (mut reader, mut writer) = peer.into_split();
            let mut to_peer = input;
            let from_peer = output;
            let bridge = tokio::spawn(async move {
                let tx = async {
                    while let Some(bytes) = to_peer.recv().await {
                        if writer.write_all(&bytes).await.is_err() {
                            break;
                        }
                    }
                };
                let rx = async {
                    loop {
                        let mut header = [0; 4];
                        if reader.read_exact(&mut header).await.is_err() {
                            break;
                        }
                        let extra = if header[1] & 3 == 1 { 4 } else { 0 };
                        let len = usize::from(u16::from_be_bytes([header[2], header[3]])) + extra;
                        let mut frame = header.to_vec();
                        frame.resize(4 + len, 0);
                        if reader.read_exact(&mut frame[4..]).await.is_err() {
                            break;
                        }
                        if from_peer.send(frame).await.is_err() {
                            break;
                        }
                    }
                };
                tokio::select! { _=tx=>{}, _=rx=>{} }
            });
            // Unused memory ends keep one fixture type for wired and TCP tests.
            let (_, dummy_input) = tokio::sync::mpsc::channel(1);
            let (dummy_output, _) = tokio::sync::mpsc::channel(1);
            (Some(transport), dummy_input, dummy_output, Some(bridge))
        } else {
            (None, input, output, None)
        };
        let engine_control = control.clone();
        let engine_id = id.clone();
        let (cancel, mut cancelled) = tokio::sync::watch::channel(false);
        let task = tokio::spawn(async move {
            let mut transport = MemoryUsb {
                input,
                output,
                tcp,
                wireless: mode != 0,
            };
            let mut media = crate::native_playback::SessionMedia::default();
            let ready = crate::readiness::Readiness::default();
            let session = crate::aa_session::run_with_tls_policy(
                &mut transport,
                engine_control,
                state,
                engine_id,
                &mut media,
                Some(&ready),
                AaTls::test_wireless,
            );
            let result = crate::wireless::run_until_end(&ready, &mut cancelled, session).await;
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
        // Home may activate a ready session before its first video descriptor.
        control
            .commands
            .send(crate::host_control::Command::Activate(id.clone()))
            .unwrap();
        assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 0x8008);
        phone_send(
            &mut phone,
            &phone_tx,
            3,
            0x8001,
            Proto::default().number(1, 1).number(2, 0).finish(),
        )
        .await;
        assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 0x8008);
        observed
            .wait_for(|s| s.video.as_ref().is_some_and(|(_, visible)| !visible))
            .await
            .unwrap();
        // A focus write/start indication alone must not expose cached video.
        phone_send(&mut phone, &phone_tx, 3, 1, vec![0, 0, 0, 1, 0x67, 1]).await;
        assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 0x8004);
        observed
            .wait_for(|s| {
                s.video.as_ref().is_some_and(|(_, visible)| *visible) && s.presentation_revision > 0
            })
            .await
            .unwrap();
        phone_send(
            &mut phone,
            &phone_tx,
            3,
            0x8007,
            Proto::default().number(2, 2).finish(),
        )
        .await;
        assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 0x8008);
        observed
            .wait_for(|s| s.host_return_revision == 1)
            .await
            .unwrap();
        assert_eq!(observed.borrow().session.as_ref().unwrap().id, id);
        if mode != 0 {
            use std::time::Duration;
            let mut stale = Vec::new();
            // Draining output without replying keeps writes successful while the
            // read future stays pending. No EOF is delivered to the engine.
            if mode == 2 {
                let healthy_start = tokio::time::Instant::now();
                for index in 0..170 {
                    let frame = phone_rx.recv().await.unwrap();
                    assert_eq!(&frame[4..6], &[0, 11]);
                    let mut response = frame[4..].to_vec();
                    response[1] = 12;
                    stale = response.clone();
                    if index % 2 == 0 {
                        phone_tx
                            .send(aa_wire::frame(0, 3, &response).unwrap())
                            .await
                            .unwrap();
                    } else {
                        phone_send(&mut phone, &phone_tx, 0, 12, response[2..].to_vec()).await;
                    }
                }
                assert!(healthy_start.elapsed() > Duration::from_secs(240));
                assert!(!task.is_finished());
                assert_eq!(observed.borrow().session.as_ref().unwrap().id, id);
                assert_eq!(
                    observed.borrow().session.as_ref().unwrap().state,
                    crate::daemon_state::ProjectionSessionStatus::Suspended
                );
            }
            if mode == 3 {
                let frame = phone_rx.recv().await.unwrap();
                let mut late_response = frame[4..].to_vec();
                late_response[1] = 12;
                cancel.send_replace(true);
                let error = task.await.unwrap().unwrap_err();
                assert_eq!(error.kind, crate::failure::Kind::Cancelled);
                assert!(!crate::wireless::retry_allowed(&error, true, 0));
                assert!(!path.exists());
                if let Some(bridge) = bridge {
                    bridge.await.unwrap();
                }
                return late_response;
            }
            // Ensure the last legitimate reply was consumed before starting the
            // measured silence. Replays, malformed protobuf, and unknown timestamps
            // subsequently exercise the actual plaintext/encrypted receive paths.
            for _ in 0..5 {
                tokio::task::yield_now().await;
            }
            let start = tokio::time::Instant::now();
            let drain = tokio::spawn(async move {
                let mut writes = 0;
                while let Some(frame) = phone_rx.recv().await {
                    assert_eq!(&frame[4..6], &[0, 11]);
                    writes += 1;
                    if mode == 2 {
                        for body in [
                            stale.clone(),
                            vec![0, 12, 8, 128],
                            vec![0, 12, 8, 0],
                            old_response.clone(),
                        ] {
                            if body.is_empty() {
                                continue;
                            }
                            if phone_tx
                                .send(aa_wire::frame(0, 3, &body).unwrap())
                                .await
                                .is_err()
                            {
                                break;
                            }
                        }
                        phone_send(
                            &mut phone,
                            &phone_tx,
                            0,
                            12,
                            Proto::default().number(1, 0).finish(),
                        )
                        .await;
                    }
                }
                // phone_tx remains alive until the engine has terminated.
                drop(phone_tx);
                writes
            });
            let error = task.await.unwrap().unwrap_err();
            let elapsed = start.elapsed();
            eprintln!("wireless liveness fixture mode={mode}: detection and fixture media cleanup at {elapsed:?}; typed retry eligible");
            assert_eq!(error.kind, crate::failure::Kind::TransportLoss);
            assert!(crate::wireless::retry_allowed(&error, false, 0));
            assert!(
                elapsed >= Duration::from_secs(9) && elapsed <= Duration::from_secs(10),
                "detection elapsed {elapsed:?}: {error}"
            );
            assert!(
                drain.await.unwrap() >= 5,
                "outgoing pings continued succeeding"
            );
            if let Some(bridge) = bridge {
                bridge.await.unwrap();
            }
            assert!(!path.exists(), "owned media socket cleaned");
            let mut stopped = cancel.subscribe();
            let stop = cancel.clone();
            let backoff =
                tokio::spawn(async move { crate::wireless::retry_backoff(&mut stopped, 1).await });
            tokio::task::yield_now().await;
            stop.send_replace(true);
            assert!(
                !backoff.await.unwrap(),
                "Disconnect must stop replacement during backoff"
            );
            return Vec::new();
        }
        // Entertainment selection is independent of focus/native-view ownership.
        let mut gate_ack = control.entertainment_ack.subscribe();
        control.entertainment.send_replace((1,false));
        gate_ack.wait_for(|revision|*revision==1).await.unwrap();
        assert_eq!(observed.borrow().session.as_ref().unwrap().id, id);
        control.entertainment.send_replace((2,true));
        gate_ack.wait_for(|revision|*revision==2).await.unwrap();
        tokio::time::advance(std::time::Duration::from_secs(240)).await;
        tokio::task::yield_now().await;
        assert!(
            !task.is_finished(),
            "suspended established session must survive setup deadline"
        );
        control
            .commands
            .send(crate::host_control::Command::Activate(id.clone()))
            .unwrap();
        assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 0x8008);
        phone_send(&mut phone, &phone_tx, 3, 1, vec![0, 0, 0, 1, 0x67, 2]).await;
        assert_eq!(phone_receive(&mut phone, &mut phone_rx).await.1, 0x8004);
        observed
            .wait_for(|s| {
                s.session.as_ref().is_some_and(|session| {
                    session.state == crate::daemon_state::ProjectionSessionStatus::Streaming
                })
            })
            .await
            .unwrap();
        assert_eq!(observed.borrow().session.as_ref().unwrap().id, id);
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
        Vec::new()
    })
    .await
    .expect("AA session fixture must complete within its bound")
}

#[test]
fn wireless_verifies_handshake_signature_separately_from_legacy_chain_policy() {
    let fixture = IdentityFixture::new();
    for corrupt in [false, true] {
        let mut phone = fixture.server();
        let mut hu = AaTls::test_wireless(&fixture.identity).unwrap();
        phone
            .read_tls(&mut Cursor::new(hu.pending().unwrap()))
            .unwrap();
        phone.process_new_packets().unwrap();
        let mut reply = Vec::new();
        while phone.wants_write() {
            phone.write_tls(&mut reply).unwrap();
        }
        let mut changed = false;
        let mut offset = 0;
        while offset + 5 <= reply.len() {
            let size = u16::from_be_bytes([reply[offset + 3], reply[offset + 4]]) as usize;
            let end = offset + 5 + size;
            let mut h = offset + 5;
            while h + 4 <= end && reply[offset] == 22 {
                let len = (usize::from(reply[h + 1]) << 16)
                    | (usize::from(reply[h + 2]) << 8)
                    | usize::from(reply[h + 3]);
                let next = h + 4 + len;
                if next > end {
                    break;
                }
                if reply[h] == 12 && corrupt {
                    reply[next - 1] ^= 1;
                    changed = true;
                }
                h = next;
            }
            offset = end;
        }
        if corrupt {
            assert!(changed);
            assert!(hu.receive(&reply).is_err());
        } else {
            assert!(hu.receive(&reply).is_ok());
        }
    }
}

#[tokio::test]
async fn actual_engine_io_failures_reach_retry_policy_without_text_matching() {
    use crate::{
        failure::{Failure, Kind},
        session::AndroidAutoTransport,
    };
    struct Broken(Option<std::io::ErrorKind>);
    impl AndroidAutoTransport for Broken {
        fn read<'a>(
            &'a mut self,
            _: &'a mut [u8],
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = std::io::Result<usize>> + Send + 'a>>
        {
            Box::pin(async move {
                match self.0 {
                    Some(kind) => Err(std::io::Error::new(kind, "arbitrary wording")),
                    None => Ok(0),
                }
            })
        }
        fn write_all<'a>(
            &'a mut self,
            _: &'a [u8],
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = std::io::Result<()>> + Send + 'a>>
        {
            Box::pin(async { Ok(()) })
        }
        fn close(
            &mut self,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = std::io::Result<()>> + Send + '_>>
        {
            Box::pin(async { Ok(()) })
        }
    }
    let fixture = IdentityFixture::new();
    for io in [
        None,
        Some(std::io::ErrorKind::ConnectionReset),
        Some(std::io::ErrorKind::PermissionDenied),
    ] {
        let control = crate::host_control::HostControl::default();
        control
            .configuration
            .send_modify(|c| c.identity = Some(fixture.identity.clone()));
        let (state, _) =
            tokio::sync::watch::channel(crate::daemon_state::ProjectionRuntimeSnapshot::default());
        let mut media = crate::native_playback::SessionMedia::default();
        let error = crate::aa_session::run(
            &mut Broken(io),
            control,
            state,
            "loss".into(),
            &mut media,
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(
            error.kind,
            if io == Some(std::io::ErrorKind::PermissionDenied) {
                Kind::Configuration
            } else {
                Kind::TransportLoss
            }
        );
        assert_eq!(
            crate::wireless::retry_allowed(&error, false, 0),
            io != Some(std::io::ErrorKind::PermissionDenied)
        );
        media.close().await;
    }
    let denied = Failure::from(bluer::Error {
        kind: bluer::ErrorKind::AuthenticationRejected,
        message: "different phone text".into(),
    });
    assert_eq!(denied.kind, Kind::Authorization);
    assert!(!crate::wireless::retry_allowed(&denied, false, 0));
    let network = crate::connectivity::network::active_state_ready(4).unwrap_err();
    assert!(crate::wireless::retry_allowed(&network, false, 0));
    let rejected_frame = crate::session::Frame {
        channel: 0,
        flags: 3,
        payload: vec![0, 2, 0, 1, 0, 1, 0, 1],
    };
    let rejected =
        Failure::from(crate::session::parse_version_response(&rejected_frame).unwrap_err());
    assert_eq!(rejected.kind, Kind::Protocol);
    assert!(!crate::wireless::retry_allowed(&rejected, false, 0));
}
