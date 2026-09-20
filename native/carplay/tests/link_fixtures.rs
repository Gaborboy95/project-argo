//! Synthetic Argo fixtures. No upstream vectors, hardware, keys or firmware operations.
use argo_carplay::{
    discovery::Discovery,
    link::{Error, LinkClient, LinkConfig},
    wifi::AccessPointSettings,
};
use std::{net::Ipv4Addr, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
};

async fn fixture(replies: Vec<(Vec<u8>, Vec<u8>)>) -> (LinkClient, tokio::task::JoinHandle<()>) {
    fixture_connections(replies, false).await
}

async fn fixture_connections(
    replies: Vec<(Vec<u8>, Vec<u8>)>,
    persistent: bool,
) -> (LinkClient, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let client = LinkClient::new(LinkConfig {
        discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
        mfi_port: port,
        wifi_port: port,
        deadline: Duration::from_secs(1),
    })
    .unwrap();
    let task = tokio::spawn(async move {
        let mut live = None;
        for (request, reply) in replies {
            let mut connection = match live.take() {
                Some(socket) => socket,
                None => listener.accept().await.unwrap().0,
            };
            let mut received = vec![0; request.len()];
            connection.read_exact(&mut received).await.unwrap();
            assert_eq!(received, request);
            connection.write_all(&reply).await.unwrap();
            if persistent {
                live = Some(connection);
            }
        }
    });
    (client, task)
}

#[tokio::test]
async fn mfi_certificate_sign_and_protocol_transactions() {
    let (client, server) = fixture_connections(
        vec![
            (vec![1], vec![0, 0, 4, 0x30, 2, 1, 0]),
            (vec![2, 0, 3, 21, 22, 23], vec![0, 0, 2, 71, 72]),
            (vec![3], vec![0, 0, 1, 2]),
            (vec![3], vec![0, 0, 1, 3]),
        ],
        true,
    )
    .await;
    assert_eq!(client.certificate().await.unwrap(), vec![0x30, 2, 1, 0]);
    assert_eq!(client.sign(&[21, 22, 23]).await.unwrap(), vec![71, 72]);
    assert_eq!(client.protocol_major().await.unwrap(), 2);
    assert_eq!(client.protocol_major().await.unwrap(), 3);
    server.await.unwrap();
}

#[tokio::test]
async fn malformed_responses_never_poison_reconnection() {
    let (client, server) = fixture(vec![
        (vec![1], vec![0, 0]),
        (vec![1], vec![0, 0, 3, 9]),
        (vec![1], vec![0, 0x10, 1]),
        (vec![1], vec![0, 0, 0]),
        (vec![1], vec![1, 0, 0]),
        (vec![3], vec![0, 0, 2, 2, 3]),
        (vec![3], vec![0, 0, 1, 99]),
        (vec![1], vec![0, 0, 1, 7]),
    ])
    .await;
    for _ in 0..2 {
        assert!(matches!(client.certificate().await, Err(Error::Io(_))));
    }
    for _ in 0..2 {
        assert!(matches!(client.certificate().await, Err(Error::Invalid(_))));
    }
    assert!(matches!(client.certificate().await, Err(Error::Remote)));
    for _ in 0..2 {
        assert!(matches!(
            client.protocol_major().await,
            Err(Error::Invalid(_))
        ));
    }
    assert_eq!(client.certificate().await.unwrap(), [7]);
    server.await.unwrap();
}

#[tokio::test]
async fn challenge_bounds_precede_connection_attempt() {
    let client = LinkClient::new(LinkConfig {
        discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
        ..LinkConfig::default()
    })
    .unwrap();
    assert!(matches!(client.sign(&[]).await, Err(Error::Invalid(_))));
    assert!(matches!(
        client.sign(&[0; 129]).await,
        Err(Error::Invalid(_))
    ));
}

