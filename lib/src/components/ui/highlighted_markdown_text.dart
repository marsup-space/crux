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
    this.highlightText,
  });

  final String data;
  final TextAlign textAlign;
  final bool softWrap;
  final TextOverflow overflow;
  final int? maxLines;
  final HighlightMarkdownStyleSheet? styleSheet;
  final String? highlightText;

  @override
  State<HighlightedMarkdownText> createState() =>
      _HighlightedMarkdownTextState();
}

class _HighlightedMarkdownTextState extends State<HighlightedMarkdownText> {
  List<InlineSpan> _spans = const [];
  int? _lastMaxWidth;
  String? _lastData;
  HighlightMarkdownStyleSheet? _lastStyleSheet;
  String? _lastHighlightText;
  String? _lastThemeId;

  List<InlineSpan> _parseMarkdown(CruxThemeData theme, {int? maxWidth}) {
    return parseMarkdownToInlineSpans(
      component.data,
      theme,
      maxWidth: maxWidth,
      styleSheet: component.styleSheet,
    );
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.toInt()
            : null;

        final highlight = component.highlightText;
        if (component.data != _lastData ||
            component.styleSheet != _lastStyleSheet ||
            theme.id != _lastThemeId ||
            maxWidth != _lastMaxWidth ||
            highlight != _lastHighlightText) {
          _lastData = component.data;
          _lastStyleSheet = component.styleSheet;
          _lastMaxWidth = maxWidth;
          _lastHighlightText = highlight;
          _lastThemeId = theme.id;
          _spans = _parseMarkdown(theme, maxWidth: maxWidth);
          if (highlight != null && highlight.isNotEmpty) {
            _spans = _applyHighlight(_spans, highlight, theme);
          }
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

List<InlineSpan> _applyHighlight(
  List<InlineSpan> spans,
  String search,
  CruxThemeData theme,
) {
  final flat = _flattenSpans(spans);
  final plainText = flat.map((e) => e.$1).join();

  final matchRange = _findHighlightRange(plainText, search);
  if (matchRange == null) return spans;

  final (index, end) = matchRange;
  final result = <_FlatSpan>[];
  int pos = 0;
  for (final span in flat) {
    final spanStart = pos;
    final spanEnd = pos + span.$1.length;
    if (spanEnd <= index || spanStart >= end) {
      result.add(span);
    } else {
      final before = index > spanStart
          ? span.$1.substring(0, index - spanStart)
          : '';
      final match = span.$1.substring(
        index.clamp(spanStart, spanEnd) - spanStart,
        end.clamp(spanStart, spanEnd) - spanStart,
      );
      final after = end < spanEnd ? span.$1.substring(end - spanStart) : '';
      if (before.isNotEmpty) result.add((before, span.$2));
      result.add((match, _mergedWithHighlight(span.$2, theme)));
      if (after.isNotEmpty) result.add((after, span.$2));
    }
    pos = spanEnd;
  }
  return _unflattenSpans(result);
}

(int, int)? _findHighlightRange(String plainText, String search) {
  if (search.isEmpty) return null;

  final exact = plainText.indexOf(search);
  if (exact >= 0) return (exact, exact + search.length);

  final normText = _norm(plainText);
  final normSearch = _norm(search);
  final normIdx = normText.indexOf(normSearch);
  if (normIdx >= 0) {
    return _recoverRange(plainText, normText, normIdx, normSearch.length);
  }

  return _wordOverlapRange(plainText, search);
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

(int, int)? _recoverRange(
  String text,
  String normText,
  int normStart,
  int normLen,
) {
  int charPos = 0;
  int normPos = 0;
  int start = -1;

  while (charPos < text.length && normPos < normStart) {
    final ch = text[charPos];
    charPos++;
    if (ch == ' ' || ch == '\n' || ch == '\t') {
      while (charPos < text.length &&
          (text[charPos] == ' ' ||
              text[charPos] == '\n' ||
              text[charPos] == '\t')) {
        charPos++;
      }
    }
    normPos++;
  }

  start = charPos;
  int normEnd = normStart + normLen;
  while (charPos < text.length && normPos < normEnd) {
    final ch = text[charPos];
    charPos++;
    if (ch == ' ' || ch == '\n' || ch == '\t') {
      while (charPos < text.length &&
          (text[charPos] == ' ' ||
              text[charPos] == '\n' ||
              text[charPos] == '\t')) {
        charPos++;
      }
    }
    normPos++;
  }

  return (start, charPos);
}

(int, int)? _wordOverlapRange(String plainText, String search) {
  final excerptWords = _norm(
    search,
  ).split(' ').where((w) => w.length > 2).toList();
  if (excerptWords.isEmpty) return null;

  final windowSize = search.length * 2;
  final step = (windowSize / 2).floor();

  int bestStart = 0;
  double bestScore = 0;

  for (int start = 0; start < plainText.length; start += step) {
    final end = (start + windowSize).clamp(0, plainText.length);
    final window = plainText.substring(start, end);
    final windowNorm = _norm(window);

    int matched = 0;
    for (final word in excerptWords) {
      if (windowNorm.contains(word)) matched++;
    }

    final score = matched / excerptWords.length;
    if (score > bestScore) {
      bestScore = score;
      bestStart = start;
    }
  }

  if (bestScore >= 0.6) {
    final end = (bestStart + windowSize).clamp(0, plainText.length);
    return (bestStart, end);
  }
  return null;
}

TextStyle? _mergedWithHighlight(TextStyle? base, CruxThemeData theme) {
  return TextStyle(
    color: theme.onColor(theme.selection),
    backgroundColor: theme.selection,
    fontWeight: FontWeight.bold,
    fontStyle: base?.fontStyle,
    decoration: base?.decoration,
  );
}

/// Parses [text] as GitHub-Flavored Markdown and returns a flat list of
/// [InlineSpan]s suitable for terminal rendering.
///
/// This is the shared entry point used by every markdown-aware widget
/// in the app (the main chat response renderer, the TLDR summary
/// renderer, the BTW bubble, tool detail panes, etc.) so they all
/// produce visually consistent output — including tables, code
/// blocks, and the full box-drawing border treatment.
///
/// Pass [maxWidth] to constrain the rendered width to the available
/// terminal columns; tables, code blocks, and HR rules respect this
/// value. [styleSheet] overrides the theme-derived default styles.
List<InlineSpan> parseMarkdownToInlineSpans(
  String text,
  CruxThemeData theme, {
  int? maxWidth,
  HighlightMarkdownStyleSheet? styleSheet,
}) {
  final effectiveStyleSheet =
      styleSheet ?? HighlightMarkdownStyleSheet.fromTheme(theme);
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  final nodes = document.parse(text);

  final visitor = _HighlightMarkdownVisitor(
    effectiveStyleSheet,
    theme: theme,
    maxWidth: maxWidth,
  );
  return visitor.visitNodes(nodes);
}

typedef _FlatSpan = (String, TextStyle?);

List<_FlatSpan> _flattenSpans(List<InlineSpan> spans) {
  final result = <_FlatSpan>[];
  for (final span in spans) {
    if (span is TextSpan) {
      if (span.text != null && span.text!.isNotEmpty) {
        result.add((span.text!, span.style));
      }
      if (span.children != null) {
        result.addAll(_flattenSpans(span.children!));
      }
    }
  }
  return result;
}

List<InlineSpan> _unflattenSpans(List<_FlatSpan> flat) {
  return flat.map((e) => TextSpan(text: e.$1, style: e.$2)).toList();
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

  factory HighlightMarkdownStyleSheet.terminalDark(CruxThemeData theme) {
    return HighlightMarkdownStyleSheet.fromTheme(theme);
  }

  factory HighlightMarkdownStyleSheet.thinking(CruxThemeData theme) {
    return _build(theme, theme.thinkingExpandedText);
  }

  factory HighlightMarkdownStyleSheet.fromTheme(CruxThemeData theme) {
    return _build(theme, theme.markdownText);
  }

  static HighlightMarkdownStyleSheet _build(
    CruxThemeData theme,
    Color baseColor,
  ) {
    return HighlightMarkdownStyleSheet(
      paragraphStyle: TextStyle(color: baseColor),
      h1Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH1),
      h2Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH2),
      h3Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH3),
      h4Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH4),
      h5Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH5),
      h6Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH6),
      boldStyle: TextStyle(fontWeight: FontWeight.bold, color: theme.mdBold),
      italicStyle: TextStyle(
        fontStyle: FontStyle.italic,
        color: theme.mdItalic,
      ),
      strikethroughStyle: TextStyle(
        decoration: TextDecoration.lineThrough,
        color: theme.mdStrikethrough,
      ),
      codeStyle: TextStyle(
        color: theme.mdInlineCode,
        backgroundColor: theme.mdInlineCodeBg,
      ),
      codeBlockStyle: TextStyle(
        color: theme.mdCodeBlockText,
        backgroundColor: theme.codeBlockBackground,
      ),
      blockquoteStyle: TextStyle(
        color: theme.mdBlockquote,
        fontStyle: FontStyle.italic,
      ),
      linkStyle: TextStyle(
        color: theme.mdLink,
        decoration: TextDecoration.underline,
      ),
      codeBlockBackground: theme.codeBlockBackground,
      codeBlockHeaderStyle: TextStyle(color: theme.codeBlockHeader),
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
  _HighlightMarkdownVisitor(
    this.styleSheet, {
    required this.theme,
    this.maxWidth,
  });

