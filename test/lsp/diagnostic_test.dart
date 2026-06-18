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
        range: const LspRange(
          LspPosition(2, 9),
          LspPosition(2, 17),
        ),
        message: "A value of type 'String' can't be returned",
        severity: LspDiagnosticSeverity.error,
        source: 'dart',
        code: 'A value of type \'String\' can\'t be returned',
      );
      final payload = buildLspPayload([diag]);
      expect(payload, contains('<crux-lsp>'));
      expect(payload, contains('</crux-lsp>'));
      expect(payload, contains("can't be returned"));  // message preserved
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
}
