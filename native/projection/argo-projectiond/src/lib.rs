//! Native projection sidecar foundation.
//!
//! The public host protocol is projection-neutral. Android Auto USB and
//! session code live below separate traits so a later Wi-Fi transport can feed
//! the same session engine and a CarPlay engine can use the same host IPC.

pub mod aa_channels;
#[cfg(unix)]
pub mod aa_session;
pub mod aa_tls;
pub mod aa_wire;
pub mod configuration;
pub mod daemon_state;
pub mod host_control;
pub mod identity;
pub mod ipc;
#[cfg(unix)]
pub mod ipc_server;
pub mod logging;
pub mod media;
#[cfg(unix)]
pub mod native_playback;
pub mod session;
pub mod usb;
#[cfg(feature = "linux-usb")]
pub mod usb_runtime;
#[cfg(all(test, unix))]
mod wired_tests;
