import 'package:nocterm/nocterm.dart';

/// A clickable session reference found in rendered markdown text.
///
/// Surfaces the `ses://<digits>` references the LLM writes in its
/// replies so the TUI can render them as clickable regions that
/// jump straight to the referenced session.
///
/// Offsets are absolute positions in the **plain rendered text** of
/// a markdown rendering (i.e. the result of flattening
/// [InlineSpan] trees to a single string), matching what
/// [RenderParagraph.getCharacterIndexAtLocalPosition] expects.
class SessionRef {
  /// The integer session id parsed from the `ses://<digits>` text.
  final int sessionId;

  /// Absolute offset of the matched substring in the rendered text.
  final int offset;

  /// Length of the matched substring in characters.
  final int length;

  const SessionRef({
    required this.sessionId,
    required this.offset,
    required this.length,
  });

  bool containsIndex(int index) => index >= offset && index < offset + length;

  /// The literal text of the reference, e.g. `ses://1014`.
  String get displayText => 'ses://$sessionId';

  @override
  String toString() =>
      'SessionRef(id=$sessionId @$offset:$length "ses://$sessionId")';
}

final _sesRefRegex = RegExp(r'ses://(\d{1,9})');

/// Walk a markdown-rendered inline-span tree and return every
/// `ses://<digits>` reference found **outside of code spans**.
///
/// "Code span" detection is heuristic: any span whose accumulated
/// style has a non-null `backgroundColor` is treated as code. That
/// catches both inline code (`` `foo` ``) and fenced code blocks,
/// because [HighlightMarkdownStyleSheet] sets `backgroundColor` on
/// both `codeStyle` and `codeBlockStyle`.
///
/// Excluding code spans matters because the prompt itself documents
/// the format inside backticks — without the exclusion, the
/// example `ses://1014` in every reply would itself become a link.
///
/// The walk is single-pass and order-preserving: refs come back in
/// the order they appear in the rendered text. IDs are capped at 9
/// digits to keep regex behaviour predictable as the auto-increment
/// counter grows over time.
List<SessionRef> parseSessionRefs(List<InlineSpan> spans) {
  final result = <SessionRef>[];
  final offsetRef = [0];

  void walk(InlineSpan span, bool inCode) {
    if (span is! TextSpan) return;
    final style = span.style;
    final childInCode = inCode || (style?.backgroundColor != null);
    final text = span.text ?? '';

    if (!childInCode && text.isNotEmpty) {
      for (final m in _sesRefRegex.allMatches(text)) {
        final id = int.tryParse(m.group(1)!);
        if (id != null && id > 0) {
          result.add(
            SessionRef(
              sessionId: id,
              offset: offsetRef[0] + m.start,
              length: m.group(0)!.length,
            ),
          );
        }
      }
    }

    offsetRef[0] += text.length;

    if (span.children != null) {
      for (final child in span.children!) {
        walk(child, childInCode);
      }
    }
  }

  for (final span in spans) {
    walk(span, false);
  }
  return result;
}

/// Apply link styling on top of an inline-span tree for each
/// [SessionRef] region. The overlay merges [linkStyle] onto the
/// span's existing style so inline formatting (bold, italic, …)
/// survives the link treatment.
///
/// If [hoveredRef] is non-null, that specific ref's region uses
/// [hoverStyle] instead. Callers should call this again whenever
/// hover state changes.
///
/// Returns the original [spans] unchanged when [refs] is empty.
List<InlineSpan> applySessionLinkStyles(
  List<InlineSpan> spans,
  List<SessionRef> refs,
  TextStyle linkStyle,
  TextStyle? hoverStyle,
  SessionRef? hoveredRef,
) {
  if (refs.isEmpty) return spans;

  // Flatten the tree to (text, style) tuples with running offsets.
  // This mirrors the private `_flattenSpans` helper used by the
  // highlight overlay — reimplemented here so session_refs.dart
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
  // around any overlapping refs. Refs are already in offset order
  // (parseSessionRefs walks the tree in order), so we can break
  // early on the first ref past the current span's end.
  final result = <_FlatSpan>[];
  var pos = 0;
  for (final entry in flat) {
    final (text, baseStyle) = entry;
    final spanStart = pos;
    final spanEnd = pos + text.length;

    final overlapping = <SessionRef>[];
    for (final r in refs) {
      if (r.offset >= spanEnd) break;
      if (r.offset + r.length > spanStart) {
        overlapping.add(r);
      }
    }

    if (overlapping.isEmpty) {
      result.add(entry);
      pos = spanEnd;
      continue;
    }

    var cursor = spanStart;
    for (final r in overlapping) {
      final refStart = r.offset;
      final refEnd = r.offset + r.length;

      if (refStart > cursor) {
        result.add((
          text.substring(cursor - spanStart, refStart - spanStart),
          baseStyle,
        ));
      }

      final isHovered =
          hoveredRef != null &&
          hoveredRef.offset == r.offset &&
          hoveredRef.length == r.length;
      final overlay = (isHovered && hoverStyle != null)
          ? hoverStyle
          : linkStyle;
      result.add((
        text.substring(
          (refStart - spanStart).clamp(0, text.length),
          (refEnd - spanStart).clamp(0, text.length),
        ),
        _mergeStyles(baseStyle, overlay),
      ));
      cursor = refEnd;
    }
    if (cursor < spanEnd) {
      result.add((text.substring(cursor - spanStart), baseStyle));
    }
    pos = spanEnd;
  }

  return result.map((e) => TextSpan(text: e.$1, style: e.$2)).toList();
}

typedef _FlatSpan = (String, TextStyle?);

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
