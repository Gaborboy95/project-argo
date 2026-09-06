import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// The IHS channel returns a platform-view ID, never an external-texture ID.
/// Size messages use logical pixels; native frame dimensions remain independent.
class IhsProjectionSurface extends StatefulWidget {
  const IhsProjectionSurface({
    super.key,
    required this.viewType,
    required this.creationParams,
    this.diagnostics = false,
  });

  final String viewType;
  final Map<String, Object?> creationParams;
  final bool diagnostics;

  @override
  State<IhsProjectionSurface> createState() => _IhsProjectionSurfaceState();
}

class _IhsProjectionSurfaceState extends State<IhsProjectionSurface> {
  _IhsProjectionController? _controller;
  String? _error;

  void _reportError(Object error) {
    debugPrint('Argo projection: IHS surface unavailable: $error');
    // Creation can finish during layout. Update the error UI outside layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _error = '$error');
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return const Center(child: Text('Native projection surface unavailable'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return const Text('Native projection requires bounded dimensions');
        }
        final size = constraints.biggest;
        final direction = Directionality.of(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _controller?.updateLayout(size, direction);
        });
        return PlatformViewLink(
          viewType: widget.viewType,
          onCreatePlatformView: (params) {
            return _controller = _IhsProjectionController(
              viewId: params.id,
              viewType: params.viewType,
              creationParams: widget.creationParams,
              direction: direction,
              onCreated: params.onPlatformViewCreated,
              onError: _reportError,
              diagnostics: widget.diagnostics,
            );
          },
          surfaceFactory: (context, controller) => PlatformViewSurface(
            controller: controller,
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
            gestureRecognizers: const {},
          ),
        );
      },
    );
  }
}

/// Deliberately limited to Argo's IHS surface. PlatformViewLink owns disposal.
class _IhsProjectionController extends PlatformViewController {
  _IhsProjectionController({
    required this.viewId,
    required this.viewType,
    required this.creationParams,
    required this.direction,
    required this.onCreated,
    required this.onError,
    required this.diagnostics,
  });

  @override
  final int viewId;
  final String viewType;
  final Map<String, Object?> creationParams;
  TextDirection direction;
  final ValueChanged<int> onCreated;
  final ValueChanged<Object> onError;
  final bool diagnostics;
  Future<void> _tail = Future<void>.value();
  Future<void>? _disposal;
  bool _started = false;
  bool _disposed = false;
  bool _createIssued = false;
  bool _created = false;
  Size? _size;

  @override
  bool get awaitingCreation => !_started && !_disposed;

  Future<void> _enqueue(Future<void> Function() operation) {
    return _tail = _tail.then((_) => operation()).catchError((Object error) {
      onError(error);
    });
  }

  @override
  Future<void> create({Size? size, Offset? position}) {
    if (!awaitingCreation || size == null || size.isEmpty || !size.isFinite) {
      return _tail;
    }
    _started = true;
    _size = size;
    final initialDirection = direction;
    return _enqueue(() async {
      if (_disposed) return;
      final encoded = const StandardMessageCodec().encodeMessage(
        creationParams,
      )!;
      _createIssued = true;
      final result = await SystemChannels.platform_views.invokeMethod<Object?>(
        'create',
        <String, Object?>{
          'id': viewId,
          'viewType': viewType,
          'direction': initialDirection == TextDirection.ltr ? 0 : 1,
          'width': size.width,
          'height': size.height,
          'left': position?.dx ?? 0.0,
          'top': position?.dy ?? 0.0,
          'params': encoded.buffer.asUint8List(
            encoded.offsetInBytes,
            encoded.lengthInBytes,
          ),
        },
      );
      if (result != viewId) {
        throw StateError(
          'IHS create returned $result for platform view $viewId',
        );
      }
      _created = true;
      // Dispose waits for this operation, then releases it.
      if (_disposed) return;
      if (diagnostics) {
        debugPrint(
          'Argo renderer test: IHS create acknowledged id=$viewId; '
          'PlatformViewLayer composition, logical size=$size',
        );
      }
      // IHS acknowledges the ID after factory dispatch, but this installed host
      // does not propagate factory refusal. Native logs remain authoritative.
      onCreated(viewId);
    });
  }

  void updateLayout(Size size, TextDirection newDirection) {
    if (_disposed || !_started || size.isEmpty || !size.isFinite) return;
    final resize = _size != size;
    final redirect = direction != newDirection;
    if (!resize && !redirect) return;
    _size = size;
    direction = newDirection;
    unawaited(
      _enqueue(() async {
        if (_disposed || !_created) return;
        if (resize) {
          await SystemChannels.platform_views.invokeMethod<Object?>('resize', {
            'id': viewId,
            'width': size.width,
            'height': size.height,
          });
        }
        if (redirect) {
          await SystemChannels.platform_views.invokeMethod<void>(
            'setDirection',
            {
              'id': viewId,
              'direction': newDirection == TextDirection.ltr ? 0 : 1,
            },
          );
        }
      }),
    );
  }

  @override
  Future<void> dispose() {
    _disposed = true;
    return _disposal ??= _enqueue(() async {
      if (!_createIssued) return;
      await SystemChannels.platform_views.invokeMethod<void>('dispose', {
        'id': viewId,
      });
    });
  }

  // ProjectionView's outer Listener already maps all projection input. Never
  // duplicate it through the platform-view gesture or focus channel.
  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {}
  @override
  Future<void> clearFocus() async {}
}
