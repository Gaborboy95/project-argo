/// Deliberately small, strict JSON-schema subset used at the host boundary.
/// Unsupported schema keywords fail configuration instead of being ignored.
final class AssistantSchema {
  AssistantSchema(Map<String, Object?> schema)
    : json = Map.unmodifiable(schema) {
    _checkSchema(json);
  }

  final Map<String, Object?> json;

  void validate(Object? value) => _validate(json, value, 'arguments');

  static void _checkSchema(Map<String, Object?> schema, [int depth = 0]) {
    if (depth > 8) throw const FormatException('Schema nesting exceeds 8.');
    const supported = {
      'type',
      'description',
      'properties',
      'required',
      'additionalProperties',
      'enum',
      'minimum',
      'maximum',
      'maxLength',
      'minLength',
      'items',
      'maxItems',
    };
    if (schema.keys.any((key) => !supported.contains(key))) {
      throw const FormatException('Unsupported assistant schema keyword.');
    }
    final type = schema['type'];
    if (!const {
      'object',
      'array',
      'string',
      'boolean',
      'integer',
      'number',
      'null',
    }.contains(type)) {
      throw const FormatException('Unsupported assistant schema type.');
    }
    if (type == 'object') {
      if (schema['additionalProperties'] != false ||
          schema['properties'] is! Map) {
        throw const FormatException(
          'Objects require properties and additionalProperties:false.',
        );
      }
      final properties = schema['properties'] as Map;
      if (properties.length > 32) {
        throw const FormatException('Too many properties.');
      }
      for (final entry in properties.entries) {
        if (entry.key is! String || entry.value is! Map) {
          throw const FormatException('Invalid property schema.');
        }
        _checkSchema(Map<String, Object?>.from(entry.value as Map), depth + 1);
      }
      final required = schema['required'] ?? const [];
      if (required is! List ||
          required.any(
            (key) => key is! String || !properties.containsKey(key),
          )) {
        throw const FormatException('Invalid required properties.');
      }
    }
    if (type == 'array') {
      if (schema['items'] is! Map) {
        throw const FormatException('Array items required.');
      }
      _checkSchema(
        Map<String, Object?>.from(schema['items'] as Map),
        depth + 1,
      );
    }
    if (schema.containsKey('enum') &&
        (schema['enum'] is! List || (schema['enum'] as List).isEmpty)) {
      throw const FormatException('Enum must be a nonempty list.');
    }
    for (final key in ['minimum', 'maximum']) {
      final value = schema[key];
      if (value != null && (value is! num || !value.isFinite)) {
        throw FormatException('$key must be finite.');
      }
    }
    for (final key in ['minLength', 'maxLength', 'maxItems']) {
      final value = schema[key];
      if (value != null && (value is! int || value < 0)) {
        throw FormatException('$key must be a nonnegative integer.');
      }
    }
  }

  static void _validate(Map schema, Object? value, String path) {
    final type = schema['type'];
    final valid = switch (type) {
      'object' => value is Map<String, Object?>,
      'array' => value is List,
      'string' => value is String,
      'boolean' => value is bool,
      'integer' => value is int,
      'number' => value is num && value.isFinite,
      'null' => value == null,
      _ => false,
    };
    if (!valid) throw FormatException('$path must be $type.');
    if (schema['enum'] case final List allowed) {
      if (!allowed.contains(value)) {
        throw FormatException('$path is not an allowed value.');
      }
    }
    if (value is Map<String, Object?>) {
      final properties = schema['properties'] as Map;
      if (value.keys.any((key) => !properties.containsKey(key))) {
        throw FormatException('$path has unknown properties.');
      }
      for (final key in schema['required'] as List? ?? const []) {
        if (!value.containsKey(key)) {
          throw FormatException('$path.$key is required.');
        }
      }
      for (final entry in value.entries) {
        _validate(
          properties[entry.key] as Map,
          entry.value,
          '$path.${entry.key}',
        );
      }
    } else if (value is List) {
      if (value.length > (schema['maxItems'] as int? ?? 64)) {
        throw FormatException('$path is too long.');
      }
      for (final item in value) {
        _validate(schema['items'] as Map, item, '$path[]');
      }
    } else if (value is String) {
      if (value.length > (schema['maxLength'] as int? ?? 1024) ||
          value.length < (schema['minLength'] as int? ?? 0)) {
        throw FormatException('$path has invalid length.');
      }
    } else if (value is num) {
      if ((schema['minimum'] is num && value < (schema['minimum'] as num)) ||
          (schema['maximum'] is num && value > (schema['maximum'] as num))) {
        throw FormatException('$path is outside its allowed range.');
      }
    }
  }
}

Map<String, Object?> assistantObjectSchema(Map<String, Object?> properties) => {
  'type': 'object',
  'properties': properties,
  'required': properties.keys.toList(),
  'additionalProperties': false,
};
