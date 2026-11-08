// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

use std::fs;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::thread::sleep;
use std::time::Instant;

use crate::*;

const I2C_SLAVE: libc::c_ulong = 0x0703;

const GPIO_CHIP: &str = "/dev/gpiochip0";
const GPIO_V2_LINE_FLAG_OUTPUT: u64 = 1 << 3;
const GPIO_V2_GET_LINE_IOCTL: u32 =
    (3 << 30) | ((size_of::<LineRequest>() as u32) << 16) | (0xB4 << 8) | 0x07;
const GPIO_V2_LINE_SET_VALUES_IOCTL: u32 =
    (3 << 30) | ((size_of::<LineValues>() as u32) << 16) | (0xB4 << 8) | 0x0F;

const POWER_OFF_SETTLE: Duration = Duration::from_millis(50);
const POWER_ON_SETTLE: Duration = Duration::from_millis(100);

#[repr(C)]
struct LineRequest {
    offsets: [u32; 64],
    consumer: [u8; 32],
    flags: u64,
    num_attrs: u32,
    config_padding: [u32; 5],
    attrs: [[u64; 3]; 10],
    num_lines: u32,
    event_buffer_size: u32,
    padding: [u32; 5],
    fd: i32,
}

#[repr(C)]
struct LineValues {
    bits: u64,
    mask: u64,
}

const _: () = assert!(size_of::<LineRequest>() == 592 && size_of::<LineValues>() == 16);

struct PowerLine(fs::File);

impl PowerLine {
    fn on(gpio: u32) -> Result<Self, MfiError> {
        let chip = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(GPIO_CHIP)
            .map_err(|e| MfiError::Io(format!("open {GPIO_CHIP}: {e}")))?;
        let mut req: LineRequest = unsafe { std::mem::zeroed() };
        req.offsets[0] = gpio;
        req.num_lines = 1;
        req.flags = GPIO_V2_LINE_FLAG_OUTPUT;
        req.consumer[..8].copy_from_slice(b"livi-mfi");
        if unsafe { libc::ioctl(chip.as_raw_fd(), GPIO_V2_GET_LINE_IOCTL as _, &mut req) } < 0 {
            return Err(MfiError::Io(format!(
                "claim gpio {gpio}: {}",
                std::io::Error::last_os_error()
            )));
        }
        let line = Self(unsafe { <fs::File as std::os::fd::FromRawFd>::from_raw_fd(req.fd) });
        sleep(POWER_OFF_SETTLE);
        line.set(true)
            .map_err(|e| MfiError::Io(format!("power gpio {gpio}: {e}")))?;
        sleep(POWER_ON_SETTLE);
        Ok(line)
    }

    fn set(&self, on: bool) -> std::io::Result<()> {
        let mut values = LineValues {
            bits: u64::from(on),
            mask: 1,
        };
        if unsafe {
            libc::ioctl(
                self.0.as_raw_fd(),
                GPIO_V2_LINE_SET_VALUES_IOCTL as _,
                &mut values,
            )
        } < 0
        {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }
}

impl Drop for PowerLine {
    fn drop(&mut self) {
        let _ = self.set(false);
    }
}

pub struct I2cCoprocessor {
    file: fs::File,
    addr: u16,
    protocol_major: Option<u8>,
    _power: Option<PowerLine>,
}

impl I2cCoprocessor {
    pub fn open(bus: u32, power_gpio: i32) -> Result<Self, MfiError> {
        let power = match u32::try_from(power_gpio) {
            Ok(gpio) => Some(PowerLine::on(gpio)?),
            Err(_) => None,
        };
        let bus_path = format!("/dev/i2c-{bus}");
        let addr = Self::probe(&bus_path)?;
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&bus_path)
            .map_err(|e| MfiError::Io(format!("open {bus_path}: {e}")))?;
        set_slave(&file, addr)?;
        let mut chip = Self {
            file,
            addr,
            protocol_major: None,
            _power: power,
        };
        chip.protocol_major = chip.read_reg(REG_PROTOCOL_MAJOR, 1).ok().map(|v| v[0]);
        Ok(chip)
    }

    pub fn address(&self) -> u16 {
        self.addr
    }

