import 'setting_key.dart';
import 'settings_schema.dart';

abstract final class AppSettingKeys {
  static final lastModule = SettingKey<String>(
    id: 'app.navigation.lastModule',
    defaultValue: 'home',
    serialize: _serializeString,
    deserialize: _deserializeString,
  );

  static SettingsSchema createSchema() =>
      SettingsSchema()..register(lastModule);

  static Object _serializeString(String value) => value;

  static String _deserializeString(Object? value) {
    if (value is! String || value.isEmpty) {
      throw const FormatException('Expected a non-empty string.');
    }
    return value;
  }
}
