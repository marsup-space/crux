import 'package:nocterm/nocterm.dart' show ChangeNotifier;

/// Which scroll behavior the plan pane is in.
///
/// - [follow]: the view auto-scrolls to each agent edit (the changed
///   lines flash). The next agent edit is the re-center trigger — the
///   view never snaps mid-scroll on its own.
/// - [free]: the user is browsing; agent edits only flash (no scroll),
///   and a "Jump to latest" affordance returns to [follow].
enum PlanViewMode { follow, free }

/// Which way a boundary ambiguity in [SourceMap.renderedToSource]
/// resolves — see its doc.
enum MapBias { start, end }

/// One agent-visible position range selected inside the plan document.
///
/// Char-granular: [startLine] / [startCol] / [endLine] / [endCol] come
/// from the vendored `dart_markdown` source locations (0-based lines and
/// columns), so a selection landing on a `**` marker reports the marker's
/// columns while one landing on the content reports the content's.
///
/// [text] is the verbatim selected *source* text (recovered from the
/// source range, not the rendered text) so the agent can re-locate the
/// selection if line numbers went stale after an edit.
class PlanSelection {
  final String text;
  final int startLine;
  final int startCol;
  final int endLine;
  final int endCol;

  /// The plan version the user was viewing when the selection was made.
  /// When this differs from HEAD, the lines/cols map against that
  /// version's text, not the current file.
  final int fromVersion;

  const PlanSelection({
    required this.text,
    required this.startLine,
    required this.startCol,
    required this.endLine,
    required this.endCol,
    required this.fromVersion,
  });
}

/// One contiguous mapping between a range of the rendered (flat,
/// unwrapped) text and the source markdown.
///
/// For content spans, `rendered[renderedStart..renderedEnd)` corresponds
/// to `source[sourceStart..sourceEnd)`. For marker spans (`#`, `**`,
/// backticks, list bullets, code/table chrome, …) [isMarker] is true and
/// the rendered range is zero-width — the marker itself is not visible in
/// the rendered output, but its source range is recorded so lookups that
/// land *between* two rendered characters resolve to the marker.
class SourceSpan {
  final int renderedStart;
  final int renderedEnd;
  final int sourceStart;
  final int sourceEnd;
  final bool isMarker;

  /// Number of `\n` characters in the rendered range. Tracked explicitly
  /// (rather than re-derived from text) so the source→rendered row math
  /// stays exact for chrome spans that embed a trailing newline (code
  /// block borders, table rules).
  final int newlines;

  const SourceSpan({
    required this.renderedStart,
    required this.renderedEnd,
    required this.sourceStart,
    required this.sourceEnd,
    this.isMarker = false,
    this.newlines = 0,
  });

  int get renderedLength => renderedEnd - renderedStart;
}

/// Exact source coordinates of a single point in the rendered text.
class SourcePosition {
  final int offset;
  final int line;
  final int column;

  const SourcePosition({
    required this.offset,
    required this.line,
    required this.column,
  });

  @override
  String toString() => 'SourcePosition($line:$column, @$offset)';
}

/// Maps between the rendered plan text (what the user selects over) and
/// the source markdown (what the agent edits).
///
/// Built atomically in the same pass that produces the render spans
/// (`lib/src/markdown/plan_markdown_parser.dart`), so the two never go
/// stale relative to each other.
///
/// Two directions:
///   - [renderedToSource] — selection → source (char-perfect, including
///     marker positions; used by the `<plan-context>` selection block).
///   - [sourceLinesToRenderedRows] — source → rendered (used by the
///     change-flash highlight and follow-mode scrolling).
///
/// "Rendered row" here means the *unwrapped* row: the flat text split on
/// `\n`. Terminal word-wrap is applied later by the layout engine and is
/// a separate concept (see §9.4 of the design doc).
class SourceMap {
  /// Spans sorted by [SourceSpan.renderedStart], contiguous over the
  /// rendered text (marker spans are zero-width inserts).
  final List<SourceSpan> spans;

  /// Char offset of the start of each source line (0-based), computed
  /// from the raw document text. Used for offset ↔ line/column math.
  final List<int> lineStartOffsets;

  /// Total rows in the rendered flat text (`'\n'.count + 1`).
  final int renderedRowCount;