    fn probe(bus_path: &str) -> Result<u16, MfiError> {
        let deadline = Instant::now() + PROBE_TIMEOUT;
        while Instant::now() < deadline {
            for cand in DEV_ADDR_CANDIDATES {
                let Ok(mut f) = fs::OpenOptions::new().read(true).write(true).open(bus_path) else {
                    continue;
                };
                if set_slave(&f, cand).is_err() {
                    continue;
                }
                let mut buf = [0u8; 1];
                if read_once(&mut f, REG_DEVICE_VERSION, &mut buf).is_ok() {
                    return Ok(cand);
                }
            }
            sleep(BUSY_RETRY);
        }
        Err(MfiError::NoChip {
            probed: DEV_ADDR_CANDIDATES.to_vec(),
        })
    }

    fn retry(
        &mut self,
        what: &str,
        mut op: impl FnMut(&mut fs::File) -> bool,
    ) -> Result<(), MfiError> {
        let deadline = Instant::now() + IO_TIMEOUT;
        loop {
            if op(&mut self.file) {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(MfiError::Timeout(what.to_string()));
            }
            sleep(BUSY_RETRY);
        }
    }

    fn read_reg(&mut self, reg: u8, n: usize) -> Result<Vec<u8>, MfiError> {
        read_reg_bounded(&mut self.file, reg, n, IO_TIMEOUT)
    }

    fn write_reg(&mut self, reg: u8, data: &[u8]) -> Result<(), MfiError> {
        let mut frame = Vec::with_capacity(data.len() + 1);
        frame.push(reg);
        frame.extend_from_slice(data);
        self.retry(&format!("write at 0x{reg:02X}"), |f| {
            f.write_all(&frame).is_ok()
        })
    }
}

/// Select/read is one complete transaction. A short/failed read can have
/// advanced the chip's pointer: never continue it with read_exact on the tail.
fn read_selected(io: &mut (impl Read + Write), reg: u8, output: &mut [u8]) -> std::io::Result<()> {
    match io.write(&[reg])? {
        1 => {}
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WriteZero,
                "short register select",
            ));
        }
    }
    let size = io.read(output)?;
    if size != output.len() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "short register read",
        ));
    }
    Ok(())
}

fn read_once(io: &mut (impl Read + Write), reg: u8, output: &mut [u8]) -> std::io::Result<()> {
    // Experimental PIO workaround: the first receive after a long transfer can
    // contain a stale byte. Discard one byte from an immutable register, then
    // explicitly reselect the actual target. No control/error register is used.
    read_selected(io, REG_PROTOCOL_MAJOR, &mut [0])?;
    read_selected(io, reg, output)
}

fn read_reg_bounded(
    io: &mut (impl Read + Write),
    reg: u8,
    size: usize,
    budget: Duration,
) -> Result<Vec<u8>, MfiError> {
    if !(1..=CERTIFICATE_MAX).contains(&size) {
        return Err(MfiError::ResponseSize {
            what: "register read",
            size,
            maximum: CERTIFICATE_MAX,
        });
    }
    let mut output = vec![0; size];
    let deadline = Instant::now() + budget;
    loop {
        match read_once(io, reg, &mut output) {
            Ok(()) => return Ok(output),
            Err(error) => {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err(MfiError::Timeout(format!(
                        "read register 0x{reg:02X}: {error}"
                    )));
                }
                sleep(BUSY_RETRY.min(remaining));
                // The retry budget includes the wait; don't start another
                // blocking kernel transaction after it has already expired.
                if Instant::now() >= deadline {
                    return Err(MfiError::Timeout(format!(
                        "read register 0x{reg:02X}: {error}"
                    )));
                }
            }
        }
    }
}

fn read_data_bounded(
    io: &mut (impl Read + Write),
    length_reg: u8,
    data_reg: u8,
    what: &'static str,
    maximum: usize,
) -> Result<Vec<u8>, MfiError> {
    let length = read_reg_bounded(io, length_reg, 2, IO_TIMEOUT)?;
    let size = usize::from(u16::from_be_bytes([length[0], length[1]]));
    if !(1..=maximum).contains(&size) {
        return Err(MfiError::ResponseSize {
            what,
            size,
            maximum,
        });
    }
    read_reg_bounded(io, data_reg, size, IO_TIMEOUT)
}

fn set_slave(file: &fs::File, addr: u16) -> Result<(), MfiError> {
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), I2C_SLAVE as _, addr as libc::c_ulong) };
    if rc < 0 {
        Err(MfiError::Io(format!(
            "I2C_SLAVE 0x{addr:02X}: {}",
            std::io::Error::last_os_error()
        )))
    } else {
        Ok(())
    }
}

impl AuthCoprocessor for I2cCoprocessor {
    fn protocol_major(&mut self) -> Result<u8, MfiError> {
        match self.protocol_major {
            Some(v) => Ok(v),
            None => {
                let v = self.read_reg(REG_PROTOCOL_MAJOR, 1)?[0];
                self.protocol_major = Some(v);
                Ok(v)
            }
        }
    }

