//! Bounded, transport-independent CarPlay protocol building blocks.
//!
//! Wire-format research: f-io / Lasse Heitgres, LIVI, revision
//! a23dc0c5fcdb6d069c679eddfd73298e58f44783. See CREDITS.md and
//! docs/carplay-livi-review.md. These are independently written codecs, not
//! imported LIVI source. They do not constitute an operational CarPlay stack:
//! USB/lockdown, authenticated AirPlay and native audio still need integration.

pub mod airplay;
#[cfg(feature = "linux-audio")]
pub mod audio;
pub mod csm;
pub mod iap2;
#[cfg(all(feature = "linux-usb", target_os = "linux"))]
pub mod ncm;
#[cfg(feature = "airplay")]
pub mod pairing;
#[cfg(feature = "airplay")]
pub mod receiver;
#[cfg(all(feature = "linux-usb", target_os = "linux"))]
pub mod usb_mux;
#[cfg(all(feature = "linux-usbmuxd", target_os = "linux"))]
pub mod usbmux;
pub mod wired;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    Bounds,
    Malformed,
    Checksum,
    Unsupported,
    State,
    Sequence,
    Timeout,
    Rejected,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "CarPlay protocol {self:?}")
    }
}

impl std::error::Error for Error {}
