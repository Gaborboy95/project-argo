//! Bounded IPv4 discovery. mDNS wire behavior informed by f-io/LIVI revision
//! a23dc0c5fcdb6d069c679eddfd73298e58f44783; see docs/carplay-livi-review.md.
use std::{
    io,
    net::{Ipv4Addr, SocketAddrV4},
    time::Duration,
};
use tokio::{net::UdpSocket, time::timeout};

pub const LINK_NAME: &str = "livi-link.local";
const QUERY_ID: u16 = 0x4152;

/// A fixed address is an explicitly trusted diagnostic/test override, never a phone field.
#[derive(Clone, Debug)]
pub enum Discovery {
    Mdns,
    Address(Ipv4Addr),
}

impl Discovery {
    pub async fn resolve(&self, within: Duration) -> io::Result<Ipv4Addr> {
        if let Self::Address(address) = self {
            return Ok(*address);
        }
        timeout(within, discover())
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "LIVI Link mDNS unavailable"))?
    }
}

async fn discover() -> io::Result<Ipv4Addr> {
    // An ephemeral unicast-response query avoids a competing persistent :5353 daemon.
    // Query each current IPv4 interface: NCM is commonly not the default route.
    let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).await?;
    socket.set_multicast_ttl_v4(255)?;
    let mut query = vec![0x41, 0x52, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
    query.extend_from_slice(b"\x09livi-link\x05local\x00\x00\x01\x80\x01");
    send_queries(
        &socket,
        &query,
        interface_addresses()?,
        SocketAddrV4::new(Ipv4Addr::new(224, 0, 0, 251), 5353),
    )
    .await?;
    let mut response = [0; 1501];
    // Cap unrelated traffic as well as time spent waiting for a reply.
    for _ in 0..64 {
        let (length, from) = socket.recv_from(&mut response).await?;
        if from.port() != 5353 || length > 1500 {
            continue;
        }
        if let Some(address) = parse_answer(&response[..length]) {
            // The reference responds with the address of the interface it received on.
            if from.ip() == address {
                return Ok(address);
            }
        }
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidData,
        "mDNS response limit",
    ))
}

/// Interface inventory can change between getifaddrs and send. One failed
/// interface (for example a VPN going down) must not hide an available NCM link.
async fn send_queries(
    socket: &UdpSocket,
    query: &[u8],
    addresses: impl IntoIterator<Item = Ipv4Addr>,
    destination: SocketAddrV4,
) -> io::Result<()> {
    let mut sent = false;
    let mut last_error = None;
    for address in addresses {
        let result = match socket2::SockRef::from(socket).set_multicast_if_v4(&address) {
            Ok(()) => socket.send_to(query, destination).await.map(|_| ()),
            Err(error) => Err(error),
        };
        match result {
            Ok(()) => sent = true,
            Err(error) => last_error = Some(error),
        }
    }
    if sent {
        Ok(())
    } else {
        Err(last_error.unwrap_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotConnected,
                "No multicast interface accepted the Link query",
            )
        }))
    }
}

fn interface_addresses() -> io::Result<Vec<Ipv4Addr>> {
    let mut head = std::ptr::null_mut();
    // SAFETY: getifaddrs initializes a linked list which remains alive until freeifaddrs.
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut current = head;
    let mut addresses = Vec::new();
    while !current.is_null() {
        // SAFETY: pointers come from the live getifaddrs list; sockaddr family is checked.
        let item = unsafe { &*current };
        if !item.ifa_addr.is_null()
            && item.ifa_flags & libc::IFF_UP as u32 != 0
            && item.ifa_flags & libc::IFF_LOOPBACK as u32 == 0
            && item.ifa_flags & libc::IFF_MULTICAST as u32 != 0
            && unsafe { (*item.ifa_addr).sa_family } == libc::AF_INET as u16
        {
            let address = unsafe { &*item.ifa_addr.cast::<libc::sockaddr_in>() };
            let address = Ipv4Addr::from(address.sin_addr.s_addr.to_ne_bytes());
            if !addresses.contains(&address) && addresses.len() < 16 {
                addresses.push(address);
            }
        }
        current = item.ifa_next;
    }
    // SAFETY: exactly the list allocated above, freed once after all reads.
    unsafe {
        libc::freeifaddrs(head);
    }
    if addresses.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::NotConnected,
            "No IPv4 network interface",
        ));
    }
    Ok(addresses)
}

