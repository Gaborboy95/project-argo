//! Argo-authored synthetic carkit and remote-coprocessor fixtures. These verify
//! wiring and teardown; they cannot establish real-phone/MFi acceptance.
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

fn config() -> wired::Configuration {
    wired::Configuration {
        identity: csm::AccessoryIdentity {
            name: "Argo synthetic".into(),
            model: "Fixture".into(),
            manufacturer: "Argo".into(),
            serial: "test-001".into(),
            firmware: "1".into(),
            hardware: "1".into(),
            language: "en".into(),
            usb_interface: 3,
        },
        start_session: csm::StartSession {
            transport: csm::SessionTransport::Wired {
                address: "fe80::1".parse().unwrap(),
            },
            port: 7000,
            device_identifier: "02:00:00:00:00:01".into(),
            public_key: [8; 32],
            source_version: "1.0".into(),
        },
    }
}

async fn read_frame(socket: &mut DuplexStream) -> iap2::Frame {
    let mut header = [0; 9];
    socket.read_exact(&mut header).await.unwrap();
    let length = u16::from_be_bytes([header[2], header[3]]) as usize;
    let mut bytes = header.to_vec();
    bytes.resize(length, 0);
    socket.read_exact(&mut bytes[9..]).await.unwrap();
    iap2::Frame::decode(&bytes).unwrap()
}

