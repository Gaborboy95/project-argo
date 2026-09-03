import 'package:argo/core/diagnostics/diagnostics_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps only the configured bounded history', () {
    final diagnostics = DiagnosticsService(maxEntries: 3);

    diagnostics.info('test', 'one');
    diagnostics.warning('test', 'two');
    diagnostics.error('test', 'three');
    diagnostics.info('test', 'four');

    expect(diagnostics.snapshot.map((entry) => entry.message), [
      'two',
      'three',
      'four',
    ]);
    expect(
      () => diagnostics.snapshot.add(diagnostics.snapshot.first),
      throwsUnsupportedError,
    );
  });

  test('streams structured entries as they are recorded', () async {
    final now = DateTime.utc(2026, 9, 3, 12);
    final diagnostics = DiagnosticsService(clock: () => now);
    final entries = <DiagnosticEntry>[];
    final subscription = diagnostics.entries.listen(entries.add);
    final failure = StateError('failed');
    final stackTrace = StackTrace.current;

    final recorded = diagnostics.error(
      'test.component',
      'A component failed.',
      error: failure,
      stackTrace: stackTrace,
    );

    expect(entries, [same(recorded)]);
    expect(recorded.timestamp, now);
    expect(recorded.severity, DiagnosticSeverity.error);
    expect(recorded.source, 'test.component');
    expect(recorded.error, same(failure));
    expect(recorded.stackTrace, same(stackTrace));
    await subscription.cancel();
  });
}
