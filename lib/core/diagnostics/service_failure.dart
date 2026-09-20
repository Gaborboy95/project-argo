import 'dart:convert';

enum FailureKind {
  disabled,
  missingService,
  unsupported,
  staleSession,
  unavailableDevice,
  rejected,
  busy,
  timeout,
  cancelled,
  internal,
}

/// Carries the original cause locally. Export deliberately uses an allowlist:
/// arbitrary backend text can contain phone content, identities or credentials.
final class ServiceFailure implements Exception {
  const ServiceFailure({
    required this.feature,
    required this.operation,
    required this.kind,
    required this.summary,
    required this.cause,
    this.retryable = false,
    this.recovery,
  });
  final String feature, operation, summary;
  final FailureKind kind;
  final Object cause;
  final bool retryable;
  final String? recovery;
  String get detail => cause.toString();
  String get copyDiagnostics => jsonEncode({
    'schema': 1,
    'kind': kind.name,
    'feature':
        const {
          'carplay',
          'androidAuto',
          'camera',
          'models',
          'audio',
          'projection',
          'setup',
        }.contains(feature)
        ? feature
        : 'integration',
    'operation':
        const {
          'activate',
          'connect',
          'disconnect',
          'observe',
          'configure',
          'command',
          'status',
          'gain',
          'focus',
        }.contains(operation)
        ? operation
        : 'operation',
    'retryable': retryable,
    // Even summaries/feature names supplied by a backend are untrusted.
    'technicalCause': 'Omitted: may contain private integration or phone data.',
  });
  @override
  bool operator ==(Object other) =>
      other is ServiceFailure &&
      feature == other.feature &&
      operation == other.operation &&
      kind == other.kind &&
      summary == other.summary &&
      detail == other.detail &&
      retryable == other.retryable &&
      recovery == other.recovery;
  @override
  int get hashCode => Object.hash(
    feature,
    operation,
    kind,
    summary,
    detail,
    retryable,
    recovery,
  );
  @override
  String toString() => summary;
}
