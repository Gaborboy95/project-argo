//! Local usbmuxd/lockdown carkit attachment. No USB configuration changes,
//! pairing-record writes, remote USB proxy or dongle firmware operations.
//!
//! Independently written using usbmuxd and lockdown wire formats; LIVI research
//! provenance is in `protocol/mod.rs`. OpenSSL provides TLS; `plist` provides
//! bounded event decoding. Trusted host pairing credentials stay in memory.

use openssl::{
    pkey::PKey,
    ssl::{SslConnector, SslMethod, SslVerifyMode, SslVersion},
    x509::X509,
};
use plist::{
    Dictionary, Value,
    stream::{Event, Reader},
};
use std::{
    io::{self, Cursor},
    pin::Pin,
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::UnixStream,
    time::timeout,
};
use tokio_openssl::SslStream;

const SOCKET: &str = "/var/run/usbmuxd";
const MAX_PLIST: usize = 256 * 1024;
const CARKIT: &str = "com.apple.carkit.service";
const DEADLINE: Duration = Duration::from_secs(20);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Device {
    pub id: u32,
    pub udid: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    Unavailable,
    Timeout,
    Bounds,
    Malformed,
    Untrusted,
    InvalidPairRecord,
    InvalidHostCertificate,
    InvalidHostKey,
    InvalidDeviceCertificate,
    HostKeyMismatch,
    SessionNotEncrypted,
    NotIPhone,
    ServiceUnavailable,
    Tls,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "local wired attachment {self:?}")
    }
}
impl std::error::Error for Error {}
impl From<io::Error> for Error {
    fn from(_: io::Error) -> Self {
        Self::Unavailable
    }
}

pub trait Stream: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Stream for T {}

fn dictionary(entries: &[(&str, Value)]) -> Dictionary {
    entries
        .iter()
        .map(|(key, value)| ((*key).to_owned(), value.clone()))
        .collect()
}

fn encode(value: Dictionary) -> Result<Vec<u8>, Error> {
    let mut bytes = Vec::new();
    Value::Dictionary(value)
        .to_writer_xml(&mut bytes)
        .map_err(|_| Error::Malformed)?;
    if bytes.len() > MAX_PLIST {
        return Err(Error::Bounds);
    }
    Ok(bytes)
}

pub(crate) fn decode(bytes: &[u8]) -> Result<Dictionary, Error> {
    if bytes.is_empty() || bytes.len() > MAX_PLIST {
        return Err(Error::Bounds);
    }
    // Cap expanded binary-plist references as well as XML nesting before making
    // a recursive Value tree. No parser is handed a phone-selected allocation.
    let mut events = Vec::new();
    let mut depth = 0usize;
    let mut expanded = 0usize;
    for event in Reader::new(Cursor::new(bytes)) {
        let event = event.map_err(|_| Error::Malformed)?;
        // Binary plists may reference the same large object many times. Count
        // expanded retained data, not just encoded input length or event count.
        let payload = match &event {
            Event::Data(value) => value.len(),
            Event::String(value) => value.len(),
            _ => 0,
        };
        expanded = expanded.checked_add(payload + 64).ok_or(Error::Bounds)?;
        if expanded > MAX_PLIST {
            return Err(Error::Bounds);
        }
        match &event {
            Event::StartArray(count) | Event::StartDictionary(count) => {
                depth += 1;
                if depth > 16 || count.is_some_and(|v| v > 4096) {
                    return Err(Error::Bounds);
                }
            }
            Event::EndCollection => {
                depth = depth.checked_sub(1).ok_or(Error::Malformed)?;
            }
            Event::Data(bytes) if bytes.len() > MAX_PLIST => return Err(Error::Bounds),
            Event::String(text) if text.len() > 8192 => return Err(Error::Bounds),
            _ => {}
        }
        if events.len() >= 4096 {
            return Err(Error::Bounds);
        }
        events.push(Ok(event));
    }
    if depth != 0 {
        return Err(Error::Malformed);
    }
    Value::from_events(events)
        .map_err(|_| Error::Malformed)?
        .into_dictionary()
        .ok_or(Error::Malformed)
}

