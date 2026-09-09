import 'package:nocterm/nocterm.dart';

import '../../utils/markdown_links.dart';
import '../../utils/quick_reply_parser.dart';
import '../../utils/session_refs.dart';
import 'diagram_viewport.dart';

/// A render-order segment of markdown that contains either ordinary inline
/// text or one diagram viewport. Keeping this boundary explicit prevents
/// text-only span transforms from flattening diagram sentinels into ordinary
/// empty [TextSpan]s.
sealed class MarkdownDiagramSegment {
  const MarkdownDiagramSegment();
}

/// A consecutive text run in the original flattened markdown coordinate
/// space. [textOffset] lets callers project link and quick-reply offsets onto
/// this individual RichText segment.
class MarkdownTextSegment extends MarkdownDiagramSegment {
  const MarkdownTextSegment({required this.spans, required this.textOffset});

  final List<InlineSpan> spans;
  final int textOffset;

  int get textLength => markdownSpanTextLength(spans);
}

/// One parseable fenced diagram, rendered by [DiagramViewport] rather than a
/// [RichText].
class MarkdownViewportSegment extends MarkdownDiagramSegment {
  const MarkdownViewportSegment(this.slice);

  final DiagramBlockSlice slice;
}

/// Split [spans] at their actual sentinel objects, not at cached list indices.
///
/// Style overlays regularly rebuild `TextSpan` trees. Index-based splitting
/// against such a rebuilt list can put a later text block in the viewport's
/// layout slot, which is how adjacent `text` and `mermaid` fences could paint
/// on top of each other. Scanning the preserved parse result makes the diagram
/// boundary structural and stable even if the surrounding text is split,
/// highlighted, or substituted later.
List<MarkdownDiagramSegment> splitMarkdownDiagramSegments(
  List<InlineSpan> spans,
  List<DiagramBlockSlice> slices,
) {
  if (slices.isEmpty) {
    return [MarkdownTextSegment(spans: spans, textOffset: 0)];
  }

  final sliceByFence = <int, DiagramBlockSlice>{
    for (final slice in slices) slice.fenceIndex: slice,
  };
  final result = <MarkdownDiagramSegment>[];
  final pendingText = <InlineSpan>[];
  var textOffset = 0;

  void flushText() {
    if (pendingText.isEmpty) return;
    final text = List<InlineSpan>.unmodifiable(pendingText);
    result.add(MarkdownTextSegment(spans: text, textOffset: textOffset));
    textOffset += markdownSpanTextLength(text);
    pendingText.clear();
  }

  for (final span in spans) {
    if (span case DiagramSentinelSpan(:final fenceIndex)) {
      final slice = sliceByFence[fenceIndex];
      if (slice == null) {
        // A stale or incomplete parse must remain harmless text rather than
        // making following spans disappear from the layout flow.
        pendingText.add(span);
        continue;
      }
      flushText();
      result.add(MarkdownViewportSegment(slice));
      continue;
    }
    pendingText.add(span);
  }
  flushText();

  return result;
}

/// Flat UTF-16 text length of a span tree, matching RenderParagraph offsets.
int markdownSpanTextLength(Iterable<InlineSpan> spans) {
  var length = 0;
  for (final span in spans) {
    length += _spanTextLength(span);
  }
  return length;
}

int _spanTextLength(InlineSpan span) {
  if (span is! TextSpan) return 0;
  var length = span.text?.length ?? 0;
  final children = span.children;
  if (children != null) {
    for (final child in children) {
      length += _spanTextLength(child);
    }
  }
  return length;
}

/// Projects global rendered-text metadata into one [MarkdownTextSegment].
/// Text-only overlay helpers receive only local spans, so their offsets must
/// be translated before styling or substitution can target the correct run.
class MarkdownTextSegmentMetadata {
  const MarkdownTextSegmentMetadata({
    required this.sessionRefs,
    required this.markdownLinks,
    required this.quickReplies,
  });

  final List<SessionRef> sessionRefs;
  final List<MarkdownLink> markdownLinks;
  final List<QuickReply> quickReplies;
}

MarkdownTextSegmentMetadata projectMarkdownTextSegmentMetadata(
  MarkdownTextSegment segment, {
  required List<SessionRef> sessionRefs,
  required List<MarkdownLink> markdownLinks,
  required List<QuickReply> quickReplies,
}) {
  final start = segment.textOffset;
  final end = start + segment.textLength;
  return MarkdownTextSegmentMetadata(
    sessionRefs: [
      for (final ref in sessionRefs)
        if (ref.offset >= start && ref.offset + ref.length <= end)
          SessionRef(
            sessionId: ref.sessionId,
            offset: ref.offset - start,
            length: ref.length,
          ),
    ],
    markdownLinks: [
      for (final link in markdownLinks)
        if (link.offset >= start && link.offset + link.length <= end)
          MarkdownLink(
            label: link.label,
            url: link.url,
            offset: link.offset - start,
            length: link.length,
          ),
    ],
    quickReplies: [
      for (final reply in quickReplies)
        if (reply.sourceStart >= start && reply.sourceEnd <= end)
          QuickReply(
            label: reply.label,
            answer: reply.answer,
            sourceStart: reply.sourceStart - start,
            sourceLength: reply.sourceLength,
          ),
    ],
  );
}

