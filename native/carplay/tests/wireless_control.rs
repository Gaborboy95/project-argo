//! Synthetic Bluetooth peer with an independent frame-level oracle. No radio,
//! phone, Wi-Fi settings or firmware are touched by these tests.
use argo_carplay::{
    discovery::Discovery,
    link::{LinkClient, LinkConfig},
    protocol::{csm, iap2, wired},
};
use std::{net::Ipv4Addr, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, DuplexStream, duplex},
    net::TcpListener,
    sync::watch,
    time::timeout,
};

fn configuration() -> wired::Configuration {
    wired::Configuration {
        identity: csm::AccessoryIdentity {
            name: "Argo fixture".into(),
            model: "Fixture".into(),
            manufacturer: "Argo".into(),
            serial: "synthetic".into(),
            firmware: "1".into(),
            hardware: "1".into(),
            language: "en".into(),
            usb_interface: 3,
        },
        start_session: csm::StartSession {
            transport: csm::SessionTransport::Wireless {
                address: "fe80::1234".parse().unwrap(),
                ssid: "Argo fixture".into(),
                passphrase: "synthetic-secret".into(),
                channel: 36,
                security: csm::WirelessSecurity::Wpa2,
            },
            port: 7000,
            device_identifier: "02:00:00:00:00:07".into(),
            public_key: [8; 32],
            source_version: "1.0".into(),
        },
    }
}

async fn read_frame(stream: &mut DuplexStream) -> iap2::Frame {
    let mut header = [0; 9];
    stream.read_exact(&mut header).await.unwrap();
    let size = usize::from(u16::from_be_bytes([header[2], header[3]]));
    assert!((9..=65535).contains(&size));
    let mut bytes = header.to_vec();
    bytes.resize(size, 0);
    stream.read_exact(&mut bytes[9..]).await.unwrap();
    iap2::Frame::decode(&bytes).unwrap()
}

struct Phone {
    stream: DuplexStream,
    sent: u8,
    received: u8,
    bytes: Vec<u8>,
}

impl Phone {
    async fn synchronize(mut stream: DuplexStream, window: u8, version: u8) -> Self {
        let mut marker = [0; 6];
        stream.read_exact(&mut marker).await.unwrap();
        assert_eq!(marker, [0xff, 0x55, 2, 0, 0xee, 0x10]);
        // Bluetooth is passive until the detection marker is echoed, unlike
        // the existing USB carkit stream's immediate zero-ACK negotiation.
        stream.write_all(&marker).await.unwrap();
        let hello = read_frame(&mut stream).await;
        assert_eq!(hello.flags, iap2::SYN);
        let sync = iap2::Synchronization::decode(&hello.payload).unwrap();
        assert_eq!(
            (sync.window, sync.retransmit_ms, sync.ack_ms, sync.retries),
            (4, 4000, 500, 4)
        );
        assert_eq!(
            sync.sessions,
            vec![iap2::Session {
                id: 10,
                kind: 0,
                version: 2
            }]
        );
        let peer = iap2::Synchronization {
            window,
            max_frame: 1024,
            retransmit_ms: 1000,
            ack_ms: 100,
            retries: 3,
            ack_count: 1,
            sessions: vec![iap2::Session {
                id: 10,
                kind: 0,
                version,
            }],
        };
        stream
            .write_all(
                &iap2::Frame {
                    flags: iap2::SYN | iap2::ACK,
                    sequence: 254,
                    acknowledgement: hello.sequence,
                    session: 0,
                    payload: peer.encode().unwrap(),
                }
                .encode()
                .unwrap(),
            )
            .await
            .unwrap();
        let ack = read_frame(&mut stream).await;
        assert_eq!(ack.flags, iap2::ACK);
        assert_eq!(ack.acknowledgement, 254);
        Self {
            stream,
            sent: 254,
            received: hello.sequence,
            bytes: Vec::new(),
        }
    }

    async fn send(&mut self, message: csm::Message) {
        self.sent = self.sent.wrapping_add(1);
        self.stream
            .write_all(
                &iap2::Frame {
                    flags: iap2::ACK,
                    sequence: self.sent,
                    acknowledgement: self.received,
                    session: 10,
                    payload: message.encode().unwrap(),
                }
                .encode()
                .unwrap(),
            )
            .await
            .unwrap();
    }