  final HighlightMarkdownStyleSheet styleSheet;
  final CruxThemeData theme;
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
          style: TextStyle(color: theme.outline),
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

    final bgColor = styleSheet.codeBlockBackground ?? theme.codeBlockBackground;
    final headerStyle =
        styleSheet.codeBlockHeaderStyle ??
        TextStyle(color: theme.codeBlockHeader);
    final codeStyle =
        styleSheet.codeBlockStyle ??
        TextStyle(
          color: theme.mdCodeBlockText,
          backgroundColor: theme.codeBlockBackground,
        );

    final width = maxWidth ?? 80;
    final langLabel = language ?? '';
    final headerContent = langLabel.isNotEmpty ? ' $langLabel ' : '';
    final headerPadding = width - 3 - headerContent.length;
    final headerLine = '┌─$headerContent${'─' * math.max(0, headerPadding)}';
    final footerLine = '└${'─' * (width - 1)}';

    // Strip a single trailing newline (markdown code blocks always end in `\n`)
    // so we don't render an extra empty line after the gutter.
    final stripped = code.endsWith('\n')
        ? code.substring(0, code.length - 1)
        : code;

    final spans = <InlineSpan>[];

    spans.add(
      TextSpan(
        text: '$headerLine\n',
        style: headerStyle.copyWith(backgroundColor: bgColor),
      ),
    );

