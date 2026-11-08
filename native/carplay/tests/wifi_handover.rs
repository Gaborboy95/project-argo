//! Synthetic recorded-AirPlay handover. Uses real LinkClient I/O and an
//! independent iAP frame oracle, without radios, a phone or an MFi coprocessor.
#![cfg(feature = "airplay")]

use argo_carplay::{
    discovery::Discovery,
    link::{LinkClient, LinkConfig},
    protocol::{csm, handover, iap2, now_playing, wired, wireless},
};
use std::{
    net::Ipv4Addr,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, duplex},
    net::TcpListener,
    sync::watch,
    time::timeout,
};

fn configuration() -> wired::Configuration {
    wired::Configuration {
        identity: csm::AccessoryIdentity {
            name: "Argo synthetic".into(),
            model: "Fixture".into(),
            manufacturer: "Argo".into(),
            serial: "handover-fixture".into(),
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

struct Phone {
    relay: handover::ReceiverSide,
    wire: Vec<u8>,
    csm: Vec<u8>,
    sent: u8,
    received: u8,
}
impl Phone {
    async fn take(&mut self, size: usize) -> Vec<u8> {
        while self.wire.len() < size {
            self.wire
                .extend(self.relay.outgoing.recv().await.expect("owned Wi-Fi relay"));
        }
        self.wire.drain(..size).collect()
    }
    async fn frame(&mut self) -> iap2::Frame {
        let header = self.take(9).await;
        let size = usize::from(u16::from_be_bytes([header[2], header[3]]));
        assert!((9..=65535).contains(&size));
        let bytes = [header, self.take(size - 9).await].concat();
        iap2::Frame::decode(&bytes).unwrap()
    }
    async fn synchronize(relay: handover::ReceiverSide) -> Self {
        let mut phone = Self {
            relay,
            wire: vec![],
            csm: vec![],
            sent: 254,
            received: 0,
        };
        assert_eq!(phone.take(6).await, iap2::DETECT);
        // A fresh IP link initiates zero-ACK negotiation without waiting for a
        // Bluetooth detection-marker echo.
        let hello = phone.frame().await;
        assert_eq!(hello.flags, iap2::SYN);
        let offered = iap2::Synchronization::decode(&hello.payload).unwrap();
        assert_eq!(
            (
                offered.window,
                offered.retransmit_ms,
                offered.ack_ms,
                offered.retries
            ),
            (4, 0, 0, 0)
        );
        assert!(
            offered
                .sessions
                .iter()
                .any(|session| session.id == 10 && session.kind == 0 && session.version == 2)
        );
        phone.received = hello.sequence;
        let peer = iap2::Synchronization {
            window: 4,
            max_frame: 1024,
            retransmit_ms: 0,
            ack_ms: 0,
            retries: 0,
            ack_count: 0,
            sessions: vec![iap2::Session {
                id: 10,
                kind: 0,
                version: 2,
            }],
        };
        phone
            .relay
            .deliver(
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
            .unwrap();
        let ack = phone.frame().await;
        assert_eq!(ack.flags, iap2::ACK);
        assert_eq!(ack.acknowledgement, 254);
        phone
    }
    async fn send(&mut self, message: csm::Message) {
        self.sent = self.sent.wrapping_add(1);
        let frame = iap2::Frame {
            flags: iap2::ACK,
            sequence: self.sent,
            acknowledgement: self.received,
            session: 10,
            payload: message.encode().unwrap(),
        }
        .encode()
        .unwrap();
        self.relay.deliver(&frame).unwrap();
    }
    async fn receive(&mut self) -> csm::Message {
        loop {
            if self.csm.len() >= 6 {
                let size = usize::from(u16::from_be_bytes([self.csm[2], self.csm[3]]));
                if self.csm.len() >= size {
                    let message = csm::Message::decode(&self.csm[..size]).unwrap();
                    self.csm.drain(..size);
                    return message;
                }
            }
            let frame = self.frame().await;
            if frame.payload.is_empty() {
                continue;
            }
            assert_eq!(frame.session, 10);
            assert_eq!(frame.sequence, self.received.wrapping_add(1));
            self.received = frame.sequence;
            self.csm.extend(frame.payload);
        }
    }
}

fn title(value: &str) -> csm::Message {
    csm::Message {
        id: now_playing::UPDATE,
        parameters: vec![
            csm::Parameter::group(0, &[csm::Parameter::string(1, value).unwrap()]).unwrap(),
        ],
    }
}

#[tokio::test]
async fn recorded_airplay_authenticates_fresh_ip_iap_keeps_metadata_and_never_restarts_projection()
{
    timeout(Duration::from_secs(4), async {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let link = LinkClient::new(LinkConfig {
            discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
            mfi_port: listener.local_addr().unwrap().port(),
            ..LinkConfig::default()
        })
        .unwrap();
        let mfi = tokio::spawn(async move {
            let (mut service, _) = listener.accept().await.unwrap();
            assert_eq!(service.read_u8().await.unwrap(), 1);
            service.write_all(&[0, 0, 3, 0x30, 1, 0]).await.unwrap();
            assert_eq!(service.read_u8().await.unwrap(), 2);
            assert_eq!(service.read_u16().await.unwrap(), 32);
            let mut challenge = [0; 32];
            service.read_exact(&mut challenge).await.unwrap();
            assert_eq!(challenge, [6; 32]);
            service.write_all(&[0, 0, 2, 9, 9]).await.unwrap();
        });
        let (host, mut bluetooth_phone) = duplex(65536);
        let (relay, control) = handover::channel([2, 0, 0, 0, 0, 1], [2, 0, 0, 0, 0, 7]);
        relay.recorded.send_replace(true);
        assert!(relay.request_disable("02:00:00:00:00:01"));
        let disconnected = Arc::new(AtomicBool::new(false));
        let dropped = disconnected.clone();
        let (cancel, stop) = watch::channel(false);
        let (state, _) = watch::channel(wired::State::StartSessionSent);
        let (metadata, mut observed) = watch::channel(now_playing::Metadata::default());
        let driver = tokio::spawn(async move {
            wireless::run_with_handover(
                host,
                &link,
                configuration(),
                [2, 0, 0, 0, 0, 7],
                stop,
                state,
                metadata,
                control,
                async move {
                    dropped.store(true, Ordering::SeqCst);
                    Ok(())
                },
            )
            .await
        });
        let mut phone = Phone::synchronize(relay).await;
        assert_eq!(
            bluetooth_phone.read(&mut [0; 1]).await.unwrap(),
            0,
            "selected BT stream must close without ending AirPlay"
        );
        assert!(disconnected.load(Ordering::SeqCst));
        phone
            .send(csm::Message::empty(csm::START_IDENTIFICATION))
            .await;
        let identity = phone.receive().await;
        assert_eq!(identity.id, csm::IDENTIFICATION);
        assert!(identity.one(17).is_ok());
        assert!(identity.one(24).is_ok());
        phone
            .send(csm::Message::empty(csm::IDENTIFICATION_ACCEPTED))
            .await;
        phone
            .send(csm::Message::empty(csm::REQUEST_CERTIFICATE))
            .await;
        let certificate = phone.receive().await;
        assert_eq!(certificate.id, csm::CERTIFICATE);
        assert_eq!(certificate.one(0).unwrap(), [0x30, 1, 0]);
        phone
            .send(csm::Message {
                id: csm::REQUEST_SIGNATURE,
                parameters: vec![csm::Parameter::new(0, [6; 32])],
            })
            .await;
        let signature = phone.receive().await;
        assert_eq!(signature.id, csm::SIGNATURE);
        assert_eq!(signature.one(0).unwrap(), [9, 9]);
        phone.send(csm::Message::empty(csm::AUTH_SUCCEEDED)).await;
        assert_eq!(phone.receive().await.id, now_playing::START);
        assert_eq!(phone.receive().await.id, now_playing::POWER_START);
        phone
            .send(title("Wi-Fi song after Bluetooth handover"))
            .await;
        phone
            .send(csm::Message {
                id: now_playing::POWER_UPDATE,
                parameters: vec![csm::Parameter::new(6, 73u16.to_be_bytes())],
            })
            .await;
        observed
            .wait_for(|metadata| {
                metadata.battery_percent == Some(73)
                    && metadata
                        .media
                        .as_ref()
                        .and_then(|media| media.title.as_deref())
                        == Some("Wi-Fi song after Bluetooth handover")
            })
            .await
            .unwrap();
        // Availability is still valid iAP traffic, but this link belongs to an
        // already-recorded AirPlay session and must not start another one.
        phone
            .send(csm::Message {
                id: csm::AVAILABILITY,
                parameters: vec![csm::Parameter::group(1, &[csm::Parameter::new(0, [1])]).unwrap()],
            })
            .await;
        phone
            .send(csm::Message::empty(csm::REQUEST_WIFI_CONFIGURATION))
            .await;
        // A metadata barrier proves the driver processed both preceding requests.
        phone.send(title("Retained recorded session")).await;
        observed
            .wait_for(|metadata| {
                metadata
                    .media
                    .as_ref()
                    .and_then(|media| media.title.as_deref())
                    == Some("Retained recorded session")
            })
            .await
            .unwrap();
        assert!(
            timeout(Duration::from_millis(50), phone.receive())
                .await
                .is_err(),
            "recorded IP iAP must emit neither StartSession nor WiFiConfiguration"
        );
        assert!(*phone.relay.recorded.borrow());
        assert!(!phone.relay.is_failed());
        assert!(!driver.is_finished());
        cancel.send_replace(true);
        assert!(matches!(
            driver.await.unwrap(),
            Err(wired::Error::Cancelled)
        ));
        mfi.await.unwrap();
    })
    .await
    .unwrap();
}
