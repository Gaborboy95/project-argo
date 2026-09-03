typedef SettingSerializer<T> = Object? Function(T value);
typedef SettingDeserializer<T> = T Function(Object? value);

/// A stable, namespaced, typed application setting definition.
final class SettingKey<T> {
  SettingKey({
    required this.id,
    required this.defaultValue,
    required this.serialize,
    required this.deserialize,
  }) : valueType = T {
    if (!_idPattern.hasMatch(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'Must contain at least two dot-separated stable name segments',
      );
    }
    deserialize(serialize(defaultValue));
  }

  static final RegExp _idPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)+$',
  );

  final String id;
  final T defaultValue;
  final SettingSerializer<T> serialize;
  final SettingDeserializer<T> deserialize;
  final Type valueType;
}
