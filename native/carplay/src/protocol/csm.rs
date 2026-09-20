//! Strict iAP2 control messages. IDs and field layouts are interoperability
//! facts researched from LIVI at the revision recorded in `protocol/mod.rs`.

use super::Error;
use std::{net::IpAddr, time::Duration};

pub const START_IDENTIFICATION: u16 = 0x1d00;
pub const IDENTIFICATION: u16 = 0x1d01;
pub const IDENTIFICATION_ACCEPTED: u16 = 0x1d02;
pub const IDENTIFICATION_REJECTED: u16 = 0x1d03;
pub const REQUEST_CERTIFICATE: u16 = 0xaa00;
pub const CERTIFICATE: u16 = 0xaa01;
pub const REQUEST_SIGNATURE: u16 = 0xaa02;
pub const SIGNATURE: u16 = 0xaa03;
pub const AUTH_FAILED: u16 = 0xaa04;
pub const AUTH_SUCCEEDED: u16 = 0xaa05;
pub const AVAILABILITY: u16 = 0x4300;
pub const START_SESSION: u16 = 0x4301;
const MAX_MESSAGE: usize = 65525; // Fits one maximum-size iAP2 data frame.
const MAX_PARAMS: usize = 64;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Parameter {
    pub id: u16,
    pub value: Vec<u8>,
}

impl Parameter {
    pub fn new(id: u16, value: impl Into<Vec<u8>>) -> Self {
        Self {
            id,
            value: value.into(),
        }
    }

    pub fn string(id: u16, value: &str) -> Result<Self, Error> {
        if value.is_empty() || value.len() > 255 || value.bytes().any(|b| b == 0 || b < 0x20) {
            return Err(Error::Bounds);
        }
        let mut bytes = value.as_bytes().to_vec();
        bytes.push(0);
        Ok(Self::new(id, bytes))
    }

    pub fn group(id: u16, fields: &[Self]) -> Result<Self, Error> {
        Ok(Self::new(id, encode_parameters(fields)?))
    }
}

fn encode_parameters(parameters: &[Parameter]) -> Result<Vec<u8>, Error> {
    if parameters.len() > MAX_PARAMS {
        return Err(Error::Bounds);
    }
    let mut bytes = Vec::new();
    for p in parameters {
        let length = p.value.len().checked_add(4).ok_or(Error::Bounds)?;
        if length > u16::MAX as usize || bytes.len() + length > MAX_MESSAGE - 6 {
            return Err(Error::Bounds);
        }
        bytes.extend_from_slice(&(length as u16).to_be_bytes());
        bytes.extend_from_slice(&p.id.to_be_bytes());
        bytes.extend_from_slice(&p.value);
    }
    Ok(bytes)
}

