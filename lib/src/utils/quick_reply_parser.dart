import 'package:nocterm/nocterm.dart';

/// A clickable quick-reply token found in rendered markdown text.
///
/// Surfaces the `ask://label{answer}` and `ask://label` tokens the
/// agent writes in its replies so the TUI can render them as
/// clickable buttons. Clicking the button either submits `answer` as
/// the next user message (when the chat input is empty) or appends it
/// to the current draft (when the input is non-empty) — see
/// `docs/design-quick-reply.md` for the full UX spec.
///
/// Offsets are absolute positions in the **plain rendered text** of a
/// markdown rendering (i.e. the result of flattening [InlineSpan]
/// trees to a single string), matching what
/// [RenderParagraph.getCharacterIndexAtLocalPosition] expects.
///
/// Labels and answers are returned **trimmed** and with all
/// surrounding whitespace removed. The label and answer may differ
/// (explicit form `ask://label{answer}`) or be identical (shorthand
/// `ask://label`, where `answer` defaults to `label`). Either way both
/// are non-empty.
class QuickReply {
  /// Display text shown on the rendered button.
  final String label;

  /// Text submitted or appended when the button is clicked. Always
  /// non-empty and trimmed.
  final String answer;

  /// Absolute offset of the matched `ask://…` substring in the
  /// rendered text.
  final int sourceStart;

  /// Length of the matched substring in characters.
  final int sourceLength;

  QuickReply({
    required this.label,
    required this.answer,
    required this.sourceStart,
    required this.sourceLength,
  });

  /// One past the last character index of the matched token.
  int get sourceEnd => sourceStart + sourceLength;

  /// Absolute offset of the rendered label in the **post-substitution**
  /// rendered text. `null` until [applyQuickReplyTokens] has run on
  /// the spans containing this reply; populated by the renderer as it
  /// walks the span tree and substitutes each reply region with its
  /// label.
  ///
  /// Hit-testing in `HighlightedMarkdownText._linkAtEvent` reads the
  /// character index from `RenderParagraph` against the rendered
  /// (substituted) text, so it MUST use [renderedStart] (and
  /// [containsRenderedIndex]) — not [sourceStart] / [containsIndex].
  /// The source offsets are kept for cases where the original
  /// `ask://…` substring needs to be located (e.g. debugging or
  /// telemetry), but no runtime UI flow hits against them after
  /// substitution.
  int? renderedStart;

  /// Length of the rendered label (always equal to [label].length).
  /// Tracked separately so [containsRenderedIndex] is symmetric with
  /// [containsIndex].
  int? renderedLength;

  bool containsIndex(int index) => index >= sourceStart && index < sourceEnd;

  bool containsRenderedIndex(int index) {
    final rs = renderedStart;
    final rl = renderedLength;
    if (rs == null || rl == null) return false;
    return index >= rs && index < rs + rl;
  }

  @override
  String toString() {
    final rendered = renderedStart != null
        ? ' rendered=$renderedStart:$renderedLength'
        : '';
    return 'QuickReply("$label" -> "$answer" '
        '@$sourceStart:$sourceLength$rendered)';
  }
}

/// Reference regex for quick-reply tokens. Two alternatives tried in
/// order:
///
///   1. `ask://label{answer}` — explicit form. Label is non-greedy
///      non-brace text; answer is non-greedy non-brace text between
///      `{` and the FIRST `}` (no nesting).
///   2. `ask://label` — shorthand. Label extends up to the next
///      `ask://` token, end-of-line, or end-of-input. Whitespace is
///      NOT a shorthand boundary — labels can be multi-word.
///      `ask://Use cache` is one button with label "Use cache".
///
/// `{` and `}` are reserved and cannot appear in label or answer.
/// Agents that need them must rephrase.
///
/// NOTE: this regex can greedily span across another `ask://` substring
/// when an inner `ask://{...}` block is reachable from an outer
/// `ask://`. We defend against that in [parseQuickReplies] via
/// post-validation: if a match's label itself contains `ask://`, we
/// treat the match as degenerate and advance past just the opener so
/// the inner `ask://` becomes the next candidate.
final _askRegex = RegExp(
  r'ask://'
  r'(?:'
  r'([^{}\n]+?)\s*\{\s*([^}\n]*?)\s*\}' // explicit: ask://label{answer}
  r'|'
  r'([^{}\n]+?)' // shorthand: ask://label
  r'(?=ask://|$|\n)' //   terminated by next ask / eol / eof
  r')',
  multiLine: true,
);