async fn synchronize(phone: &mut DuplexStream, separate_ack: bool) {
    let mut marker = [0; 6];
    phone.read_exact(&mut marker).await.unwrap();
    assert_eq!(marker, iap2::DETECT);
    let hello = read_frame(phone).await;
    let sync = iap2::Synchronization::decode(&hello.payload).unwrap();
    assert_eq!((sync.sessions[0].version, sync.retransmit_ms), (2, 0));
    if separate_ack {
        phone.write_all(&iap2::DETECT).await.unwrap();
    }
    phone
        .write_all(
            &iap2::Frame {
                flags: if separate_ack {
                    iap2::SYN
                } else {
                    iap2::SYN | iap2::ACK
                },
                sequence: 254,
                acknowledgement: hello.sequence,
                session: 0,
                payload: hello.payload,
            }
            .encode()
            .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(read_frame(phone).await.acknowledgement, 254);
    if separate_ack {
        phone
            .write_all(
                &iap2::Frame {
                    flags: iap2::ACK,
                    sequence: 254,
                    acknowledgement: hello.sequence,
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

async fn send(phone: &mut DuplexStream, sequence: u8, message: csm::Message) {
    let bytes = iap2::Frame {
        flags: iap2::ACK,
        sequence,
        acknowledgement: 31,
        session: iap2::CONTROL_SESSION,
        payload: message.encode().unwrap(),
    }
    .encode()
    .unwrap();
    phone.write_all(&bytes).await.unwrap();
}

#[tokio::test]
async fn real_link_client_drives_authentication_before_start_and_cancels_cleanly() {
    timeout(Duration::from_secs(3), async {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let link = LinkClient::new(LinkConfig {
            discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
            mfi_port: listener.local_addr().unwrap().port(),
            ..LinkConfig::default()
        })
        .unwrap();
        let mfi = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            assert_eq!(stream.read_u8().await.unwrap(), 1);
            stream.write_all(&[0, 0, 3, 0x30, 1, 0]).await.unwrap();
            assert_eq!(stream.read_u8().await.unwrap(), 2);
            assert_eq!(stream.read_u16().await.unwrap(), 32);
            let mut challenge = [0; 32];
            stream.read_exact(&mut challenge).await.unwrap();
            assert_eq!(challenge, [6; 32]);
            stream.write_all(&[0, 0, 2, 9, 9]).await.unwrap();
        });
        let (host, mut phone) = duplex(65536);
        let (cancel, cancel_rx) = watch::channel(false);
        let (state, mut state_rx) = watch::channel(wired::State::Synchronizing);
        let driver =
            tokio::spawn(async move { wired::run(host, &link, config(), cancel_rx, state).await });
        synchronize(&mut phone, false).await;
        send(
            &mut phone,
            255,
            csm::Message::empty(csm::START_IDENTIFICATION),
        )
        .await;
        assert_eq!(
            csm::Message::decode(&read_frame(&mut phone).await.payload)
                .unwrap()
                .id,
            csm::IDENTIFICATION
        );
        send(
            &mut phone,
            0,
            csm::Message::empty(csm::IDENTIFICATION_ACCEPTED),
        )
        .await;
        send(&mut phone, 1, csm::Message::empty(csm::REQUEST_CERTIFICATE)).await;
        let cert = csm::Message::decode(&read_frame(&mut phone).await.payload).unwrap();
        assert_eq!(cert.id, csm::CERTIFICATE);
        assert_eq!(cert.one(0).unwrap(), [0x30, 1, 0]);
        send(
            &mut phone,
            2,
            csm::Message {
                id: csm::REQUEST_SIGNATURE,
                parameters: vec![csm::Parameter::new(0, vec![6; 32])],
            },
        )
        .await;
        let signature = csm::Message::decode(&read_frame(&mut phone).await.payload).unwrap();
        assert_eq!(signature.id, csm::SIGNATURE);
        assert_eq!(signature.one(0).unwrap(), [9, 9]);
        send(&mut phone, 3, csm::Message::empty(csm::AUTH_SUCCEEDED)).await;
        send(
            &mut phone,
            4,
            csm::Message {
                id: csm::AVAILABILITY,
                parameters: vec![
                    csm::Parameter::group(0, &[csm::Parameter::new(0, vec![1])]).unwrap(),
                ],
            },
        )
        .await;
        assert_eq!(
            csm::Message::decode(&read_frame(&mut phone).await.payload)
                .unwrap()
                .id,
            csm::START_SESSION
        );
        state_rx
            .wait_for(|v| *v == wired::State::StartSessionSent)
            .await
            .unwrap();
        cancel.send(true).unwrap();
        assert!(matches!(
            driver.await.unwrap(),
            Err(wired::Error::Cancelled)
        ));
        assert_eq!(*state_rx.borrow(), wired::State::Closed);
        assert_eq!(phone.read(&mut [0]).await.unwrap(), 0);
        mfi.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test(start_paused = true)]
async fn synchronization_deadline_releases_owned_stream() {
    let link = LinkClient::new(LinkConfig {
        discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
        ..LinkConfig::default()
    })
    .unwrap();
    let (host, mut phone) = duplex(1024);
    let (_cancel, cancel_rx) = watch::channel(false);
    let (state, state_rx) = watch::channel(wired::State::Synchronizing);
    let driver =
        tokio::spawn(async move { wired::run(host, &link, config(), cancel_rx, state).await });
    tokio::task::yield_now().await;
    tokio::time::advance(Duration::from_secs(31)).await;
    assert!(matches!(
        driver.await.unwrap(),
        Err(wired::Error::Protocol(
            argo_carplay::protocol::Error::Timeout
        ))
    ));
    assert_eq!(*state_rx.borrow(), wired::State::Closed);
    let mut rest = Vec::new();
    phone.read_to_end(&mut rest).await.unwrap();
    assert!(rest.starts_with(&iap2::DETECT));
}

#[tokio::test]
async fn unplug_mid_header_closes_without_reconnect_or_mfi_request() {
    let link = LinkClient::new(LinkConfig {
        discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
        ..LinkConfig::default()
    })
    .unwrap();
    let (host, mut phone) = duplex(1024);
    let (_cancel, cancel_rx) = watch::channel(false);
    let (state, state_rx) = watch::channel(wired::State::Synchronizing);
    let driver =
        tokio::spawn(async move { wired::run(host, &link, config(), cancel_rx, state).await });
    phone.write_all(&[0xff, 0x5a, 0]).await.unwrap();
    drop(phone);
    assert!(matches!(driver.await.unwrap(), Err(wired::Error::Io(_))));
    assert_eq!(*state_rx.borrow(), wired::State::Closed);
}

#[tokio::test]
async fn detector_echo_and_separate_syn_then_ack_establish_control() {
    timeout(Duration::from_secs(2), async {
        let link = LinkClient::new(LinkConfig {
            discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
            ..LinkConfig::default()
        })
        .unwrap();
        let (host, mut phone) = duplex(65536);
        let (cancel, cancel_rx) = watch::channel(false);
        let (state, _) = watch::channel(wired::State::Synchronizing);
        let driver =
            tokio::spawn(async move { wired::run(host, &link, config(), cancel_rx, state).await });
        synchronize(&mut phone, true).await;
        send(
            &mut phone,
            255,
            csm::Message::empty(csm::START_IDENTIFICATION),
        )
        .await;
        assert_eq!(
            csm::Message::decode(&read_frame(&mut phone).await.payload)
                .unwrap()
                .id,
            csm::IDENTIFICATION
        );
        cancel.send(true).unwrap();
        assert!(matches!(
            driver.await.unwrap(),
            Err(wired::Error::Cancelled)
        ));
    })
    .await
    .unwrap();
}
