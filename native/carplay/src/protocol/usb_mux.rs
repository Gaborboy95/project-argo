//! Bounded, session-owned local USB multiplexer for iPhone configuration 6.
//! The system usbmuxd remains the trust-record authority; it does not own this
//! CarPlay USB function. Framing researched in the pinned LIVI reference.
use super::{Error, ncm};
use nusb::{
    Endpoint,
    transfer::{Buffer, Bulk, In, Out},
};
use std::{collections::BTreeMap, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, DuplexStream, WriteHalf},
    sync::{mpsc, oneshot},
    task::{JoinHandle, JoinSet},
    time::timeout,
};
type Result<T> = std::result::Result<T, Error>;
fn failure<T>(_: T) -> Error {
    Error::Rejected
}
const MAX_FRAME: usize = 65536;

fn envelope(protocol: u32, sequence: u16, body: &[u8]) -> Result<Vec<u8>> {
    if body.len() + 16 > MAX_FRAME {
        return Err(Error::Bounds);
    }
    let mut bytes = Vec::with_capacity(body.len() + 16);
    bytes.extend_from_slice(&protocol.to_be_bytes());
    bytes.extend_from_slice(&((body.len() + 16) as u32).to_be_bytes());
    bytes.extend_from_slice(&0xfeedfaceu32.to_be_bytes());
    bytes.extend_from_slice(&sequence.to_be_bytes());
    bytes.extend_from_slice(&[0, 0]);
    bytes.extend_from_slice(body);
    Ok(bytes)
}
struct Packet {
    source: u16,
    destination: u16,
    sequence: u32,
    ack: u32,
    flags: u8,
    payload: Vec<u8>,
}
fn packet(bytes: &[u8]) -> Result<Packet> {
    if bytes.len() < 36
        || bytes.len() > MAX_FRAME
        || bytes[..4] != 6u32.to_be_bytes()
        || bytes[4..8] != (bytes.len() as u32).to_be_bytes()
        || bytes[8..12] != 0xfacefaceu32.to_be_bytes()
    {
        return Err(Error::Malformed);
    }
    let header = ((bytes[28] >> 4) as usize) * 4;
    if header < 20 || 16 + header > bytes.len() {
        return Err(Error::Bounds);
    }
    Ok(Packet {
        source: u16::from_be_bytes(bytes[16..18].try_into().unwrap()),
        destination: u16::from_be_bytes(bytes[18..20].try_into().unwrap()),
        sequence: u32::from_be_bytes(bytes[20..24].try_into().unwrap()),
        ack: u32::from_be_bytes(bytes[24..28].try_into().unwrap()),
        flags: bytes[29],
        payload: bytes[16 + header..].to_vec(),
    })
}
struct Connection {
    remote: u16,
    sent: u32,
    received: u32,
    acknowledged: u32,
    ready: Option<oneshot::Sender<Result<DuplexStream>>>,
    client: Option<DuplexStream>,
    writer: WriteHalf<DuplexStream>,
}
impl Connection {
    fn encode(&self, flags: u8, payload: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(20 + payload.len());
        bytes.extend_from_slice(&[0, 0]);
        bytes.extend_from_slice(&self.remote.to_be_bytes());
        bytes.extend_from_slice(&self.sent.to_be_bytes());
        bytes.extend_from_slice(&self.received.to_be_bytes());
        bytes.extend_from_slice(&[0x50, flags, 2, 0, 0, 0, 0, 0]);
        bytes.extend_from_slice(payload);
        bytes
    }
}
enum Event {
    Open(u16, oneshot::Sender<Result<DuplexStream>>),
    Data(u16, Vec<u8>),
    Closed(u16),
    Packet(Vec<u8>),
}
pub struct UsbMux {
    events: mpsc::Sender<Event>,
    task: JoinHandle<Result<()>>,
    pub udid: String,
}
impl UsbMux {
    pub async fn start() -> Result<Self> {
        let phone = ncm::one_phone().await?;
        let serial = phone.serial_number().ok_or(Error::Malformed)?;
        if !(8..=128).contains(&serial.len())
            || !serial.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
        {
            return Err(Error::Malformed);
        }
        let udid = if serial.len() == 24 {
            format!("{}-{}", &serial[..8], &serial[8..])
        } else {
            serial.to_owned()
        };
        let device = phone.open().await.map_err(failure)?;
        let config = device.active_configuration().map_err(failure)?;
        if config.configuration_value() != 6 {
            return Err(Error::State);
        }
        let interface = config
            .interface_alt_settings()
            .find(|i| i.class() == 255 && i.subclass() == 254 && i.protocol() == 2)
            .ok_or(Error::Unsupported)?;
        let input = interface
            .endpoints()
            .find(|e| {
                e.address() & 128 != 0 && e.transfer_type() == nusb::descriptors::TransferType::Bulk
            })
            .ok_or(Error::Malformed)?
            .address();
        let output = interface
            .endpoints()
            .find(|e| {
                e.address() & 128 == 0 && e.transfer_type() == nusb::descriptors::TransferType::Bulk
            })
            .ok_or(Error::Malformed)?
            .address();
        let interface = device
            .claim_interface(interface.interface_number())
            .await
            .map_err(failure)?;
        let mut input = interface.endpoint::<Bulk, In>(input).map_err(failure)?;
        let mut output = interface.endpoint::<Bulk, Out>(output).map_err(failure)?;
        let mut hello = vec![0; 20];
        hello[4..8].copy_from_slice(&20u32.to_be_bytes());
        hello[8..12].copy_from_slice(&2u32.to_be_bytes());
        write(&mut output, &hello).await?;
        timeout(Duration::from_secs(3), async {
            for _ in 0..8 {
                input.submit(Buffer::new(MAX_FRAME));
                let version = input.next_complete().await;
                version.status.map_err(failure)?;
                let bytes = &version.buffer;
                if bytes.len() >= 12
                    && bytes[..4] == [0, 0, 0, 0]
                    && bytes[8..12] == 2u32.to_be_bytes()
                {
                    return Ok(());
                }
            }
            Err(Error::Unsupported)
        })
        .await
        .map_err(|_| Error::Timeout)??;
        write(&mut output, &envelope(2, 0, &[7])?).await?;
        let (events, mut receiver) = mpsc::channel(16);
        let loop_events = events.clone();
        let task = tokio::spawn(async move {
            let result = async {
            let _interface = interface;
            let mut tasks = JoinSet::new();
            let incoming = loop_events.clone();
            tasks.spawn(async move {
                let mut pending = Vec::new();
                loop {
                    input.submit(Buffer::new(MAX_FRAME));
                    let completion = input.next_complete().await;
                    completion.status.map_err(failure)?;
                    if pending.len() + completion.buffer.len() > MAX_FRAME * 2 {
                        return Err(Error::Bounds);
                    }
                    pending.extend_from_slice(&completion.buffer);
                    while pending.len() >= 8 {
                        let size = u32::from_be_bytes(pending[4..8].try_into().unwrap()) as usize;
                        if !(16..=MAX_FRAME).contains(&size) {
                            return Err(Error::Bounds);
                        }
                        if pending.len() < size {
                            break;
                        }
                        let bytes = pending.drain(..size).collect();
                        incoming.send(Event::Packet(bytes)).await.map_err(failure)?;
                    }
                }
            });
            let mut connections: BTreeMap<u16, Connection> = BTreeMap::new();
            let mut port = 1u16;
            let mut sequence = 1u16;
            loop {
                let event = tokio::select! {value=receiver.recv()=>value.ok_or(Error::State)?,ended=tasks.join_next()=>{ended.ok_or(Error::State)?.map_err(failure)??;continue;}};
                match event {
                    Event::Open(remote, ready) => {
                        if connections.len() >= 4 || tasks.len() >= 9 || port == u16::MAX {
                            let _ = ready.send(Err(Error::Bounds));
                            continue;
                        }
                        let local = port;
                        port += 1;
                        let (client, stream) = tokio::io::duplex(131072);
                        let (mut reader, writer) = tokio::io::split(stream);
                        let sender = loop_events.clone();
                        tasks.spawn(async move {
                            let mut bytes = [0; 16384];
                            loop {
                                let size = reader.read(&mut bytes).await.map_err(failure)?;
                                if size == 0 {
                                    sender.send(Event::Closed(local)).await.map_err(failure)?;

                                    return Ok(());
                                }
                                sender
                                    .send(Event::Data(local, bytes[..size].to_vec()))
                                    .await
                                    .map_err(failure)?;
                            }
                        });
                        let connection = Connection {
                            remote,
                            sent: 0,
                            received: 0,
                            acknowledged: 0,
                            ready: Some(ready),
                            client: Some(client),
                            writer,
                        };
                        send(&mut output, &mut sequence, local, &connection, 2, &[]).await?;
                        connections.insert(local, connection);
                    }
                    Event::Data(local, bytes) => {
                        if let Some(connection) = connections.get_mut(&local) {
                            if connection.ready.is_some()
                                || connection.sent.wrapping_sub(connection.acknowledged) > 131072
                            {
                                return Err(Error::Bounds);
                            }
                            send(&mut output, &mut sequence, local, connection, 16, &bytes).await?;
                            connection.sent = connection.sent.wrapping_add(bytes.len() as u32);
                        }
                    }
                    Event::Closed(local) => {
                        if let Some(connection) = connections.remove(&local) {
                            send(&mut output, &mut sequence, local, &connection, 17, &[]).await?;
                        }
                    }
                    Event::Packet(bytes) => {
                        if bytes[..4] != 6u32.to_be_bytes() {
                            continue;
                        }
                        let packet = packet(&bytes)?;
                        let local = packet.destination;
                        if let Some(connection) = connections.get_mut(&local) {
                            if packet.source != connection.remote {
                                return Err(Error::Malformed);
                            }
                            if packet.flags & 4 != 0 {
                                connections.remove(&local);
                                continue;
                            }
                            if packet.flags & 18 == 18 && connection.ready.is_some() {
                                if packet.ack != 1 {
                                    return Err(Error::Sequence);
                                }
                                connection.sent = 1;
                                connection.acknowledged = 1;
                                connection.received = packet.sequence.wrapping_add(1);
                                send(&mut output, &mut sequence, local, connection, 16, &[])
                                    .await?;
                                let client = connection.client.take().ok_or(Error::State)?;
                                if connection.ready.take().unwrap().send(Ok(client)).is_err() {
                                    connections.remove(&local);
                                }
                                continue;
                            }
                            if connection.ready.is_some() {
                                return Err(Error::State);
                            }
                            if packet.flags & 16 != 0 {
                                if packet.ack.wrapping_sub(connection.acknowledged)
                                    <= connection.sent.wrapping_sub(connection.acknowledged)
                                {
                                    connection.acknowledged = packet.ack;
                                } else {
                                    return Err(Error::Sequence);
                                }
                            }
                            if !packet.payload.is_empty() {
                                if packet.sequence == connection.received {
                                    timeout(
                                        Duration::from_secs(2),
                                        connection.writer.write_all(&packet.payload),
                                    )
                                    .await
                                    .map_err(|_| Error::Timeout)?
                                    .map_err(failure)?;
                                    connection.received = connection
                                        .received
                                        .wrapping_add(packet.payload.len() as u32);
                                } else if packet.sequence.wrapping_add(packet.payload.len() as u32)
                                    != connection.received
                                {
                                    return Err(Error::Sequence);
                                }
                                send(&mut output, &mut sequence, local, connection, 16, &[])
                                    .await?;
                            }
                            if packet.flags & 1 != 0 {
                                connection.received = connection.received.wrapping_add(1);
                                send(&mut output, &mut sequence, local, connection, 16, &[])
                                    .await?;
                                connections.remove(&local);
                            }
                        }
                    }
                }
            }
            }.await;
            if let Err(error) = &result {
                eprintln!("Local USB multiplexer ended: {error}");
            }
            result
        });
        Ok(Self { events, task, udid })
    }
    pub async fn connect(&self, port: u16) -> Result<DuplexStream> {
        let (ready, receiver) = oneshot::channel();
        self.events
            .send(Event::Open(port, ready))
            .await
            .map_err(failure)?;
        timeout(Duration::from_secs(5), receiver)
            .await
            .map_err(|_| Error::Timeout)?
            .map_err(failure)?
    }
    pub async fn close(mut self) {
        self.task.abort();
        let _ = (&mut self.task).await;
    }
}
impl Drop for UsbMux {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn send(
    output: &mut Endpoint<Bulk, Out>,
    sequence: &mut u16,
    local: u16,
    connection: &Connection,
    flags: u8,
    bytes: &[u8],
) -> Result<()> {
    let mut tcp = connection.encode(flags, bytes);
    tcp[..2].copy_from_slice(&local.to_be_bytes());
    let message = envelope(6, *sequence, &tcp)?;
    *sequence = sequence.wrapping_add(1);
    write(output, &message).await
}
async fn write(output: &mut Endpoint<Bulk, Out>, bytes: &[u8]) -> Result<()> {
    let mut buffer = Buffer::new(bytes.len());
    buffer.extend_from_slice(bytes);
    output.submit(buffer);
    timeout(Duration::from_secs(3), output.next_complete())
        .await
        .map_err(|_| Error::Timeout)?
        .status
        .map_err(failure)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mux_packet_bounds_and_tcp_options() {
        let (_client, stream) = tokio::io::duplex(64);
        let (_reader, writer) = tokio::io::split(stream);
        let c = Connection {
            remote: 62078,
            sent: 1,
            received: 22,
            acknowledged: 1,
            ready: None,
            client: None,
            writer,
        };
        let tcp = c.encode(16, &[1, 2, 3]);
        let mut bytes = envelope(6, 65535, &tcp).unwrap();
        bytes[8..12].copy_from_slice(&0xfacefaceu32.to_be_bytes());
        let decoded = packet(&bytes).unwrap();
        assert_eq!(decoded.source, 0);
        assert_eq!(decoded.destination, 62078);
        assert_eq!(decoded.payload, [1, 2, 3]);
        for len in 0..bytes.len() {
            assert!(packet(&bytes[..len]).is_err());
        }
        let mut bad = bytes;
        bad[28] = 0xf0;
        assert!(packet(&bad).is_err());
    }
}
