import 'package:crux/src/utils/partial_json_field_extractor.dart';
import 'package:crux/src/utils/tool_metrics_animator.dart';
import 'package:test/test.dart';

void main() {
  group('streaming tool line deltas', () {
    test('counts partial write content lines', () {
      final delta = toolMetricsLineDeltaFromPartialJson(
        toolName: 'write',
        partialJson: r'{"filePath":"lib/a.dart","content":"one\ntwo',
      );

      expect(delta.addedLines, 2);
      expect(delta.removedLines, isNull);
    });

    test('counts edit old/new lines independently', () {
      final delta = toolMetricsLineDeltaFromPartialJson(
        toolName: 'edit',
        partialJson: r'{"oldString":"a\nb\nc","newString":"x\ny"',
      );

      expect(delta.addedLines, 2);
      expect(delta.removedLines, 3);
    });

    test('returns null line deltas before edit/write payload appears', () {
      final delta = toolMetricsLineDeltaFromPartialJson(
        toolName: 'edit',
        partialJson: r'{"filePath":"lib/a.dart"',
      );

      expect(delta.addedLines, isNull);
      expect(delta.removedLines, isNull);
    });
  });

  group('PartialJsonFieldExtractor (lenient streaming mode)', () {
    // The streaming tool-call preview uses the lenient mode so
    // the line-count badge can appear while the LLM is still
    // emitting the field, instead of waiting for the closing
    // quote. These tests pin that contract.
    test('handles complete JSON strings', () {
      expect(
        PartialJsonFieldExtractor.extractStringField(
          r'{"content":"a\nb"}',
          'content',
          lenient: true,
        ),
        'a\nb',
      );
    });

    test('returns the partial value when the closing quote is missing', () {
      expect(
        PartialJsonFieldExtractor.extractStringField(
          r'{"content":"a\nb',
          'content',
          lenient: true,
        ),
        'a\nb',
      );
    });

    test('unescapes common string escapes', () {
      expect(
        PartialJsonFieldExtractor.extractStringField(
          r'{"content":"say \"hi\"\tthere"}',
          'content',
          lenient: true,
        ),
        'say "hi"\tthere',
      );
    });
  });
}