    async fn receive(&mut self) -> csm::Message {
        loop {
            if self.bytes.len() >= 6 {
                let size = usize::from(u16::from_be_bytes([self.bytes[2], self.bytes[3]]));
                if self.bytes.len() >= size {
                    let message = csm::Message::decode(&self.bytes[..size]).unwrap();
                    self.bytes.drain(..size);
                    return message;
                }
            }
            let frame = read_frame(&mut self.stream).await;
            if frame.payload.is_empty() {
                continue;
            }
            assert_eq!(frame.flags, iap2::ACK);
            assert_eq!(frame.session, 10);
            assert_eq!(frame.sequence, self.received.wrapping_add(1));
            self.received = frame.sequence;
            self.bytes.extend(frame.payload);
            self.stream
                .write_all(
                    &iap2::Frame {
                        flags: iap2::ACK,
                        sequence: self.sent,
                        acknowledgement: self.received,
                        session: 0,
                        payload: vec![],
                    }
                    .encode()
                    .unwrap(),
                )
                .await
                .unwrap();
        }
    }
}

#[tokio::test]
async fn reliable_bluetooth_authenticates_then_answers_wifi_and_starts_wireless() {
    complete_wireless_handshake(8, 2).await;
}

#[tokio::test]
async fn peer_control_version_one_and_full_sequence_window_can_start_wireless() {
    // The peer's incoming capabilities are independent of Argo's version-two
    // advertisement. The reliable link uses the full seven-bit sequence window.
    complete_wireless_handshake(127, 1).await;
}

struct RunningPeer {
    phone: Phone,
    cancel: watch::Sender<bool>,
    progress: watch::Receiver<wired::State>,
    driver: tokio::task::JoinHandle<Result<(), wired::Error>>,
    mfi: tokio::task::JoinHandle<()>,
}

async fn awaiting_authentication_result(window: u8, version: u8) -> RunningPeer {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let link = LinkClient::new(LinkConfig {
        discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
        mfi_port: listener.local_addr().unwrap().port(),
        ..LinkConfig::default()
    })
    .unwrap();
    let mfi = tokio::spawn(async move {
        let (mut remote, _) = listener.accept().await.unwrap();
        assert_eq!(remote.read_u8().await.unwrap(), 1);
        // A large certificate exercises fragmentation against the phone's
        // independently selected 1024-byte reliable frame limit.
        remote.write_all(&[0, 8, 0]).await.unwrap();
        remote.write_all(&vec![0x30; 2048]).await.unwrap();
        assert_eq!(remote.read_u8().await.unwrap(), 2);
        assert_eq!(remote.read_u16().await.unwrap(), 32);
        let mut challenge = [0; 32];
        remote.read_exact(&mut challenge).await.unwrap();
        assert_eq!(challenge, [6; 32]);
        remote.write_all(&[0, 0, 2, 9, 9]).await.unwrap();
    });
    let (host, phone) = duplex(65536);
    let (cancel, stop) = watch::channel(false);
    let (state, progress) = watch::channel(wired::State::Synchronizing);
    let driver = tokio::spawn(async move {
        wired::run_wireless(
            host,
            &link,
            configuration(),
            [2, 0, 0, 0, 0, 7],
            stop,
            state,
        )
        .await
    });
    let mut phone = Phone::synchronize(phone, window, version).await;
    phone
        .send(csm::Message::empty(csm::START_IDENTIFICATION))
        .await;
    let identity = phone.receive().await;
    assert_eq!(identity.id, csm::IDENTIFICATION);
    assert!(identity.one(16).is_err());
    assert!(identity.one(17).is_ok());
    assert!(identity.one(24).is_ok());
    phone
        .send(csm::Message::empty(csm::IDENTIFICATION_ACCEPTED))
        .await;
    phone
        .send(csm::Message::empty(csm::REQUEST_CERTIFICATE))
        .await;
    let cert = phone.receive().await;
    assert_eq!(cert.id, csm::CERTIFICATE);
    assert_eq!(cert.one(0).unwrap(), vec![0x30; 2048]);
    phone
        .send(csm::Message {
            id: csm::REQUEST_SIGNATURE,
            parameters: vec![csm::Parameter::new(0, [6; 32])],
        })
        .await;
    let signature = phone.receive().await;
    assert_eq!(signature.id, csm::SIGNATURE);
    assert_eq!(signature.one(0).unwrap(), [9, 9]);
    RunningPeer {
        phone,
        cancel,
        progress,
        driver,
        mfi,
    }
}

async fn authenticated(window: u8, version: u8) -> RunningPeer {
    let mut running = awaiting_authentication_result(window, version).await;
    running
        .phone
        .send(csm::Message::empty(csm::AUTH_SUCCEEDED))
        .await;
    running
        .progress
        .wait_for(|s| *s == wired::State::WaitingForAvailability)
        .await
        .unwrap();
    running
}

