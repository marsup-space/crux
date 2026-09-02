// Tests for the `ShellMonitorNotice` pure-data surface (noise gate +
// mkMonitorTail evidence picker). ALL display wording lives in the
// i18n catalog at the chat-panel wiring site, so these tests assert
// STRUCTURE (fields, gates), never English strings.
import 'package:test/test.dart';

import 'package:crux/src/tools/shell_monitor.dart';

void main() {
  group('ShellMonitorNotice', () {
    test('carries intent as the primary subject field', () {
      final n = ShellMonitorNotice(
        configured: true,
        command: 'dart test',
        intent: 'run the unit tests',
        kind: 'PROGRESS',
        elapsedSeconds: 95,
        nextCheckSeconds: 60,
        totalOutputBytes: 1234,
      );
      expect(n.intent, 'run the unit tests');
      expect(n.command, 'dart test');
      expect(n.kind, 'PROGRESS');
      expect(n.nextCheckSeconds, 60);
    });

    test('STUCK notice carries no next-check time', () {
      final n = ShellMonitorNotice(
        configured: true,
        command: 'c',
        intent: 'build',
        kind: 'STUCK',
        elapsedSeconds: 180,
        reason: 'waiting for stdin',
      );
      expect(n.nextCheckSeconds, isNull);
      expect(n.reason, 'waiting for stdin');
    });

    test('isMeaningful gates the unconfigured arm announcement', () {
      expect(
        ShellMonitorNotice(
          configured: true,
          command: 'c',
          kind: 'CONFIGURED',
        ).isMeaningful,
        isTrue,
      );
      expect(
        ShellMonitorNotice(
          configured: false,
          command: 'c',
          kind: 'CONFIGURED',
        ).isMeaningful,
        isFalse,
      );
      // Verdicts are always meaningful.
      expect(
        ShellMonitorNotice(
          configured: true,
          command: 'c',
          kind: 'PROGRESS',
          nextCheckSeconds: 30,
        ).isMeaningful,
        isTrue,
      );
      // Errors and fallbacks too.
      expect(
        ShellMonitorNotice(
          configured: true,
          command: 'c',
          kind: 'EVAL_ERROR',
          reason: 'boom',
        ).isMeaningful,
        isTrue,
      );
    });
  });

  group('mkMonitorTail', () {
    test('picks the last non-blank line', () {
      expect(mkMonitorTail('a\n b \n\nc\n'), 'c');
    });

    test('empty tail stays empty', () {
      expect(mkMonitorTail(''), isEmpty);
      expect(mkMonitorTail('\n \n'), isEmpty);
    });

    test('clamps long lines with a leading ellipsis', () {
      final long = 'x' * 200;
      final out = mkMonitorTail(long);
      expect(out.startsWith('…'), isTrue);
      expect(
        out.length,
        kMonitorNoticeTailMaxChars + 1, // ellipsis char
      );
    });
  });
}
