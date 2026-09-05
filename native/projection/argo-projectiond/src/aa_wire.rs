//! Post-version AA framing, with per-channel plaintext reassembly after TLS.
use std::collections::BTreeMap;
pub const MAX_MESSAGE: usize = 4 * 1024 * 1024;
pub struct Packet {
    pub channel: u8,
    pub flags: u8,
    pub bytes: Vec<u8>,
}
#[derive(Default)]
pub struct PacketDecoder {
    buffered: Vec<u8>,
}
impl PacketDecoder {
    pub fn push(&mut self, bytes: &[u8]) -> Result<(), String> {
        if self.buffered.len() + bytes.len() > 128 * 1024 {
            return Err("AA receive buffer limit".into());
        }
        self.buffered.extend_from_slice(bytes);
        Ok(())
    }
    pub fn packet(&mut self) -> Result<Option<Packet>, String> {
        if self.buffered.len() < 4 {
            return Ok(None);
        }
        let flags = self.buffered[1];
        if flags & !0x0f != 0 {
            return Err("unknown AA frame flags".into());
        }
        let size = u16::from_be_bytes([self.buffered[2], self.buffered[3]]) as usize;
        if size == 0 {
            return Err("empty AA frame".into());
        }
        let header = if flags & 3 == 1 { 8 } else { 4 };
        if self.buffered.len() < header {
            return Ok(None);
        }
        if header == 8 {
            let total = u32::from_be_bytes(self.buffered[4..8].try_into().unwrap()) as usize;
            if total == 0 || total > MAX_MESSAGE {
                return Err("AA fragment declaration limit".into());
            }
        }
        if self.buffered.len() < header + size {
            return Ok(None);
        }
        let packet = Packet {
            channel: self.buffered[0],
            flags,
            bytes: self.buffered[header..header + size].to_vec(),
        };
        self.buffered.drain(..header + size);
        Ok(Some(packet))
    }
    pub fn disconnect(&self) -> Result<(), String> {
        if self.buffered.is_empty() {
            Ok(())
        } else {
            Err("AA disconnected mid-frame".into())
        }
    }
}
#[derive(Default)]
pub struct Messages {
    fragments: BTreeMap<u8, (u8, Vec<u8>)>,
}
impl Messages {
    pub fn accept(
        &mut self,
        channel: u8,
        flags: u8,
        bytes: Vec<u8>,
    ) -> Result<Option<Vec<u8>>, String> {
        if flags & 1 != 0 {
            if self.fragments.contains_key(&channel) {
                return Err("AA fragment overwritten".into());
            }
            if flags & 2 != 0 {
                return Ok(Some(bytes));
            }
            if self.fragments.len() >= 16 {
                return Err("too many AA fragment channels".into());
            }
            self.fragments.insert(channel, (flags & 0x0c, Vec::new()));
        }
        let total: usize = self.fragments.values().map(|(_, b)| b.len()).sum();
        if total + bytes.len() > MAX_MESSAGE {
            return Err("AA reassembly limit".into());
        }
        let (original, data) = self
            .fragments
            .get_mut(&channel)
            .ok_or("AA continuation without first fragment")?;
        if *original != flags & 0x0c {
            return Err("AA fragment flags changed".into());
        }
        data.extend(bytes);
        if flags & 2 != 0 {
            return Ok(self.fragments.remove(&channel).map(|(_, b)| b));
        }
        Ok(None)
    }
}
pub fn frame(channel: u8, flags: u8, payload: &[u8]) -> Result<Vec<u8>, String> {
    if payload.is_empty() || payload.len() > u16::MAX as usize {
        return Err("AA outbound frame limit".into());
    }
    let mut wire = vec![channel, flags];
    wire.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    wire.extend_from_slice(payload);
    Ok(wire)
}
pub fn encrypted_frames(channel: u8, control: bool, records: &[u8]) -> Result<Vec<u8>, String> {
    let mut pieces = Vec::new();
    let mut offset = 0;
    while offset < records.len() {
        if records.len() - offset < 5 {
            return Err("short outbound TLS header".into());
        }
        let length = 5 + u16::from_be_bytes([records[offset + 3], records[offset + 4]]) as usize;
        if offset + length > records.len() {
            return Err("short outbound TLS record".into());
        }
        pieces.push(&records[offset..offset + length]);
        offset += length;
    }
    let mut wire = Vec::new();
    for (index, bytes) in pieces.iter().enumerate() {
        let flags = 8
            | if control { 4 } else { 0 }
            | if index == 0 { 1 } else { 0 }
            | if index + 1 == pieces.len() { 2 } else { 0 };
        let mut packet = frame(channel, flags, bytes)?;
        if flags & 3 == 1 {
            packet.splice(4..4, (records.len() as u32).to_be_bytes());
        }
        wire.extend(packet);
    }
    Ok(wire)
}
