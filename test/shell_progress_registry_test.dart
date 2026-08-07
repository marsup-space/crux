import 'package:crux/src/services/shell_progress_registry.dart';
import 'package:crux/src/tools/shell_progress_parser.dart';
import 'package:test/test.dart';

void main() {
  group('ShellProgressRegistry', () {
    test('update creates an entry; entriesFor returns it', () {
      final reg = ShellProgressRegistry();
      reg.update(
        1,
        'call-1',
        'git clone ...',
        const ShellProgress(percent: 45, hasPercent: true, signalCount: 1),
      );
      final entries = reg.entriesFor(1);
      expect(entries.length, 1);
      expect(entries[0].callId, 'call-1');
      expect(entries[0].command, 'git clone ...');
      expect(entries[0].progress.percent, 45);
      expect(entries[0].finished, isFalse);
    });

    test('update replaces the snapshot for the same callId', () {
      final reg = ShellProgressRegistry();
      reg.update(
        1,
        'c',
        'cmd',
        const ShellProgress(percent: 10, hasPercent: true, signalCount: 1),
      );
      reg.update(
        1,
        'c',
        'cmd',
        const ShellProgress(percent: 60, hasPercent: true, signalCount: 1),
      );
      expect(reg.entriesFor(1)[0].progress.percent, 60);
    });

    test('finish marks the entry done; finished entries prune after TTL',
        () {
      final reg = ShellProgressRegistry(finishedTtl: Duration.zero);
      reg.update(
        1,
        'c',
        'cmd',
        const ShellProgress(percent: 100, hasPercent: true, signalCount: 1),
      );
      expect(reg.entriesFor(1).length, 1);
      reg.finish(1, 'c', exitCode: 0);
      // TTL zero → pruned on the next read.
      expect(reg.entriesFor(1), isEmpty);
    });

    test('finished entries stay visible within the TTL', () {
      final reg = ShellProgressRegistry(
        finishedTtl: const Duration(minutes: 1),
      );
      reg.update(
        1,
        'c',
        'cmd',
        const ShellProgress(percent: 100, hasPercent: true, signalCount: 1),
      );
      reg.finish(1, 'c', exitCode: 0);
      final entries = reg.entriesFor(1);
      expect(entries.length, 1);
      expect(entries[0].finished, isTrue);
      expect(entries[0].exitCode, 0);
    });

    test('sessions are isolated', () {
      final reg = ShellProgressRegistry();
      reg.update(
        1,
        'a',
        'cmd',
        const ShellProgress(percent: 10, hasPercent: true, signalCount: 1),
      );
      reg.update(
        2,
        'b',
        'cmd',
        const ShellProgress(percent: 90, hasPercent: true, signalCount: 1),
      );
      expect(reg.entriesFor(1).length, 1);
      expect(reg.entriesFor(2).length, 1);
      expect(reg.entriesFor(1)[0].callId, 'a');
      expect(reg.entriesFor(2)[0].callId, 'b');
    });

    test('clearSession drops all entries for a session', () {
      final reg = ShellProgressRegistry();
      reg.update(
        1,
        'a',
        'cmd',
        const ShellProgress(percent: 10, hasPercent: true, signalCount: 1),
      );
      reg.clearSession(1);
      expect(reg.entriesFor(1), isEmpty);
    });
  });

  group('ShellProgressSinkImpl', () {
    test('forwards updates and finish into its registry', () {
      final registry = ShellProgressRegistry();
      final sink = ShellProgressSinkImpl(
        sessionId: 7,
        callId: 'call-9',
        registry: registry,
      );
      sink.update(
        const ShellProgress(phase: 'Compiling', signalCount: 1),
        command: 'cargo build',
      );
      expect(registry.entriesFor(7)[0].command, 'cargo build');
      sink.finish(
        exitCode: 0,
        summary: const {
          'phase': 'Compiling',
          'durationSec': 42,
          'bytes': 1234,
          'exitCode': 0,
        },
      );
      expect(sink.summary!['durationSec'], 42);
      expect(registry.entriesFor(7)[0].finished, isTrue);
      expect(registry.entriesFor(7)[0].exitCode, 0);
    });
  });
}