/// Walk a markdown-rendered inline-span tree and return every
/// `ask://…` quick-reply token found **outside of code spans**.
///
/// Code-span detection mirrors `parseSessionRefs`: any span whose
/// accumulated style has a non-null `backgroundColor` is treated as
/// code, catching both inline code (`` `foo` ``) and fenced code
/// blocks. This matters because the agent's own prompt documentation
/// for the `ask://` syntax lives inside backticks — without the
/// exclusion, the doc text itself would render as buttons.
///
/// **Algorithm — two passes over the span tree:**
///
/// 1. *Flatten pass*: walk every span (code and non-code alike) and
///    build a single flat string of all the text in order. Code
///    regions are recorded as `[start, end)` intervals in the flat
///    string's coordinate system, so we can later look up whether a
///    given offset sits inside a code span.
/// 2. *Regex pass*: run `_askRegex` against the full flat string
///    once. Because the string is contiguous, a token whose answer
///    contains an inline code span (e.g. backticks around a shell
///    command) matches cleanly across the span boundary.
///
/// Matches whose **start** position lies inside a code region are
/// dropped — those are the agent's own prompt-doc examples, not
/// real user-facing tokens. A match that *crosses* a code boundary
/// (starts outside, extends inside, or vice versa) is accepted:
/// the agent meant the whole thing, and the wire syntax is the same
/// either way.
///
/// Tokens whose label or answer trims to empty are silently dropped.
/// Tokens whose label itself contains `ask://` (meaning the regex
/// spanned across another `ask://` in the same string) are also
/// dropped, and the scan resumes from just past the offending
/// opener so the inner token gets a fresh chance to match.
///
/// Replies come back in the order they appear in the rendered text.
List<QuickReply> parseQuickReplies(List<InlineSpan> spans) {
  // Pass 1: flatten spans to a single string + record code regions.
  final flatText = StringBuffer();
  final codeRegions = <_CodeRegion>[];

  void walk(InlineSpan span, bool inCode) {
    if (span is! TextSpan) return;
    final style = span.style;
    final childInCode = inCode || (style?.backgroundColor != null);
    final text = span.text ?? '';

    if (text.isNotEmpty) {
      if (childInCode) {
        codeRegions.add(
          _CodeRegion(flatText.length, flatText.length + text.length),
        );
      }
      flatText.write(text);
    }

    if (span.children != null) {
      for (final child in span.children!) {
        walk(child, childInCode);
      }
    }
  }

  for (final span in spans) {
    walk(span, false);
  }

  // Pass 2: run the regex against the full flat string. Code
  // exclusion is now a per-match check, not a per-span skip — so
  // tokens that cross a code boundary match correctly.
  final result = <QuickReply>[];
  final text = flatText.toString();
  var pos = 0;
  while (pos < text.length) {
    final nextStart = text.indexOf('ask://', pos);
    if (nextStart == -1) break;

    // Drop matches that START inside a code region. The end may
    // extend outside (and that's fine — the agent's own prompt doc
    // does this with `\`ask://...\`` examples, and the whole token
    // is just doc text that shouldn't render as a button). What we
    // MUST avoid is the start being in code, because that would
    // mean the `ask://` literal came from the doc itself.
    if (_isInCode(nextStart, codeRegions)) {
      pos = nextStart + 'ask://'.length;
      continue;
    }

    final m = _askRegex.matchAsPrefix(text.substring(nextStart));
    if (m == null) {
      // Defensive: we just found 'ask://' but the full regex didn't
      // match (shouldn't happen, but if it does, skip past this
      // literal to avoid infinite looping).
      pos = nextStart + 'ask://'.length;
      continue;
    }

    String label;
    String answer;
    if (m.group(1) != null) {
      // Explicit form: group(1) is the label, group(2) is the
      // answer.
      label = m.group(1)!.trim();
      answer = m.group(2)!.trim();
    } else {
      // Shorthand form: group(3) is the label; answer defaults to
      // the label per the spec.
      label = m.group(3)!.trim();
      answer = label;
    }

    // Reject degenerate tokens where the regex spanned across
    // another `ask://` substring. Skip past just the opener so the
    // inner `ask://` (if any) becomes the next candidate.
    if (label.contains('ask://')) {
      pos = nextStart + 'ask://'.length;
      continue;
    }
    // Reject tokens whose label or answer trimmed to empty. The
    // regex itself prevents this for explicit forms (label
    // `[^{}\n]+?` requires ≥1 non-brace char), but shorthand forms
    // can still trim down to empty (e.g. `ask:// ` with a trailing
    // space). Skip past the full match in that case.
    if (label.isEmpty || answer.isEmpty) {
      pos = nextStart + m.end;
      continue;
    }

    // For shorthand matches, the regex greedily absorbs any
    // trailing whitespace into the label group (the `\s` isn't a
    // shorthand boundary — see docs/design-quick-reply.md). The
    // renderer treats `sourceLength` as "everything to delete from
    // the source", so leaving the trailing space in the range
    // would silently swallow the separator between two adjacent
    // shorthand tokens and make the rendered buttons run into each
    // other ("YesNo" instead of "Yes No"). Trim it off the source
    // range so the renderer keeps the whitespace as ordinary
    // "before text" for the next token (or the trailing edge of
    // the line). The label itself is already trimmed above.
    //
    // Explicit-form matches never have this problem — the explicit
    // form's `\s*\{` keeps the label cleanly bounded by `{` and
    // there's no trailing whitespace to discard, so the trim is a
    // no-op there.
    final sourceLength = text
        .substring(nextStart, nextStart + m.end)
        .trimRight()
        .length;

    result.add(
      QuickReply(
        label: label,
        answer: answer,
        sourceStart: nextStart,
        sourceLength: sourceLength,
      ),
    );
    pos = nextStart + m.end;
  }

  return result;
}

