import 'package:crux/src/services/auxiliary_service.dart';
import 'package:crux/src/tools/shell_risk.dart';
import 'package:test/test.dart';

/// Unit tests for the shell-risk verdict parser behind
/// [AuxiliaryService.assessShellCommand]. These exercise the pure
/// parsing layer only (via the test-only wrapper) — no network
/// calls, no ProviderService.
void main() {
  group('parseShellRiskVerdictForTesting', () {
    test('parses bare verdict tokens', () {
      expect(parseShellRiskVerdictForTesting('SAFE').kind,
          ShellRiskVerdictKind.safe);
      expect(parseShellRiskVerdictForTesting('UNSAFE').kind,
          ShellRiskVerdictKind.unsafe);
      expect(parseShellRiskVerdictForTesting('UNCERTAIN').kind,
          ShellRiskVerdictKind.uncertain);
    });

    test('bare verdict carries no reason', () {
      expect(parseShellRiskVerdictForTesting('SAFE').reason, isNull);
      expect(parseShellRiskVerdictForTesting('UNSAFE').reason, isNull);
    });

    test('tolerates mixed case', () {
      expect(parseShellRiskVerdictForTesting('safe').kind,
          ShellRiskVerdictKind.safe);
      expect(parseShellRiskVerdictForTesting('Unsafe').kind,
          ShellRiskVerdictKind.unsafe);
      expect(parseShellRiskVerdictForTesting('uncertain').kind,
          ShellRiskVerdictKind.uncertain);
    });

    test('tolerates trailing punctuation on the verdict line', () {
      expect(parseShellRiskVerdictForTesting('SAFE.').kind,
          ShellRiskVerdictKind.safe);
      expect(parseShellRiskVerdictForTesting('UNSAFE:').kind,
          ShellRiskVerdictKind.unsafe);
      expect(parseShellRiskVerdictForTesting('UNCERTAIN —').kind,
          ShellRiskVerdictKind.uncertain);
    });

    test('parses a reason from the second line', () {
      final verdict =
          parseShellRiskVerdictForTesting('SAFE\nRead-only inspection.');
      expect(verdict.kind, ShellRiskVerdictKind.safe);
      expect(verdict.reason, 'Read-only inspection.');
    });

    test('parses a same-line reason after a separator', () {
      final verdict = parseShellRiskVerdictForTesting(
          'UNSAFE: deletes the entire home directory');
      expect(verdict.kind, ShellRiskVerdictKind.unsafe);
      expect(verdict.reason, 'deletes the entire home directory');
    });

    test('joins multi-line reasons', () {
      final verdict = parseShellRiskVerdictForTesting(
          'UNCERTAIN\nDepends on the source.\nCannot verify it.');
      expect(verdict.kind, ShellRiskVerdictKind.uncertain);
      expect(verdict.reason, 'Depends on the source.\nCannot verify it.');
    });

    test('ignores leading whitespace before the verdict line', () {
      final verdict = parseShellRiskVerdictForTesting('\n\n  UNSAFE\nnope');
      expect(verdict.kind, ShellRiskVerdictKind.unsafe);
      expect(verdict.reason, 'nope');
    });

    test('empty input is unparsable → uncertain', () {
      expect(parseShellRiskVerdictForTesting('').kind,
          ShellRiskVerdictKind.uncertain);
      expect(parseShellRiskVerdictForTesting('   \n  ').kind,
          ShellRiskVerdictKind.uncertain);
    });

    test('prose without a verdict token is unparsable → uncertain', () {
      expect(
          parseShellRiskVerdictForTesting(
                  'I think this command is safe because it only reads files.')
              .kind,
          ShellRiskVerdictKind.uncertain);
    });

    test('a longer token starting with a keyword is not a verdict', () {
      // "SAFELY" must not be accepted as SAFE.
      expect(parseShellRiskVerdictForTesting('SAFELY remove the dir').kind,
          ShellRiskVerdictKind.uncertain);
    });

    test('unparsable verdicts carry no reason', () {
      expect(parseShellRiskVerdictForTesting('garbage').reason, isNull);
    });
  });
}