  const SourceMap({
    required this.spans,
    required this.lineStartOffsets,
    required this.renderedRowCount,
  });

  static const SourceMap empty = SourceMap(
    spans: [],
    lineStartOffsets: [0],
    renderedRowCount: 0,
  );

  bool get isEmpty => spans.isEmpty;

  /// Resolve a rendered flat offset (the coordinate space
  /// `RenderParagraph.getCharacterIndexAtLocalPosition` reports, and the
  /// `SelectionInfo` fragments are expressed in) to exact source
  /// coordinates.
  ///
  /// [bias] resolves the boundary ambiguity when a hidden marker and a
  /// content span meet at [renderedOffset] (e.g. `**bold**`: the closing
  /// `**` marker and the trailing ` text` both sit at the rendered offset
  /// just past "bold"):
  ///   - [MapBias.start] — a selection's START anchors to the *following*
  ///     content (the 'b' of bold → content start).
  ///   - [MapBias.end] — a selection's END (exclusive) anchors to the
  ///     *preceding* content's end (just past 'd' → bold's source end),
  ///     so the markers themselves are excluded from the range.
  SourcePosition renderedToSource(
    int renderedOffset, {
    MapBias bias = MapBias.start,
  }) {
    if (spans.isEmpty) {
      return const SourcePosition(offset: 0, line: 0, column: 0);
    }
    final sourceOffset = _renderedToSourceOffset(renderedOffset, bias);
    return _sourcePositionForOffset(sourceOffset);
  }

  /// Map a rendered offset to a source char offset.
  ///
  /// Inside a content span: proportional position within the span
  /// (rendered and source lengths usually match; when they differ —
  /// e.g. link label-only rendering — the position clamps to the span's
  /// source range).
  ///
  /// At a boundary between spans, zero-width marker spans are consulted
  /// first so a click "on the seam" maps to the marker that lives there;
  /// otherwise the position clamps to the nearest preceding span's source
  /// end (gaps in the rendered text only occur around markers).
  int _renderedToSourceOffset(int renderedOffset, MapBias bias) {
    SourceSpan? before; // nearest span ending at/before the offset
    SourceSpan? after; // nearest span starting at/after the offset
    for (final span in spans) {
      if (span.renderedStart < renderedOffset &&
          renderedOffset < span.renderedEnd) {
        // Strictly inside a (content) span.
        final rel = renderedOffset - span.renderedStart;
        final maxRel = span.sourceEnd - span.sourceStart;
        return span.sourceStart + rel.clamp(0, maxRel);
      }
      if (span.renderedEnd <= renderedOffset &&
          (before == null || span.renderedEnd >= before.renderedEnd)) {
        // Prefer the span whose end is closest; on ties prefer content.
        if (before == null ||
            span.renderedEnd > before.renderedEnd ||
            (span.renderedEnd == before.renderedEnd && !span.isMarker)) {
          before = span;
        }
      }
      if (span.renderedStart >= renderedOffset &&
          (after == null || span.renderedStart <= after.renderedStart)) {
        if (after == null ||
            span.renderedStart < after.renderedStart ||
            (span.renderedStart == after.renderedStart && !span.isMarker)) {
          after = span;
        }
      }
    }

    if (bias == MapBias.end) {
      // A selection's exclusive END anchors to the preceding content's
      // source end — so trailing markers (`**` close) are excluded.
      if (before != null && !before.isMarker) {
        return before.sourceEnd;
      }
      if (before != null && before.renderedEnd == renderedOffset) {
        return before.sourceEnd;
      }
    } else {
      // A selection's START anchors to the following content's source
      // start — the 'b' of `**bold**`, not the hidden marker.
      if (after != null &&
          !after.isMarker &&
          after.renderedStart == renderedOffset) {
        return after.sourceStart;
      }
    }

    // Markers parked exactly at the offset (gaps between content).
    for (final span in spans) {
      if (span.isMarker && span.renderedStart == renderedOffset) {
        return span.sourceStart;
      }
    }

    if (after != null && after.renderedStart == renderedOffset) {
      return after.sourceStart;
    }
    if (before != null && before.renderedEnd == renderedOffset) {
      return before.sourceEnd;
    }
    if (before != null && renderedOffset >= before.renderedEnd) {
      return before.sourceEnd;
    }
    if (after != null) return after.sourceStart;
    return 0;
  }

