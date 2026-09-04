use std::fs;
use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct AndroidAutoIdentity {
    pub certificate: PathBuf,
    pub private_key: PathBuf,
}

#[derive(Debug, PartialEq, Eq)]
pub enum IdentityError {
    MissingCertificate,
    MissingPrivateKey,
    InvalidCertificatePem,
    InvalidPrivateKeyPem,
    CertificateKeyMismatch,
}

impl AndroidAutoIdentity {
    /// Structural validation only. A hardware TLS engine must additionally
    /// parse the certificate and verify that the private key matches before it
    /// sends any handshake bytes.
    pub fn validate_files(&self) -> Result<(), IdentityError> {
        let cert = read(&self.certificate).ok_or(IdentityError::MissingCertificate)?;
        let key = read(&self.private_key).ok_or(IdentityError::MissingPrivateKey)?;
        if !contains_pem(&cert, "CERTIFICATE") {
            return Err(IdentityError::InvalidCertificatePem);
        }
        if !contains_pem(&key, "PRIVATE KEY") {
            return Err(IdentityError::InvalidPrivateKeyPem);
        }
        let mut certificate_reader = BufReader::new(
            File::open(&self.certificate).map_err(|_| IdentityError::MissingCertificate)?,
        );
        let certificates = rustls_pemfile::certs(&mut certificate_reader)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| IdentityError::InvalidCertificatePem)?;
        let mut key_reader = BufReader::new(
            File::open(&self.private_key).map_err(|_| IdentityError::MissingPrivateKey)?,
        );
        let private_key = rustls_pemfile::private_key(&mut key_reader)
            .map_err(|_| IdentityError::InvalidPrivateKeyPem)?
            .ok_or(IdentityError::InvalidPrivateKeyPem)?;
        let provider = rustls::crypto::ring::default_provider();
        rustls::sign::CertifiedKey::from_der(certificates, private_key, &provider)
            .map_err(|_| IdentityError::CertificateKeyMismatch)?;
        Ok(())
    }
}

fn read(path: &Path) -> Option<Vec<u8>> {
    fs::read(path).ok()
}

fn contains_pem(bytes: &[u8], label: &str) -> bool {
    let start = format!("-----BEGIN {label}-----");
    let end = format!("-----END {label}-----");
    let text = String::from_utf8_lossy(bytes);
    text.contains(&start) && text.contains(&end)
}
