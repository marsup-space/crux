import 'dart:convert';

import 'package:crux/src/lsp/protocol.dart';
import 'package:test/test.dart';

void main() {
  group('LspPosition', () {
    test('fromJson reads line and character', () {
      expect(
        LspPosition.fromJson({'line': 3, 'character': 12}),
        const LspPosition(3, 12),
      );
    });

    test('fromJson defaults missing fields to 0', () {
      expect(LspPosition.fromJson(const {}), const LspPosition(0, 0));
    });

    test('toJson round-trips', () {
      const pos = LspPosition(7, 5);
      final round = LspPosition.fromJson(pos.toJson());
      expect(round, pos);
    });

    test('equality and hashCode work', () {
      expect(const LspPosition(1, 2), const LspPosition(1, 2));
      expect(
        const LspPosition(1, 2).hashCode,
        const LspPosition(1, 2).hashCode,
      );
      expect(const LspPosition(1, 2) == const LspPosition(1, 3), isFalse);
    });
  });

  group('LspRange', () {
    test('fromJson reads start and end', () {
      final r = LspRange.fromJson({
        'start': {'line': 1, 'character': 2},
        'end': {'line': 3, 'character': 4},
      });
      expect(r.start, const LspPosition(1, 2));
      expect(r.end, const LspPosition(3, 4));
    });

    test('fromJson tolerates null/missing range', () {
      final r = LspRange.fromJson({});
      expect(r.start, const LspPosition(0, 0));
      expect(r.end, const LspPosition(0, 0));
    });
  });

  group('LspDiagnosticSeverity', () {
    test('fromJson reads wire values', () {
      expect(LspDiagnosticSeverity.fromJson(1), LspDiagnosticSeverity.error);
      expect(LspDiagnosticSeverity.fromJson(2), LspDiagnosticSeverity.warning);
      expect(
        LspDiagnosticSeverity.fromJson(3),
        LspDiagnosticSeverity.information,
      );
      expect(LspDiagnosticSeverity.fromJson(4), LspDiagnosticSeverity.hint);
    });

    test('fromJson returns null for unknown values', () {
      expect(LspDiagnosticSeverity.fromJson(5), isNull);
      expect(LspDiagnosticSeverity.fromJson('error'), isNull);
      expect(LspDiagnosticSeverity.fromJson(null), isNull);
    });
  });

  group('LspDiagnostic.fromJson', () {
    test('parses a full diagnostic', () {
      final d = LspDiagnostic.fromJson({
        'range': {
          'start': {'line': 5, 'character': 0},
          'end': {'line': 5, 'character': 10},
        },
        'message': "Expected ';'",
        'severity': 1,
        'source': 'typescript',
        'code': 1005,
        'relatedInformation': [
          {
            'uri': 'file:///foo/bar.ts',
            'range': {
              'start': {'line': 1, 'character': 0},
              'end': {'line': 1, 'character': 1},
            },
            'message': 'declared here',
          },
        ],
      });
      expect(d.message, "Expected ';'");
      expect(d.severity, LspDiagnosticSeverity.error);
      expect(d.source, 'typescript');
      expect(d.code, '1005');
      expect(d.relatedInformation, hasLength(1));
      expect(d.range.start, const LspPosition(5, 0));
    });

    test('treats numeric and string codes uniformly', () {
      final a = LspDiagnostic.fromJson({'message': 'x', 'code': 42});
      final b = LspDiagnostic.fromJson({'message': 'x', 'code': 'E42'});
      expect(a.code, '42');
      expect(b.code, 'E42');
    });

    test('handles missing severity as null', () {
      final d = LspDiagnostic.fromJson({
        'range': {
          'start': {'line': 0, 'character': 0},
          'end': {'line': 0, 'character': 0},
        },
        'message': 'note',
      });
      expect(d.severity, isNull);
    });
  });

  group('LspRpcError', () {
    test('formats with method and code', () {
      final err = LspRpcError.fromJson({
        'code': -32601,
        'message': 'Method not found',
      }, method: 'foo/bar');
      expect(err.code, -32601);
      expect(err.message, 'Method not found');
      expect(err.method, 'foo/bar');
      expect(err.toString(), contains('foo/bar'));
    });
  });

  group('Diagnostic JSON round-trip via extension', () {
    test('encodes then decodes to an equal diagnostic', () {
      final original = LspDiagnostic(
        range: const LspRange(LspPosition(2, 3), LspPosition(2, 9)),
        message: 'broken',
        severity: LspDiagnosticSeverity.warning,
        source: 'dart',
        code: 'W42',
      );
      final json = jsonDecode(original.toJsonString()) as Map<String, dynamic>;
      final restored = LspDiagnostic.fromJson(json);
      expect(restored, original);
    });
  });
}
