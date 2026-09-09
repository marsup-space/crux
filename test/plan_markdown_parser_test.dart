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
      expect(result.headings.map((h) => h.text), ['Alpha', 'Beta', 'Gamma']);
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

  group('plan_markdown_parser lists (tight items)', () {
    // Regression: tight lists expose emphasis/code/link nodes as DIRECT
    // children of the list item (no paragraph wrapper). Routing those
    // through the block walk's default case emitted a paragraph gap
    // after every inline node, shredding items into visual paragraphs.
    test('ordered-list item renders as one continuous block', () {
      final result = parsePlanDocument(
        '1. **Plan scrollbar** — add a scrollbar to the pane, matching the\n'
        '   chat history\'s scrollbar.\n'
        '2. **Privacy** — stop rendering `<plan-context>` inline.\n',
        const _TestTheme(),
      );
      // Item content must stay on consecutive rows: no blank rows
      // INSIDE an item (blank row only after the final item).
      final rows = result.renderedText.split('\n');
      // The first item's text starts right after its bullet on row 0
      // and its second source line continues on row 1.
      expect(rows[0], startsWith('1. Plan scrollbar — add a scrollbar'));
      expect(rows[1], "chat history's scrollbar.");
      // The second item follows immediately — no blank row between.
      expect(rows[2], startsWith('2. Privacy — stop rendering'));
      // Inline code renders its content (no gap shredding).
      expect(rows[2], contains('<plan-context>'));
    });

    test('bullet-list items render with bullets and no inner gaps', () {
      final result = parsePlanDocument(
        '- `AnnotatedScrollbar` is ListView-specific.\n'
        '- Everything else is shared code.\n',
        const _TestTheme(),
      );
      final rows = result.renderedText.split('\n');
      expect(rows[0], startsWith('• AnnotatedScrollbar'));
      expect(rows[1], startsWith('• Everything else'));
      // Rows 0/1 are dense content; the remaining 1-2 rows are the
      // list-level trailing separator(s) — no blank row INSIDE items.
      expect(rows.length, lessThanOrEqualTo(4));
    });

    test('nested list items keep their inline emphasis', () {
      final result = parsePlanDocument(
        '- outer **bold** item\n'
        '  - inner *italic* item\n',
        const _TestTheme(),
      );
      final rows = result.renderedText.split('\n');
      expect(rows[0], startsWith('• outer bold item'));
      expect(rows[1], contains('inner italic item'));
    });
  });

  group('plan_markdown_parser diagram fences (mermaid/d2)', () {
    test('a parseable mermaid fence renders the graph inside the box', () {
      final result = parsePlanDocument(
        '```mermaid\n'
        'flowchart LR\n'
        '  A[Start] --> B[End]\n'
        '```\n',
        const _TestTheme(),
        maxWidth: 80,
      );
      final rows = result.renderedText.split('\n');
      // Box header carries the language label.
      expect(rows.first, contains('╭─ mermaid'));
      // Some rendered row contains an arrow — the graph, not raw source
      // (`-->` with boxes around it; raw source would show `A[Start]`).
      expect(
        rows.any(
          (r) =>
              r.contains('──') && r.contains('▶') ||
              r.contains('-->') == false && r.contains('['),
        ),
        isTrue,
        reason: 'diagram art expected; got:\n${result.renderedText}',
      );
      expect(
        result.renderedText.contains('flowchart LR'),
        isFalse,
        reason: 'raw source must not leak when parsing succeeded',
      );
    });

    test('an unparseable (streaming partial) fence falls back to code', () {
      final result = parsePlanDocument(
        '```mermaid\n'
        'this is not diagram source\n'
        '```\n',
        const _TestTheme(),
        maxWidth: 80,
      );
      // Fallback renders RAW source rows — the source text is present.
      expect(result.renderedText, contains('this is not diagram source'));
    });

    test('non-diagram fences never hit the diagram path', () {
      final result = parsePlanDocument(
        '```dart\nvoid main() {}\n```\n',
        const _TestTheme(),
        maxWidth: 80,
      );
      expect(result.renderedText, contains('void main() {}'));
      expect(result.renderedText.contains('╭─ dart'), isTrue);
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