/// Applies a search highlight to one text segment. Diagram sentinels never
/// reach this function, so flattening cannot erase a structural block marker.
List<InlineSpan> applyMarkdownTextHighlight(
  List<InlineSpan> spans,
  String search, {
  required Color selectionColor,
  required Color Function(Color) onSelection,
}) {
  final flat = _flattenSpans(spans);
  final plainText = flat.map((entry) => entry.$1).join();
  final matchRange = _findHighlightRange(plainText, search);
  if (matchRange == null) return spans;

  final (index, end) = matchRange;
  final result = <_FlatSpan>[];
  var position = 0;
  for (final span in flat) {
    final spanStart = position;
    final spanEnd = position + span.$1.length;
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
      result.add((
        match,
        _mergedWithHighlight(span.$2, selectionColor, onSelection),
      ));
      if (after.isNotEmpty) result.add((after, span.$2));
    }
    position = spanEnd;
  }
  return result
      .map((entry) => TextSpan(text: entry.$1, style: entry.$2))
      .toList();
}

typedef _FlatSpan = (String, TextStyle?);

List<_FlatSpan> _flattenSpans(List<InlineSpan> spans) {
  final result = <_FlatSpan>[];
  void visit(InlineSpan span) {
    if (span is! TextSpan) return;
    final text = span.text;
    if (text != null && text.isNotEmpty) {
      result.add((text, span.style));
    }
    final children = span.children;
    if (children != null) {
      for (final child in children) {
        visit(child);
      }
    }
  }

  for (final span in spans) {
    visit(span);
  }
  return result;
}

(int, int)? _findHighlightRange(String plainText, String search) {
  if (search.isEmpty) return null;
  final exact = plainText.indexOf(search);
  if (exact >= 0) return (exact, exact + search.length);

  final normalizedText = _normalize(plainText);
  final normalizedSearch = _normalize(search);
  final normalizedIndex = normalizedText.indexOf(normalizedSearch);
  if (normalizedIndex >= 0) {
    return _recoverRange(
      plainText,
      normalizedText,
      normalizedIndex,
      normalizedSearch.length,
    );
  }
  return _wordOverlapRange(plainText, search);
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

(int, int) _recoverRange(
  String text,
  String normalizedText,
  int normalizedStart,
  int normalizedLength,
) {
  var charPosition = 0;
  var normalizedPosition = 0;
  while (charPosition < text.length && normalizedPosition < normalizedStart) {
    final character = text[charPosition++];
    if (character == ' ' || character == '\n' || character == '\t') {
      while (charPosition < text.length &&
          (text[charPosition] == ' ' ||
              text[charPosition] == '\n' ||
              text[charPosition] == '\t')) {
        charPosition++;
      }
    }
    normalizedPosition++;
  }

  final start = charPosition;
  final normalizedEnd = normalizedStart + normalizedLength;
  while (charPosition < text.length && normalizedPosition < normalizedEnd) {
    final character = text[charPosition++];
    if (character == ' ' || character == '\n' || character == '\t') {
      while (charPosition < text.length &&
          (text[charPosition] == ' ' ||
              text[charPosition] == '\n' ||
              text[charPosition] == '\t')) {
        charPosition++;
      }
    }
    normalizedPosition++;
  }
  return (start, charPosition);
}

(int, int)? _wordOverlapRange(String plainText, String search) {
  final words = _normalize(search)
      .split(' ')
      .where((word) => word.length > 2)
      .toList();
  if (words.isEmpty) return null;

  final windowSize = search.length * 2;
  final step = (windowSize / 2).floor();
  var bestStart = 0;
  var bestScore = 0.0;
  for (var start = 0; start < plainText.length; start += step) {
    final end = (start + windowSize).clamp(0, plainText.length);
    final normalizedWindow = _normalize(plainText.substring(start, end));
    final matched = words.where(normalizedWindow.contains).length;
    final score = matched / words.length;
    if (score > bestScore) {
      bestScore = score;
      bestStart = start;
    }
  }
  if (bestScore < 0.6) return null;
  return (bestStart, (bestStart + windowSize).clamp(0, plainText.length));
}

TextStyle _mergedWithHighlight(
  TextStyle? base,
  Color selectionColor,
  Color Function(Color) onSelection,
) {
  return TextStyle(
    color: onSelection(selectionColor),
    backgroundColor: selectionColor,
    fontWeight: FontWeight.bold,
    fontStyle: base?.fontStyle,
    decoration: base?.decoration,
  );
}
