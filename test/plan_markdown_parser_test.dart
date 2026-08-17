import 'package:crux/src/components/ui/markdown_isolate.dart'
    show MarkdownThemeFields;
import 'package:crux/src/markdown/plan_markdown_parser.dart';
import 'package:nocterm/nocterm.dart' show Color;
import 'package:test/test.dart';

void main() {
  group('plan_markdown_parser headings', () {
    test('emits headings with their flat rendered rows', () {
      final result = parsePlanDocument(
        '# Alpha\n\n'
        'Some intro paragraph.\n\n'
        '## Beta\n\n'
        'More text here.\n\n'
        '### Gamma\n',
        const _TestTheme(),
      );
      expect(result.headings.map((h) => h.text), [
        'Alpha',
        'Beta',
        'Gamma',
      ]);
      // Rows are 0-based flat rows. Each block is followed by a blank
      // separator row (the `_emitBlockGap` extra `\n`).
      //   0  Alpha
      //   1  (blank)
      //   2  Some intro paragraph.
      //   3  (blank)
      //   4  Beta
      //   ...
      expect(result.headings.map((h) => h.renderedRow), [0, 4, 8]);
      // Sanity: the recorded rows actually land on the heading text in
      // the rendered flat output.
      final rows = result.renderedText.split('\n');
      for (final h in result.headings) {
        expect(rows[h.renderedRow], h.text);
      }
    });

    test('heading rows track multi-line paragraphs above them', () {
      // A hard line break inside a paragraph pushes the heading down a
      // row; the recorded row must account for it.
      final result = parsePlanDocument(
        'line one  \nline two\n\n# After\n',
        const _TestTheme(),
      );
      expect(result.headings.single.text, 'After');
      final rows = result.renderedText.split('\n');
      expect(rows[result.headings.single.renderedRow], 'After');
    });

    test('a doc with no headings yields an empty list', () {
      final result = parsePlanDocument(
        'just a paragraph\n\n- a list item\n',
        const _TestTheme(),
      );
      expect(result.headings, isEmpty);
    });
  });
}

/// Colorless theme — the parser only reads colors, never touches a
/// [BuildContext], so a stub is enough.
class _TestTheme implements MarkdownThemeFields {
  const _TestTheme();
  static const _c = Color(0xFF000000);
  @override
  Color get markdownText => _c;
  @override
  Color get thinkingExpandedText => _c;
  @override
  Color get mdH1 => _c;
  @override
  Color get mdH2 => _c;
  @override
  Color get mdH3 => _c;
  @override
  Color get mdH4 => _c;
  @override
  Color get mdH5 => _c;
  @override
  Color get mdH6 => _c;
  @override
  Color get mdBold => _c;
  @override
  Color get mdItalic => _c;
  @override
  Color get mdStrikethrough => _c;
  @override
  Color get mdInlineCode => _c;
  @override
  Color get mdInlineCodeBg => _c;
  @override
  Color get mdCodeBlockText => _c;
  @override
  Color get mdBlockquote => _c;
  @override
  Color get mdLink => _c;
  @override
  Color get codeBlockBackground => _c;
  @override
  Color get codeBlockGutter => _c;
  @override
  Color get codeBlockHeader => _c;
  @override
  Color get outline => _c;
  @override
  Color get surface => _c;
  @override
  Color get surfaceVariant => _c;
  @override
  Color get highlightDefault => _c;
  @override
  Color get highlightKeyword => _c;
  @override
  Color get highlightStorage => _c;
  @override
  Color get highlightFunction => _c;
  @override
  Color get highlightType => _c;
  @override
  Color get highlightAttribute => _c;
  @override
  Color get highlightString => _c;
  @override
  Color get highlightComment => _c;
  @override
  Color get highlightConstant => _c;
  @override
  Color get highlightNumeric => _c;
  @override
  Color get highlightVariable => _c;
  @override
  Color get highlightTag => _c;
  @override
  Color get highlightPunctuation => _c;
  @override
  Color get syntaxOperator => _c;
}