    fn read_certificate(&mut self) -> Result<Vec<u8>, MfiError> {
        read_data_bounded(
            &mut self.file,
            REG_CERT_LENGTH,
            REG_CERT_DATA,
            "certificate",
            CERTIFICATE_MAX,
        )
    }

    fn generate_challenge_response(&mut self, challenge: &[u8]) -> Result<Vec<u8>, MfiError> {
        let n = challenge.len();
        if !(CHALLENGE_MIN..=CHALLENGE_MAX).contains(&n) {
            return Err(MfiError::ChallengeSize(n));
        }
        self.write_reg(REG_CHALLENGE_LENGTH, &(n as u16).to_be_bytes())?;
        self.write_reg(REG_CHALLENGE_DATA, challenge)?;
        self.write_reg(REG_AUTH_CONTROL_STATUS, &[AUTH_START])?;

        sleep(Duration::from_millis(10));
        let deadline = Instant::now() + AUTH_TIMEOUT;
        loop {
            if let Ok(status) = self.read_reg(REG_AUTH_CONTROL_STATUS, 1)
                && status[0] == AUTH_DONE
            {
                break;
            }
            if Instant::now() >= deadline {
                let error_code = self.read_reg(REG_ERROR_CODE, 1).ok().map(|v| v[0]);
                return Err(MfiError::AuthFailed { error_code });
            }
            sleep(AUTH_POLL);
        }

        read_data_bounded(
            &mut self.file,
            REG_SIGNATURE_LENGTH,
            REG_SIGNATURE_DATA,
            "signature",
            SIGNATURE_MAX,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;

    #[derive(Debug, PartialEq)]
    enum Operation {
        Select(u8),
        Read(u8, usize),
    }
    struct Bus {
        selected: u8,
        offset: usize,
        stale: bool,
        certificate: Vec<u8>,
        signature: Vec<u8>,
        length_override: Option<(u8, u16)>,
        fail_data: usize,
        short_length: usize,
        operations: Vec<Operation>,
    }
    impl Default for Bus {
        fn default() -> Self {
            Self {
                selected: 0,
                offset: 0,
                stale: false,
                certificate: (0..945).map(|n| (n % 251) as u8).collect(),
                signature: vec![0x57; 128],
                length_override: None,
                fail_data: 0,
                short_length: 0,
                operations: Vec::new(),
            }
        }
    }
    impl Write for Bus {
        fn write(&mut self, value: &[u8]) -> io::Result<usize> {
            assert_eq!(value.len(), 1, "tests permit register selection only");
            self.selected = value[0];
            self.offset = 0;
            self.operations.push(Operation::Select(self.selected));
            Ok(1)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    impl Read for Bus {
        fn read(&mut self, output: &mut [u8]) -> io::Result<usize> {
            self.operations
                .push(Operation::Read(self.selected, output.len()));
            if self.selected == REG_CERT_DATA && self.fail_data != 0 {
                self.fail_data -= 1;
                // A failed syscall may still have advanced the device pointer.
                self.offset += 3;
                self.stale = true;
                return Err(io::ErrorKind::WouldBlock.into());
            }
            let contents = match self.selected {
                REG_PROTOCOL_MAJOR => vec![2],
                REG_DEVICE_VERSION => vec![7],
                REG_CERT_LENGTH | REG_SIGNATURE_LENGTH => {
                    let length = self
                        .length_override
                        .filter(|(reg, _)| *reg == self.selected)
                        .map(|(_, length)| length)
                        .unwrap_or_else(|| {
                            if self.selected == REG_CERT_LENGTH {
                                self.certificate.len() as u16
                            } else {
                                self.signature.len() as u16
                            }
                        });
                    length.to_be_bytes().to_vec()
                }
                REG_CERT_DATA => self.certificate.clone(),
                REG_SIGNATURE_DATA => self.signature.clone(),
                other => panic!("unexpected read at 0x{other:02X}"),
            };
            let mut size = output.len().min(contents.len().saturating_sub(self.offset));
            if self.selected == REG_CERT_LENGTH && self.short_length != 0 {
                self.short_length -= 1;
                size = 1;
            }
            output[..size].copy_from_slice(&contents[self.offset..self.offset + size]);
            self.offset += size;
            if self.stale && size != 0 {
                output[0] = 0x9C;
                self.stale = false;
            }
            // Model the observed cold-boot failure: the next receive following
            // a long certificate read returns a stale first byte.
            if size > 2 {
                self.stale = true;
            }
            Ok(size)
        }
    }

    #[test]
    fn immutable_priming_discards_stale_first_byte_between_repeated_certificate_reads() {
        let mut bus = Bus::default();
        for _ in 0..3 {
            let result = read_data_bounded(
                &mut bus,
                REG_CERT_LENGTH,
                REG_CERT_DATA,
                "certificate",
                CERTIFICATE_MAX,
            )
            .unwrap();
            assert_eq!(result, bus.certificate);
        }
        // Without priming, the same model reproduces the reported 0x9CB1 length.
        let mut unprimed = [0; 2];
        read_selected(&mut bus, REG_CERT_LENGTH, &mut unprimed).unwrap();
        assert_eq!(unprimed, [0x9C, 0xB1]);
        let major = read_reg_bounded(&mut bus, REG_PROTOCOL_MAJOR, 1, IO_TIMEOUT).unwrap();
        assert_eq!(major, [2]);
    }

    #[test]
    fn failed_data_read_retries_priming_and_reselects_actual_register() {
        let mut bus = Bus {
            fail_data: 1,
            ..Bus::default()
        };
        let result = read_reg_bounded(&mut bus, REG_CERT_DATA, 945, IO_TIMEOUT).unwrap();
        assert_eq!(result, bus.certificate);
        let selections = bus
            .operations
            .iter()
            .filter_map(|op| match op {
                Operation::Select(reg) => Some(*reg),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(
            selections,
            [
                REG_PROTOCOL_MAJOR,
                REG_CERT_DATA,
                REG_PROTOCOL_MAJOR,
                REG_CERT_DATA
            ]
        );
    }

    #[test]
    fn short_read_is_restarted_at_register_boundary_instead_of_continuing_the_tail() {
        let mut bus = Bus {
            short_length: 1,
            ..Bus::default()
        };
        let result = read_reg_bounded(&mut bus, REG_CERT_LENGTH, 2, IO_TIMEOUT).unwrap();
        assert_eq!(result, [3, 0xB1]);
        let reads = bus
            .operations
            .iter()
            .filter_map(|op| match op {
                Operation::Read(REG_CERT_LENGTH, size) => Some(*size),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(reads, [2, 2]);
    }

    #[test]
    fn certificate_and_signature_lengths_are_checked_before_any_data_register_read() {
        for (length_reg, data_reg, name, maximum) in [
            (
                REG_CERT_LENGTH,
                REG_CERT_DATA,
                "certificate",
                CERTIFICATE_MAX,
            ),
            (
                REG_SIGNATURE_LENGTH,
                REG_SIGNATURE_DATA,
                "signature",
                SIGNATURE_MAX,
            ),
        ] {
            for size in [0, maximum + 1, 0x9CB1] {
                let mut bus = Bus {
                    length_override: Some((length_reg, size as u16)),
                    ..Bus::default()
                };
                assert!(
                    matches!(read_data_bounded(&mut bus, length_reg, data_reg, name, maximum),
                    Err(MfiError::ResponseSize { size: actual, .. }) if actual == size)
                );
                assert!(!bus.operations.contains(&Operation::Select(data_reg)));
            }
            let mut bus = Bus {
                certificate: vec![0x43; CERTIFICATE_MAX],
                signature: vec![0x53; SIGNATURE_MAX],
                ..Bus::default()
            };
            assert_eq!(
                read_data_bounded(&mut bus, length_reg, data_reg, name, maximum)
                    .unwrap()
                    .len(),
                maximum
            );
        }
    }

    struct Busy(usize);
    impl Write for Busy {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            self.0 += 1;
            Err(io::ErrorKind::WouldBlock.into())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    impl Read for Busy {
        fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
            panic!("failed selection must not start a read")
        }
    }
    #[test]
    fn retry_and_allocation_are_bounded_before_touching_an_invalid_target() {
        let mut bus = Busy(0);
        for size in [0, CERTIFICATE_MAX + 1] {
            assert!(matches!(
                read_reg_bounded(&mut bus, REG_CERT_DATA, size, IO_TIMEOUT),
                Err(MfiError::ResponseSize { .. })
            ));
        }
        assert_eq!(bus.0, 0);
        assert!(matches!(
            read_reg_bounded(&mut bus, REG_CERT_LENGTH, 2, Duration::ZERO),
            Err(MfiError::Timeout(_))
        ));
        assert_eq!(bus.0, 1);
    }
}