async fn mux_exchange(stream: &mut UnixStream, request: Dictionary) -> Result<Dictionary, Error> {
    let payload = encode(request)?;
    let mut packet = Vec::with_capacity(payload.len() + 16);
    for value in [(payload.len() + 16) as u32, 1, 8, 1] {
        packet.extend_from_slice(&value.to_le_bytes());
    }
    packet.extend(payload);
    stream.write_all(&packet).await?;
    let mut header = [0; 16];
    stream.read_exact(&mut header).await?;
    let words: Vec<u32> = header
        .as_chunks::<4>()
        .0
        .iter()
        .map(|b| u32::from_le_bytes(*b))
        .collect();
    let length = words[0] as usize;
    if !(16..=MAX_PLIST + 16).contains(&length) {
        return Err(Error::Bounds);
    }
    if words[1..] != [1, 8, 1] {
        return Err(Error::Malformed);
    }
    let mut bytes = vec![0; length - 16];
    stream.read_exact(&mut bytes).await?;
    decode(&bytes)
}

async fn mux_request(request: Dictionary) -> Result<Dictionary, Error> {
    let mut stream = UnixStream::connect(SOCKET).await?;
    mux_exchange(&mut stream, request).await
}

fn parse_devices(response: Dictionary) -> Result<Vec<Device>, Error> {
    let list = response
        .get("DeviceList")
        .and_then(Value::as_array)
        .ok_or(Error::Malformed)?;
    if list.len() > 32 {
        return Err(Error::Bounds);
    }
    let mut devices = Vec::new();
    for value in list {
        let entry = value.as_dictionary().ok_or(Error::Malformed)?;
        let properties = entry
            .get("Properties")
            .and_then(Value::as_dictionary)
            .ok_or(Error::Malformed)?;
        if properties.get("ConnectionType").and_then(Value::as_string) != Some("USB") {
            continue;
        }
        let id = entry
            .get("DeviceID")
            .and_then(Value::as_unsigned_integer)
            .and_then(|v| u32::try_from(v).ok())
            .ok_or(Error::Malformed)?;
        let udid = properties
            .get("SerialNumber")
            .and_then(Value::as_string)
            .ok_or(Error::Malformed)?;
        if !(8..=128).contains(&udid.len())
            || !udid.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        {
            return Err(Error::Malformed);
        }
        devices.push(Device {
            id,
            udid: udid.into(),
        });
    }
    Ok(devices)
}

async fn inventory() -> Result<Vec<Device>, Error> {
    parse_devices(
        mux_request(dictionary(&[
            ("MessageType", "ListDevices".into()),
            ("ClientVersionString", "Argo".into()),
            ("kLibUSBMuxVersion", 3u32.into()),
        ]))
        .await?,
    )
}

/// Read-only local system inventory. Network-paired devices are excluded.
pub async fn devices() -> Result<Vec<Device>, Error> {
    timeout(Duration::from_secs(5), inventory())
        .await
        .map_err(|_| Error::Timeout)?
}

async fn connect(device: &Device, port: u16) -> Result<Box<dyn Stream>, Error> {
    let mut socket = UnixStream::connect(SOCKET).await?;
    let reply = mux_exchange(
        &mut socket,
        dictionary(&[
            ("MessageType", "Connect".into()),
            ("DeviceID", device.id.into()),
            ("PortNumber", u32::from(port.to_be()).into()),
        ]),
    )
    .await?;
    if reply.get("Number").and_then(Value::as_unsigned_integer) != Some(0) {
        return Err(Error::ServiceUnavailable);
    }
    Ok(Box::new(socket))
}

async fn lockdown(stream: &mut Box<dyn Stream>, request: Dictionary) -> Result<Dictionary, Error> {
    let bytes = encode(request)?;
    stream.write_u32(bytes.len() as u32).await?;
    stream.write_all(&bytes).await?;
    let length = stream.read_u32().await? as usize;
    if length == 0 || length > MAX_PLIST {
        return Err(Error::Bounds);
    }
    let mut bytes = vec![0; length];
    stream.read_exact(&mut bytes).await?;
    let reply = decode(&bytes)?;
    if reply.contains_key("Error") {
        return Err(Error::ServiceUnavailable);
    }
    Ok(reply)
}

