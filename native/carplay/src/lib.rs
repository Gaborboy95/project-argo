//! Native CarPlay work informed by f-io / Lasse Heitgres and LIVI at
//! a23dc0c5fcdb6d069c679eddfd73298e58f44783. See CREDITS.md and
//! docs/carplay-livi-review.md. Protocol interoperability, not an MFi emulator.
pub mod artwork;
pub mod diagnostic;
pub mod discovery;
pub mod dongle_iap;
pub mod hci;
pub mod link;
#[cfg(feature = "airplay")]
pub mod mdns_advertisement;
pub mod media;
pub mod protocol;
pub mod vhci;
pub mod wifi;
#[cfg(target_os = "linux")]
pub mod wireless_bluetooth;
#[cfg(all(feature = "airplay", feature = "linux-usb"))]
pub mod wireless_network;

#[cfg(feature = "airplay")]
pub mod runtime_control;

#[cfg(feature = "airplay")]
pub mod session_runtime;

#[cfg(all(feature = "airplay", feature = "linux-usb"))]
pub mod wired_runtime;

#[cfg(all(feature = "airplay", feature = "linux-usb"))]
pub mod wireless_runtime;

pub mod usb_lease;

#[cfg(all(feature = "airplay", feature = "linux-usb"))]
pub mod management;
