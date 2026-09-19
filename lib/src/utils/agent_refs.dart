import 'package:nocterm/nocterm.dart';

/// A clickable agent reference found in rendered markdown text.
///
/// Surfaces the `agent://<name>` references the LLM writes in its replies
/// so the TUI can render them as clickable regions — the agent-counterpart
/// of [SessionRef] (`ses://`). The persisted name is a stable constellation
/// id (`agent://orion`, `agent://libra-2`); the UI renders a localized
/// display name at the presentation boundary.
///
/// Offsets are absolute positions in the **plain rendered text** of a
/// markdown rendering, matching what
/// [RenderParagraph.getCharacterIndexAtLocalPosition] expects.
class AgentRef {
  /// The persisted constellation id parsed from the `agent://<id>` text.
  final String name;

  /// Absolute offset of the matched substring in the rendered text.
  final int offset;

  /// Length of the matched substring in characters.
  final int length;

  const AgentRef({
    required this.name,
    required this.offset,
    required this.length,
  });

  bool containsIndex(int index) => index >= offset && index < offset + length;

  /// The literal text of the reference, e.g. `agent://orion`.
  String get displayText => 'agent://$name';

  @override
  String toString() => 'AgentRef($name @$offset:$length "$displayText")';
}

final _agentRefRegex = RegExp(r'agent://([a-z][a-z0-9-]*)');

/// Walk a markdown-rendered inline-span tree and return every
/// `agent://<name>` reference found **outside of code spans** — the
/// same walk and code-span exclusion as [parseSessionRefs].
///
/// Names are lowercase constellation ids or their `-2`-suffixed
/// derivatives; anything else (URLs, prose) does not match.
List<AgentRef> parseAgentRefs(List<InlineSpan> spans) {
  final result = <AgentRef>[];
  final offsetRef = [0];

  void walk(InlineSpan span, bool inCode) {
    if (span is! TextSpan) return;
    final style = span.style;
    final childInCode = inCode || (style?.backgroundColor != null);
    final text = span.text ?? '';

    if (!childInCode && text.isNotEmpty) {
      for (final m in _agentRefRegex.allMatches(text)) {
        result.add(
          AgentRef(
            name: m.group(1)!,
            offset: offsetRef[0] + m.start,
            length: m.group(0)!.length,
          ),
        );
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

/// Apply link styling on top of an inline-span tree for each [AgentRef]
/// region — the agent-counterpart of [applySessionLinkStyles].
///
/// [displayNames] optionally localizes the rendered text: it receives
/// the persisted id and returns the display form (e.g. `orion` →
/// `猎户座`). The link still targets the stable id; only what the user
/// READS changes. Null renders the raw reference verbatim.
///
/// Returns the original [spans] unchanged when [refs] is empty.
List<InlineSpan> applyAgentLinkStyles(
  List<InlineSpan> spans,
  List<AgentRef> refs, {
  TextStyle? linkStyle,
  TextStyle? hoverStyle,
  AgentRef? hoveredRef,
  String Function(String id)? displayNames,
}) {
  if (refs.isEmpty) return spans;
  final effectiveLinkStyle = linkStyle ?? const TextStyle();

  String displayFor(AgentRef r) {
    if (displayNames == null) return r.displayText;
    final localized = displayNames(r.name);
    return localized.isEmpty ? r.displayText : localized;
  }

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

  final result = <_FlatSpan>[];
  var pos = 0;
  for (final entry in flat) {
    final (text, baseStyle) = entry;
    final spanStart = pos;
    final spanEnd = pos + text.length;

    final overlapping = <AgentRef>[];
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
      result.add((
        displayFor(r),
        isHovered && hoverStyle != null
            ? _mergeStyles(baseStyle, hoverStyle)
            : _mergeStyles(baseStyle, effectiveLinkStyle),
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