pub fn decode_parameters(mut bytes: &[u8]) -> Result<Vec<Parameter>, Error> {
    if bytes.len() > MAX_MESSAGE - 6 {
        return Err(Error::Bounds);
    }
    let mut fields = Vec::new();
    while !bytes.is_empty() {
        if bytes.len() < 4 || fields.len() == MAX_PARAMS {
            return Err(Error::Bounds);
        }
        let length = usize::from(u16::from_be_bytes([bytes[0], bytes[1]]));
        if length < 4 || length > bytes.len() {
            return Err(Error::Malformed);
        }
        fields.push(Parameter::new(
            u16::from_be_bytes([bytes[2], bytes[3]]),
            &bytes[4..length],
        ));
        bytes = &bytes[length..];
    }
    Ok(fields)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Message {
    pub id: u16,
    pub parameters: Vec<Parameter>,
}

impl Message {
    pub fn empty(id: u16) -> Self {
        Self {
            id,
            parameters: Vec::new(),
        }
    }

    pub fn encode(&self) -> Result<Vec<u8>, Error> {
        let parameters = encode_parameters(&self.parameters)?;
        let mut bytes = Vec::with_capacity(parameters.len() + 6);
        bytes.extend_from_slice(&[0x40, 0x40]);
        bytes.extend_from_slice(&((parameters.len() + 6) as u16).to_be_bytes());
        bytes.extend_from_slice(&self.id.to_be_bytes());
        bytes.extend(parameters);
        Ok(bytes)
    }

    /// Exactly one complete message is accepted; trailing bytes are never ignored.
    pub fn decode(bytes: &[u8]) -> Result<Self, Error> {
        if !(6..=MAX_MESSAGE).contains(&bytes.len()) {
            return Err(Error::Bounds);
        }
        if bytes[..2] != [0x40, 0x40]
            || usize::from(u16::from_be_bytes([bytes[2], bytes[3]])) != bytes.len()
        {
            return Err(Error::Malformed);
        }
        Ok(Self {
            id: u16::from_be_bytes([bytes[4], bytes[5]]),
            parameters: decode_parameters(&bytes[6..])?,
        })
    }

    pub fn one(&self, id: u16) -> Result<&[u8], Error> {
        let mut matching = self.parameters.iter().filter(|p| p.id == id);
        let parameter = matching.next().ok_or(Error::Malformed)?;
        if matching.next().is_some() {
            return Err(Error::Malformed);
        }
        Ok(&parameter.value)
    }
}

/// Minimal wired identity. Optional vehicle/navigation capabilities are omitted.
pub struct AccessoryIdentity {
    pub name: String,
    pub model: String,
    pub manufacturer: String,
    pub serial: String,
    pub firmware: String,
    pub hardware: String,
    pub language: String,
    pub usb_interface: u8,
}

impl AccessoryIdentity {
    pub fn wired_message(&self) -> Result<Message, Error> {
        let mut fields = Vec::new();
        for (index, value) in [
            &self.name,
            &self.model,
            &self.manufacturer,
            &self.serial,
            &self.firmware,
            &self.hardware,
        ]
        .iter()
        .enumerate()
        {
            fields.push(Parameter::string(index as u16, value)?);
        }
        // Only claim messages implemented here. No metadata/vehicle subscriptions.
        // Core authentication/identification messages are implicit in iAP2;
        // these lists describe the optional application messages only.
        let sent: Vec<u8> = [START_SESSION]
            .iter()
            .flat_map(|v| v.to_be_bytes())
            .collect();
        let received: Vec<u8> = [AVAILABILITY, 0x4e0e]
            .iter()
            .flat_map(|v| v.to_be_bytes())
            .collect();
        fields.extend([
            Parameter::new(6, sent),
            Parameter::new(7, received),
            Parameter::new(8, vec![0]), // No advertised advanced charging support.
            Parameter::new(9, vec![0, 0]),
            Parameter::string(12, &self.language)?,
            Parameter::string(13, &self.language)?,
            Parameter::group(
                16,
                &[
                    Parameter::new(0, vec![0, 1]),
                    Parameter::string(1, "Argo USB")?,
                    Parameter::new(2, vec![]),
                    Parameter::new(3, vec![self.usb_interface]),
                    Parameter::new(4, vec![]),
                ],
            )?,
        ]);
        Ok(Message {
            id: IDENTIFICATION,
            parameters: fields,
        })
    }
}

/// Addresses are supplied by host interface inventory, never by the phone.
pub enum SessionTransport {
    Wired {
        address: IpAddr,
    },
    Wireless {
        address: IpAddr,
        ssid: String,
        passphrase: String,
        channel: u8,
    },
}

pub struct StartSession {
    pub transport: SessionTransport,
    pub port: u16,
    pub device_identifier: String,
    pub public_key: [u8; 32],
    pub source_version: String,
}

impl StartSession {
    pub fn message(&self) -> Result<Message, Error> {
        if self.port == 0 {
            return Err(Error::Bounds);
        }
        let (address, transport) = match &self.transport {
            SessionTransport::Wired { address } => (*address, 0),
            SessionTransport::Wireless { address, .. } => (*address, 1),
        };
        if address.is_unspecified()
            || address.is_loopback()
            || address.is_multicast()
            || matches!(address, IpAddr::V4(ip) if ip.is_broadcast())
        {
            return Err(Error::Bounds);
        }
        let network = match &self.transport {
            SessionTransport::Wired { .. } => vec![Parameter::string(0, &address.to_string())?],
            SessionTransport::Wireless {
                ssid,
                passphrase,
                channel,
                ..
            } => {
                if ssid.len() > 32
                    || !(8..=63).contains(&passphrase.len())
                    || *channel == 0
                    || *channel > 196
                {
                    return Err(Error::Bounds);
                }
                vec![
                    Parameter::string(0, ssid)?,
                    Parameter::string(1, passphrase)?,
                    Parameter::new(2, vec![*channel]),
                    Parameter::string(3, &address.to_string())?,
                    Parameter::new(4, vec![2]),
                ] // WPA2 Personal; AP owner must verify actual policy.
            }
        };
        let key: String = self.public_key.iter().map(|b| format!("{b:02x}")).collect();
        Ok(Message {
            id: START_SESSION,
            parameters: vec![
                Parameter::group(transport, &network)?,
                Parameter::new(2, u32::from(self.port).to_be_bytes().to_vec()),
                Parameter::string(3, &self.device_identifier)?,
                Parameter::string(4, &key)?,
                Parameter::string(5, &self.source_version)?,
            ],
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AuthenticationState {
    AwaitCertificateRequest,
    AwaitCertificate,
    AwaitChallenge,
    AwaitSignature,
    AwaitResult,
    Authenticated,
    Closed,
}

// Deliberately no Debug: callers must not log challenge/signature contents.
pub enum AuthenticationAction {
    ReadRealCertificate,
    SignWithRealCoprocessor(Vec<u8>),
    Send(Message),
    Complete,
}

/// Session-scoped authentication sequencing. I/O must call `fail` on any error;
/// no cached result or local signature can substitute for the real coprocessor.
pub struct Authentication {
    state: AuthenticationState,
    deadline: Duration,
}

impl Authentication {
    pub fn new(now: Duration) -> Self {
        Self {
            state: AuthenticationState::AwaitCertificateRequest,
            deadline: now.saturating_add(Duration::from_secs(15)),
        }
    }
    pub fn state(&self) -> AuthenticationState {
        self.state
    }
    pub fn fail(&mut self) {
        self.state = AuthenticationState::Closed;
    }
    pub fn check_deadline(&mut self, now: Duration) -> Result<(), Error> {
        if self.state == AuthenticationState::Closed {
            return Err(Error::State);
        }
        if self.state != AuthenticationState::Authenticated && now >= self.deadline {
            self.fail();
            return Err(Error::Timeout);
        }
        Ok(())
    }

    pub fn receive(
        &mut self,
        message: &Message,
        now: Duration,
    ) -> Result<AuthenticationAction, Error> {
        self.check_deadline(now)?;
        let outcome = match (self.state, message.id) {
            (_, AUTH_FAILED) => Err(Error::Rejected),
            (AuthenticationState::AwaitCertificateRequest, REQUEST_CERTIFICATE)
                if message.parameters.is_empty() =>
            {
                self.state = AuthenticationState::AwaitCertificate;
                Ok(AuthenticationAction::ReadRealCertificate)
            }
            (AuthenticationState::AwaitChallenge, REQUEST_SIGNATURE) => {
                let challenge = match message.one(0) {
                    Ok(value) => value,
                    Err(error) => return self.reject(error),
                };
                if message.parameters.len() != 1 || ![20, 32].contains(&challenge.len()) {
                    return self.reject(Error::Bounds);
                }
                self.state = AuthenticationState::AwaitSignature;
                Ok(AuthenticationAction::SignWithRealCoprocessor(
                    challenge.to_vec(),
                ))
            }
            (AuthenticationState::AwaitResult, AUTH_SUCCEEDED) if message.parameters.is_empty() => {
                self.state = AuthenticationState::Authenticated;
                Ok(AuthenticationAction::Complete)
            }
            _ => Err(Error::State),
        };
        if outcome.is_err() {
            self.fail();
        }
        outcome
    }

    fn reject<T>(&mut self, error: Error) -> Result<T, Error> {
        self.fail();
        Err(error)
    }

    pub fn certificate(
        &mut self,
        certificate: Vec<u8>,
        now: Duration,
    ) -> Result<AuthenticationAction, Error> {
        self.check_deadline(now)?;
        if self.state != AuthenticationState::AwaitCertificate {
            return self.reject(Error::State);
        }
        if certificate.is_empty() || certificate.len() > 8192 {
            return self.reject(Error::Bounds);
        }
        self.state = AuthenticationState::AwaitChallenge;
        Ok(AuthenticationAction::Send(Message {
            id: CERTIFICATE,
            parameters: vec![Parameter::new(0, certificate)],
        }))
    }

    pub fn signature(
        &mut self,
        signature: Vec<u8>,
        now: Duration,
    ) -> Result<AuthenticationAction, Error> {
        self.check_deadline(now)?;
        if self.state != AuthenticationState::AwaitSignature {
            return self.reject(Error::State);
        }
        if signature.is_empty() || signature.len() > 512 {
            return self.reject(Error::Bounds);
        }
        self.state = AuthenticationState::AwaitResult;
        Ok(AuthenticationAction::Send(Message {
            id: SIGNATURE,
            parameters: vec![Parameter::new(0, signature)],
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn message_boundaries_reject_truncation_trailing_and_bad_parameters() {
        let valid = [0x40, 0x40, 0, 11, 0xaa, 1, 0, 5, 0, 0, 42];
        let message = Message::decode(&valid).unwrap();
        assert_eq!(message.one(0), Ok([42].as_slice()));
        assert_eq!(message.encode().unwrap(), valid);
        for length in 0..valid.len() {
            assert!(Message::decode(&valid[..length]).is_err());
        }
        let mut extra = valid.to_vec();
        extra.push(0);
        assert_eq!(Message::decode(&extra), Err(Error::Malformed));
        assert_eq!(decode_parameters(&[0, 0, 0, 0]), Err(Error::Malformed));
        assert_eq!(Parameter::string(0, "Argo\0phone"), Err(Error::Bounds));
    }

    #[test]
    fn authentication_cannot_skip_real_certificate_or_signature() {
        let mut auth = Authentication::new(Duration::ZERO);
        assert!(matches!(
            auth.receive(&Message::empty(REQUEST_CERTIFICATE), Duration::ZERO),
            Ok(AuthenticationAction::ReadRealCertificate)
        ));
        assert!(matches!(
            auth.certificate(vec![1, 2, 3], Duration::ZERO),
            Ok(AuthenticationAction::Send(_))
        ));
        let challenge = Message {
            id: REQUEST_SIGNATURE,
            parameters: vec![Parameter::new(0, vec![7; 32])],
        };
        assert!(matches!(
            auth.receive(&challenge, Duration::ZERO),
            Ok(AuthenticationAction::SignWithRealCoprocessor(_))
        ));
        assert!(matches!(
            auth.signature(vec![8; 64], Duration::ZERO),
            Ok(AuthenticationAction::Send(_))
        ));
        assert!(matches!(
            auth.receive(&Message::empty(AUTH_SUCCEEDED), Duration::ZERO),
            Ok(AuthenticationAction::Complete)
        ));
        assert_eq!(auth.state(), AuthenticationState::Authenticated);
        let mut fresh = Authentication::new(Duration::ZERO);
        assert!(matches!(
            fresh.receive(&Message::empty(AUTH_SUCCEEDED), Duration::ZERO),
            Err(Error::State)
        ));
        assert_eq!(fresh.state(), AuthenticationState::Closed);
    }

    #[test]
    fn authentication_timeout_and_teardown_do_not_leave_signing_open() {
        let mut auth = Authentication::new(Duration::ZERO);
        assert_eq!(
            auth.check_deadline(Duration::from_secs(15)),
            Err(Error::Timeout)
        );
        assert!(matches!(
            auth.signature(vec![1; 64], Duration::from_secs(15)),
            Err(Error::State)
        ));
        let mut auth = Authentication::new(Duration::ZERO);
        auth.fail();
        assert!(matches!(
            auth.receive(&Message::empty(REQUEST_CERTIFICATE), Duration::ZERO),
            Err(Error::State)
        ));
    }

    #[test]
    fn start_session_wired_has_only_host_wired_address_and_big_endian_port() {
        let start = StartSession {
            transport: SessionTransport::Wired {
                address: "fe80::1234".parse().unwrap(),
            },
            port: 7000,
            device_identifier: "02:00:00:00:00:01".into(),
            public_key: [1; 32],
            source_version: "1.0".into(),
        };
        let wire = start.message().unwrap().encode().unwrap();
        let parsed = Message::decode(&wire).unwrap();
        assert_eq!(parsed.id, START_SESSION);
        assert_eq!(parsed.one(2), Ok(7000u32.to_be_bytes().as_slice()));
        assert!(parsed.one(1).is_err());
        let group = decode_parameters(parsed.one(0).unwrap()).unwrap();
        assert_eq!(group, vec![Parameter::string(0, "fe80::1234").unwrap()]);
    }

    #[test]
    fn identification_does_not_claim_optional_vehicle_or_radio_capabilities() {
        let identity = AccessoryIdentity {
            name: "Argo".into(),
            model: "Test".into(),
            manufacturer: "Argo".into(),
            serial: "synthetic-1".into(),
            firmware: "1".into(),
            hardware: "1".into(),
            language: "en".into(),
            usb_interface: 3,
        };
        let message = identity.wired_message().unwrap();
        let transport = decode_parameters(message.one(16).unwrap()).unwrap();
        assert_eq!(transport.iter().find(|p| p.id == 3).unwrap().value, vec![3]);
        assert!(!transport.iter().any(|p| p.id == 5));
        for absent in [17, 20, 21, 22, 24, 30] {
            assert!(message.one(absent).is_err());
        }
        assert_eq!(
            Message::decode(&message.encode().unwrap()).unwrap(),
            message
        );
    }
}