async fn complete_wireless_handshake(window: u8, version: u8) {
    timeout(Duration::from_secs(4), async {
        let RunningPeer {
            mut phone,
            cancel,
            mut progress,
            driver,
            mfi,
        } = authenticated(window, version).await;
        phone.send(csm::Message::empty(0x5702)).await;
        let wifi = phone.receive().await;
        assert_eq!(wifi.id, 0x5703);
        assert_eq!(wifi.one(3).unwrap(), [2]);
        assert_eq!(wifi.one(4).unwrap(), [36]);
        phone
            .send(csm::Message {
                id: 0x4300,
                parameters: vec![csm::Parameter::group(1, &[csm::Parameter::new(0, [1])]).unwrap()],
            })
            .await;
        let start = phone.receive().await;
        assert_eq!(start.id, 0x4301);
        assert!(start.one(0).is_err());
        let transport = csm::decode_parameters(start.one(1).unwrap()).unwrap();
        assert_eq!(
            transport.iter().find(|p| p.id == 3).unwrap().value,
            b"fe80::1234\0"
        );
        assert!(
            !transport.iter().any(|p| p.id == 4),
            "WPA2 StartSession must not contain WiFiConfiguration's enum2"
        );
        progress
            .wait_for(|s| *s == wired::State::StartSessionSent)
            .await
            .unwrap();
        // The Bluetooth control link remains alive during AirPlay and answers
        // subsequent credential requests instead of dropping after the handoff.
        phone.send(csm::Message::empty(0x5702)).await;
        assert_eq!(phone.receive().await.id, 0x5703);
        cancel.send_replace(true);
        assert!(matches!(
            driver.await.unwrap(),
            Err(wired::Error::Cancelled)
        ));
        assert_eq!(*progress.borrow(), wired::State::Closed);
        let mut rest = Vec::new();
        phone.stream.read_to_end(&mut rest).await.unwrap();
        mfi.await.unwrap();
    })
    .await
    .unwrap();
}

async fn cancelled(mut running: RunningPeer) {
    running.cancel.send_replace(true);
    assert!(matches!(
        running.driver.await.unwrap(),
        Err(wired::Error::Cancelled)
    ));
    assert_eq!(*running.progress.borrow(), wired::State::Closed);
    let mut rest = Vec::new();
    running.phone.stream.read_to_end(&mut rest).await.unwrap();
    running.mfi.await.unwrap();
}

#[tokio::test]
async fn a_phone_can_approve_carplay_after_thirty_one_seconds_then_receive_wifi_and_start() {
    // Keep real socket authentication outside the paused human-permission wait.
    // The original four-second fast-handshake bound must not cover this wait.
    let mut running = timeout(Duration::from_secs(4), authenticated(8, 2))
        .await
        .unwrap();
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(31)).await;
    assert!(
        !running.driver.is_finished(),
        "phone approval must outlive the old whole-session 30-second bound"
    );
    running
        .phone
        .send(csm::Message::empty(csm::REQUEST_WIFI_CONFIGURATION))
        .await;
    assert_eq!(running.phone.receive().await.id, csm::WIFI_CONFIGURATION);
    running
        .phone
        .send(csm::Message {
            id: csm::AVAILABILITY,
            parameters: vec![csm::Parameter::group(1, &[csm::Parameter::new(0, [1])]).unwrap()],
        })
        .await;
    assert_eq!(running.phone.receive().await.id, csm::START_SESSION);
    running
        .progress
        .wait_for(|s| *s == wired::State::StartSessionSent)
        .await
        .unwrap();
    cancelled(running).await;
}

#[tokio::test]
async fn post_authentication_availability_gets_its_own_ninety_second_bound() {
    let mut running = timeout(Duration::from_secs(4), awaiting_authentication_result(8, 2))
        .await
        .unwrap();
    tokio::time::pause();
    // Spend most of the separate authentication window first. It must not be
    // charged against the later user-approval deadline.
    tokio::time::advance(Duration::from_secs(10)).await;
    assert!(!running.driver.is_finished());
    running
        .phone
        .send(csm::Message::empty(csm::AUTH_SUCCEEDED))
        .await;
    running
        .progress
        .wait_for(|s| *s == wired::State::WaitingForAvailability)
        .await
        .unwrap();
    let started = tokio::time::Instant::now();
    tokio::time::advance(Duration::from_secs(89)).await;
    assert!(
        !running.driver.is_finished(),
        "authentication time must not shorten availability approval"
    );
    tokio::time::advance(Duration::from_secs(2)).await;
    assert!(matches!(
        running.driver.await.unwrap(),
        Err(wired::Error::Protocol(
            argo_carplay::protocol::Error::Timeout
        ))
    ));
    assert!(started.elapsed() >= Duration::from_secs(90));
    assert_eq!(*running.progress.borrow(), wired::State::Closed);
    let mut rest = Vec::new();
    running.phone.stream.read_to_end(&mut rest).await.unwrap();
    running.mfi.await.unwrap();
}

