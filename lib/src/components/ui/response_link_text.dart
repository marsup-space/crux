import 'package:markdown/markdown.dart' as md;
import 'package:nocterm/nocterm.dart';
import '../../theme/crux_theme.dart';
import 'highlighted_markdown_text.dart';

class ResponseLink {
  final String text;
  final int offset;
  final int length;
  final String? url;
  final String? anchor;

  const ResponseLink({
    required this.text,
    required this.offset,
    required this.length,
    this.url,
    this.anchor,
  });

  bool containsIndex(int index) =>
      index >= offset && index < offset + length;

  @override
  String toString() => 'ResponseLink("$text" @$offset:$length'
      '${url != null ? " url=$url" : ""}'
      '${anchor != null ? " anchor=$anchor" : ""})';
}

typedef ResponseLinkTapCallback = void Function(ResponseLink link);

final _refRegex = RegExp(r'\[([^\]\n\(]+)(?:\(([^\s\)\n]+)\))?\]');

class _ParsedTldr {
  final String displayText;
  final List<ResponseLink> links;

  const _ParsedTldr({required this.displayText, required this.links});
}

_ParsedTldr _parseTldrRefs(String tldrText) {
  final buffer = StringBuffer();
  final links = <ResponseLink>[];

  var cursor = 0;
  for (final match in _refRegex.allMatches(tldrText)) {
    if (match.start > cursor) {
      buffer.write(tldrText.substring(cursor, match.start));
    }
    final excerpt = match.group(1)!.trim();
    final url = match.group(2);
    if (excerpt.isEmpty) {
      buffer.write(match.group(0)!);
    } else {
      final linkOffset = buffer.length;
      buffer.write(excerpt);
      links.add(ResponseLink(
        text: excerpt,
        offset: linkOffset,
        length: excerpt.length,
        url: (url != null && url.isNotEmpty) ? url : null,
        anchor: excerpt,
      ));
    }
    cursor = match.end;
  }
  if (cursor < tldrText.length) {
    buffer.write(tldrText.substring(cursor));
  }

  return _ParsedTldr(displayText: buffer.toString(), links: links);
}

class ResponseLinkText extends StatefulComponent {
  final String markdownText;
  final TextStyle? linkStyle;
  final TextStyle? linkHoverStyle;
  final ResponseLinkTapCallback? onLinkTap;

  const ResponseLinkText({
    super.key,
    required this.markdownText,
    this.linkStyle,
    this.linkHoverStyle,
    this.onLinkTap,
  });

  @override
  State<ResponseLinkText> createState() => _ResponseLinkTextState();
}

class _ResponseLinkTextState extends State<ResponseLinkText> {
  ResponseLink? _hoveredLink;
  final GlobalKey _richTextKey = GlobalKey();

  _ParsedTldr? _lastParsed;
  List<InlineSpan>? _lastSpans;
  List<ResponseLink>? _lastLinks;

  RenderParagraph? get _renderParagraph {
    final ctx = _richTextKey.currentContext;
    if (ctx == null) return null;
    final el = ctx as Element;
    if (el is RenderObjectElement) {
      final ro = el.renderObject;
      if (ro is RenderParagraph) return ro;
    }
    return null;
  }

  (List<InlineSpan>, List<ResponseLink>) _buildSpans() {
    final parsed = _parseTldrRefs(component.markdownText);
    if (parsed.links.isEmpty) {
      final spans = _parseMarkdown(parsed.displayText);
      return (spans, parsed.links);
    }

    final mdSpans = _parseMarkdown(parsed.displayText);
    final plainText = _flattenToPlainText(mdSpans);

    final resolvedLinks = <ResponseLink>[];
    for (final link in parsed.links) {
      final idx = plainText.indexOf(link.text);
      if (idx >= 0) {
        resolvedLinks.add(ResponseLink(
          text: link.text,
          offset: idx,
          length: link.text.length,
          url: link.url,
          anchor: link.anchor,
        ));
      }
    }

    final styledSpans = _applyLinkStyles(mdSpans, resolvedLinks);
    return (styledSpans, resolvedLinks);
  }

  List<InlineSpan> _parseMarkdown(String text) {
    final styleSheet = HighlightMarkdownStyleSheet.terminalDark();
    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    final nodes = document.parse(text);
    final visitor = _TldrMarkdownVisitor(styleSheet);
    return visitor.visitNodes(nodes);
  }

