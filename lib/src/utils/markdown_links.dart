import 'package:nocterm/nocterm.dart';

/// A clickable markdown link found in rendered markdown text.
///
/// Surfaces the `[label](url)` links the LLM writes in its replies
/// so the TUI can render them as clickable regions that open the
/// URL in the user's default browser.
///
/// Offsets are absolute positions in the **plain rendered text** of
/// a markdown rendering (i.e. the result of flattening [InlineSpan]
/// trees to a single string), matching what
/// [RenderParagraph.getCharacterIndexAtLocalPosition] expects.
///
/// The [label] is whatever text the renderer chose to display. By
/// default the renderer hides the URL whenever a label is present,
/// so [label] is the visible text under the cursor; when no label
/// was provided in the source, [label] falls back to the raw URL.
class MarkdownLink {
  /// Visible text for the link. Falls back to [url] when the
  /// source had no label text (e.g. `[](https://example.com)`).
  final String label;

  /// The href of the `<a>` element. May be `http://` or `https://`,
  /// or any other scheme the source markdown provided — callers
  /// are responsible for filtering unsafe schemes before opening.
  final String url;

  /// Absolute offset of the link's rendered text in the markdown
  /// render's flattened plain-text output.
  final int offset;

  /// Length of the rendered text in characters.
  final int length;

  const MarkdownLink({
    required this.label,
    required this.url,
    required this.offset,
    required this.length,
  });

  bool containsIndex(int index) => index >= offset && index < offset + length;

  @override
  String toString() => 'MarkdownLink("$label" -> $url @$offset:$length)';
}

/// Apply link styling on top of an inline-span tree for each
/// [MarkdownLink] region. The overlay merges [linkStyle] onto
/// the span's existing style so inline formatting (bold, italic,
/// …) survives the link treatment.
///
/// If [hoveredLink] is non-null, that specific link's region uses
/// [hoverStyle] instead. Callers should call this again whenever
/// hover state changes.
///
/// Returns the original [spans] unchanged when [links] is empty.
List<InlineSpan> applyMarkdownLinkStyles(
  List<InlineSpan> spans,
  List<MarkdownLink> links,
  TextStyle linkStyle,
  TextStyle? hoverStyle,
  MarkdownLink? hoveredLink,
) {
  if (links.isEmpty) return spans;

  // Flatten the tree to (text, style) tuples with running offsets.
  // This mirrors the private `_flattenSpans` helper used by the
  // highlight overlay — reimplemented here so markdown_links.dart
  // stays a self-contained unit that's easy to test on its own.
  //
  // Parent styles are ACCUMULATED onto each leaf: the tree uses
  // nesting to express inheritance (paragraphStyle wrapping bold,
  // wrapping italic, …) and the leaf's own style only carries the
  // delta. Without accumulation the rebuild below would produce a
  // flat list that has lost every ancestor's color / weight /
  // background — markdown renders as plain prose. Merge direction
  // matters: the leaf must win, so merge(base: accumulated, overlay:
  // leafStyle), NOT the other way around.
  final flat = <_FlatSpan>[];
  void flatten(InlineSpan span, TextStyle? inherited) {
    if (span is! TextSpan) return;
    final style = span.style;
    final accumulated = inherited == null
        ? style
        : (style == null ? inherited : _mergeStyles(inherited, style));
    if (span.text != null && span.text!.isNotEmpty) {
      flat.add((span.text!, accumulated));
    }
    if (span.children != null) {
      for (final child in span.children!) {
        flatten(child, accumulated);
      }
    }
  }

  for (final s in spans) {
    flatten(s, null);
  }

  // Single forward sweep over the flat list, splitting each span
  // around any overlapping links. Links are already in offset
  // order (the visitor emits them in walk order), so we can break
  // early on the first link past the current span's end.
  final result = <_FlatSpan>[];
  var pos = 0;
  for (final entry in flat) {
    final (text, baseStyle) = entry;
    final spanStart = pos;
    final spanEnd = pos + text.length;

    final overlapping = <MarkdownLink>[];
    for (final l in links) {
      if (l.offset >= spanEnd) break;
      if (l.offset + l.length > spanStart) {
        overlapping.add(l);
      }
    }

    if (overlapping.isEmpty) {
      result.add(entry);
      pos = spanEnd;
      continue;
    }

    var cursor = spanStart;
    for (final l in overlapping) {
      final linkStart = l.offset;
      final linkEnd = l.offset + l.length;

      if (linkStart > cursor) {
        result.add((
          text.substring(cursor - spanStart, linkStart - spanStart),
          baseStyle,
        ));
      }

      final isHovered =
          hoveredLink != null &&
          hoveredLink.offset == l.offset &&
          hoveredLink.length == l.length;
      final overlay = (isHovered && hoverStyle != null)
          ? hoverStyle
          : linkStyle;
      result.add((
        text.substring(
          (linkStart - spanStart).clamp(0, text.length),
          (linkEnd - spanStart).clamp(0, text.length),
        ),
        _mergeStyles(baseStyle, overlay),
      ));
      cursor = linkEnd;
    }
    if (cursor < spanEnd) {
      result.add((text.substring(cursor - spanStart), baseStyle));
    }
    pos = spanEnd;
  }

  return result.map((e) => TextSpan(text: e.$1, style: e.$2)).toList();
}

TextStyle? _mergeStyles(TextStyle? base, TextStyle overlay) {
  if (base == null) return overlay;
  return TextStyle(
    color: overlay.color ?? base.color,
    backgroundColor: overlay.backgroundColor ?? base.backgroundColor,
    fontWeight: overlay.fontWeight ?? base.fontWeight,
    fontStyle: overlay.fontStyle ?? base.fontStyle,
    decoration: overlay.decoration ?? base.decoration,
  );
}

typedef _FlatSpan = (String, TextStyle?);
