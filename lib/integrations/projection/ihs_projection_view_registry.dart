import 'dart:ffi';
import 'dart:io';

typedef _RegisterNative = Int32 Function();
typedef _RegisterDart = int Function();
typedef _UnregisterNative = Void Function();
typedef _UnregisterDart = void Function();

abstract interface class ProjectionViewRegistry {
  Future<void> close();
}

final class IhsProjectionViewRegistry implements ProjectionViewRegistry {
  IhsProjectionViewRegistry._(this._unregister);
  final _UnregisterDart _unregister;
  bool _closed = false;

  static IhsProjectionViewRegistry load({String? libraryPath}) {
    if (!Platform.isLinux) {
      throw UnsupportedError(
        'The IHS projection view is supported only on Linux.',
      );
    }
    final library = DynamicLibrary.open(
      libraryPath == null || libraryPath.trim().isEmpty
          ? 'libargo_projection_view.so'
          : libraryPath,
    );
    final register = library.lookupFunction<_RegisterNative, _RegisterDart>(
      'argo_projection_view_register',
    );
    final unregister = library
        .lookupFunction<_UnregisterNative, _UnregisterDart>(
          'argo_projection_view_unregister',
        );
    final result = register();
    if (result != 0) {
      throw StateError(
        'Could not register the IHS projection view (IHS result $result).',
      );
    }
    return IhsProjectionViewRegistry._(unregister);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _unregister();
  }
}
