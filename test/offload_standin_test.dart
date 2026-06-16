import 'package:test/test.dart';
import 'package:crux/src/utils/offload_standin.dart';

void main() {
  group('parseOffloadStandIn', () {
    test('returns null for non-stand-in text', () {
      expect(parseOffloadStandIn(''), isNull);
      expect(parseOffloadStandIn('hello world'), isNull);
      expect(
        parseOffloadStandIn('foo\n[offloaded: 1 lines / 1B'),
        isNull,
        reason: 'must start with [offloaded:, not contain it mid-string',
      );
    });

    test('parses the canonical stand-in form', () {
      final parsed = parseOffloadStandIn(
        '[offloaded: 42 lines / 3.0KB; recall via offloaded_content(key="abc_oldString")]',
      );
      expect(parsed, isNotNull);
      expect(parsed!.lineCount, 42);
      expect(parsed.sizeStr, '3.0KB');
      expect(parsed.key, 'abc_oldString');
      expect(parsed.intent, isNull);
    });

    test('parses the stand-in with an intent fragment', () {
      final parsed = parseOffloadStandIn(
        '[offloaded: 1 lines / 5B; recall via offloaded_content(key="k"); intent: "fix bug"]',
      );
      expect(parsed, isNotNull);
      expect(parsed!.lineCount, 1);
      expect(parsed.sizeStr, '5B');
      expect(parsed.key, 'k');
      expect(parsed.intent, 'fix bug');
    });

    test('ignores trailing unknown fragments', () {
      // Future fields after the closing `]` would not be
      // common, but the parser must not crash on them either
      // if they appear inside the bracket (e.g. a comment).
      final parsed = parseOffloadStandIn(
        '[offloaded: 7 lines / 2.0KB; recall via offloaded_content(key="k"); future="x"]',
      );
      expect(parsed, isNotNull);
      expect(parsed!.lineCount, 7);
    });

    test('returns lineCount=0 on a malformed number', () {
      // The pattern requires `\d+`, so a non-numeric value
      // wouldn't match the outer regex at all. Verify the
      // safe-fallback behaviour for an edge case: a value
      // that matches the prefix shape but not the lineCount
      // digits should not parse.
      final parsed = parseOffloadStandIn(
        '[offloaded: -1 lines / 1B; recall via offloaded_content(key="k")]',
      );
      expect(parsed, isNull, reason: 'negative line count should not match');
    });
  });

  group('containsOffloadStandIn', () {
    test('detects a standalone stand-in', () {
      expect(
        containsOffloadStandIn(
          '[offloaded: 42 lines / 3.0KB; recall via offloaded_content(key="abc_newString")]',
        ),
        isTrue,
      );
    });

    test('detects a stand-in embedded as a line in a larger payload', () {
      expect(
        containsOffloadStandIn(
          'before\n'
          '[offloaded: 2 lines / 2.1KB; recall via offloaded_content(key="abc_newString")]\n'
          'after',
        ),
        isTrue,
      );
    });

    test('ignores ordinary prose that mentions offloading', () {
      expect(
        containsOffloadStandIn('offloaded_content is a table name'),
        isFalse,
      );
    });
  });

  group('jsonStringArgContainsOffloadStandIn', () {
    test('detects stand-in inside a complete write.content JSON string', () {
      expect(
        jsonStringArgContainsOffloadStandIn(
          '{"filePath":"x","content":"[offloaded: 42 lines / 3.0KB; recall via offloaded_content(key=\\"abc_content\\")]"}',
          'content',
        ),
        isTrue,
      );
    });

    test('detects stand-in inside a partial streamed JSON string', () {
      expect(
        jsonStringArgContainsOffloadStandIn(
          '{"filePath":"x","content":"before [offloaded: 2 lines / 2.1KB; recall via offloaded_content(key=\\"abc_content\\")]',
          'content',
        ),
        isTrue,
      );
    });

    test('only scans the requested argument value', () {
      expect(
        jsonStringArgContainsOffloadStandIn(
          '{"oldString":"[offloaded: 42 lines / 3.0KB; recall via offloaded_content(key=\\"abc_oldString\\")]","newString":"clean"}',
          'newString',
        ),
        isFalse,
        reason:
            'edit.oldString may contain a stand-in when cleaning up a polluted file',
      );
    });

    test('ignores stand-ins in later unrelated fields', () {
      expect(
        jsonStringArgContainsOffloadStandIn(
          '{"newString":"clean","intent":"mentions [offloaded: 42 lines / 3.0KB; recall via offloaded_content(key=\\"abc_newString\\")]"}',
          'newString',
        ),
        isFalse,
      );
    });
  });

  group('lineCountOfArg', () {
    test('returns 0 for null and empty', () {
      expect(lineCountOfArg(null), 0);
      expect(lineCountOfArg(''), 0);
    });

    test('counts lines in a plain string (matches `read` convention)', () {
      expect(lineCountOfArg('hello'), 1, reason: 'no newline → 1 line');
      expect(lineCountOfArg('a\nb'), 2);
      expect(
        lineCountOfArg('a\nb\nc\n'),
        4,
        reason: 'trailing newline still counts a final empty line',
      );
    });

    test('recovers line count from a stand-in pointer', () {
      // Crucial case: when oldString was offloaded, the
      // persisted args hold the stand-in. We must NOT count
      // the lines of the stand-in metadata string itself.
      final standIn =
          '[offloaded: 17 lines / 4.2KB; recall via offloaded_content(key="x")]';
      expect(lineCountOfArg(standIn), 17);
    });
  });
}
