import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/utils/unicode_width.dart';

import 'highlight_service.dart';
import '../../theme/crux_theme.dart';

class HighlightedMarkdownText extends StatefulComponent {
  const HighlightedMarkdownText(
    this.data, {
    super.key,
    this.textAlign = TextAlign.left,
    this.softWrap = true,
    this.overflow = TextOverflow.clip,
    this.maxLines,
    this.styleSheet,
  });

  final String data;
  final TextAlign textAlign;
  final bool softWrap;
  final TextOverflow overflow;
  final int? maxLines;
  final HighlightMarkdownStyleSheet? styleSheet;

  @override
  State<HighlightedMarkdownText> createState() =>
      _HighlightedMarkdownTextState();
}

class _HighlightedMarkdownTextState extends State<HighlightedMarkdownText> {
  List<InlineSpan> _spans = const [];
  int? _lastMaxWidth;
  String? _lastData;
  HighlightMarkdownStyleSheet? _lastStyleSheet;

  List<InlineSpan> _parseMarkdown({int? maxWidth}) {
    final effectiveStyleSheet =
        component.styleSheet ?? HighlightMarkdownStyleSheet.terminalDark();
    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    final nodes = document.parse(component.data);

    final visitor = _HighlightMarkdownVisitor(
      effectiveStyleSheet,
      maxWidth: maxWidth,
    );
    return visitor.visitNodes(nodes);
  }

  @override
  Component build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.toInt()
            : null;

        if (component.data != _lastData ||
            component.styleSheet != _lastStyleSheet ||
            maxWidth != _lastMaxWidth) {
          _lastData = component.data;
          _lastStyleSheet = component.styleSheet;
          _lastMaxWidth = maxWidth;
          _spans = _parseMarkdown(maxWidth: maxWidth);
        }

        return RichText(
          text: TextSpan(children: _spans),
          textAlign: component.textAlign,
          softWrap: component.softWrap,
          overflow: component.overflow,
          maxLines: component.maxLines,
        );
      },
    );
  }
}

class HighlightMarkdownStyleSheet {
  const HighlightMarkdownStyleSheet({
    this.h1Style,
    this.h2Style,
    this.h3Style,
    this.h4Style,
    this.h5Style,
    this.h6Style,
    this.paragraphStyle,
    this.boldStyle,
    this.italicStyle,
    this.strikethroughStyle,
    this.codeStyle,
    this.codeBlockStyle,
    this.blockquoteStyle,
    this.linkStyle,
    this.listBullet = '• ',
    this.horizontalRule = '─',
    this.codeBlockBackground,
    this.codeBlockHeaderStyle,
  });

  factory HighlightMarkdownStyleSheet.terminalDark() {
    return HighlightMarkdownStyleSheet(
      h1Style: const TextStyle(
        fontWeight: FontWeight.bold,
        color: CruxTheme.mdH1,
      ),
      h2Style: const TextStyle(
        fontWeight: FontWeight.bold,
        color: CruxTheme.mdH2,
      ),
      h3Style: const TextStyle(
        fontWeight: FontWeight.bold,
        color: CruxTheme.mdH3,
      ),
      h4Style: const TextStyle(
        fontWeight: FontWeight.bold,
        color: CruxTheme.mdH4,
      ),
      h5Style: const TextStyle(
        fontWeight: FontWeight.bold,
        color: CruxTheme.mdH5,
      ),
      h6Style: const TextStyle(
        fontWeight: FontWeight.bold,
        color: CruxTheme.mdH6,
      ),
      boldStyle: const TextStyle(
        fontWeight: FontWeight.bold,
        color: CruxTheme.mdBold,
      ),
      italicStyle: const TextStyle(
        fontStyle: FontStyle.italic,
        color: CruxTheme.mdItalic,
      ),
      strikethroughStyle: const TextStyle(
        decoration: TextDecoration.lineThrough,
        color: CruxTheme.mdStrikethrough,
      ),
      codeStyle: const TextStyle(
        color: CruxTheme.mdInlineCode,
        backgroundColor: CruxTheme.mdInlineCodeBg,
      ),
      codeBlockStyle: const TextStyle(
        color: CruxTheme.mdCodeBlockText,
        backgroundColor: CruxTheme.codeBlockBackground,
      ),
      blockquoteStyle: const TextStyle(
        color: CruxTheme.mdBlockquote,
        fontStyle: FontStyle.italic,
      ),
      linkStyle: const TextStyle(
        color: CruxTheme.mdLink,
        decoration: TextDecoration.underline,
      ),
      codeBlockBackground: CruxTheme.codeBlockBackground,
      codeBlockHeaderStyle: const TextStyle(color: CruxTheme.codeBlockHeader),
    );
  }

