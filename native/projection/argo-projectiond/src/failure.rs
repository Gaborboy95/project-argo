//! Internal termination policy; diagnostic wording is never a retry input.
use std::{fmt, io};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    TransportLoss,
    NetworkLoss,
    SetupTimeout,
    Cancelled,
    Authorization,
    Protocol,
    Configuration,
    Cleanup,
    BootstrapClosed,
}
#[derive(Clone, Debug)]
pub struct Failure {
    pub kind: Kind,
    pub detail: String,
    pub cleanup: Option<String>,
}
impl Failure {
    pub fn new(kind: Kind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
            cleanup: None,
        }
    }
    pub fn configuration(detail: impl ToString) -> Self {
        Self::new(Kind::Configuration, detail.to_string())
    }
    pub fn network(detail: impl ToString) -> Self {
        Self::new(Kind::NetworkLoss, detail.to_string())
    }
    pub fn timeout(detail: impl Into<String>) -> Self {
        Self::new(Kind::SetupTimeout, detail)
    }
    pub fn cancelled() -> Self {
        Self::new(Kind::Cancelled, "Explicit connection request stopped")
    }
    pub fn retryable(&self) -> bool {
        self.cleanup.is_none()
            && matches!(
                self.kind,
                Kind::TransportLoss | Kind::NetworkLoss | Kind::SetupTimeout
            )
    }
}
impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.detail)?;
        if let Some(cleanup) = &self.cleanup {
            write!(f, "; cleanup: {cleanup}")?;
        }
        Ok(())
    }
}
impl std::error::Error for Failure {}
// Protocol parsers retain their existing diagnostics. System/configuration
// boundaries explicitly map to their respective kind instead.
impl From<String> for Failure {
    fn from(s: String) -> Self {
        Self::new(Kind::Protocol, s)
    }
}
impl From<&str> for Failure {
    fn from(s: &str) -> Self {
        s.to_owned().into()
    }
}
impl From<io::Error> for Failure {
    fn from(e: io::Error) -> Self {
        let kind = match e.kind() {
            io::ErrorKind::UnexpectedEof
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::NotConnected
            | io::ErrorKind::TimedOut => Kind::TransportLoss,
            io::ErrorKind::NetworkDown
            | io::ErrorKind::NetworkUnreachable
            | io::ErrorKind::HostUnreachable => Kind::NetworkLoss,
            io::ErrorKind::InvalidData => Kind::Protocol,
            _ => Kind::Configuration,
        };
        Self::new(kind, e.to_string())
    }
}
impl From<crate::session::VersionNegotiationError> for Failure {
    fn from(e: crate::session::VersionNegotiationError) -> Self {
        use crate::session::{FrameError, VersionNegotiationError as V};
        match e {
            V::Transport(e) => e.into(),
            V::Disconnected => Self::new(Kind::TransportLoss, e.to_string()),
            V::Frame(FrameError::DisconnectMidFrame(_)) => {
                Self::new(Kind::TransportLoss, e.to_string())
            }
            _ => Self::new(Kind::Protocol, e.to_string()),
        }
    }
}

impl From<bluer::Error> for Failure {
    fn from(error: bluer::Error) -> Self {
        use bluer::ErrorKind as B;
        let kind = match error.kind {
            B::AuthenticationCanceled
            | B::AuthenticationFailed
            | B::AuthenticationRejected
            | B::AuthenticationTimeout
            | B::NotAuthorized => Kind::Authorization,
            B::ConnectionAttemptFailed => Kind::TransportLoss,
            B::NotReady => Kind::NetworkLoss,
            _ => Kind::Configuration,
        };
        Self::new(kind, error.to_string())
    }
}
