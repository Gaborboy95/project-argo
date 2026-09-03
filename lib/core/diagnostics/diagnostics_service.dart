import 'dart:async';
import 'dart:collection';

enum DiagnosticSeverity { info, warning, error }

final class DiagnosticEntry {
  const DiagnosticEntry({
    required this.timestamp,
    required this.severity,
    required this.source,
    required this.message,
    this.error,
    this.stackTrace,
  });

  final DateTime timestamp;
  final DiagnosticSeverity severity;
  final String source;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;
}

/// Process-local, bounded diagnostics suitable for application services.
final class DiagnosticsService {
  DiagnosticsService({this.maxEntries = 200, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    if (maxEntries <= 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries', 'Must be positive');
    }
  }

  final int maxEntries;
  final DateTime Function() _clock;
  final ListQueue<DiagnosticEntry> _history = ListQueue();
  final StreamController<DiagnosticEntry> _entries =
      StreamController<DiagnosticEntry>.broadcast(sync: true);

  List<DiagnosticEntry> get snapshot => List.unmodifiable(_history);
  DiagnosticEntry? get latest => _history.isEmpty ? null : _history.last;
  Stream<DiagnosticEntry> get entries => _entries.stream;

  DiagnosticEntry info(
    String source,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => _record(
    DiagnosticSeverity.info,
    source,
    message,
    error: error,
    stackTrace: stackTrace,
  );

  DiagnosticEntry warning(
    String source,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => _record(
    DiagnosticSeverity.warning,
    source,
    message,
    error: error,
    stackTrace: stackTrace,
  );

  DiagnosticEntry error(
    String source,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) => _record(
    DiagnosticSeverity.error,
    source,
    message,
    error: error,
    stackTrace: stackTrace,
  );

  DiagnosticEntry _record(
    DiagnosticSeverity severity,
    String source,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    DateTime timestamp;
    try {
      timestamp = _clock().toUtc();
    } on Object {
      timestamp = DateTime.now().toUtc();
    }
    final entry = DiagnosticEntry(
      timestamp: timestamp,
      severity: severity,
      source: source.trim().isEmpty ? 'unknown' : source,
      message: message.trim().isEmpty ? 'No diagnostic message.' : message,
      error: error,
      stackTrace: stackTrace,
    );

    try {
      if (_history.length == maxEntries) _history.removeFirst();
      _history.addLast(entry);
      _entries.add(entry);
    } on Object {
      // Diagnostics must never become a new application failure.
    }
    return entry;
  }
}