  final TextStyle? h1Style;
  final TextStyle? h2Style;
  final TextStyle? h3Style;
  final TextStyle? h4Style;
  final TextStyle? h5Style;
  final TextStyle? h6Style;
  final TextStyle? paragraphStyle;
  final TextStyle? boldStyle;
  final TextStyle? italicStyle;
  final TextStyle? strikethroughStyle;
  final TextStyle? codeStyle;
  final TextStyle? codeBlockStyle;
  final TextStyle? blockquoteStyle;
  final TextStyle? linkStyle;
  final String listBullet;
  final String horizontalRule;
  final Color? codeBlockBackground;
  final TextStyle? codeBlockHeaderStyle;
}

class _HighlightMarkdownVisitor {
  _HighlightMarkdownVisitor(this.styleSheet, {this.maxWidth});

  final HighlightMarkdownStyleSheet styleSheet;
  final int? maxWidth;
  int _listDepth = 0;

  List<InlineSpan> visitNodes(List<md.Node> nodes) {
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      final span = visitNode(node);
      if (span != null) {
        spans.add(span);
      }
    }
    if (spans.isNotEmpty) {
      spans[spans.length - 1] = _trimTrailingNewlines(spans.last);
    }
    return spans;
  }

  static InlineSpan _trimTrailingNewlines(InlineSpan span) {
    if (span is! TextSpan) return span;

    final children = span.children;
    if (children != null && children.isNotEmpty) {
      final last = children.last;
      if (last is TextSpan &&
          last.text != null &&
          RegExp(r'^\n+$').hasMatch(last.text!)) {
        final trimmed = children.sublist(0, children.length - 1);
        return TextSpan(children: trimmed, style: span.style);
      }
      final trimmedLast = _trimTrailingNewlines(last);
      if (trimmedLast != last) {
        final updated = [...children];
        updated[updated.length - 1] = trimmedLast;
        return TextSpan(children: updated, style: span.style);
      }
    } else if (span.text != null && span.text!.endsWith('\n')) {
      return TextSpan(text: span.text!.trimRight(), style: span.style);
    }

    return span;
  }

  InlineSpan? visitNode(md.Node node) {
    if (node is md.Element) {
      return visitElement(node);
    } else if (node is md.Text) {
      return TextSpan(text: node.text);
    }
    return null;
  }

  InlineSpan? visitElement(md.Element element) {
    switch (element.tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final style = element.tag == 'h1'
            ? styleSheet.h1Style
            : element.tag == 'h2'
            ? styleSheet.h2Style
            : element.tag == 'h3'
            ? styleSheet.h3Style
            : element.tag == 'h4'
            ? styleSheet.h4Style
            : element.tag == 'h5'
            ? styleSheet.h5Style
            : styleSheet.h6Style;
        return TextSpan(
          children: [
            ...visitChildren(element),
            const TextSpan(text: '\n\n'),
          ],
          style: style,
        );
      case 'p':
        return TextSpan(
          children: [
            ...visitChildren(element),
            const TextSpan(text: '\n\n'),
          ],
          style: styleSheet.paragraphStyle,
        );
      case 'strong':
      case 'b':
        return TextSpan(
          children: visitChildren(element),
          style: styleSheet.boldStyle,
        );
      case 'em':
      case 'i':
        return TextSpan(
          children: visitChildren(element),
          style: styleSheet.italicStyle,
        );
      case 'del':
      case 's':
        return TextSpan(
          children: visitChildren(element),
          style: styleSheet.strikethroughStyle,
        );
      case 'code':
        return TextSpan(text: element.textContent, style: styleSheet.codeStyle);
      case 'pre':
        return _renderCodeBlock(element);
      case 'blockquote':
        final children = visitChildren(element);
        return TextSpan(
          children: [
            TextSpan(text: '│ ', style: styleSheet.blockquoteStyle),
            ...children,
            const TextSpan(text: '\n'),
          ],
          style: styleSheet.blockquoteStyle,
        );
      case 'a':
        final href = element.attributes['href'] ?? '';
        final text = element.textContent;
        return TextSpan(
          children: [
            TextSpan(text: text, style: styleSheet.linkStyle),
            TextSpan(
              text: ' ($href)',
              style: styleSheet.linkStyle?.copyWith(
                fontWeight: FontWeight.normal,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        );
      case 'img':
        final alt = element.attributes['alt'] ?? 'image';
        return TextSpan(
          text: '[Image: $alt]',
          style: const TextStyle(fontStyle: FontStyle.italic),
        );
      case 'ul':
      case 'ol':
        _listDepth++;
        final children = visitChildren(element);
        _listDepth--;
        return TextSpan(
          children: [
            ...children,
            if (_listDepth == 0) const TextSpan(text: '\n'),
          ],
        );
      case 'li':
        final indent = '  ' * _listDepth;
        final bullet = styleSheet.listBullet;
        final children = <InlineSpan>[TextSpan(text: indent + bullet)];

        if (element.children != null) {
          for (final child in element.children!) {
            if (child is md.Element &&
                (child.tag == 'ul' || child.tag == 'ol')) {
              if (children.length > 1) {
                children.add(const TextSpan(text: '\n'));
              }
            }

            final span = visitNode(child);
            if (span != null) {
              children.add(span);
            }
          }
        }

        children.add(const TextSpan(text: '\n'));
        return TextSpan(children: children);
      case 'hr':
        final width = maxWidth ?? 40;
        return TextSpan(
          text: styleSheet.horizontalRule * width + '\n\n',
          style: const TextStyle(color: CruxTheme.outline),
        );
      case 'br':
        return const TextSpan(text: '\n');
      case 'table':
        return _renderTable(element);
      default:
        return TextSpan(children: visitChildren(element));
    }
  }

  InlineSpan _renderCodeBlock(md.Element element) {
    final codeElement = element.children != null && element.children!.isNotEmpty
        ? element.children!.first
        : null;
    final code = codeElement?.textContent ?? element.textContent;

    String? language;
    if (codeElement is md.Element) {
      final cls = codeElement.attributes['class'];
      if (cls != null && cls.startsWith('language-')) {
        language = cls.substring(9);
      }
    }

    final bgColor =
        styleSheet.codeBlockBackground ?? CruxTheme.codeBlockBackground;
    final headerStyle =
        styleSheet.codeBlockHeaderStyle ??
        const TextStyle(color: CruxTheme.codeBlockHeader);
    final codeStyle =
        styleSheet.codeBlockStyle ??
        const TextStyle(
          color: CruxTheme.mdCodeBlockText,
          backgroundColor: CruxTheme.codeBlockBackground,
        );

    final width = maxWidth ?? 80;
    final langLabel = language ?? '';
    final headerContent = langLabel.isNotEmpty ? ' $langLabel ' : '';
    final headerPadding = width - 3 - headerContent.length;
    final headerLine = '┌─$headerContent${'─' * math.max(0, headerPadding)}';
    final footerLine = '└${'─' * (width - 1)}';

    final codeLines = code.replaceAll(RegExp(r'\n$'), '').split('\n');

    final spans = <InlineSpan>[];

    spans.add(
      TextSpan(
        text: '$headerLine\n',
        style: headerStyle.copyWith(backgroundColor: bgColor),
      ),
    );

    for (var i = 0; i < codeLines.length; i++) {
      final line = codeLines[i];
      spans.add(
        TextSpan(
          text: '│ ',
          style: TextStyle(
            backgroundColor: bgColor,
            color: CruxTheme.codeBlockGutter,
          ),
        ),
      );

      if (language != null && language.isNotEmpty) {
        final highlighted = highlightCode(line, language);
        for (final span in highlighted) {
          if (span is TextSpan) {
            spans.add(
              TextSpan(
                text: span.text,
                style: (span.style ?? const TextStyle()).copyWith(
                  backgroundColor: bgColor,
                ),
                children: span.children,
              ),
            );
          } else {
            spans.add(span);
          }
        }
      } else {
        spans.add(TextSpan(text: line, style: codeStyle));
      }

      spans.add(
        TextSpan(
          text: '\n',
          style: TextStyle(backgroundColor: bgColor),
        ),
      );
    }

    spans.add(
      TextSpan(
        text: '$footerLine\n\n',
        style: headerStyle.copyWith(backgroundColor: bgColor),
      ),
    );

    return TextSpan(children: spans);
  }

  List<InlineSpan> visitChildren(md.Element element) {
    final spans = <InlineSpan>[];
    if (element.children != null) {
      for (final child in element.children!) {
        final span = visitNode(child);
        if (span != null) {
          spans.add(span);
        }
      }
    }
    return spans;
  }

  InlineSpan _renderTable(md.Element table) {
    final rows = <List<String>>[];
    final naturalWidths = <int>[];

    if (table.children != null) {
      for (final child in table.children!) {
        if (child is md.Element) {
          if (child.tag == 'thead' || child.tag == 'tbody') {
            if (child.children != null) {
              for (final row in child.children!) {
                if (row is md.Element && row.tag == 'tr') {
                  final cells = <String>[];
                  if (row.children != null) {
                    for (final cell in row.children!) {
                      if (cell is md.Element &&
                          (cell.tag == 'th' || cell.tag == 'td')) {
                        cells.add(cell.textContent);
                      }
                    }
                  }
                  rows.add(cells);

                  for (int i = 0; i < cells.length; i++) {
                    if (i >= naturalWidths.length) {
                      naturalWidths.add(0);
                    }
                    final cellWidth = UnicodeWidth.stringWidth(cells[i]);
                    naturalWidths[i] = naturalWidths[i] > cellWidth
                        ? naturalWidths[i]
                        : cellWidth;
                  }
                }
              }
            }
          }
        }
      }
    }

    if (rows.isEmpty || naturalWidths.isEmpty) {
      return const TextSpan(text: '');
    }

    final columnWidths = _distributeColumnWidths(naturalWidths);

    final wrappedRows = <List<List<String>>>[];
    for (final row in rows) {
      final wrappedCells = <List<String>>[];
      for (int c = 0; c < naturalWidths.length; c++) {
        final content = c < row.length ? row[c] : '';
        wrappedCells.add(_wrapCell(content, columnWidths[c]));
      }
      wrappedRows.add(wrappedCells);
    }

    final buffer = StringBuffer();

    _writeHorizontalBorder(buffer, columnWidths, '┌', '─', '┬', '┐');

    for (int r = 0; r < wrappedRows.length; r++) {
      final rowCells = wrappedRows[r];
      final rowHeight = rowCells.fold(
        1,
        (max, cell) => math.max(max, cell.length),
      );

      for (int l = 0; l < rowHeight; l++) {
        buffer.write('│');
        for (int c = 0; c < columnWidths.length; c++) {
          final lines = c < rowCells.length ? rowCells[c] : const [''];
          final line = l < lines.length ? lines[l] : '';
          final displayWidth = UnicodeWidth.stringWidth(line);
          final paddingNeeded = columnWidths[c] - displayWidth;
          buffer.write(' ');
          buffer.write(line);
          if (paddingNeeded > 0) {
            buffer.write(' ' * paddingNeeded);
          }
          buffer.write(' │');
        }
        buffer.write('\n');
      }

      if (r == 0 && wrappedRows.length > 1) {
        _writeHorizontalBorder(buffer, columnWidths, '├', '─', '┼', '┤');
      }
    }

    _writeHorizontalBorder(buffer, columnWidths, '└', '─', '┴', '┘');

    return TextSpan(text: buffer.toString());
  }

  List<int> _distributeColumnWidths(List<int> naturalWidths) {
    final numCols = naturalWidths.length;
    final overhead = 3 * numCols + 1;
    final naturalTotal = naturalWidths.fold(0, (sum, w) => sum + w) + overhead;

    if (maxWidth == null || naturalTotal <= maxWidth!) {
      return List.of(naturalWidths);
    }

    const minColWidth = 3;
    final available = maxWidth! - overhead;

    if (available < numCols * minColWidth) {
      return List.filled(numCols, minColWidth);
    }

    final result = List<int>.filled(numCols, 0);
    final totalNatural = naturalWidths.fold(0, (sum, w) => sum + w);

    int allocated = 0;
    for (int i = 0; i < numCols; i++) {
      result[i] = math.max(
        minColWidth,
        (naturalWidths[i] * available / totalNatural).floor(),
      );
      allocated += result[i];
    }

    var remaining = available - allocated;
    while (remaining > 0) {
      int bestIdx = 0;
      int bestDeficit = 0;
      for (int i = 0; i < numCols; i++) {
        final deficit = naturalWidths[i] - result[i];
        if (deficit > bestDeficit) {
          bestDeficit = deficit;
          bestIdx = i;
        }
      }
      if (bestDeficit == 0) break;
      result[bestIdx]++;
      remaining--;
    }

    while (remaining < 0) {
      int bestIdx = 0;
      int bestExcess = 0;
      for (int i = 0; i < numCols; i++) {
        final excess = result[i] - minColWidth;
        if (excess > bestExcess) {
          bestExcess = excess;
          bestIdx = i;
        }
      }
      if (bestExcess == 0) break;
      result[bestIdx]--;
      remaining++;
    }

    return result;
  }

  static List<String> _wrapCell(String content, int cellWidth) {
    if (cellWidth <= 0) return [''];
    if (UnicodeWidth.stringWidth(content) <= cellWidth) return [content];

    final lines = <String>[];
    final words = content.split(' ');
    var currentLine = '';
    var currentWidth = 0;

    for (final word in words) {
      final wordWidth = UnicodeWidth.stringWidth(word);

      if (currentWidth == 0) {
        if (wordWidth > cellWidth) {
          lines.addAll(_breakLongWord(word, cellWidth));
          final lastLine = lines.removeLast();
          currentLine = lastLine;
          currentWidth = UnicodeWidth.stringWidth(lastLine);
        } else {
          currentLine = word;
          currentWidth = wordWidth;
        }
      } else if (currentWidth + 1 + wordWidth <= cellWidth) {
        currentLine += ' $word';
        currentWidth += 1 + wordWidth;
      } else {
        lines.add(currentLine);
        if (wordWidth > cellWidth) {
          lines.addAll(_breakLongWord(word, cellWidth));
          final lastLine = lines.removeLast();
          currentLine = lastLine;
          currentWidth = UnicodeWidth.stringWidth(lastLine);
        } else {
          currentLine = word;
          currentWidth = wordWidth;
        }
      }
    }

    if (currentLine.isNotEmpty) {
      lines.add(currentLine);
    }

    return lines.isEmpty ? [''] : lines;
  }

  static List<String> _breakLongWord(String word, int maxWidth) {
    final parts = <String>[];
    var current = '';
    var currentWidth = 0;

    for (final grapheme in word.characters) {
      final w = UnicodeWidth.graphemeWidth(grapheme);
      if (currentWidth + w > maxWidth && current.isNotEmpty) {
        parts.add(current);
        current = grapheme;
        currentWidth = w;
      } else {
        current += grapheme;
        currentWidth += w;
      }
    }
    if (current.isNotEmpty) parts.add(current);
    return parts.isEmpty ? [''] : parts;
  }

  static void _writeHorizontalBorder(
    StringBuffer buffer,
    List<int> columnWidths,
    String left,
    String fill,
    String middle,
    String right,
  ) {
    buffer.write(left);
    for (int i = 0; i < columnWidths.length; i++) {
      buffer.write(fill * (columnWidths[i] + 2));
      if (i < columnWidths.length - 1) {
        buffer.write(middle);
      }
    }
    buffer.write(right);
    buffer.write('\n');
  }
}