fn field<'a>(pair: &'a Dictionary, name: &str) -> Result<&'a [u8], Error> {
    pair.get(name)
        .and_then(Value::as_data)
        .filter(|v| !v.is_empty() && v.len() <= 16384)
        .ok_or(Error::Untrusted)
}

async fn tls(stream: Box<dyn Stream>, pair: &Dictionary) -> Result<Box<dyn Stream>, Error> {
    let certificate = X509::from_pem(field(pair, "HostCertificate")?)
        .map_err(|_| Error::InvalidHostCertificate)?;
    let key = PKey::private_key_from_pem(field(pair, "HostPrivateKey")?)
        .map_err(|_| Error::InvalidHostKey)?;
    let pinned = X509::from_pem(field(pair, "DeviceCertificate")?)
        .and_then(|c| c.to_der())
        .map_err(|_| Error::InvalidDeviceCertificate)?;
    let mut builder = SslConnector::builder(SslMethod::tls_client()).map_err(|_| Error::Tls)?;
    builder
        .set_min_proto_version(Some(SslVersion::TLS1_2))
        .map_err(|_| Error::Tls)?;
    builder
        .set_certificate(&certificate)
        .map_err(|_| Error::Tls)?;
    builder.set_private_key(&key).map_err(|_| Error::Tls)?;
    builder
        .check_private_key()
        .map_err(|_| Error::HostKeyMismatch)?;
    // The local trust record is the authority. Hostname/CA validation is replaced
    // by an exact leaf certificate pin; TLS still verifies possession of its key.
    builder.set_verify_callback(SslVerifyMode::PEER, move |_, context| {
        context.error_depth() != 0
            || context
                .current_cert()
                .and_then(|cert| cert.to_der().ok())
                .is_some_and(|der| der == pinned)
    });
    let mut configuration = builder.build().configure().map_err(|_| Error::Tls)?;
    configuration.set_verify_hostname(false);
    configuration.set_use_server_name_indication(false);
    let ssl = configuration.into_ssl("Device").map_err(|_| Error::Tls)?;
    let mut stream = SslStream::new(ssl, stream).map_err(|_| Error::Tls)?;
    Pin::new(&mut stream)
        .connect()
        .await
        .map_err(|_| Error::Tls)?;
    Ok(Box::new(stream))
}

/// Opens only an already-trusted, currently enumerated local USB iPhone.
/// The system owns the pair record. A missing trust record is a typed error;
/// this function never writes one or prompts through an unrelated UI.
pub async fn open_carkit(device: &Device) -> Result<Box<dyn Stream>, Error> {
    timeout(DEADLINE, async {
        if !inventory().await?.contains(device) {
            return Err(Error::Unavailable);
        }
        trusted_carkit(&device.udid, |port| connect(device, port)).await
    })
    .await
    .map_err(|_| Error::Timeout)?
}

#[cfg(feature = "linux-usb")]
pub async fn open_local_carkit(host: &super::usb_mux::UsbMux) -> Result<Box<dyn Stream>, Error> {
    trusted_carkit(&host.udid, |port| async move {
        host.connect(port)
            .await
            .map(|stream| Box::new(stream) as Box<dyn Stream>)
            .map_err(|_| Error::Unavailable)
    })
    .await
}