    // Emit a piece of text with the code-block background baked in.
    void emitText(String text, {TextStyle? style}) {
      if (text.isEmpty) return;
      spans.add(
        TextSpan(
          text: text,
          style: (style ?? const TextStyle()).copyWith(backgroundColor: bgColor),
        ),
      );
    }

    // Emit the gutter prefix for a new line.
    void emitGutter() {
      spans.add(
        TextSpan(
          text: '│ ',
          style: TextStyle(
            backgroundColor: bgColor,
            color: theme.codeBlockGutter,
          ),
        ),
      );
    }

    // Emit a chunk of [text] using [style], splitting at every newline so a
    // gutter is re-emitted at the start of each new line.
    void emitWithGutterAtNewlines(String text, TextStyle style) {
      var idx = 0;
      while (true) {
        final nl = text.indexOf('\n', idx);
        if (nl == -1) {
          emitText(text.substring(idx), style: style);
          return;
        }
        emitText(text.substring(idx, nl + 1), style: style);
        if (idx + nl + 1 < stripped.length) emitGutter();
        idx = nl + 1;
      }
    }

    if (stripped.isEmpty) {
      // Empty code block — still render a single gutter so the box has height.
      emitGutter();
    } else {
      final highlightService = HighlightService.instance;
      final highlighter = (highlightService != null &&
              language != null &&
              language.isNotEmpty)
          ? highlightService.highlighterFor(language)
          : null;

      if (highlighter == null) {
        // No highlighter available: render the whole block in [codeStyle],
        // emitting a gutter at every newline.
        emitGutter();
        emitWithGutterAtNewlines(stripped, codeStyle);
      } else {
        // IMPORTANT: highlight the entire code block as a single string, not
        // line-by-line. Dart's `///` doc-comment grammar (and many other
        // grammars) uses `begin`/`while`/`end` pairs that span across lines,
        // which only work when the highlighter sees the full context.
        final styleService = highlightService!;
        final tokens = highlighter.highlight(stripped);
        emitGutter();

        int cursor = 0;
        int tokenIdx = 0;

        // Advance past any tokens we have already emitted.
        void skipFinishedTokens() {
          while (tokenIdx < tokens.length &&
              cursor >= tokens[tokenIdx].end) {
            tokenIdx++;
          }
        }

        while (cursor < stripped.length) {
          skipFinishedTokens();
          final token = tokenIdx < tokens.length ? tokens[tokenIdx] : null;

          int boundary;
          TextStyle segmentStyle;

          if (token != null && cursor >= token.start && cursor < token.end) {
            // Cursor sits inside the current token: emit up to the next
            // newline or the end of the token, whichever comes first. This
            // ensures we re-emit the gutter between every line, even when a
            // multi-line token (e.g. a `///` doc comment or `/* ... */` block)
            // spans several lines.
            final nlInToken = stripped.indexOf('\n', cursor);
            if (nlInToken != -1 && nlInToken < token.end) {
              boundary = nlInToken + 1;
            } else {
              boundary = token.end;
            }
            final color = colorForScopes(token.scopes, theme);
            final tmStyle = styleService.styleForScopes(token.scopes);
            segmentStyle = TextStyle(
              color: color,
              fontWeight: tmStyle?.bold == true
                  ? FontWeight.bold
                  : FontWeight.normal,
              fontStyle: tmStyle?.italic == true
                  ? FontStyle.italic
                  : FontStyle.normal,
            );
          } else if (token != null && cursor < token.start) {
            // Cursor sits in a gap before the next token: emit unstyled
            // fallback text up to the next newline or the token start.
            final nlInGap = stripped.indexOf('\n', cursor);
            if (nlInGap != -1 && nlInGap < token.start) {
              boundary = nlInGap + 1;
            } else {
              boundary = token.start;
            }
            segmentStyle = codeStyle;
          } else {
            // No more tokens: emit the rest as unstyled, splitting at newlines.
            emitWithGutterAtNewlines(stripped.substring(cursor), codeStyle);
            cursor = stripped.length;
            continue;
          }

          emitText(stripped.substring(cursor, boundary), style: segmentStyle);
          cursor = boundary;
          if (cursor < stripped.length &&
              stripped[cursor - 1] == '\n') {
            emitGutter();
          }
        }
      }
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