  List<InlineSpan> _applyLinkStyles(
    List<InlineSpan> spans,
    List<ResponseLink> links,
  ) {
    if (links.isEmpty) return spans;

    final flat = _flattenSpans(spans);
    final plainText = flat.map((e) => e.$1).join();

    final linkStyle = component.linkStyle ?? TextStyle(
      color: CruxTheme.tldrLink,
      decoration: TextDecoration.underline,
    );
    final linkHoverStyle = component.linkHoverStyle ?? TextStyle(
      color: CruxTheme.tldrLinkHoverFg,
      backgroundColor: CruxTheme.tldrLink,
      fontWeight: FontWeight.bold,
    );

    final result = <_FlatSpan>[];
    int pos = 0;
    for (final span in flat) {
      final spanStart = pos;
      final spanEnd = pos + span.$1.length;

      ResponseLink? overlappingLink;
      int linkStart = -1;
      int linkEnd = -1;
      for (final link in links) {
        if (spanEnd > link.offset && spanStart < link.offset + link.length) {
          overlappingLink = link;
          linkStart = link.offset;
          linkEnd = link.offset + link.length;
          break;
        }
      }

      if (overlappingLink == null) {
        result.add(span);
      } else {
        final before = linkStart > spanStart
            ? span.$1.substring(0, linkStart - spanStart)
            : '';
        final matchStart = linkStart.clamp(spanStart, spanEnd) - spanStart;
        final matchEnd = linkEnd.clamp(spanStart, spanEnd) - spanStart;
        final match = span.$1.substring(matchStart, matchEnd);
        final after = linkEnd < spanEnd
            ? span.$1.substring(linkEnd - spanStart)
            : '';

        final isHovered = _hoveredLink != null &&
            _hoveredLink!.offset == overlappingLink.offset &&
            _hoveredLink!.length == overlappingLink.length;
        final style = isHovered
            ? _mergeStyles(span.$2, linkHoverStyle)
            : _mergeStyles(span.$2, linkStyle);

        if (before.isNotEmpty) result.add((before, span.$2));
        result.add((match, style));
        if (after.isNotEmpty) result.add((after, span.$2));
      }
      pos = spanEnd;
    }

    return result.map((e) => TextSpan(text: e.$1, style: e.$2)).toList();
  }

  TextStyle? _mergeStyles(TextStyle? base, TextStyle overlay) {
    return TextStyle(
      color: overlay.color ?? base?.color,
      backgroundColor: overlay.backgroundColor ?? base?.backgroundColor,
      fontWeight: overlay.fontWeight ?? base?.fontWeight,
      fontStyle: overlay.fontStyle ?? base?.fontStyle,
      decoration: overlay.decoration ?? base?.decoration,
    );
  }

  @override
  Component build(BuildContext context) {
    final (spans, links) = _buildSpans();
    _lastSpans = spans;
    _lastLinks = links;

    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        opaque: true,
        onHover: _handleHover,
        onExit: (_) {
          if (_hoveredLink != null) {
            _hoveredLink = null;
            setState(() {});
          }
        },
        child: RichText(
          key: _richTextKey,
          text: TextSpan(children: spans),
        ),
      ),
    );
  }

  static bool _sameLink(ResponseLink? a, ResponseLink? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.offset == b.offset && a.length == b.length;
  }

  void _handleHover(MouseEvent event) {
    final link = _linkAtEvent(event);
    if (!_sameLink(link, _hoveredLink)) {
      _hoveredLink = link;
      setState(() {});
    }
  }

  void _handleTap() {
    if (_hoveredLink != null) {
      component.onLinkTap?.call(_hoveredLink!);
    }
  }

  ResponseLink? _linkAtEvent(MouseEvent event) {
    final links = _lastLinks;
    if (links == null || links.isEmpty) return null;
    final rp = _renderParagraph;
    if (rp == null) return null;

    final globalOffset = rp.globalPaintOffset;
    final localX = event.x.toDouble() - globalOffset.dx;
    final localY = event.y.toDouble() - globalOffset.dy;

    if (localX < 0 || localY < 0) return null;

    final charIndex = rp.getCharacterIndexAtLocalPosition(
      Offset(localX, localY),
    );

    for (final link in links) {
      if (link.containsIndex(charIndex)) return link;
    }
    return null;
  }
}

typedef _FlatSpan = (String, TextStyle?);

String _flattenToPlainText(List<InlineSpan> spans) {
  final buffer = StringBuffer();
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text != null) buffer.write(span.text);
      if (span.children != null) {
        for (final child in span.children!) {
          walk(child);
        }
      }
    }
  }
  for (final span in spans) {
    walk(span);
  }
  return buffer.toString();
}

List<_FlatSpan> _flattenSpans(List<InlineSpan> spans) {
  final result = <_FlatSpan>[];
  void walk(InlineSpan span, TextStyle? parentStyle) {
    if (span is TextSpan) {
      final mergedStyle = _mergeSpanStyles(parentStyle, span.style);
      if (span.text != null && span.text!.isNotEmpty) {
        result.add((span.text!, mergedStyle));
      }
      if (span.children != null) {
        for (final child in span.children!) {
          walk(child, mergedStyle);
        }
      }
    }
  }
  for (final span in spans) {
    walk(span, null);
  }
  return result;
}

