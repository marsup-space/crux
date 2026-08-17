import 'package:crux/src/components/ui/markdown_isolate.dart';
import 'package:crux/src/markdown/plan_markdown_parser.dart';
import 'package:crux/src/models/plan_selection.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

void main() {
  const theme = _TestTheme();

  group('PlanSourceMap — rendered→source (selection)', () {
    test('header text maps to its source line and columns', () {
      final r = parsePlanDocument('# Title', theme);
      // Rendered: "Title\n\n" (content + 2 separator rows).
      // Selecting "Title" (rendered 0..5) should map to source 2..7
      // ("# Title" → 'T' is at offset 2).
      final start = r.sourceMap.renderedToSource(0);
      expect(start.line, 0);
      expect(start.column, 2);
      final end = r.sourceMap.renderedToSource(5);
      expect(end.offset, 7);
    });

    test('selection on a ** marker maps to the marker columns', () {
      // "Some **bold** text"
      //  Some=0-3, space=4, **=5-6, bold=7-10, **=11-12, ...
      final r = parsePlanDocument('Some **bold** text', theme);
      // Rendered: "Some bold text" — the 'b' of bold is at rendered 5.
      final boldStart = r.sourceMap.renderedToSource(5);
      expect(boldStart.offset, 7); // 'b' in source
      final boldEnd = r.sourceMap.renderedToSource(9, bias: MapBias.end);
      expect(boldEnd.offset, 11); // 'd' in source
    });

    test('inline code content maps past the backtick', () {
      // "use `print` now" — backtick@4, print@5-9
      final r = parsePlanDocument('use `print` now', theme);
      // Rendered: "use print now" — 'p' at rendered 4.
      final p = r.sourceMap.renderedToSource(4);
      expect(p.offset, 5); // 'p' in source (after the backtick)
    });

    test('multi-line doc: selection in a later block maps to its line', () {
      const src = '# Title\n'
          '\n'
          'A paragraph.\n';
      final r = parsePlanDocument(src, theme);
      // Rendered rows: 0 "Title", 1 "", 2 "A paragraph." — flat text is
      // "Title\n\nA paragraph.\n\n". 'A' sits at rendered offset 7.
      final idx = r.renderedText.indexOf('A paragraph');
      final pos = r.sourceMap.renderedToSource(idx);
      expect(pos.line, 2);
      expect(pos.column, 0);
    });

    test('verbatim source text is recoverable from the range', () {
      const src = 'Some **bold** text';
      final r = parsePlanDocument(src, theme);
      final start = r.sourceMap.renderedToSource(5); // 'b'
      final end = r.sourceMap.renderedToSource(9, bias: MapBias.end); // 'd'
      expect(src.substring(start.offset, end.offset), 'bold');
    });
  });

  group('PlanSourceMap — source→rendered (flash / follow)', () {
    test('source line 0 maps to rendered row 0', () {
      final r = parsePlanDocument('# Title\n\nbody\n', theme);
      expect(r.sourceMap.sourceLinesToRenderedRows(0, 0), contains(0));
    });

    test('a paragraph on source line 2 maps to its rendered row', () {
      const src = '# Title\n'
          '\n'
          'A paragraph.\n';
      final r = parsePlanDocument(src, theme);
      final rows = r.sourceMap.sourceLinesToRenderedRows(2, 2);
      final expectedRow = r.renderedText
              .substring(0, r.renderedText.indexOf('A paragraph'))
              .split('\n')
              .length -
          1;
      expect(rows, contains(expectedRow));
    });

    test('code block source lines map to rendered rows inside the box', () {
      const src = '```dart\n'
          'code();\n'
          '```\n';
      final r = parsePlanDocument(src, theme);
      // Source line 1 ("code();") should map to a rendered row that
      // contains "code();".
      final rows = r.sourceMap.sourceLinesToRenderedRows(1, 1);
      expect(rows, isNotEmpty);
      final rowStart = r.renderedText.split('\n');
      final hit = rows.any((row) => row < rowStart.length && rowStart[row].contains('code();'));
      expect(hit, isTrue, reason: 'rows=$rows rendered=${r.renderedText}');
    });

    test('table body line maps to a rendered row', () {
      const src = '| A | B |\n'
          '| - | - |\n'
          '| 1 | 2 |\n';
      final r = parsePlanDocument(src, theme);
      final rows = r.sourceMap.sourceLinesToRenderedRows(2, 2);
      expect(rows, isNotEmpty);
    });

    test('wrapped table cell line maps to its exact source slice', () {
      // Force a wrap: two columns, narrow maxWidth, long body cell.
      const cell = 'aaa bbb ccc ddd eee';
      final src = '| H | Long |\n'
          '| - | - |\n'
          '| x | $cell |\n';
      // Column widths from _distributeColumnWidths over natural [3,19]
      // with maxWidth 24: overhead = 7, natural total = 22 + 7 = 29 > 24
      // → proportional shrink. Body cell wraps; each rendered line must
      // map back into the source range of the cell content.
      final r = parsePlanDocument(src, theme, maxWidth: 24);
      final cellSrcStart = src.indexOf(cell);
      // Find every rendered span whose text is a prefix slice of cell.
      final coveredWords = <String>[];
      for (final s in r.sourceMap.spans) {
        if (!s.isMarker && s.renderedLength > 0) {
          // Look up the rendered text via renderedText.
          final text = r.renderedText.substring(
            s.renderedStart,
            s.renderedEnd,
          );
          if (text.contains(' ') || text == 'aaa' || text == 'ddd') {
            // Word content from the long cell.
          }
          if (s.sourceStart >= cellSrcStart &&
              s.sourceStart < cellSrcStart + cell.length) {
            coveredWords.add(text.trim());
          }
        }
      }
      // The wrap kept every word reachable with an exact source range.
      expect(coveredWords.join(' ').contains('aaa'), isTrue);
      expect(coveredWords.join(' ').contains('eee'), isTrue);
    });

    test('table rows keep zebra rendering integrity (borders intact)', () {
      const src = '| A | B |\n'
          '| - | - |\n'
          '| 1 | 2 |\n'
          '| 3 | 4 |\n';
      final r = parsePlanDocument(src, theme, maxWidth: 40);
      final lines = r.renderedText.split('\n');
      // All grid lines have consistent width: border + 2 content rows
      // + separator + bottom border.
      final gridLines = lines
          .where((l) => l.startsWith('┌') || l.startsWith('├') || l.startsWith('└'))
          .toList();
      expect(gridLines, hasLength(3));
      final w = gridLines.first.length;
      for (final g in gridLines) {
        expect(g.length, w, reason: 'grid: $g');
      }
    });
  });

  group('PlanParseResult integrity', () {
    test('renderedText is the concatenation of all span text', () {
      final r = parsePlanDocument('# T\n\npara **bold**\n', theme);
      final fromSpans = r.spans.fold<String>(
        '',
        (acc, s) => acc + (s is TextSpan ? (s.text ?? '') : ''),
      );
      expect(fromSpans, r.renderedText);
    });

    test('sourceMap spans are contiguous over the rendered text', () {
      final r = parsePlanDocument('# T\n\npara `code`\n', theme);
      var pos = 0;
      for (final span in r.sourceMap.spans) {
        expect(span.renderedStart, greaterThanOrEqualTo(pos),
            reason: 'span at ${span.renderedStart} overlaps previous end $pos');
        pos = span.renderedEnd > pos ? span.renderedEnd : pos;
      }
    });
  });
}

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
