import 'setting_key.dart';
import 'settings_schema.dart';

abstract final class AppSettingKeys {
  static final lastModule = SettingKey<String>(
    id: 'app.navigation.lastModule',
    defaultValue: 'home',
    serialize: _serializeString,
    deserialize: _deserializeString,
  );

  static final audioMasterVolume = SettingKey<double>(
    id: 'audio.master.volume',
    defaultValue: 0.5,
    serialize: _serializeDouble,
    deserialize: _unitDouble('audio.master.volume'),
  );

  static final audioMuted = SettingKey<bool>(
    id: 'audio.master.muted',
    defaultValue: false,
    serialize: (value) => value,
    deserialize: (value) {
      if (value is bool) return value;
      throw const FormatException('Expected a boolean.');
    },
  );

  static final audioBalance = SettingKey<double>(
    id: 'audio.output.balance',
    defaultValue: 0,
    serialize: _serializeDouble,
    deserialize: _signedUnitDouble('audio.output.balance'),
  );

  static final audioFader = SettingKey<double>(
    id: 'audio.output.fader',
    defaultValue: 0,
    serialize: _serializeDouble,
    deserialize: _signedUnitDouble('audio.output.fader'),
  );

  static final audioBassDb = _eqKey('audio.equalizer.bassDb');
  static final audioMidDb = _eqKey('audio.equalizer.midDb');
  static final audioTrebleDb = _eqKey('audio.equalizer.trebleDb');
  static final audioPreferredOutput = SettingKey<String>(
    id: 'audio.output.preferred',
    defaultValue: '',
    serialize: _serializeString,
    deserialize: (value) {
      if (value is String) return value;
      throw const FormatException('Expected a string.');
    },
  );

  static SettingsSchema createSchema() => SettingsSchema()
    ..register(lastModule)
    ..register(audioMasterVolume)
    ..register(audioMuted)
    ..register(audioBalance)
    ..register(audioFader)
    ..register(audioBassDb)
    ..register(audioMidDb)
    ..register(audioTrebleDb)
    ..register(audioPreferredOutput);

  static Object _serializeString(String value) => value;

  static String _deserializeString(Object? value) {
    if (value is! String || value.isEmpty) {
      throw const FormatException('Expected a non-empty string.');
    }
    return value;
  }

  static Object _serializeDouble(double value) => value;

  static SettingKey<double> _eqKey(String id) => SettingKey<double>(
    id: id,
    defaultValue: 0,
    serialize: _serializeDouble,
    deserialize: _boundedDouble(id, -12, 12),
  );

  static double Function(Object?) _unitDouble(String id) =>
      _boundedDouble(id, 0, 1);

  static double Function(Object?) _signedUnitDouble(String id) =>
      _boundedDouble(id, -1, 1);

  static double Function(Object?) _boundedDouble(
    String id,
    double minimum,
    double maximum,
  ) => (value) {
    if (value is num) {
      final decoded = value.toDouble();
      if (decoded.isFinite && decoded >= minimum && decoded <= maximum) {
        return decoded;
      }
    }
    throw FormatException('$id must be finite and within $minimum..$maximum.');
  };
}
