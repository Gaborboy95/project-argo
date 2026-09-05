//! Android Auto's in-memory TLS client. Never use this peer policy for HTTP,
//! network services, or IPC authentication. Trust is the explicitly attached
//! USB peer, not a WebPKI hostname. Legacy AA certificates may not be WebPKI
//! compatible; certificate-chain and signature authentication are intentionally
//! not claimed here. TLS Finished verification and encryption remain mandatory.
use crate::identity::AndroidAutoIdentity;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, ClientConnection, DigitallySignedStruct, SignatureScheme};
use std::{
    io::{self, Read, Write},
    sync::Arc,
};

#[derive(Debug)]
struct AttachedUsbPeer;
impl ServerCertVerifier for AttachedUsbPeer {
    fn verify_server_cert(
        &self,
        cert: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        if cert.is_empty() || cert.len() > 64 * 1024 {
            return Err(rustls::Error::General(
                "invalid AA peer certificate size".into(),
            ));
        }
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }
    fn verify_tls13_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("AA TLS 1.3 is disabled".into()))
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

pub struct AaTls {
    connection: ClientConnection,
}
impl AaTls {
    pub fn new(identity: &AndroidAutoIdentity) -> Result<Self, String> {
        identity
            .validate_files()
            .map_err(|error| format!("AA identity: {error:?}"))?;
        let cert = std::fs::read(&identity.certificate).map_err(|e| e.to_string())?;
        let key = std::fs::read(&identity.private_key).map_err(|e| e.to_string())?;
        let certs = rustls_pemfile::certs(&mut cert.as_slice())
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        let key = rustls_pemfile::private_key(&mut key.as_slice())
            .map_err(|e| e.to_string())?
            .ok_or("AA private key missing")?;
        let mut config =
            ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
                .with_protocol_versions(&[&rustls::version::TLS12])
                .map_err(|e| e.to_string())?
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(AttachedUsbPeer))
                .with_client_auth_cert(certs, key)
                .map_err(|e| e.to_string())?;
        config.enable_sni = false;
        config.resumption = rustls::client::Resumption::disabled();
        let mut connection = ClientConnection::new(
            Arc::new(config),
            ServerName::IpAddress(std::net::Ipv4Addr::LOCALHOST.into()),
        )
        .map_err(|e| e.to_string())?;
        connection.set_buffer_limit(Some(256 * 1024));
        Ok(Self { connection })
    }
    pub fn handshaking(&self) -> bool {
        self.connection.is_handshaking()
    }
    pub fn receive(&mut self, bytes: &[u8]) -> Result<Vec<u8>, String> {
        if bytes.len() > 64 * 1024 {
            return Err("oversized TLS record input".into());
        }
        let mut cursor = io::Cursor::new(bytes);
        while cursor.position() < bytes.len() as u64 {
            self.connection
                .read_tls(&mut cursor)
                .map_err(|e| e.to_string())?;
            self.connection
                .process_new_packets()
                .map_err(|e| format!("AA TLS: {e}"))?;
        }
        let mut plaintext = Vec::new();
        match self.connection.reader().read_to_end(&mut plaintext) {
            Ok(_) => {}
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e.to_string()),
        }
        Ok(plaintext)
    }
    pub fn pending(&mut self) -> Result<Vec<u8>, String> {
        let mut bytes = Vec::new();
        while self.connection.wants_write() {
            self.connection
                .write_tls(&mut bytes)
                .map_err(|e| e.to_string())?;
        }
        Ok(bytes)
    }
    pub fn encrypt(&mut self, bytes: &[u8]) -> Result<Vec<u8>, String> {
        if self.handshaking() {
            return Err("AA data before TLS completion".into());
        }
        self.connection
            .writer()
            .write_all(bytes)
            .map_err(|e| e.to_string())?;
        self.pending()
    }
}
