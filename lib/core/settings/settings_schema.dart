import 'setting_key.dart';

/// The setting definitions understood by the current application build.
final class SettingsSchema {
  final Map<String, SettingKey<dynamic>> _keys = {};

  List<SettingKey<dynamic>> get keys => List.unmodifiable(_keys.values);

  void register<T>(SettingKey<T> key) {
    final existing = _keys[key.id];
    if (existing != null) {
      throw StateError(
        'Setting key "${key.id}" is already registered as '
        '${existing.valueType}.',
      );
    }
    _keys[key.id] = key;
  }

  void requireRegistered<T>(SettingKey<T> key) {
    final registered = _keys[key.id];
    if (registered == null) {
      throw StateError('Setting key "${key.id}" is not registered.');
    }
    if (!identical(registered, key)) {
      throw StateError(
        'Setting key "${key.id}" conflicts with its registered definition.',
      );
    }
  }
}
