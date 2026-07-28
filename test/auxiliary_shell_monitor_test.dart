import 'package:crux/src/services/auxiliary_service.dart';
import 'package:crux/src/tools/shell_monitor.dart';
import 'package:test/test.dart';

/// Unit tests for the shell-monitor verdict parser behind
/// [AuxiliaryService.assessShellProgress]. These exercise the pure
/// parsing layer only (via the test-only wrapper) — no network
/// calls, no ProviderService.
void main() {
  group('parseShellMonitorVerdictForTesting — verdict kind', () {
    test('parses bare verdict tokens', () {
      expect(parseShellMonitorVerdictForTesting('PROGRESS').kind,
          ShellMonitorVerdictKind.progress);
      expect(parseShellMonitorVerdictForTesting('STUCK').kind,
          ShellMonitorVerdictKind.stuck);
      expect(parseShellMonitorVerdictForTesting('UNCERTAIN').kind,
          ShellMonitorVerdictKind.uncertain);
    });

    test('tolerates mixed case', () {
      expect(parseShellMonitorVerdictForTesting('progress').kind,
          ShellMonitorVerdictKind.progress);
      expect(parseShellMonitorVerdictForTesting('Stuck').kind,
          ShellMonitorVerdictKind.stuck);
      expect(parseShellMonitorVerdictForTesting('uncertain').kind,
          ShellMonitorVerdictKind.uncertain);
    });

    test('tolerates trailing punctuation', () {
      expect(parseShellMonitorVerdictForTesting('PROGRESS.').kind,
          ShellMonitorVerdictKind.progress);
      expect(parseShellMonitorVerdictForTesting('STUCK:').kind,
          ShellMonitorVerdictKind.stuck);
      expect(parseShellMonitorVerdictForTesting('UNCERTAIN —').kind,
          ShellMonitorVerdictKind.uncertain);
    });

    test('unparsable input fails open to uncertain, never stuck', () {
      expect(parseShellMonitorVerdictForTesting('').kind,
          ShellMonitorVerdictKind.uncertain);
      expect(parseShellMonitorVerdictForTesting('   ').kind,
          ShellMonitorVerdictKind.uncertain);
      expect(parseShellMonitorVerdictForTesting('I think it is fine').kind,
          ShellMonitorVerdictKind.uncertain);
      // A longer word that merely starts with a verdict token is not
      // a verdict.
      expect(parseShellMonitorVerdictForTesting('STUCKER').kind,
          ShellMonitorVerdictKind.uncertain);
    });
  });

  group('parseShellMonitorVerdictForTesting — interval', () {
    test('defaults to 30s when no interval is given', () {
      expect(parseShellMonitorVerdictForTesting('PROGRESS').intervalSeconds,
          kMonitorDefaultIntervalSeconds);
    });

    test('parses an interval from the first line', () {
      expect(parseShellMonitorVerdictForTesting('PROGRESS 60').intervalSeconds,
          60);
      expect(
          parseShellMonitorVerdictForTesting('STUCK 20').intervalSeconds, 20);
    });

    test('parses interval even with a reason after it', () {
      final v = parseShellMonitorVerdictForTesting(
          'PROGRESS 120 — still compiling, 900/1500 crates');
      expect(v.intervalSeconds, 120);
    });

    test('clamps the interval to the agreed bounds', () {
      expect(parseShellMonitorVerdictForTesting('PROGRESS 1').intervalSeconds,
          kMonitorMinIntervalSeconds);
      expect(
          parseShellMonitorVerdictForTesting('PROGRESS 99999').intervalSeconds,
          kMonitorMaxIntervalSeconds);
    });

    test('uses the FIRST integer as the interval, not a later one', () {
      // "60" is the interval; "900" is part of the reason.
      final v = parseShellMonitorVerdictForTesting('PROGRESS 60 — 900 crates');
      expect(v.intervalSeconds, 60);
    });
  });

  group('parseShellMonitorVerdictForTesting — reason', () {
    test('bare verdict carries no reason', () {
      expect(parseShellMonitorVerdictForTesting('PROGRESS').reason, isNull);
    });

    test('parses a same-line reason after the interval', () {
      final v = parseShellMonitorVerdictForTesting('STUCK 5 — waiting on a '
          'Password: prompt it will never receive');
      expect(v.kind, ShellMonitorVerdictKind.stuck);
      expect(v.reason,
          'waiting on a Password: prompt it will never receive');
    });

    test('the interval digits are stripped from the reason', () {
      final v = parseShellMonitorVerdictForTesting('PROGRESS 60 — on track');
      expect(v.reason, 'on track');
      expect(v.reason, isNot(contains('60')));
    });

    test('joins multi-line reasons', () {
      final v = parseShellMonitorVerdictForTesting(
          'UNCERTAIN 30\nOutput stopped growing.\nCannot tell why.');
      expect(v.kind, ShellMonitorVerdictKind.uncertain);
      expect(v.reason, 'Output stopped growing.\nCannot tell why.');
    });
  });
}