TextStyle? _mergeSpanStyles(TextStyle? parent, TextStyle? child) {
  if (parent == null) return child;
  if (child == null) return parent;
  return TextStyle(
    color: child.color ?? parent.color,
    backgroundColor: child.backgroundColor ?? parent.backgroundColor,
    fontWeight: child.fontWeight ?? parent.fontWeight,
    fontStyle: child.fontStyle ?? parent.fontStyle,
    decoration: child.decoration ?? parent.decoration,
  );
}

class _TldrMarkdownVisitor {
  _TldrMarkdownVisitor(this.styleSheet);

  final HighlightMarkdownStyleSheet styleSheet;
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
        );
      case 'strong':
        return TextSpan(
          children: visitChildren(element),
          style: styleSheet.boldStyle,
        );
      case 'em':
        return TextSpan(
          children: visitChildren(element),
          style: styleSheet.italicStyle,
        );
      case 'del':
        return TextSpan(
          children: visitChildren(element),
          style: styleSheet.strikethroughStyle,
        );
      case 'code':
        return TextSpan(
          text: element.textContent,
          style: styleSheet.codeStyle,
        );
      case 'pre':
        return TextSpan(text: element.textContent);
      case 'blockquote':
        return TextSpan(
          children: [
            TextSpan(
              text: '│ ',
              style: styleSheet.blockquoteStyle,
            ),
            ...visitChildren(element),
          ],
        );
      case 'a':
        return TextSpan(
          children: visitChildren(element),
          style: styleSheet.linkStyle,
        );
      case 'ul':
        _listDepth++;
        final spans = <InlineSpan>[];
        for (final child in element.children ?? <md.Node>[]) {
          spans.add(TextSpan(
            children: [
              TextSpan(text: '  ' * (_listDepth - 1) + '• '),
              ...visitChildren(child as md.Element),
              const TextSpan(text: '\n'),
            ],
          ));
        }
        _listDepth--;
        return TextSpan(children: spans);
      case 'ol':
        _listDepth++;
        final spans = <InlineSpan>[];
        var i = 1;
        for (final child in element.children ?? <md.Node>[]) {
          spans.add(TextSpan(
            children: [
              TextSpan(text: '  ' * (_listDepth - 1) + '$i. '),
              ...visitChildren(child as md.Element),
              const TextSpan(text: '\n'),
            ],
          ));
          i++;
        }
        _listDepth--;
        return TextSpan(children: spans);
      case 'li':
        return TextSpan(children: visitChildren(element));
      case 'hr':
        return TextSpan(
          text: '${'─' * 40}\n',
          style: TextStyle(color: CruxTheme.divider),
        );
      case 'img':
        final alt = element.attributes['alt'] ?? '';
        return TextSpan(text: alt);
      case 'table':
        return _visitTable(element);
      case 'thead':
      case 'tbody':
      case 'tr':
        return TextSpan(children: visitChildren(element));
      case 'th':
      case 'td':
        return TextSpan(
          children: [
            ...visitChildren(element),
            const TextSpan(text: ' '),
          ],
        );
      case 'br':
        return const TextSpan(text: '\n');
      default:
        return TextSpan(children: visitChildren(element));
    }
  }

  List<InlineSpan> visitChildren(md.Element parent) {
    final spans = <InlineSpan>[];
    for (final child in parent.children ?? <md.Node>[]) {
      final span = visitNode(child);
      if (span != null) {
        spans.add(span);
      }
    }
    return spans;
  }

  InlineSpan _visitTable(md.Element table) {
    final rows = <List<String>>[];
    void collectRows(md.Element element) {
      if (element.tag == 'tr') {
        final cells = <String>[];
        for (final cell in element.children ?? <md.Node>[]) {
          if (cell is md.Element && (cell.tag == 'th' || cell.tag == 'td')) {
            cells.add(cell.textContent.trim());
          }
        }
        rows.add(cells);
      } else {
        for (final child in element.children ?? <md.Node>[]) {
          if (child is md.Element) collectRows(child);
        }
      }
    }
    collectRows(table);

    if (rows.isEmpty) return const TextSpan(text: '');

    final maxCols = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final colWidths = List.filled(maxCols, 0);
    for (final row in rows) {
      for (var i = 0; i < row.length && i < maxCols; i++) {
        if (row[i].length > colWidths[i]) colWidths[i] = row[i].length;
      }
    }

    final spans = <InlineSpan>[];
    for (var r = 0; r < rows.length; r++) {
      if (r == 1) {
        final sep = colWidths.map((w) => '─' * (w + 2)).join('┼');
        spans.add(TextSpan(
          text: '$sep\n',
          style: TextStyle(color: CruxTheme.divider),
        ));
      }
      final cells = <String>[];
      for (var c = 0; c < maxCols; c++) {
        final text = c < rows[r].length ? rows[r][c] : '';
        cells.add(text.padRight(colWidths[c]));
      }
      final style = r == 0 ? styleSheet.boldStyle : null;
      spans.add(TextSpan(text: ' ${cells.join(' │ ')} \n', style: style));
    }
    return TextSpan(children: spans);
  }
}
