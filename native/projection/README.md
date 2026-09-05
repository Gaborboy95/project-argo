# Argo projection native boundary

This directory contains two independently deployable pieces:

- `argo-projectiond`: the projection-protocol sidecar and bounded, versioned
  control IPC. USB transport and the Android Auto session engine are separate.
- `argo-projection-view`: an out-of-tree ivi-homescreen platform-view producer.
  It queries capabilities, never switches on an embedder backend name, and
  implements the required per-view renegotiation callback.

Media does not cross the Dart control socket. The intended native data path is:

```text
argo-projectiond media socket -> GStreamer -> argo-projection-view -> IHS grant
```

The view discovers the active EGL/Vulkan render device and exports native
linear RGB DMA-BUFs after verifying IHS format/modifier support. It prefers
texture import, then a DRM plane, then SHM only when a real SHM buffer is
provided. Current upstream IHS advertises SHM without allocating its buffer;
that case fails explicitly. H.264 decode and RGB conversion use GStreamer;
NV12 is never assumed importable as RGB. Native PCM playback uses separate
GStreamer/PipeWire pipelines and metadata-only Argo focus gains.

No Android Auto certificate or private key is included. The hardware-proven
USB/version path now continues into memory TLS 1.2, service discovery and AV
channels. Identity files are explicitly configured and key-pair validated.
Read the runbook's narrow USB peer-trust policy before deployment.

See [the checkpoint runbook](../../tool/projection/README.md) for build,
permissions, standalone debugging, the exact homescreen launch, and the
required remaining end-to-end hardware acceptance.
