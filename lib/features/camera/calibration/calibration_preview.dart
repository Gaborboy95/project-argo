import 'package:flutter/material.dart';

import '../../../core/camera/camera_service.dart';
import '../ihs_camera_surface.dart';

/// Native submission requires a viewport fitted to the current source image.
/// Center loosens both dimensions even inside a stretched configuration column.
class CalibrationPreview extends StatelessWidget {
  const CalibrationPreview({
    super.key,
    required this.service,
    this.height = 360,
  });
  final CameraService service;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: StreamBuilder<CameraSnapshot>(
      stream: service.changes,
      initialData: service.current,
      builder: (context, snapshot) {
        final frame = snapshot.data!;
        final width = frame.width ?? 1920;
        final height = frame.height ?? 1080;
        return Center(
          child: AspectRatio(
            aspectRatio: width > 0 && height > 0 ? width / height : 16 / 9,
            child: IhsCameraSurface(external: true),
          ),
        );
      },
    ),
  );
}
