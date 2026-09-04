import 'dart:convert';
import 'dart:io';

import '../vehicle_capability.dart';
import '../vehicle_profile.dart';

const vehicleIntegrationManifestSchemaVersion = 1;

/// Parses the public, application-facing metadata for a vehicle integration.
final class VehicleIntegrationManifestParser {
  const VehicleIntegrationManifestParser();

  VehicleProfile parseString(String source) => parse(jsonDecode(source));

  VehicleProfile parse(Object? source) {
    if (source is! Map<String, Object?>) {
      throw const FormatException(
        'Vehicle integration manifest root must be a JSON object.',
      );
    }
    final schemaVersion = source['schemaVersion'];
    if (schemaVersion != vehicleIntegrationManifestSchemaVersion) {
      throw FormatException(
        'Unsupported vehicle integration schema version: $schemaVersion.',
      );
    }

    final id = _requiredString(source, 'id');
    final displayName = _requiredString(source, 'displayName');
    final rawCapabilities = source['capabilities'] ?? const <Object?>[];
    if (rawCapabilities is! List<Object?>) {
      throw const FormatException('"capabilities" must be a JSON array.');
    }

    final capabilityIds = <String>{};
    final capabilities = <VehicleCapability>{};
    for (var index = 0; index < rawCapabilities.length; index++) {
      final capabilityId = rawCapabilities[index];
      if (capabilityId is! String || capabilityId.isEmpty) {
        throw FormatException(
          'Capability at index $index must be a non-empty string.',
        );
      }
      if (!capabilityIds.add(capabilityId)) {
        throw FormatException('Duplicate capability "$capabilityId".');
      }
      try {
        capabilities.add(VehicleCapability(id: capabilityId));
      } on ArgumentError catch (error) {
        throw FormatException(
          'Invalid capability "$capabilityId": ${error.message}.',
        );
      }
    }

    try {
      return VehicleProfile(
        id: id,
        displayName: displayName,
        capabilities: capabilities,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid vehicle profile: ${error.message}.');
    }
  }

  Future<VehicleProfile> load(File file) async {
    Object? decoded;
    String? profileId;
    try {
      decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?> && decoded['id'] is String) {
        profileId = decoded['id'] as String;
      }
      return parse(decoded);
    } on Object catch (error, stackTrace) {
      throw VehicleIntegrationManifestException(
        filePath: file.path,
        profileId: profileId,
        cause: error,
        causeStackTrace: stackTrace,
      );
    }
  }

  static String _requiredString(Map<String, Object?> source, String name) {
    final value = source[name];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('"$name" must be a non-empty string.');
    }
    return value;
  }
}

/// File-aware manifest error suitable for bootstrap diagnostics.
final class VehicleIntegrationManifestException implements Exception {
  const VehicleIntegrationManifestException({
    required this.filePath,
    required this.cause,
    required this.causeStackTrace,
    this.profileId,
  });

  final String filePath;
  final String? profileId;
  final Object cause;
  final StackTrace causeStackTrace;

  @override
  String toString() =>
      'Could not load vehicle integration manifest "$filePath": $cause';
}
