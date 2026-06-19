import 'package:crux/src/utils/partial_json_field_extractor.dart';
import 'package:test/test.dart';

void main() {
  group('PartialJsonFieldExtractor', () {
    test('extracts complete string fields', () {
      expect(
        PartialJsonFieldExtractor.extractStringField(
          r'{"filePath":"lib/main.dart","content":"x"}',
          'filePath',
        ),
        'lib/main.dart',
      );
    });

    test('returns null while a string value is still streaming', () {
      expect(
        PartialJsonFieldExtractor.extractStringField(
          r'{"filePath":"lib/main.dart',
          'filePath',
        ),
        isNull,
      );
    });

    test('unescapes common JSON escapes and unicode escapes', () {
      expect(
        PartialJsonFieldExtractor.extractStringField(
          r'{"oldString":"a\n\"b\"\u0041"}',
          'oldString',
        ),
        'a\n"b"A',
      );
    });

    test('returns empty strings as valid values', () {
      expect(
        PartialJsonFieldExtractor.extractStringField(
          r'{"oldString":""}',
          'oldString',
        ),
        '',
      );
    });

    test('returns null for malformed escapes', () {
      expect(
        PartialJsonFieldExtractor.extractStringField(
          r'{"oldString":"bad\x"}',
          'oldString',
        ),
        isNull,
      );
    });
  });
}
