//! Android Open Accessory Protocol bring-up, separate from the AA session.

pub const REQUEST_GET_PROTOCOL: u8 = 51;
pub const REQUEST_SEND_STRING: u8 = 52;
pub const REQUEST_START: u8 = 53;

#[cfg(feature = "linux-usb")]
pub mod nusb_backend {
    use std::time::Duration;

    use futures_lite::StreamExt;
    use nusb::descriptors::TransferType;
    use nusb::hotplug::HotplugEvent;
    use nusb::transfer::{ControlIn, ControlOut, ControlType, Direction, Recipient};
    use nusb::{DeviceInfo, DeviceId};

    use super::{IDENTITY_STRINGS, REQUEST_GET_PROTOCOL, REQUEST_SEND_STRING, REQUEST_START};

    const GOOGLE_VENDOR_ID: u16 = 0x18d1;
    const ACCESSORY_PRODUCT_IDS: [u16; 6] =
        [0x2d00, 0x2d01, 0x2d02, 0x2d03, 0x2d04, 0x2d05];
    const CONTROL_TIMEOUT: Duration = Duration::from_secs(2);

    #[derive(Clone, Debug)]
    pub enum DeviceEvent {
        Candidate(DeviceInfo),
        Accessory(DeviceInfo),
        Removed(DeviceId),
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub struct BulkEndpoints {
        pub interface: u8,
        pub input: u8,
        pub output: u8,
    }

    pub fn is_accessory(info: &DeviceInfo) -> bool {
        info.vendor_id() == GOOGLE_VENDOR_ID
            && ACCESSORY_PRODUCT_IDS.contains(&info.product_id())
    }

    /// Conservative class filter. Actual AOAP support is established only by
    /// GET_PROTOCOL; a failed probe leaves the unrelated USB device untouched.
    pub fn is_candidate(info: &DeviceInfo) -> bool {
        matches!(info.class(), 0x00 | 0xff)
            && info.interfaces().any(|interface| {
                !matches!(
                    interface.class(),
                    0x01 | 0x03 | 0x07 | 0x08 | 0x09 | 0x0e
                )
            })
    }

    pub async fn request_accessory_mode(info: &DeviceInfo) -> Result<u16, String> {
        let device = info.open().await.map_err(|error| error.to_string())?;
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
            .map_err(|error| error.to_string())?;
        if protocol.len() < 2 {
            return Err("AOAP GET_PROTOCOL returned a short response".to_owned());
        }
        let version = u16::from_le_bytes([protocol[0], protocol[1]]);
        if version == 0 {
            return Err("device reported unsupported AOAP version 0".to_owned());
        }
        for (index, value) in IDENTITY_STRINGS.iter().enumerate() {
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
                .map_err(|error| error.to_string())?;
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
            .map_err(|error| error.to_string())?;
        Ok(version)
    }

    pub async fn discover_bulk_endpoints(info: &DeviceInfo) -> Result<BulkEndpoints, String> {
        let device = info.open().await.map_err(|error| error.to_string())?;
        let configuration = device
            .active_configuration()
            .map_err(|error| error.to_string())?;
        for interface in configuration.interfaces() {
            for alternate in interface.alt_settings() {
                let mut input = None;
                let mut output = None;
                for endpoint in alternate.endpoints() {
                    if endpoint.transfer_type() != TransferType::Bulk {
                        continue;
                    }
                    match endpoint.direction() {
                        Direction::In => input = Some(endpoint.address()),
                        Direction::Out => output = Some(endpoint.address()),
                    }
                }
                if let (Some(input), Some(output)) = (input, output) {
                    return Ok(BulkEndpoints {
                        interface: interface.interface_number(),
                        input,
                        output,
                    });
                }
            }
        }
        Err("accessory exposes no interface with bulk input and output".to_owned())
    }

    /// Watches re-enumeration and unplug events. Session ownership is handed
    /// to the caller, keeping USB discovery independent from AA framing/TLS.
    pub async fn watch(mut on_event: impl FnMut(DeviceEvent)) -> Result<(), String> {
        let mut watcher = nusb::watch_devices().map_err(|error| error.to_string())?;
        while let Some(event) = watcher.next().await {
            match event {
                HotplugEvent::Connected(info) if is_accessory(&info) => {
                    on_event(DeviceEvent::Accessory(info));
                }
                HotplugEvent::Connected(info) if is_candidate(&info) => {
                    on_event(DeviceEvent::Candidate(info));
                }
                HotplugEvent::Connected(_) => {}
                HotplugEvent::Disconnected(id) => on_event(DeviceEvent::Removed(id)),
            }
        }
        Err("USB hotplug stream ended".to_owned())
    }
}

const IDENTITY_STRINGS: [&str; 6] = [
    "Project Argo",
    "Wired projection",
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccessoryState {
    Absent,
    Switching,
    Present,
}

#[derive(Debug)]
pub struct AccessoryLifecycle {
    serial: Option<String>,
    state: AccessoryState,
}

impl Default for AccessoryLifecycle {
    fn default() -> Self {
        Self {
            serial: None,
            state: AccessoryState::Absent,
        }
    }
}

impl AccessoryLifecycle {
    pub fn candidate_seen(&mut self, serial: &str) -> bool {
        if self.state != AccessoryState::Absent {
            return false;
        }
        self.serial = Some(serial.to_owned());
        self.state = AccessoryState::Switching;
        true
    }

    pub fn accessory_seen(&mut self, serial: &str) -> bool {
        if self.state != AccessoryState::Switching || self.serial.as_deref() != Some(serial) {
            return false;
        }
        self.state = AccessoryState::Present;
        true
    }

    pub fn unplugged(&mut self, serial: &str) -> bool {
        if self.serial.as_deref() != Some(serial) {
            return false;
        }
        self.serial = None;
        self.state = AccessoryState::Absent;
        true
    }

    pub fn state(&self) -> AccessoryState {
        self.state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeUsb {
        requests: Vec<UsbControlRequest>,
    }

    impl UsbControlTransport for FakeUsb {
        type Error = ();

        fn control(&mut self, request: UsbControlRequest) -> Result<Vec<u8>, Self::Error> {
            let reply = match request {
                UsbControlRequest::In {
                    request: REQUEST_GET_PROTOCOL,
                    ..
                } => vec![2, 0],
                _ => Vec::new(),
            };
            self.requests.push(request);
            Ok(reply)
        }
    }

    #[test]
    fn aoap_uses_get_protocol_strings_and_start() {
        let mut usb = FakeUsb::default();
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
            usb.requests.last(),
            Some(UsbControlRequest::Out {
                request: REQUEST_START,
                data,
                ..
            }) if data.is_empty()
        ));
    }

    #[test]
    fn reenumeration_and_unplug_are_explicit() {
        let mut lifecycle = AccessoryLifecycle::default();
        assert!(lifecycle.candidate_seen("phone-1"));
        assert_eq!(lifecycle.state(), AccessoryState::Switching);
        assert!(!lifecycle.accessory_seen("another-phone"));
        assert!(lifecycle.accessory_seen("phone-1"));
        assert_eq!(lifecycle.state(), AccessoryState::Present);
        assert!(lifecycle.unplugged("phone-1"));
        assert_eq!(lifecycle.state(), AccessoryState::Absent);
    }
}
