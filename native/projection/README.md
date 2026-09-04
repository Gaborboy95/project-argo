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

The checked-in view implements the universal RGB `SOFTWARE_SHM` floor. Its
render-path selector prefers a compatible DMA-BUF texture and then a DRM plane,
but those paths are requested only after a decoder/exporter proves that its
fourcc and modifier intersect the formats advertised by IHS. In particular,
an NV12 decoder buffer is not assumed to be directly importable by an IHS
backend that currently grants RGB formats.

No Android Auto certificate or private key is included. A hardware session is
fail-closed until an independently provisioned compatible identity is supplied.
