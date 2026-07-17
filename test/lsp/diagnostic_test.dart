import 'package:crux/src/lsp/diagnostic.dart';
import 'package:crux/src/lsp/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('LSP payload marker', () {
    test('buildLspPayload returns empty string for empty list', () {
      expect(buildLspPayload(const []), '');
    });

    test('buildLspPayload encodes a diagnostic as JSON in the marker', () {
      final diag = LspDiagnostic(
        range: const LspRange(LspPosition(2, 9), LspPosition(2, 17)),
        message: "A value of type 'String' can't be returned",
        severity: LspDiagnosticSeverity.error,
        source: 'dart',
        code: 'A value of type \'String\' can\'t be returned',
      );
      final payload = buildLspPayload([diag]);
      expect(payload, contains('<crux-lsp>'));
      expect(payload, contains('</crux-lsp>'));
      expect(payload, contains("can't be returned")); // message preserved
      expect(payload, contains('"source":"dart"'));
      expect(payload, contains('"severity":1'));
    });

    test('extractLspPayload returns clean content + diagnostics', () {
      final diag = LspDiagnostic(
        range: const LspRange(LspPosition(0, 0), LspPosition(0, 5)),
        message: 'broken',
        severity: LspDiagnosticSeverity.error,
        source: 'dart',
      );
      final original = 'Edit applied to foo.dart: Replaced 1 occurrence.';
      final embedded = '$original${buildLspPayload([diag])}';
      final parsed = extractLspPayload(embedded);

      expect(parsed.diagnostics, hasLength(1));
      expect(parsed.diagnostics.first.message, 'broken');
      expect(parsed.diagnostics.first.source, 'dart');
      expect(parsed.diagnostics.first.severity, LspDiagnosticSeverity.error);
      expect(parsed.diagnostics.first.range.start.line, 0);
      expect(parsed.diagnostics.first.range.start.character, 0);
      // Visible content is the original — marker stripped.
      expect(parsed.visible, original);
    });

    test('extractLspPayload returns input unchanged when no marker', () {
      const content = 'Edit applied to foo.dart: 1 replacement.';
      final parsed = extractLspPayload(content);
      expect(parsed.diagnostics, isEmpty);
      expect(parsed.visible, content);
    });

    test('extractLspPayload is lenient: malformed JSON yields empty list', () {
      final malformed = 'Edit applied\n<crux-lsp>{not json}</crux-lsp>';
      final parsed = extractLspPayload(malformed);
      expect(parsed.diagnostics, isEmpty);
      // Visible is the original (with marker still there since
      // close-tag was present but the body failed to parse — we
      // still strip the marker so the user doesn't see it).
      expect(parsed.visible, isNot(contains('<crux-lsp>')));
      expect(parsed.visible, isNot(contains('</crux-lsp>')));
    });

    test('extractLspPayload tolerates a missing close tag', () {
      final content = 'Edit applied\n<crux-lsp>\n[{}, {}]';
      final parsed = extractLspPayload(content);
      // Without a close tag, we leave the content alone rather
      // than guess where the marker ends.
      expect(parsed.diagnostics, isEmpty);
      expect(parsed.visible, content);
    });

    test('extractLspPayload round-trips multiple diagnostics', () {
      final diags = List.generate(3, (i) {
        return LspDiagnostic(
          range: LspRange(LspPosition(i, 0), LspPosition(i, 1)),
          message: 'err $i',
          severity: LspDiagnosticSeverity.error,
          source: 'dart',
        );
      });
      final original = 'Wrote file';
      final embedded = '$original${buildLspPayload(diags)}';
      final parsed = extractLspPayload(embedded);
      expect(parsed.diagnostics, hasLength(3));
      expect(parsed.visible, original);
    });

    test('extractLspPayload preserves optional fields gracefully', () {
      // No source, no code, no severity — just a message.
      final diag = LspDiagnostic(
        range: const LspRange(LspPosition(0, 0), LspPosition(0, 1)),
        message: 'minimal',
      );
      final embedded = 'x${buildLspPayload([diag])}';
      final parsed = extractLspPayload(embedded);
      expect(parsed.diagnostics, hasLength(1));
      expect(parsed.diagnostics.first.source, isNull);
      expect(parsed.diagnostics.first.severity, isNull);
      expect(parsed.diagnostics.first.message, 'minimal');
    });
  });

  group('errorDiagnostics', () {
    LspDiagnostic makeDiag(LspDiagnosticSeverity? severity, String message) {
      return LspDiagnostic(
        range: const LspRange(LspPosition(0, 0), LspPosition(0, 1)),
        message: message,
        severity: severity,
      );
    }

    test('keeps only error-severity diagnostics', () {
      final result = errorDiagnostics([
        makeDiag(LspDiagnosticSeverity.error, 'err1'),
        makeDiag(LspDiagnosticSeverity.warning, 'warn1'),
        makeDiag(LspDiagnosticSeverity.error, 'err2'),
        makeDiag(LspDiagnosticSeverity.information, 'info1'),
        makeDiag(LspDiagnosticSeverity.hint, 'hint1'),
      ]);
      expect(result, hasLength(2));
      expect(result.map((d) => d.message), ['err1', 'err2']);
    });

    test('treats null severity as error (per LSP spec)', () {
      // The LSP spec says missing `severity` defaults to Error
      // (severity 1). Crux follows that here so the bubble count
      // matches the tool detail pane's count.
      final result = errorDiagnostics([
        makeDiag(null, 'no-severity'),
        makeDiag(LspDiagnosticSeverity.error, 'explicit-error'),
        makeDiag(LspDiagnosticSeverity.warning, 'warn'),
      ]);
      expect(result, hasLength(2));
      expect(
        result.map((d) => d.message),
        containsAll(['no-severity', 'explicit-error']),
      );
    });

    test('returns empty list for an all-warnings input', () {
      // This is the case that triggered the bubble vs. detail
      // mismatch: 1 warning in → bubble used to show "1 error"
      // while the detail pane correctly showed 0 errors.
      final result = errorDiagnostics([
        makeDiag(LspDiagnosticSeverity.warning, 'warn1'),
        makeDiag(LspDiagnosticSeverity.information, 'info1'),
      ]);
      expect(result, isEmpty);
    });

    test('empty input → empty output', () {
      expect(errorDiagnostics(const []), isEmpty);
    });
  });

  group('reportDiagnostics', () {
    LspDiagnostic makeDiag(
      LspDiagnosticSeverity? severity,
      String message, {
      int line = 0,
      int col = 0,
    }) {
      return LspDiagnostic(
        range: LspRange(LspPosition(line, col), LspPosition(line, col + 1)),
        message: message,
        severity: severity,
      );
    }

    test('renders only error-severity entries in a file block', () {
      final out = reportDiagnostics('a.dart', [
        makeDiag(LspDiagnosticSeverity.error, 'boom', line: 2, col: 4),
        makeDiag(LspDiagnosticSeverity.warning, 'meh'),
      ]);
      expect(
        out,
        '<diagnostics file="a.dart">\nERROR [3:5] boom\n</diagnostics>',
      );
    });

    test('treats null severity as error (LSP spec default)', () {
      final out = reportDiagnostics('a.dart', [makeDiag(null, 'no-sev')]);
      expect(out, contains('ERROR [1:1] no-sev'));
    });

    test('returns empty string when nothing is error-level', () {
      expect(
        reportDiagnostics('a.dart', [
          makeDiag(LspDiagnosticSeverity.warning, 'w'),
        ]),
        '',
      );
      expect(reportDiagnostics('a.dart', const []), '');
    });

    test('caps entries at maxPerFile and summarizes the remainder', () {
      final diags = List.generate(
        7,
        (i) => makeDiag(LspDiagnosticSeverity.error, 'err $i'),
      );
      final out = reportDiagnostics('a.dart', diags, maxPerFile: 5);
      expect(out, contains('err 4'));
      expect(out, isNot(contains('err 5')));
      expect(out, contains('... and 2 more'));
    });

    test('truncates over-long messages when maxMessageChars is set', () {
      final longMessage = 'x' * 300;
      final out = reportDiagnostics('a.dart', [
        makeDiag(LspDiagnosticSeverity.error, longMessage),
      ], maxMessageChars: 160);
      expect(out, contains('${'x' * 160}…'));
      expect(out, isNot(contains('x' * 161)));
    });
  });

  group('reportDiagnosticsSameTurn', () {
    test('applies the same-turn budget (5 entries, 160 chars/message)', () {
      final diags = List.generate(
        8,
        (i) => LspDiagnostic(
          range: LspRange(LspPosition(i, 0), LspPosition(i, 1)),
          message: 'err $i ${'y' * 200}',
          severity: LspDiagnosticSeverity.error,
        ),
      );
      final out = reportDiagnosticsSameTurn('a.dart', diags);
      expect(out, startsWith('<diagnostics file="a.dart">'));
      expect(out, contains('... and 3 more'));
      expect(out, isNot(contains('err 5')));
      // Each message capped at 160 chars + ellipsis.
      expect(out, isNot(contains('y' * 161)));
    });
  });
}
