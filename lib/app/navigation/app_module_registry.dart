import 'app_module.dart';

/// An explicitly populated, deterministically ordered module catalog.
final class AppModuleRegistry {
  static final RegExp _idPattern = RegExp(
    r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$',
  );

  final List<AppModule> _modules = [];
  final Set<String> _ids = {};

  List<AppModule> get modules => List.unmodifiable(_modules);

  void register(AppModule module) {
    if (!_idPattern.hasMatch(module.id)) {
      throw ArgumentError.value(
        module.id,
        'module.id',
        'Must be a stable lowercase identifier',
      );
    }
    if (!_ids.add(module.id)) {
      throw StateError('App module "${module.id}" is already registered.');
    }
    _modules.add(module);
  }
}
