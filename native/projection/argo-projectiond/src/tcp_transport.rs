//! An admitted TCP stream; this module never opens a listener.
use crate::session::AndroidAutoTransport;
use std::{future::Future, io, pin::Pin, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};
pub struct TcpAaTransport {
    stream: TcpStream,
}
impl TcpAaTransport {
    pub(crate) fn admitted(stream: TcpStream) -> io::Result<Self> {
        stream.set_nodelay(true)?;
        socket2::SockRef::from(&stream).set_tcp_keepalive(
            &socket2::TcpKeepalive::new()
                .with_time(Duration::from_secs(5))
                .with_interval(Duration::from_secs(5)),
        )?;
        #[cfg(target_os = "linux")]
        socket2::SockRef::from(&stream).set_tcp_user_timeout(Some(Duration::from_secs(15)))?;
        Ok(Self { stream })
    }
}
impl AndroidAutoTransport for TcpAaTransport {
    fn wireless(&self) -> bool {
        true
    }
    fn read<'a>(
        &'a mut self,
        bytes: &'a mut [u8],
    ) -> Pin<Box<dyn Future<Output = io::Result<usize>> + Send + 'a>> {
        Box::pin(async move {
            let size = bytes.len().min(16384);
            self.stream.read(&mut bytes[..size]).await
        })
    }
    fn write_all<'a>(
        &'a mut self,
        bytes: &'a [u8],
    ) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + 'a>> {
        Box::pin(async move {
            if bytes.len() > 256 * 1024 {
                return Err(io::Error::other("TCP AA write exceeds bound"));
            }
            tokio::time::timeout(Duration::from_secs(5), self.stream.write_all(bytes))
                .await
                .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "TCP AA write timed out"))?
        })
    }
    fn close(&mut self) -> Pin<Box<dyn Future<Output = io::Result<()>> + Send + '_>> {
        Box::pin(async move { self.stream.shutdown().await })
    }
}
