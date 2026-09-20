//! LIVI Link MFi interoperability, independently implemented from the protocol
//! reviewed at f-io/LIVI a23dc0c5fcdb6d069c679eddfd73298e58f44783.
//! No key extraction, authentication emulation, firmware or persistent writes.
use crate::discovery::Discovery;
use std::{
    fmt,
    future::Future,
    io,
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::Mutex,
    time::timeout,
};

pub const MFI_PORT: u16 = 5000;
pub const WIFI_PORT: u16 = 5001;
pub const MAX_CERTIFICATE: usize = 4096;
pub const MAX_SIGNATURE: usize = 512;
pub const MAX_CHALLENGE: usize = 128;

#[derive(Debug)]
pub enum Error {
    Busy,
    Timeout,
    Io(io::ErrorKind),
    Invalid(&'static str),
    Remote,
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Busy => write!(f, "another LIVI Link operation is in progress"),
            Self::Timeout => write!(f, "LIVI Link operation timed out"),
            Self::Io(kind) => write!(f, "LIVI Link unavailable ({kind:?})"),
            Self::Invalid(reason) => write!(f, "invalid LIVI Link response: {reason}"),
            Self::Remote => write!(f, "LIVI Link rejected the operation"),
        }
    }
}
impl std::error::Error for Error {}
impl From<io::Error> for Error {
    fn from(value: io::Error) -> Self {
        if value.kind() == io::ErrorKind::TimedOut {
            Self::Timeout
        } else {
            Self::Io(value.kind())
        }
    }
}

#[derive(Clone, Debug)]
pub struct LinkConfig {
    pub discovery: Discovery,
    pub mfi_port: u16,
    pub wifi_port: u16,
    pub deadline: Duration,
}
impl Default for LinkConfig {
    fn default() -> Self {
        Self {
            discovery: Discovery::Mdns,
            mfi_port: MFI_PORT,
            wifi_port: WIFI_PORT,
            deadline: Duration::from_secs(5),
        }
    }
}

struct MfiConnection {
    socket: TcpStream,
    certificate: Option<Vec<u8>>,
}

#[derive(Clone)]
pub struct LinkClient {
    pub(crate) config: LinkConfig,
    pub(crate) permit: Arc<Mutex<()>>,
    mfi_socket: Arc<Mutex<Option<MfiConnection>>>,
}
impl LinkClient {
    pub fn new(config: LinkConfig) -> Result<Self, Error> {
        if config.deadline.is_zero()
            || config.deadline > Duration::from_secs(30)
            || config.mfi_port == 0
            || config.wifi_port == 0
        {
            return Err(Error::Invalid("configuration bounds"));
        }
        Ok(Self {
            config,
            permit: Arc::new(Mutex::new(())),
            mfi_socket: Arc::new(Mutex::new(None)),
        })
    }
    pub async fn resolve(&self) -> Result<Ipv4Addr, Error> {
        Ok(self.config.discovery.resolve(self.config.deadline).await?)
    }
    pub(crate) async fn connect(&self, port: u16) -> Result<TcpStream, Error> {
        let address = self.resolve().await?;
        let socket = TcpStream::connect(SocketAddr::from((address, port))).await?;
        socket.set_nodelay(true)?;
        Ok(socket)
    }
    /// Reuse a healthy connection, matching the single-client remote service.
    /// Take ownership during IO: cancellation/errors drop the socket, never reuse partial replies.
    /// Concurrent callers receive Busy (there is no unbounded queue or implicit sign retry).
    async fn request(
        &self,
        bytes: &[u8],
        maximum: usize,
        cached_certificate: bool,
    ) -> Result<Vec<u8>, Error> {
        let _guard = self.permit.try_lock().map_err(|_| Error::Busy)?;
        let mut connection = self.mfi_socket.lock().await;
        if cached_certificate
            && let Some(certificate) = connection
                .as_ref()
                .and_then(|state| state.certificate.as_ref())
        {
            return Ok(certificate.clone());
        }
        let previous = connection.take();
        let (body, socket) = deadline(self.config.deadline, async {
            let mut state = match previous {
                Some(state) => state,
                None => MfiConnection {
                    socket: self.connect(self.config.mfi_port).await?,
                    certificate: None,
                },
            };
            let socket = &mut state.socket;
            socket.write_all(bytes).await?;
            let mut header = [0; 3];
            socket.read_exact(&mut header).await?;
            if header[0] != 0 {
                return Err(Error::Remote);
            }
            let size = u16::from_be_bytes([header[1], header[2]]) as usize;
            if size == 0 || size > maximum {
                return Err(Error::Invalid("MFi payload length"));
            }
            let mut body = vec![0; size];
            socket.read_exact(&mut body).await?;
            if bytes == [3] && !matches!(body.as_slice(), [2 | 3]) {
                return Err(Error::Invalid("unknown MFi protocol generation"));
            }
            if bytes == [1] {
                state.certificate = Some(body.clone());
            }
            Ok((body, state))
        })
        .await?;
        *connection = Some(socket);
        Ok(body)
    }
    pub async fn certificate(&self) -> Result<Vec<u8>, Error> {
        self.request(&[1], MAX_CERTIFICATE, false).await
    }
    /// Reuse the public certificate only for this healthy MFi connection. A real
    /// phone challenge still goes to the coprocessor every time; this is not a health probe.
    pub async fn authentication_certificate(&self) -> Result<Vec<u8>, Error> {
        self.request(&[1], MAX_CERTIFICATE, true).await
    }
    pub async fn sign(&self, challenge: &[u8]) -> Result<Vec<u8>, Error> {
        if challenge.is_empty() || challenge.len() > MAX_CHALLENGE {
            return Err(Error::Invalid("challenge length"));
        }
        let mut request = Vec::with_capacity(challenge.len() + 3);
        request.push(2);
        request.extend_from_slice(&(challenge.len() as u16).to_be_bytes());
        request.extend_from_slice(challenge);
        self.request(&request, MAX_SIGNATURE, false).await
    }
    pub async fn protocol_major(&self) -> Result<u8, Error> {
        let reply = self.request(&[3], 1, false).await?;
        match reply[0] {
            major @ (2 | 3) => Ok(major),
            _ => Err(Error::Invalid("unknown MFi protocol generation")),
        }
    }
}

pub(crate) async fn deadline<T>(
    duration: Duration,
    operation: impl Future<Output = Result<T, Error>>,
) -> Result<T, Error> {
    timeout(duration, operation)
        .await
        .map_err(|_| Error::Timeout)?
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test(start_paused = true)]
    async fn deadline_bounds_a_stalled_connect_future() {
        let operation = std::future::pending::<Result<(), Error>>();
        assert!(matches!(
            deadline(Duration::from_secs(2), operation).await,
            Err(Error::Timeout)
        ));
    }
}
