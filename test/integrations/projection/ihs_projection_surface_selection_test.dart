import 'package:argo/integrations/projection/ihs_projection_surface_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefers compatible DMA-BUF import then DRM plane', () {
    const host = IhsProjectionSurfaceCapabilities(
      offered: {
        IhsProjectionSurfaceKind.dmaBufTexture,
        IhsProjectionSurfaceKind.drmPlane,
        IhsProjectionSurfaceKind.softwareShm,
      },
      formats: {'XR24'},
    );
    expect(
      selectIhsProjectionSurface(
        host: host,
        producer: const ProjectionProducerCapabilities(
          dmaBufFormats: {'XR24'},
          canDirectScanout: true,
        ),
      ),
      IhsProjectionSurfaceKind.dmaBufTexture,
    );
  });

  test('DMA-BUF incompatibility uses universal software fallback', () {
    expect(
      selectIhsProjectionSurface(
        host: const IhsProjectionSurfaceCapabilities(
          offered: {
            IhsProjectionSurfaceKind.dmaBufTexture,
            IhsProjectionSurfaceKind.softwareShm,
          },
          formats: {'XR24'},
        ),
        producer: const ProjectionProducerCapabilities(
          dmaBufFormats: {'NV12'},
          canDirectScanout: false,
        ),
      ),
      IhsProjectionSurfaceKind.softwareShm,
    );
  });

  test('renegotiated capabilities are selected afresh', () {
    const producer = ProjectionProducerCapabilities(
      dmaBufFormats: {'XR24'},
      canDirectScanout: true,
    );
    final first = selectIhsProjectionSurface(
      host: const IhsProjectionSurfaceCapabilities(
        offered: {
          IhsProjectionSurfaceKind.dmaBufTexture,
          IhsProjectionSurfaceKind.softwareShm,
        },
        formats: {'XR24'},
      ),
      producer: producer,
    );
    final afterOutputChange = selectIhsProjectionSurface(
      host: const IhsProjectionSurfaceCapabilities(
        offered: {IhsProjectionSurfaceKind.softwareShm},
        formats: {},
      ),
      producer: producer,
    );
    expect(first, IhsProjectionSurfaceKind.dmaBufTexture);
    expect(afterOutputChange, IhsProjectionSurfaceKind.softwareShm);
  });
}
