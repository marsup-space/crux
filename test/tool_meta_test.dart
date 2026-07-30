import 'package:crux/src/utils/tool_meta.dart';
import 'package:test/test.dart';

void main() {
  group('parseToolRouting', () {
    test('returns null for null input', () {
      expect(parseToolRouting(null), isNull);
    });

    test('returns null for empty string', () {
      expect(parseToolRouting(''), isNull);
    });

    test('returns null for malformed JSON', () {
      expect(parseToolRouting('not json'), isNull);
      expect(parseToolRouting('{routing: system-proxy}'), isNull);
      expect(parseToolRouting('{}'), isNull);
      expect(parseToolRouting('{"other":"value"}'), isNull);
    });

    test('parses system-proxy routing', () {
      final r = parseToolRouting('{"routing":"system-proxy"}');
      expect(r, isNotNull);
      expect(r!.value, 'system-proxy');
      expect(r.isProxied, isTrue);
    });

    test('direct routing is hidden (no UI metadata)', () {
      // `direct` is the default; we never persist it. The parser
      // returns null so neither bubble nor detail view renders
      // anything for direct calls.
      expect(parseToolRouting('{"routing":"direct"}'), isNull);
    });

    test('handles whitespace variations in the JSON', () {
      expect(
        parseToolRouting('  {"routing":"system-proxy"}  ')?.value,
        'system-proxy',
      );
      expect(
        parseToolRouting('{"routing"  :  "system-proxy"}')?.value,
        'system-proxy',
      );
    });

    test('unescapes JSON string escapes', () {
      // A routing value with an escaped quote should round-trip.
      // (Not used in practice yet — but the parser shouldn't blow
      // up if a future routing value contains one.)
      final r = parseToolRouting(r'{"routing":"a\"b"}');
      expect(r?.value, 'a"b');
    });

    test('handles additional unknown fields gracefully', () {
      // Future fields may be added to the meta blob; the routing
      // parser should ignore them rather than fail.
      final r = parseToolRouting(
        '{"routing":"system-proxy","future":"value","count":3}',
      );
      expect(r?.value, 'system-proxy');
    });
  });

  group('buildToolMeta', () {
    test('returns empty string for null routing', () {
      expect(buildToolMeta(), '');
      expect(buildToolMeta(routing: null), '');
    });

    test('returns empty string for direct routing (default)', () {
      // We never persist the default — direct means "no UI meta".
      expect(buildToolMeta(routing: const ToolRouting('direct')), '');
    });

    test('serialises system-proxy routing', () {
      expect(
        buildToolMeta(routing: const ToolRouting('system-proxy')),
        '{"routing":"system-proxy"}',
      );
    });

    test('escapes JSON special characters in the value', () {
      expect(
        buildToolMeta(routing: const ToolRouting('a"b')),
        r'{"routing":"a\"b"}',
      );
      expect(
        buildToolMeta(routing: const ToolRouting('a\\b')),
        r'{"routing":"a\\b"}',
      );
    });
  });

  group('round-trip', () {
    test('build → parse returns the original routing', () {
      for (final value in ['system-proxy', 'direct', 'custom-routing']) {
        final meta = buildToolMeta(routing: ToolRouting(value));
        final parsed = parseToolRouting(meta);
        if (value == 'direct') {
          // direct is intentionally suppressed.
          expect(parsed, isNull);
        } else {
          expect(parsed?.value, value);
        }
      }
    });
  });

  group('routingBubbleHint', () {
    test('null routing → null hint', () {
      expect(routingBubbleHint(null), isNull);
    });

    test('system-proxy → "via system proxy"', () {
      expect(
        routingBubbleHint(parseToolRouting('{"routing":"system-proxy"}')),
        'via system proxy',
      );
    });

    test('direct → null (suppressed)', () {
      expect(
        routingBubbleHint(parseToolRouting('{"routing":"direct"}')),
        isNull,
      );
    });

    test('unknown routing → echoes the value', () {
      expect(
        routingBubbleHint(parseToolRouting('{"routing":"custom"}')),
        'custom',
      );
    });
  });
}
