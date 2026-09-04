enum IhsProjectionSurfaceKind { dmaBufTexture, drmPlane, softwareShm }

final class IhsProjectionSurfaceCapabilities {
  const IhsProjectionSurfaceCapabilities({
    required this.offered,
    required this.formats,
  });

  final Set<IhsProjectionSurfaceKind> offered;
  final Set<String> formats;
}

final class ProjectionProducerCapabilities {
  const ProjectionProducerCapabilities({
    required this.dmaBufFormats,
    required this.canDirectScanout,
  });

  final Set<String> dmaBufFormats;
  final bool canDirectScanout;
}

/// Mirrors the native IHS decision without switching on backend identity.
IhsProjectionSurfaceKind selectIhsProjectionSurface({
  required IhsProjectionSurfaceCapabilities host,
  required ProjectionProducerCapabilities producer,
}) {
  final compatibleDmaBuf = producer.dmaBufFormats.any(host.formats.contains);
  if (compatibleDmaBuf &&
      host.offered.contains(IhsProjectionSurfaceKind.dmaBufTexture)) {
    return IhsProjectionSurfaceKind.dmaBufTexture;
  }
  if (compatibleDmaBuf &&
      producer.canDirectScanout &&
      host.offered.contains(IhsProjectionSurfaceKind.drmPlane)) {
    return IhsProjectionSurfaceKind.drmPlane;
  }
  if (host.offered.contains(IhsProjectionSurfaceKind.softwareShm)) {
    return IhsProjectionSurfaceKind.softwareShm;
  }
  throw UnsupportedError('No compatible IHS projection surface is available.');
}