#[tokio::test]
async fn concurrent_requests_fail_busy_and_cancellation_releases_lease() {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let client = LinkClient::new(LinkConfig {
        discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
        mfi_port: listener.local_addr().unwrap().port(),
        ..LinkConfig::default()
    })
    .unwrap();
    let copy = client.clone();
    let request = tokio::spawn(async move { copy.certificate().await });
    let (mut socket, _) = listener.accept().await.unwrap();
    assert_eq!(socket.read_u8().await.unwrap(), 1);
    assert!(matches!(client.protocol_major().await, Err(Error::Busy)));
    request.abort();
    let _ = request.await;
    assert_eq!(socket.read(&mut [0; 1]).await.unwrap(), 0);
    let copy = client.clone();
    let next = tokio::spawn(async move { copy.protocol_major().await });
    let (mut socket, _) = listener.accept().await.unwrap();
    assert_eq!(socket.read_u8().await.unwrap(), 3);
    socket.write_all(&[0, 0, 1, 3]).await.unwrap();
    assert_eq!(next.await.unwrap().unwrap(), 3);
}

#[tokio::test]
async fn slow_peer_hits_total_deadline_without_implicit_retry() {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let client = LinkClient::new(LinkConfig {
        discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
        mfi_port: listener.local_addr().unwrap().port(),
        deadline: Duration::from_millis(30),
        ..LinkConfig::default()
    })
    .unwrap();
    let task = tokio::spawn(async move { client.certificate().await });
    let (mut socket, _) = listener.accept().await.unwrap();
    assert_eq!(socket.read_u8().await.unwrap(), 1);
    assert!(matches!(task.await.unwrap(), Err(Error::Timeout)));
    assert_eq!(socket.read(&mut [0; 1]).await.unwrap(), 0);
}

#[tokio::test]
async fn wifi_status_is_read_only_and_strict() {
    let (client, server) = fixture(vec![
        (
            b"status\n".to_vec(),
            b"state off\nbt on\ncountry_code HU\nchannel 36\nssid synthetic fixture\nok\n".to_vec(),
        ),
        (
            b"status\n".to_vec(),
            b"state on\nstate off\nbt on\nok\n".to_vec(),
        ),
        (b"status\n".to_vec(), b"state strange\nbt on\nok\n".to_vec()),
        (b"status\n".to_vec(), b"state on\nok\n".to_vec()),
        (b"status\n".to_vec(), vec![b'x'; 514]),
        (b"status\n".to_vec(), b"error fixture-only\n".to_vec()),
        (b"status\n".to_vec(), b"state off\nbt off\nok\n".to_vec()),
    ])
    .await;
    let status = client.wifi_status().await.unwrap();
    assert!(!status.access_point_enabled);
    assert!(status.bluetooth_enabled);
    assert_eq!(status.channel, Some(36));
    for _ in 0..4 {
        assert!(matches!(client.wifi_status().await, Err(Error::Invalid(_))));
    }
    assert!(matches!(client.wifi_status().await, Err(Error::Remote)));
    assert!(!client.wifi_status().await.unwrap().bluetooth_enabled);
    server.await.unwrap();
}

#[tokio::test]
async fn wifi_apply_preserves_connection_local_pending_values() {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
    let client = LinkClient::new(LinkConfig {
        discovery: Discovery::Address(Ipv4Addr::LOCALHOST),
        wifi_port: listener.local_addr().unwrap().port(),
        ..LinkConfig::default()
    })
    .unwrap();
    let server = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut connection = BufReader::new(socket);
        for expected in ["set country HU\n", "set channel 44\n", "apply\n"] {
            let mut line = String::new();
            connection.read_line(&mut line).await.unwrap();
            assert_eq!(line, expected);
            connection.get_mut().write_all(b"ok\n").await.unwrap();
        }
        assert_eq!(
            connection.read_u8().await.unwrap_err().kind(),
            std::io::ErrorKind::UnexpectedEof
        );
    });
    client
        .apply_access_point_settings(&AccessPointSettings::new("hu", 44).unwrap())
        .await
        .unwrap();
    server.await.unwrap();
    for (country, channel) in [("H\n", 44), ("HU\nset", 44), ("HU", 0), ("HU", 197)] {
        assert!(AccessPointSettings::new(country, channel).is_err());
    }
}

#[tokio::test]
async fn explicit_access_point_switch_has_no_save_or_bluetooth_side_effect() {
    let (client, server) = fixture(vec![
        (b"on\n".to_vec(), b"ok\n".to_vec()),
        (b"off\n".to_vec(), b"ok\n".to_vec()),
    ])
    .await;
    client.set_access_point_enabled(true).await.unwrap();
    client.set_access_point_enabled(false).await.unwrap();
    server.await.unwrap();
}
