//! Android Open Accessory Protocol bring-up, separate from AA framing.

use std::time::{Duration, Instant};

pub const REQUEST_GET_PROTOCOL: u8 = 51;
pub const REQUEST_SEND_STRING: u8 = 52;
pub const REQUEST_START: u8 = 53;

const ACCESSORY_WAIT: Duration = Duration::from_secs(15);
const IDENTITY_STRINGS: [&str; 6] = [
    "Android",
    "Android Auto",
    "Project Argo projection host",
    "1.0",
    "https://github.com/",
    "ARGO-0001",
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UsbControlRequest {
    In {
        request: u8,
        value: u16,
        index: u16,
        length: u16,
    },
    Out {
        request: u8,
        value: u16,
        index: u16,
        data: Vec<u8>,
    },
}

pub trait UsbControlTransport {
    type Error;
    fn control(&mut self, request: UsbControlRequest) -> Result<Vec<u8>, Self::Error>;
}

#[derive(Debug, PartialEq, Eq)]
pub enum AoapError<E> {
    Transport(E),
    ShortProtocolReply,
    UnsupportedProtocol(u16),
}

pub fn request_accessory_mode<T: UsbControlTransport>(
    transport: &mut T,
) -> Result<u16, AoapError<T::Error>> {
    let reply = transport
        .control(UsbControlRequest::In {
            request: REQUEST_GET_PROTOCOL,
            value: 0,
            index: 0,
            length: 2,
        })
        .map_err(AoapError::Transport)?;
    if reply.len() < 2 {
        return Err(AoapError::ShortProtocolReply);
    }
    let version = u16::from_le_bytes([reply[0], reply[1]]);
    if version == 0 {
        return Err(AoapError::UnsupportedProtocol(version));
    }
    for (index, value) in IDENTITY_STRINGS.iter().enumerate() {
        let mut data = value.as_bytes().to_vec();
        data.push(0);
        transport
            .control(UsbControlRequest::Out {
                request: REQUEST_SEND_STRING,
                value: 0,
                index: index as u16,
                data,
            })
            .map_err(AoapError::Transport)?;
    }
    transport
        .control(UsbControlRequest::Out {
            request: REQUEST_START,
            value: 0,
            index: 0,
            data: Vec::new(),
        })
        .map_err(AoapError::Transport)?;
    Ok(version)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UsbDeviceKey {
    pub id: String,
    pub serial: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UsbConnectionState {
    Disconnected,
    Discovered(UsbDeviceKey),
    Probing(UsbDeviceKey),
    Switching {
        device: UsbDeviceKey,
        protocol_version: u16,
    },
    WaitingForAccessory {
        original: UsbDeviceKey,
        deadline: Instant,
    },
    AccessoryPresent(UsbDeviceKey),
    SessionStarting(UsbDeviceKey),
    WaitingForTls {
        device: UsbDeviceKey,
        protocol_major: u16,
        protocol_minor: u16,
    },
    Failed {
        device: UsbDeviceKey,
        reason: String,
    },
}

/// Pure state machine used by the nusb runtime. One wired phone is owned at a
/// time. A failed device cannot be retried until it disappears and reappears.
#[derive(Clone, Debug)]
pub struct UsbConnectionStateMachine {
    state: UsbConnectionState,
}

impl Default for UsbConnectionStateMachine {
    fn default() -> Self {
        Self {
            state: UsbConnectionState::Disconnected,
        }
    }
}

impl UsbConnectionStateMachine {
    pub fn state(&self) -> &UsbConnectionState {
        &self.state
    }

    pub fn candidate_discovered(&mut self, device: UsbDeviceKey) -> bool {
        let available = match &self.state {
            UsbConnectionState::Disconnected => true,
            UsbConnectionState::Failed { device: failed, .. } => failed.id != device.id,
            _ => false,
        };
        if !available {
            return false;
        }
        self.state = UsbConnectionState::Discovered(device.clone());
        self.state = UsbConnectionState::Probing(device);
        true
    }

    pub fn accessory_switch_requested(
        &mut self,
        id: &str,
        protocol_version: u16,
        now: Instant,
    ) -> bool {
        let UsbConnectionState::Probing(device) = &self.state else {
            return false;
        };
        if device.id != id {
            return false;
        }
        let original = device.clone();
        self.state = UsbConnectionState::Switching {
            device: original.clone(),
            protocol_version,
        };
        self.state = UsbConnectionState::WaitingForAccessory {
            original,
            deadline: now + ACCESSORY_WAIT,
        };
        true
    }

    pub fn probe_failed(&mut self, id: &str, reason: impl Into<String>) -> bool {
        let UsbConnectionState::Probing(device) = &self.state else {
            return false;
        };
        if device.id != id {
            return false;
        }
        self.state = UsbConnectionState::Failed {
            device: device.clone(),
            reason: reason.into(),
        };
        true
    }

    pub fn accessory_discovered(&mut self, device: UsbDeviceKey, now: Instant) -> bool {
        match &self.state {
            UsbConnectionState::Disconnected => {}
            UsbConnectionState::WaitingForAccessory { original, deadline }
                if now <= *deadline && serials_can_correlate(original, &device) => {}
            _ => return false,
        }
        self.state = UsbConnectionState::AccessoryPresent(device);
        true
    }

    pub fn session_starting(&mut self, id: &str) -> bool {
        let UsbConnectionState::AccessoryPresent(device) = &self.state else {
            return false;
        };
        if device.id != id {
            return false;
        }
        self.state = UsbConnectionState::SessionStarting(device.clone());
        true
    }

    pub fn version_negotiated(&mut self, id: &str, major: u16, minor: u16) -> bool {
        let UsbConnectionState::SessionStarting(device) = &self.state else {
            return false;
        };
        if device.id != id {
            return false;
        }
        self.state = UsbConnectionState::WaitingForTls {
            device: device.clone(),
            protocol_major: major,
            protocol_minor: minor,
        };
        true
    }

    pub fn session_failed(&mut self, id: &str, reason: impl Into<String>) -> bool {
        let device = match &self.state {
            UsbConnectionState::AccessoryPresent(device)
            | UsbConnectionState::SessionStarting(device)
            | UsbConnectionState::WaitingForTls { device, .. }
                if device.id == id =>
            {
                device.clone()
            }
            _ => return false,
        };
        self.state = UsbConnectionState::Failed {
            device,
            reason: reason.into(),
        };
        true
    }

    pub fn removed(&mut self, id: &str) -> bool {
        let owns_device = match &self.state {
            UsbConnectionState::Disconnected => false,
            UsbConnectionState::WaitingForAccessory { original, .. } => original.id == id,
            UsbConnectionState::Discovered(device)
            | UsbConnectionState::Probing(device)
            | UsbConnectionState::Switching { device, .. }
            | UsbConnectionState::AccessoryPresent(device)
            | UsbConnectionState::SessionStarting(device)
            | UsbConnectionState::WaitingForTls { device, .. }
            | UsbConnectionState::Failed { device, .. } => device.id == id,
        };
        if owns_device && !matches!(self.state, UsbConnectionState::WaitingForAccessory { .. }) {
            self.state = UsbConnectionState::Disconnected;
        }
        owns_device
    }

    pub fn expire_accessory_wait(&mut self, now: Instant) -> bool {
        let UsbConnectionState::WaitingForAccessory { original, deadline } = &self.state else {
            return false;
        };
        if now < *deadline {
            return false;
        }
        self.state = UsbConnectionState::Failed {
            device: original.clone(),
            reason: "timed out waiting for Android accessory re-enumeration".to_owned(),
        };
        true
    }

    pub fn reset(&mut self) {
        self.state = UsbConnectionState::Disconnected;
    }
}

fn serials_can_correlate(original: &UsbDeviceKey, accessory: &UsbDeviceKey) -> bool {
    match (&original.serial, &accessory.serial) {
        (Some(expected), Some(actual)) => expected == actual,
        _ => true,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndpointDirection {
    Input,
    Output,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EndpointCandidate {
    pub interface: u8,
    pub alternate_setting: u8,
    pub address: u8,
    pub direction: EndpointDirection,
    pub bulk: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BulkEndpoints {
    pub interface: u8,
    pub alternate_setting: u8,
    pub input: u8,
    pub output: u8,
}

pub fn select_bulk_endpoints(
    endpoints: impl IntoIterator<Item = EndpointCandidate>,
) -> Option<BulkEndpoints> {
    let mut groups: Vec<(u8, u8, Option<u8>, Option<u8>)> = Vec::new();
    for endpoint in endpoints.into_iter().filter(|endpoint| endpoint.bulk) {
        let key = (endpoint.interface, endpoint.alternate_setting);
        let index = groups
            .iter()
            .position(|group| (group.0, group.1) == key)
            .unwrap_or_else(|| {
                groups.push((key.0, key.1, None, None));
                groups.len() - 1
            });
        match endpoint.direction {
            EndpointDirection::Input => groups[index].2.get_or_insert(endpoint.address),
            EndpointDirection::Output => groups[index].3.get_or_insert(endpoint.address),
        };
    }
    groups
        .into_iter()
        .find_map(|(interface, alternate_setting, input, output)| {
            Some(BulkEndpoints {
                interface,
                alternate_setting,
                input: input?,
                output: output?,
            })
        })
}

#[cfg(feature = "linux-usb")]
pub mod nusb_backend {
    use std::future::Future;
    use std::io;
    use std::pin::Pin;

    use nusb::descriptors::TransferType;
    use nusb::transfer::{Bulk, Direction};
    #[cfg(target_os = "linux")]
    use nusb::transfer::{ControlIn, ControlOut, ControlType, Recipient};
    use nusb::{DeviceInfo, Interface};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::{BulkEndpoints, EndpointCandidate, EndpointDirection, select_bulk_endpoints};
    #[cfg(target_os = "linux")]
    use super::{IDENTITY_STRINGS, REQUEST_GET_PROTOCOL, REQUEST_SEND_STRING, REQUEST_START};
    use crate::session::AndroidAutoTransport;

    const GOOGLE_VENDOR_ID: u16 = 0x18d1;
    const ACCESSORY_PRODUCT_IDS: [u16; 6] = [0x2d00, 0x2d01, 0x2d02, 0x2d03, 0x2d04, 0x2d05];
    const ANDROID_PHONE_VENDOR_IDS: [u16; 12] = [
        0x04e8, 0x0bb4, 0x0fce, 0x1004, 0x12d1, 0x18d1, 0x19d2, 0x22b8, 0x2717, 0x2a70, 0x2d95,
        0x413c,
    ];
    #[cfg(target_os = "linux")]
    const CONTROL_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(2);
    const TRANSFER_BYTES: usize = 16 * 1024;

    pub fn is_accessory(info: &DeviceInfo) -> bool {
        info.vendor_id() == GOOGLE_VENDOR_ID && ACCESSORY_PRODUCT_IDS.contains(&info.product_id())
    }

    /// Restrict probes to devices exposing the Android Debug Bridge interface
    /// or a vendor-specific device/interface. GET_PROTOCOL remains the final
    /// authority and a failed probe is parked until unplug.
    pub fn is_candidate(info: &DeviceInfo) -> bool {
        if is_accessory(info) {
            return false;
        }
        let has_adb = info
            .interfaces()
            .any(|interface| interface.class() == 0xff && interface.subclass() == 0x42);
        let phone_vendor = ANDROID_PHONE_VENDOR_IDS.contains(&info.vendor_id());
        let phone_interface = info
            .interfaces()
            .any(|interface| matches!(interface.class(), 0x06 | 0xff));
        has_adb || (phone_vendor && matches!(info.class(), 0x00 | 0xff) && phone_interface)
    }

    #[cfg(target_os = "linux")]
    pub async fn request_accessory_mode(info: &DeviceInfo) -> Result<u16, String> {
        let device = info
            .open()
            .await
            .map_err(|error| format!("open: {error}"))?;
        let protocol = device
            .control_in(
                ControlIn {
                    control_type: ControlType::Vendor,
                    recipient: Recipient::Device,
                    request: REQUEST_GET_PROTOCOL,
                    value: 0,
                    index: 0,
                    length: 2,
                },
                CONTROL_TIMEOUT,
            )
            .await
            .map_err(|error| format!("GET_PROTOCOL: {error}"))?;
        if protocol.len() < 2 {
            return Err("GET_PROTOCOL returned a short response".to_owned());
        }
        let version = u16::from_le_bytes([protocol[0], protocol[1]]);
        if version == 0 {
            return Err("device reported unsupported AOAP protocol version 0".to_owned());
        }
        for (index, value) in IDENTITY_STRINGS.iter().enumerate() {
            let value = if index == 5 {
                info.serial_number()
                    .filter(|serial| !serial.is_empty())
                    .unwrap_or(value)
            } else {
                value
            };
            let mut data = value.as_bytes().to_vec();
            data.push(0);
            device
                .control_out(
                    ControlOut {
                        control_type: ControlType::Vendor,
                        recipient: Recipient::Device,
                        request: REQUEST_SEND_STRING,
                        value: 0,
                        index: index as u16,
                        data: &data,
                    },
                    CONTROL_TIMEOUT,
                )
                .await
                .map_err(|error| format!("SEND_STRING {index}: {error}"))?;
        }
        device
            .control_out(
                ControlOut {
                    control_type: ControlType::Vendor,
                    recipient: Recipient::Device,
                    request: REQUEST_START,
                    value: 0,
                    index: 0,
                    data: &[],
                },
                CONTROL_TIMEOUT,
            )
            .await
            .map_err(|error| format!("START: {error}"))?;
        Ok(version)
    }

    #[cfg(not(target_os = "linux"))]
    pub async fn request_accessory_mode(_info: &DeviceInfo) -> Result<u16, String> {
        Err("AOAP USB switching is supported only on Linux".to_owned())
    }

    async fn discover_bulk_endpoints(info: &DeviceInfo) -> Result<BulkEndpoints, String> {
        let device = info
            .open()
            .await
            .map_err(|error| format!("open: {error}"))?;
        let configuration = device
            .active_configuration()
            .map_err(|error| format!("active configuration: {error}"))?;
        let mut candidates = Vec::new();
        for interface in configuration.interfaces() {
            for alternate in interface.alt_settings() {
                for endpoint in alternate.endpoints() {
                    candidates.push(EndpointCandidate {
                        interface: interface.interface_number(),
                        alternate_setting: alternate.alternate_setting(),
                        address: endpoint.address(),
                        direction: match endpoint.direction() {
                            Direction::In => EndpointDirection::Input,
                            Direction::Out => EndpointDirection::Output,
                        },
                        bulk: endpoint.transfer_type() == TransferType::Bulk,
                    });
                }
            }
        }
        select_bulk_endpoints(candidates)
            .ok_or_else(|| "accessory exposes no interface with bulk IN and OUT".to_owned())
    }

    pub struct UsbAaTransport {
        reader: Option<nusb::io::EndpointRead<Bulk>>,
        writer: Option<nusb::io::EndpointWrite<Bulk>>,
        _interface: Option<Interface>,
    }

    impl UsbAaTransport {
        pub async fn open(info: &DeviceInfo) -> Result<(Self, BulkEndpoints), String> {
            let endpoints = discover_bulk_endpoints(info).await?;
            let device = info
                .open()
                .await
                .map_err(|error| format!("open: {error}"))?;
            let interface = device
                .claim_interface(endpoints.interface)
                .await
                .map_err(|error| format!("claim interface {}: {error}", endpoints.interface))?;
            if interface.get_alt_setting() != endpoints.alternate_setting {
                interface
                    .set_alt_setting(endpoints.alternate_setting)
                    .await
                    .map_err(|error| {
                        format!(
                            "select alternate setting {}: {error}",
                            endpoints.alternate_setting
                        )
                    })?;
            }
            let reader = interface
                .endpoint::<Bulk, nusb::transfer::In>(endpoints.input)
                .map_err(|error| format!("open bulk IN endpoint: {error}"))?
                .reader(TRANSFER_BYTES)
                .with_num_transfers(4);
            let writer = interface
                .endpoint::<Bulk, nusb::transfer::Out>(endpoints.output)
                .map_err(|error| format!("open bulk OUT endpoint: {error}"))?
                .writer(TRANSFER_BYTES)
                .with_num_transfers(4);
            Ok((
                Self {
                    reader: Some(reader),
                    writer: Some(writer),
                    _interface: Some(interface),
                },
                endpoints,
            ))
        }

        fn closed_error() -> io::Error {
            io::Error::new(io::ErrorKind::NotConnected, "AA USB transport is closed")
        }
    }

    impl AndroidAutoTransport for UsbAaTransport {
        fn read<'a>(
            &'a mut self,
            bytes: &'a mut [u8],
        ) -> Pin<Box<dyn Future<Output = io::Result<usize>> + Send + 'a>> {
            Box::pin(async move {
                let reader = self.reader.as_mut().ok_or_else(Self::closed_error)?;
                reader.read(bytes).await
            })
        }

        fn write_all<'a>(
            &'a mut self,
            bytes: &'a [u8],
        ) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + 'a>> {
            Box::pin(async move {
                let writer = self.writer.as_mut().ok_or_else(Self::closed_error)?;
                writer.write_all(bytes).await?;
                writer.flush().await
            })
        }

        fn close(&mut self) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + '_>> {
            Box::pin(async move {
                if let Some(reader) = self.reader.as_mut() {
                    reader.cancel_all();
                }
                self.reader = None;
                self.writer = None;
                self._interface = None;
                Ok(())
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeUsb {
        requests: Vec<UsbControlRequest>,
        reply: Vec<u8>,
        fail_at: Option<usize>,
    }

    impl UsbControlTransport for FakeUsb {
        type Error = &'static str;

        fn control(&mut self, request: UsbControlRequest) -> Result<Vec<u8>, Self::Error> {
            if self.fail_at == Some(self.requests.len()) {
                return Err("control failed");
            }
            let reply = if matches!(
                request,
                UsbControlRequest::In {
                    request: REQUEST_GET_PROTOCOL,
                    ..
                }
            ) {
                self.reply.clone()
            } else {
                Vec::new()
            };
            self.requests.push(request);
            Ok(reply)
        }
    }

    #[test]
    fn aoap_uses_get_protocol_required_strings_and_start() {
        let mut usb = FakeUsb {
            reply: vec![2, 0],
            ..FakeUsb::default()
        };
        assert_eq!(request_accessory_mode(&mut usb), Ok(2));
        assert_eq!(usb.requests.len(), 8);
        assert!(matches!(
            usb.requests.first(),
            Some(UsbControlRequest::In {
                request: REQUEST_GET_PROTOCOL,
                length: 2,
                ..
            })
        ));
        for (index, request) in usb.requests[1..7].iter().enumerate() {
            assert!(matches!(
                request,
                UsbControlRequest::Out {
                    request: REQUEST_SEND_STRING,
                    index: actual,
                    ..
                } if *actual == index as u16
            ));
        }
        assert!(matches!(
            &usb.requests[1],
            UsbControlRequest::Out { data, .. } if data == b"Android\0"
        ));
        assert!(matches!(
            usb.requests.last(),
            Some(UsbControlRequest::Out {
                request: REQUEST_START,
                data,
                ..
            }) if data.is_empty()
        ));
    }

    #[test]
    fn failed_get_protocol_stops_before_switching() {
        let mut usb = FakeUsb {
            reply: vec![0, 0],
            ..FakeUsb::default()
        };
        assert_eq!(
            request_accessory_mode(&mut usb),
            Err(AoapError::UnsupportedProtocol(0))
        );
        assert_eq!(usb.requests.len(), 1);
    }

    #[test]
    fn candidate_switch_reenumeration_and_unplug_are_explicit() {
        let now = Instant::now();
        let original = UsbDeviceKey {
            id: "1-2".to_owned(),
            serial: Some("phone-1".to_owned()),
        };
        let accessory = UsbDeviceKey {
            id: "1-3".to_owned(),
            serial: Some("phone-1".to_owned()),
        };
        let mut lifecycle = UsbConnectionStateMachine::default();
        assert!(lifecycle.candidate_discovered(original.clone()));
        assert!(matches!(lifecycle.state(), UsbConnectionState::Probing(_)));
        assert!(lifecycle.accessory_switch_requested("1-2", 2, now));
        assert!(lifecycle.removed("1-2"));
        assert!(matches!(
            lifecycle.state(),
            UsbConnectionState::WaitingForAccessory { .. }
        ));
        assert!(lifecycle.accessory_discovered(accessory.clone(), now));
        assert!(lifecycle.session_starting("1-3"));
        assert!(lifecycle.version_negotiated("1-3", 1, 7));
        assert!(matches!(
            lifecycle.state(),
            UsbConnectionState::WaitingForTls { .. }
        ));
        assert!(lifecycle.removed("1-3"));
        assert_eq!(lifecycle.state(), &UsbConnectionState::Disconnected);
    }

    #[test]
    fn unplug_while_switching_clears_only_after_the_accessory_window() {
        let now = Instant::now();
        let original = UsbDeviceKey {
            id: "candidate".to_owned(),
            serial: None,
        };
        let mut lifecycle = UsbConnectionStateMachine::default();
        lifecycle.candidate_discovered(original);
        lifecycle.accessory_switch_requested("candidate", 2, now);
        assert!(lifecycle.removed("candidate"));
        assert!(lifecycle.expire_accessory_wait(now + ACCESSORY_WAIT));
        assert!(matches!(
            lifecycle.state(),
            UsbConnectionState::Failed { .. }
        ));
        assert!(!lifecycle.candidate_discovered(UsbDeviceKey {
            id: "candidate".to_owned(),
            serial: None,
        }));
        assert!(lifecycle.candidate_discovered(UsbDeviceKey {
            id: "replugged-candidate".to_owned(),
            serial: None,
        }));
        assert!(matches!(lifecycle.state(), UsbConnectionState::Probing(_)));
    }

    #[test]
    fn endpoint_pair_must_share_interface_and_alternate_setting() {
        let selected = select_bulk_endpoints([
            EndpointCandidate {
                interface: 0,
                alternate_setting: 0,
                address: 0x81,
                direction: EndpointDirection::Input,
                bulk: true,
            },
            EndpointCandidate {
                interface: 0,
                alternate_setting: 1,
                address: 0x01,
                direction: EndpointDirection::Output,
                bulk: true,
            },
            EndpointCandidate {
                interface: 2,
                alternate_setting: 1,
                address: 0x82,
                direction: EndpointDirection::Input,
                bulk: true,
            },
            EndpointCandidate {
                interface: 2,
                alternate_setting: 1,
                address: 0x03,
                direction: EndpointDirection::Output,
                bulk: true,
            },
        ]);
        assert_eq!(
            selected,
            Some(BulkEndpoints {
                interface: 2,
                alternate_setting: 1,
                input: 0x82,
                output: 0x03,
            })
        );
    }
}
