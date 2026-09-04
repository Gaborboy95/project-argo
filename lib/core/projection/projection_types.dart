enum ProjectionProtocol { androidAuto, carPlay }

enum ProjectionTransport { usb, wifi }

enum ProjectionSessionState {
  connecting,
  ready,
  streaming,
  suspended,
  failed,
  disconnected,
}

enum ProjectionVideoRole { main, cluster }

enum ProjectionVideoCodec { h264, hevc, vp9, av1 }

enum ProjectionAudioRole { media, speech, system, communication }

enum ProjectionInputButton {
  home,
  back,
  select,
  up,
  down,
  left,
  right,
  playPause,
  next,
  previous,
  phoneAccept,
  phoneReject,
  voiceAssistant,
}

enum ProjectionTouchPhase { down, move, up, cancel }

enum ProjectionDriverSide { left, right }

final class ProjectionTouch {
  const ProjectionTouch({
    required this.pointerId,
    required this.phase,
    required this.x,
    required this.y,
  });

  final int pointerId;
  final ProjectionTouchPhase phase;

  /// Normalized projection-content coordinate in the inclusive 0..1 range.
  final double x;
  final double y;

  void validate() {
    if (pointerId < 0 || pointerId > 65535) {
      throw RangeError.range(pointerId, 0, 65535, 'pointerId');
    }
    if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      throw ArgumentError.value(
        '($x, $y)',
        'touch',
        'Coordinates must be finite and within 0..1',
      );
    }
  }
}

final class ProjectionInsets {
  const ProjectionInsets({
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  void validate({String name = 'insets'}) {
    for (final value in [left, top, right, bottom]) {
      if (!value.isFinite || value < 0) {
        throw ArgumentError.value(
          value,
          name,
          'Must be finite and non-negative',
        );
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectionInsets &&
      left == other.left &&
      top == other.top &&
      right == other.right &&
      bottom == other.bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}
