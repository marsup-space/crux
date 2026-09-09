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

  bool containsIndex(int index) => index >= offset && index < offset + length;

  @override
  String toString() =>
      'ResponseLink("$text" @$offset:$length'
      '${url != null ? " url=$url" : ""}'
      '${anchor != null ? " anchor=$anchor" : ""})';
}

typedef ResponseLinkTapCallback = void Function(ResponseLink link);

final _refRegex = RegExp(r'\[([^\]]+)\]');

class _ParsedTldr {
  final String displayText;
  final List<ResponseLink> links;

  const _ParsedTldr({required this.displayText, required this.links});
}

String _normForCompare(String s) {
  return s
      .replaceAll(RegExp(r'[*_`~"\u201C\u201D\u2018\u2019]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();
}

_ParsedTldr _parseTldrRefs(String tldrText) {
  final buffer = StringBuffer();
  final links = <ResponseLink>[];

  var cursor = 0;
  var refIndex = 0;
  for (final match in _refRegex.allMatches(tldrText)) {
    if (match.start > cursor) {
      buffer.write(tldrText.substring(cursor, match.start));
    }
    final excerpt = match.group(1)!.trim();
    if (excerpt.isEmpty) {
      buffer.write(match.group(0)!);
    } else {
      refIndex++;
      final bufStr = buffer.toString();
      final normExcerpt = _normForCompare(excerpt);
      final normBuf = _normForCompare(bufStr);
      final isRedundant = normBuf.endsWith(normExcerpt);
      if (!isRedundant) {
        buffer.write(excerpt);
      }
      final linkOffset = buffer.length;
      buffer.write(' [R$refIndex]');
      links.add(
        ResponseLink(
          text: '[R$refIndex]',
          offset: linkOffset + 1,
          length: '[R$refIndex]'.length,
          url: null,
          anchor: excerpt,
        ),
      );
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

  (List<InlineSpan>, List<ResponseLink>) _buildSpans(
    CruxThemeData theme, {
    int? maxWidth,
  }) {
    final parsed = _parseTldrRefs(component.markdownText);
    if (parsed.links.isEmpty) {
      final spans = _parseMarkdown(parsed.displayText, theme, maxWidth);
      return (spans, parsed.links);
    }

    final mdSpans = _parseMarkdown(parsed.displayText, theme, maxWidth);
    final plainText = _flattenToPlainText(mdSpans);

    final resolvedLinks = <ResponseLink>[];
    var searchFrom = 0;
    for (final link in parsed.links) {
      final idx = plainText.indexOf(link.text, searchFrom);
      if (idx >= 0) {
        resolvedLinks.add(
          ResponseLink(
            text: link.text,
            offset: idx,
            length: link.text.length,
            url: link.url,
            anchor: link.anchor,
          ),
        );
        searchFrom = idx + link.text.length;
      }
    }

    final styledSpans = _applyLinkStyles(mdSpans, resolvedLinks, theme);
    return (styledSpans, resolvedLinks);
  }

  List<InlineSpan> _parseMarkdown(
    String text,
    CruxThemeData theme,
    int? maxWidth,
  ) {
    return parseMarkdownToInlineSpans(text, theme, maxWidth: maxWidth);
  }

  List<InlineSpan> _applyLinkStyles(
    List<InlineSpan> spans,
    List<ResponseLink> links,
    CruxThemeData theme,
  ) {
    if (links.isEmpty) return spans;

    final flat = _flattenSpans(spans);
    final linkStyle =
        component.linkStyle ??
        TextStyle(color: theme.tldrLink, decoration: TextDecoration.underline);
    final linkHoverStyle =
        component.linkHoverStyle ??
        TextStyle(
          color: theme.onColor(theme.tldrLink),
          backgroundColor: theme.tldrLink,
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

        final isHovered =
            _hoveredLink != null &&
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
    final theme = CruxTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.toInt()
            : null;
        final (spans, links) = _buildSpans(theme, maxWidth: maxWidth);
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
      },
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
