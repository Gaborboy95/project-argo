//! Native projection sidecar foundation.
//!
//! The public host protocol is projection-neutral. Android Auto USB and
//! session code live below separate traits so a later Wi-Fi transport can feed
//! the same session engine and a CarPlay engine can use the same host IPC.

pub mod identity;
pub mod ipc;
pub mod media;
pub mod session;
pub mod usb;