async fn trusted_carkit<F, Fut>(udid: &str, mut open: F) -> Result<Box<dyn Stream>, Error>
where
    F: FnMut(u16) -> Fut,
    Fut: std::future::Future<Output = Result<Box<dyn Stream>, Error>>,
{
    timeout(DEADLINE, async {
        let response = mux_request(dictionary(&[
            ("MessageType", "ReadPairRecord".into()),
            ("PairRecordID", udid.to_owned().into()),
        ]))
        .await?;
        let record = response
            .get("PairRecordData")
            .and_then(Value::as_data)
            .ok_or(Error::Untrusted)?;
        let pair = decode(record).map_err(|_| Error::InvalidPairRecord)?;
        let host = pair
            .get("HostID")
            .and_then(Value::as_string)
            .filter(|s| !s.is_empty() && s.len() <= 128)
            .ok_or(Error::Untrusted)?;
        let buid = pair
            .get("SystemBUID")
            .and_then(Value::as_string)
            .filter(|s| !s.is_empty() && s.len() <= 128)
            .ok_or(Error::Untrusted)?;
        let mut stream = open(62078).await?;
        let product = lockdown(
            &mut stream,
            dictionary(&[
                ("Request", "GetValue".into()),
                ("Key", "ProductType".into()),
                ("Label", "argo-carplayd".into()),
            ]),
        )
        .await?;
        if !product
            .get("Value")
            .and_then(Value::as_string)
            .is_some_and(|s| s.starts_with("iPhone") && s.len() < 64)
        {
            return Err(Error::NotIPhone);
        }
        let response = lockdown(
            &mut stream,
            dictionary(&[
                ("Request", "StartSession".into()),
                ("HostID", host.into()),
                ("SystemBUID", buid.into()),
                ("Label", "argo-carplayd".into()),
            ]),
        )
        .await?;
        if response.get("EnableSessionSSL").and_then(Value::as_boolean) != Some(true) {
            return Err(Error::SessionNotEncrypted);
        }
        stream = tls(stream, &pair).await?;
        let response = lockdown(
            &mut stream,
            dictionary(&[
                ("Request", "StartService".into()),
                ("Service", CARKIT.into()),
                ("Label", "argo-carplayd".into()),
            ]),
        )
        .await?;
        let port = response
            .get("Port")
            .and_then(Value::as_unsigned_integer)
            .and_then(|v| u16::try_from(v).ok())
            .filter(|v| *v != 0)
            .ok_or(Error::Malformed)?;
        let carkit = open(port).await?;
        match response.get("EnableServiceSSL") {
            Some(Value::Boolean(true)) => tls(carkit, &pair).await,
            Some(Value::Boolean(false)) | None => Ok(carkit),
            _ => Err(Error::Malformed),
        }
    })
    .await
    .map_err(|_| Error::Timeout)?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plist_depth_is_rejected_before_recursive_value_creation() {
        let data = format!(
            "<plist>{}<string>x</string>{}</plist>",
            "<array>".repeat(17),
            "</array>".repeat(17)
        );
        assert_eq!(decode(data.as_bytes()), Err(Error::Bounds));
        assert_eq!(decode(&vec![0; MAX_PLIST + 1]), Err(Error::Bounds));
    }

    #[test]
    fn repeated_binary_plist_references_cannot_amplify_retained_memory() {
        // Synthetic array with three references to the same 96 KiB data object.
        // Encoded size is below the input bound; expanded values exceed it.
        let mut bytes = b"bplist00".to_vec();
        bytes.extend_from_slice(&[0xa3, 1, 1, 1]);
        bytes.extend_from_slice(&[0x4f, 0x12]);
        bytes.extend_from_slice(&(96u32 * 1024).to_be_bytes());
        bytes.resize(bytes.len() + 96 * 1024, 7);
        let offsets = bytes.len() as u64;
        bytes.extend_from_slice(&8u32.to_be_bytes());
        bytes.extend_from_slice(&12u32.to_be_bytes());
        bytes.extend_from_slice(&[0, 0, 0, 0, 0, 0, 4, 1]);
        bytes.extend_from_slice(&2u64.to_be_bytes());
        bytes.extend_from_slice(&0u64.to_be_bytes());
        bytes.extend_from_slice(&offsets.to_be_bytes());
        assert!(bytes.len() < MAX_PLIST);
        assert_eq!(decode(&bytes), Err(Error::Bounds));
    }

    #[test]
    fn inventory_ignores_network_and_validates_local_identifiers() {
        let device = |kind: &str, serial: &str| {
            Value::Dictionary(dictionary(&[
                ("DeviceID", 1u32.into()),
                (
                    "Properties",
                    Value::Dictionary(dictionary(&[
                        ("ConnectionType", kind.into()),
                        ("SerialNumber", serial.into()),
                    ])),
                ),
            ]))
        };
        let response = dictionary(&[(
            "DeviceList",
            Value::Array(vec![
                device("Network", "remote-001"),
                device("USB", "synthetic-001"),
            ]),
        )]);
        assert_eq!(
            parse_devices(response).unwrap(),
            vec![Device {
                id: 1,
                udid: "synthetic-001".into()
            }]
        );
        assert_eq!(
            parse_devices(dictionary(&[(
                "DeviceList",
                Value::Array(vec![device("USB", "../../record")])
            )])),
            Err(Error::Malformed)
        );
    }

    #[tokio::test]
    async fn oversized_lockdown_is_rejected_before_body_read() {
        let (host, mut phone) = UnixStream::pair().unwrap();
        let task = tokio::spawn(async move {
            let mut stream: Box<dyn Stream> = Box::new(host);
            lockdown(&mut stream, dictionary(&[("Request", "GetValue".into())])).await
        });
        let length = phone.read_u32().await.unwrap();
        let mut request = vec![0; length as usize];
        phone.read_exact(&mut request).await.unwrap();
        phone.write_u32(u32::MAX).await.unwrap();
        assert_eq!(task.await.unwrap(), Err(Error::Bounds));
    }

    #[tokio::test]
    async fn mux_header_requires_matching_tag_and_bounds() {
        let (mut host, mut server) = UnixStream::pair().unwrap();
        let task = tokio::spawn(async move { mux_exchange(&mut host, Dictionary::new()).await });
        let length = server.read_u32_le().await.unwrap();
        let mut request = vec![0; length as usize - 4];
        server.read_exact(&mut request).await.unwrap();
        for value in [16u32, 1, 8, 2] {
            server.write_u32_le(value).await.unwrap();
        }
        assert_eq!(task.await.unwrap(), Err(Error::Malformed));
    }

    fn certificate() -> (PKey<openssl::pkey::Private>, X509) {
        use openssl::{
            asn1::Asn1Time,
            ec::{EcGroup, EcKey},
            hash::MessageDigest,
            nid::Nid,
            x509::X509NameBuilder,
        };
        let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap();
        let key = PKey::from_ec_key(EcKey::generate(&group).unwrap()).unwrap();
        let mut name = X509NameBuilder::new().unwrap();
        name.append_entry_by_text("CN", "Argo synthetic fixture")
            .unwrap();
        let name = name.build();
        let mut builder = X509::builder().unwrap();
        builder.set_version(2).unwrap();
        builder.set_subject_name(&name).unwrap();
        builder.set_issuer_name(&name).unwrap();
        builder.set_pubkey(&key).unwrap();
        builder
            .set_not_before(&Asn1Time::days_from_now(0).unwrap())
            .unwrap();
        builder
            .set_not_after(&Asn1Time::days_from_now(1).unwrap())
            .unwrap();
        builder.sign(&key, MessageDigest::sha256()).unwrap();
        (key, builder.build())
    }

    #[tokio::test]
    async fn tls_requires_matching_trusted_device_certificate() {
        use openssl::ssl::{Ssl, SslAcceptor};
        let (key, cert) = certificate();
        let (_, wrong_cert) = certificate();
        for matches in [true, false] {
            let (host, device) = UnixStream::pair().unwrap();
            let mut acceptor = SslAcceptor::mozilla_intermediate(SslMethod::tls_server()).unwrap();
            acceptor.set_certificate(&cert).unwrap();
            acceptor.set_private_key(&key).unwrap();
            let ssl = Ssl::new(acceptor.build().context()).unwrap();
            let server = tokio::spawn(async move {
                let mut stream = SslStream::new(ssl, device).unwrap();
                Pin::new(&mut stream).accept().await
            });
            let pair = dictionary(&[
                ("HostCertificate", Value::Data(cert.to_pem().unwrap())),
                (
                    "HostPrivateKey",
                    Value::Data(key.private_key_to_pem_pkcs8().unwrap()),
                ),
                (
                    "DeviceCertificate",
                    Value::Data(if matches {
                        cert.to_pem().unwrap()
                    } else {
                        wrong_cert.to_pem().unwrap()
                    }),
                ),
            ]);
            assert_eq!(tls(Box::new(host), &pair).await.is_ok(), matches);
            assert_eq!(server.await.unwrap().is_ok(), matches);
        }
    }
}
