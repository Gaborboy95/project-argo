# Native projection boundary

`argo-projectiond` owns Android Auto USB/Wi-Fi transport, TLS, channel state,
Bluetooth bootstrap, AP ownership and native PCM playback. The separate
`argo-projection-view` library decodes the daemon's native video feed and supplies
IHS platform-view buffers. Video/PCM never cross Dart control IPC.

IPC v5 carries bounded session/configuration/metadata/connectivity messages.
The daemon owns external identity; per-session display/audio settings are frozen.
USB and Wi-Fi share one engine and an exclusive session lease. A validated video
AV START latches wireless readiness independently of visible/suspended presentation.
Internal typed failures determine bounded retries; uncertain cleanup prevents replacement.

The native view checks host capabilities and actual EGL/Vulkan device support,
converts H.264 to RGB with GStreamer and exports supported linear DMA-BUFs.
SHM requires a real granted buffer. PCM uses separate bounded GStreamer pipelines
with GstSystemClock and normal PipeWire synchronization.

- [Build and dependency reference](../../tool/projection/README.md)
- [Session ownership and IPC](../../docs/architecture.md)
- [Wireless admission and lifecycle](../../docs/wireless.md)
- [Compatibility limits](../../docs/status.md)