/// Half-open interval `[start, end)` in the flat-text coordinate
/// system used by [parseQuickReplies]. Tracks the bounds of a code
/// span (inline code or fenced code block) so the regex pass can
/// decide whether each `ask://` candidate's start position sits
/// inside one.
class _CodeRegion {
  final int start;
  final int end;
  // ignore: prefer_const_constructors_in_immutables
  _CodeRegion(this.start, this.end);
}

bool _isInCode(int pos, List<_CodeRegion> regions) {
  for (final r in regions) {
    if (pos >= r.start && pos < r.end) return true;
  }
  return false;
}

/// Substitute `ask://…` regions in [spans] with their reply
/// `label`s, optionally applying button styling.
///
/// Every matched region is replaced with `r.label` — **never** the
/// raw `ask://label{answer}` source text. The label is the only
/// thing the user ever sees for a quick reply; the wire syntax is
/// implementation detail.
///
/// Render modes (selected by [buttonStyle]):
///
/// - `buttonStyle == null` — **label-only mode**. Emit `r.label`
///   with the surrounding `baseStyle` unchanged. The result is
///   indistinguishable from ordinary prose. Used for stale turns
///   where the choice is no longer relevant (see
///   `docs/design-quick-reply.md` §"Non-Goals: Buttons on stale
///   turns").
///
/// - `buttonStyle != null` — **button mode**. Emit `r.label`
///   overlaid with [buttonStyle] (and [hoverStyle] for the
///   currently-hovered reply, when supplied). Used for the active
///   turn. The button styling makes the clickable region stand out
///   from surrounding text.
///
/// In both modes, the surrounding text and inline formatting
/// outside the reply regions are preserved verbatim. Hit-testing
/// (when applicable) works against the original `sourceStart` /
/// `sourceEnd` offsets in the **source** markdown — the labels
/// land at those offsets in the rendered text but the click
/// resolver ([HighlightedMarkdownText]'s `_linkAtEvent`) is given
/// the un-substituted source positions via the reply object's
/// `sourceStart` / `sourceLength`, which point at where the
/// `ask://…` substring WAS in the source. This means even after
/// the source text is replaced with the label, the hit-test can
/// still ask `r.containsIndex(charIndex)` against the rendered
/// layout. See the "Hit-testing with substituted text" section
/// of the design doc if this ever needs to change.
///
/// Returns the original [spans] unchanged when [replies] is empty.
List<InlineSpan> applyQuickReplyTokens(
  List<InlineSpan> spans,
  List<QuickReply> replies, {
  TextStyle? buttonStyle,
  TextStyle? hoverStyle,
  QuickReply? hoveredReply,
}) {
  if (replies.isEmpty) return spans;

  // Flatten the tree to (text, style) tuples with running offsets.
  // Same shape `applySessionLinkStyles` uses — reimplemented here so
  // quick_reply_parser.dart stays a self-contained unit that's easy
  // to test on its own.
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
  // around any overlapping replies. Replies are already in offset
  // order (parseQuickReplies walks the tree in order), so we can
  // break early on the first reply past the current span's end.
  //
  // Two running cursors:
  //   * [pos] tracks position in the FLAT input text (pre-
  //     substitution). Used to locate each reply's [sourceStart]
  //     / [sourceEnd] region.
  //   * [renderedPos] tracks position in the OUTPUT spans (post-
  //     substitution). This is the position the label lands at
  //     and is what hit-testing reads back from the
  //     [RenderParagraph] — see [QuickReply.containsRenderedIndex].
  //
  // The renderer MUTATES each reply's [QuickReply.renderedStart] /
  // [renderedLength] fields as it emits the substituted label, so
  // the caller can hit-test against the resulting layout without
  // re-walking the span tree to compute offsets.
  final result = <_FlatSpan>[];
  var pos = 0;
  var renderedPos = 0;
  // Tracks which replies have already had their label emitted.
  // Without this, a reply whose source range spans multiple flat
  // entries — e.g. because its label or answer contains inline
  // backtick code spans, which the markdown parser splits into
  // separate inline spans — would be processed once per overlapping
  // entry and emit its label N times in a row. Match on sourceStart
  // since that's stable per reply across the sweep.
  final emittedReplies = <int>{};
  for (final entry in flat) {
    final (text, baseStyle) = entry;
    final spanStart = pos;
    final spanEnd = pos + text.length;

    // Only consider replies whose START falls inside this entry's
    // range. Replies whose start is before this entry have already
    // been processed in a previous iteration (we emit their label
    // exactly once, at the entry that contains their sourceStart).
    // Replies whose start is at or after this entry are not yet
    // processed — the loop below will pick them up.
    final overlapping = <QuickReply>[];
    for (final r in replies) {
      if (r.sourceStart >= spanEnd) break;
      if (r.sourceStart < spanStart) continue;
      if (r.sourceEnd <= spanStart) continue;
      if (emittedReplies.contains(r.sourceStart)) continue;
      overlapping.add(r);
    }

    if (overlapping.isEmpty) {
      // This entry starts no new reply. It may still be (partly)
      // covered by an already-emitted reply that started in an
      // earlier entry and straddles into this one — e.g. a reply
      // whose label/answer contains an inline code span, which the
      // markdown parser splits into separate inline spans.
      //
      // The covered portion `[spanStart, straddling.sourceEnd)` has
      // already been replaced by the reply's label, so re-emitting it
      // would duplicate the label's source text. But any text AFTER
      // the reply's `sourceEnd` (e.g. the `}` plus trailing prose that
      // shares a text span with the reply's tail) is ordinary text
      // and MUST survive. Emitting the whole entry duplicates; skipping
      // the whole entry drops that trailing text — so slice at
      // `sourceEnd` and emit only the tail.
      QuickReply? straddling;
      for (final r in replies) {
        if (r.sourceStart >= spanEnd) break;
        if (!emittedReplies.contains(r.sourceStart)) continue;
        if (r.sourceStart < spanStart && r.sourceEnd > spanStart) {
          straddling = r;
          break;
        }
      }
      if (straddling != null) {
        if (straddling.sourceEnd < spanEnd) {
          final tail = text.substring(straddling.sourceEnd - spanStart);
          result.add((tail, baseStyle));
          renderedPos += tail.length;
        }
        pos = spanEnd;
        continue;
      }
      result.add(entry);
      renderedPos += text.length;
      pos = spanEnd;
      continue;
    }

    var cursor = spanStart;
    for (final r in overlapping) {
      final replyStart = r.sourceStart;
      final replyEnd = r.sourceEnd;

      if (replyStart > cursor) {
        final beforeText = text.substring(
          cursor - spanStart,
          replyStart - spanStart,
        );
        result.add((beforeText, baseStyle));
        renderedPos += beforeText.length;
      }

      // The rendered region is ALWAYS the label — never the raw
      // `ask://label{answer}` source. Whether to layer button
      // styling on top is the only mode-dependent choice.
      final style = buttonStyle == null
          ? baseStyle
          : _mergeStyles(
              baseStyle,
              (hoveredReply != null &&
                      hoveredReply.sourceStart == r.sourceStart &&
                      hoveredReply.sourceLength == r.sourceLength &&
                      hoverStyle != null)
                  ? hoverStyle
                  : buttonStyle,
            );
      // Record rendered offsets on the reply object before emitting
      // the label — hit-testing reads these back from the layout.
      r.renderedStart = renderedPos;
      r.renderedLength = r.label.length;
      renderedPos += r.label.length;
      result.add((r.label, style));
      emittedReplies.add(r.sourceStart);
      cursor = replyEnd;
    }
    if (cursor < spanEnd) {
      final afterText = text.substring(cursor - spanStart);
      result.add((afterText, baseStyle));
      renderedPos += afterText.length;
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