fn name(data: &[u8], offset: &mut usize) -> Option<String> {
    let mut position = *offset;
    let mut followed = false;
    let mut labels = Vec::new();
    let mut bytes = 0;
    for _ in 0..32 {
        let size = *data.get(position)? as usize;
        position += 1;
        if size & 0xc0 == 0xc0 {
            let destination = ((size & 0x3f) << 8) | *data.get(position)? as usize;
            if !followed {
                *offset = position + 1;
                followed = true;
            }
            position = destination;
            continue;
        }
        if size > 63 {
            return None;
        }
        if size == 0 {
            if !followed {
                *offset = position;
            }
            return Some(labels.join("."));
        }
        bytes += size + 1;
        if bytes > 254 {
            return None;
        }
        let label = std::str::from_utf8(data.get(position..position + size)?).ok()?;
        if !label.is_ascii() {
            return None;
        }
        labels.push(label.to_ascii_lowercase());
        position += size;
    }
    None
}

fn word(data: &[u8], index: usize) -> Option<u16> {
    Some(u16::from_be_bytes(
        data.get(index..index + 2)?.try_into().ok()?,
    ))
}

fn parse_answer(data: &[u8]) -> Option<Ipv4Addr> {
    if data.len() < 12 || word(data, 0)? != QUERY_ID || word(data, 2)? & 0xf80f != 0x8000 {
        return None;
    }
    let questions = word(data, 4)?;
    let records =
        u32::from(word(data, 6)?) + u32::from(word(data, 8)?) + u32::from(word(data, 10)?);
    if questions > 16 || records > 64 {
        return None;
    }
    let mut offset = 12;
    for _ in 0..questions {
        name(data, &mut offset)?;
        offset += 4;
    }
    for _ in 0..records {
        let record_name = name(data, &mut offset)?;
        let kind = word(data, offset)?;
        let class = word(data, offset + 2)? & 0x7fff;
        let ttl = u32::from_be_bytes(data.get(offset + 4..offset + 8)?.try_into().ok()?);
        let length = word(data, offset + 8)? as usize;
        offset += 10;
        let value = data.get(offset..offset + length)?;
        if record_name == LINK_NAME && kind == 1 && class == 1 && length == 4 && ttl != 0 {
            let address = Ipv4Addr::new(value[0], value[1], value[2], value[3]);
            if !address.is_unspecified()
                && !address.is_multicast()
                && !address.is_loopback()
                && !address.is_broadcast()
            {
                return Some(address);
            }
        }
        offset += length;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn synthetic_answer_and_bounds() {
        let mut reply = vec![0x41, 0x52, 0x84, 0, 0, 0, 0, 1, 0, 0, 0, 0];
        reply.extend_from_slice(
            b"\x09livi-link\x05local\x00\x00\x01\x00\x01\x00\x00\x00\x0a\x00\x04\x0a\x14\x1e\x28",
        );
        assert_eq!(parse_answer(&reply), Some(Ipv4Addr::new(10, 20, 30, 40)));
        for i in 0..reply.len() {
            assert_eq!(parse_answer(&reply[..i]), None);
        }
        reply[12] = 0xc0;
        reply[13] = 12;
        assert_eq!(parse_answer(&reply), None);
    }
    #[tokio::test]
    async fn a_failed_interface_does_not_prevent_queries_on_a_working_one() {
        let receiver = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).await.unwrap();
        let destination =
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, receiver.local_addr().unwrap().port());
        // 240/4 is deliberately not an assigned interface; loopback keeps every
        // test datagram local and requires no dongle or multicast LAN fixture.
        let absent = Ipv4Addr::new(240, 0, 0, 1);
        send_queries(
            &socket,
            b"fixture",
            [absent, Ipv4Addr::LOCALHOST],
            destination,
        )
        .await
        .unwrap();
        let mut bytes = [0; 16];
        let (length, _) = timeout(Duration::from_secs(1), receiver.recv_from(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&bytes[..length], b"fixture");
        assert!(
            send_queries(&socket, b"fixture", [absent], destination)
                .await
                .is_err()
        );
        assert!(
            send_queries(&socket, b"fixture", [], destination)
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn fixed_fixture_resolution() {
        assert_eq!(
            Discovery::Address(Ipv4Addr::LOCALHOST)
                .resolve(Duration::from_millis(1))
                .await
                .unwrap(),
            Ipv4Addr::LOCALHOST
        );
    }
}