  /// Convert a source char offset to `{offset, line, column}` using the
  /// line-start table. Lines and columns are 0-based, matching the
  /// vendored `dart_markdown` `SourceLocation` convention.
  SourcePosition _sourcePositionForOffset(int sourceOffset) {
    var line = 0;
    // lineStartOffsets is sorted; binary search for the greatest start
    // <= sourceOffset.
    var lo = 0;
    var hi = lineStartOffsets.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lineStartOffsets[mid] <= sourceOffset) {
        line = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return SourcePosition(
      offset: sourceOffset,
      line: line,
      column: sourceOffset - lineStartOffsets[line],
    );
  }

  /// Map a source line range (0-based, inclusive) to the rendered flat
  /// rows that show it. Returns a sorted, de-duplicated list; empty when
  /// the range maps to nothing (e.g. fully-marker lines).
  ///
  /// Parser conventions this relies on (see `plan_markdown_parser.dart`):
  /// content spans never contain `\n` and every span records its newline
  /// count explicitly in [SourceSpan.newlines].
  List<int> sourceLinesToRenderedRows(int startLine, int endLine) {
    if (spans.isEmpty) return const [];
    final rows = <int>{};
    var renderedRow = 0;
    for (final span in spans) {
      if (!span.isMarker) {
        final spanStartLine = _lineForOffset(span.sourceStart);
        final spanEndLine = _lineForOffset(span.sourceEnd);
        if (spanEndLine >= startLine && spanStartLine <= endLine) {
          rows.add(renderedRow);
        }
      }
      renderedRow += span.newlines;
    }
    final sorted = rows.toList()..sort();
    return sorted;
  }

  int _lineForOffset(int sourceOffset) =>
      _sourcePositionForOffset(sourceOffset).line;
}

/// A changed region flashed in the plan pane after an agent edit.
///
/// [renderedRows] are flat (unwrapped) rows of the rendered text;
/// [startedAt] drives the fade (~1.5 s).
class FlashRegion {
  final List<int> renderedRows;
  final DateTime startedAt;

  const FlashRegion({required this.renderedRows, required this.startedAt});

  /// Fade progress in `[0, 1]`; 1 = fully faded out.
  double progressAt(DateTime now, {Duration fadeDuration = kFlashFade}) {
    final elapsed = now.difference(startedAt);
    if (elapsed >= fadeDuration) return 1.0;
    if (elapsed <= Duration.zero) return 0.0;
    return elapsed.inMicroseconds / fadeDuration.inMicroseconds;
  }

  bool isExpiredAt(DateTime now, {Duration fadeDuration = kFlashFade}) =>
      now.difference(startedAt) >= fadeDuration;
}

const Duration kFlashFade = Duration(milliseconds: 1500);

/// How a plan-doc version entered the log.
enum PlanVersionKind { edit, revert, init }

/// One entry in the version index (`index.json`).
class PlanVersionEntry {
  final int version;
  final DateTime at;
  final PlanVersionKind kind;

  /// For [PlanVersionKind.revert], the version whose content was restored.
  final int? revertedTo;

  const PlanVersionEntry({
    required this.version,
    required this.at,
    required this.kind,
    this.revertedTo,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'at': at.toIso8601String(),
    'kind': kind.name,
    if (revertedTo != null) 'revertedTo': revertedTo,
  };

  static PlanVersionEntry fromJson(Map<String, dynamic> json) {
    return PlanVersionEntry(
      version: json['version'] as int,
      at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
      kind: PlanVersionKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => PlanVersionKind.edit,
      ),
      revertedTo: json['revertedTo'] as int?,
    );
  }
}

/// Recorded when the user reverts the plan to a past version. Set on the
/// controller at revert time, consumed (and cleared) by the next turn's
/// `<plan-context>` injection so the agent knows to re-read the plan
/// before editing (§9.3).
class PlanRevertEvent {
  final int fromVersion;
  final int toVersion;
  final DateTime at;

  const PlanRevertEvent({
    required this.fromVersion,
    required this.toVersion,
    required this.at,
  });
}

/// Small ChangeNotifier base re-export shim so the controller and store
/// can be constructed in tests without dragging in the whole framework.
typedef PlanModeListenable = ChangeNotifier;