#[tokio::test]
async fn cancelling_during_human_approval_closes_the_owned_rfcomm_without_waiting_for_timeout() {
    let running = timeout(Duration::from_secs(4), authenticated(8, 2))
        .await
        .unwrap();
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(31)).await;
    assert!(!running.driver.is_finished());
    let started = tokio::time::Instant::now();
    cancelled(running).await;
    assert_eq!(started.elapsed(), Duration::ZERO);
}

#[tokio::test]
async fn an_authenticated_link_still_limits_an_unanswered_signature_result_to_fifteen_seconds() {
    let mut running = timeout(Duration::from_secs(4), awaiting_authentication_result(8, 2))
        .await
        .unwrap();
    tokio::time::pause();
    tokio::time::advance(Duration::from_secs(16)).await;
    assert!(matches!(
        running.driver.await.unwrap(),
        Err(wired::Error::Protocol(
            argo_carplay::protocol::Error::Timeout
        ))
    ));
    assert_eq!(*running.progress.borrow(), wired::State::Closed);
    let mut rest = Vec::new();
    running.phone.stream.read_to_end(&mut rest).await.unwrap();
    running.mfi.await.unwrap();
}

#[tokio::test]
async fn invalid_sequence_windows_and_unknown_control_versions_are_rejected() {
    for (window, version) in [(0, 1), (128, 1), (8, 0), (8, 3)] {
        timeout(Duration::from_secs(3), async {
            let link = LinkClient::new(LinkConfig {
                discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
                ..LinkConfig::default()
            })
            .unwrap();
            let (host, mut phone) = duplex(65536);
            let (_cancel, stop) = watch::channel(false);
            let (state, _) = watch::channel(wired::State::Synchronizing);
            let driver = tokio::spawn(async move {
                wired::run_wireless(
                    host,
                    &link,
                    configuration(),
                    [2, 0, 0, 0, 0, 7],
                    stop,
                    state,
                )
                .await
            });
            let mut marker = [0; 6];
            phone.read_exact(&mut marker).await.unwrap();
            phone.write_all(&marker).await.unwrap();
            let hello = read_frame(&mut phone).await;
            // Hand-encoded LSP deliberately bypasses the local valid-frame
            // builder, so this is an independent malformed peer on the wire.
            let payload = vec![1, window, 4, 0, 3, 232, 0, 100, 3, 1, 10, 0, version];
            phone
                .write_all(
                    &iap2::Frame {
                        flags: iap2::SYN | iap2::ACK,
                        sequence: 254,
                        acknowledgement: hello.sequence,
                        session: 0,
                        payload,
                    }
                    .encode()
                    .unwrap(),
                )
                .await
                .unwrap();
            assert!(matches!(
                driver.await.unwrap(),
                Err(wired::Error::Protocol(
                    argo_carplay::protocol::Error::Unsupported
                ))
            ));
            let mut remaining = Vec::new();
            phone.read_to_end(&mut remaining).await.unwrap();
        })
        .await
        .unwrap();
    }
}

#[tokio::test(start_paused = true)]
async fn silent_bluetooth_phone_expires_and_drops_the_owned_transport() {
    let link = LinkClient::new(LinkConfig {
        discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
        ..LinkConfig::default()
    })
    .unwrap();
    let (host, mut phone) = duplex(65536);
    let (_cancel, stop) = watch::channel(false);
    let (state, progress) = watch::channel(wired::State::Synchronizing);
    let driver = tokio::spawn(async move {
        wired::run_wireless(
            host,
            &link,
            configuration(),
            [2, 0, 0, 0, 0, 7],
            stop,
            state,
        )
        .await
    });
    tokio::task::yield_now().await;
    tokio::time::advance(Duration::from_secs(31)).await;
    assert!(matches!(
        driver.await.unwrap(),
        Err(wired::Error::Protocol(
            argo_carplay::protocol::Error::Timeout
        ))
    ));
    assert_eq!(*progress.borrow(), wired::State::Closed);
    let mut bytes = Vec::new();
    phone.read_to_end(&mut bytes).await.unwrap();
    assert!(bytes.starts_with(&iap2::DETECT));
}
