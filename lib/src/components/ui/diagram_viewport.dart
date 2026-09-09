// ignore_for_file: prefer_initializing_formals

// Draggable pan viewport for mermaid / d2 / state-diagram fences.
//
// Why this exists
// ---------------
// Chat markdown renders as ONE TextSpan tree painted by a single
// RenderParagraph. A diagram fence used to be flattened into that tree,
// which forced the layout pass to shrink+truncate the drawing until it
// fit the chat width (wide graphs lost their labels — `商会结局：车队…`)
// and, past the budget, soft-wrapped rows tore the box borders. A
// rendered diagram is plain text lines though, so pixel-faithful inline
// charts would be possible — but nocterm has no WidgetSpan: nothing
// interactive can live inside a TextSpan tree. The only way to make the
// canvas a real interactive surface is to split it out of the span tree
// into its own render object (see [DiagramViewportBlock] /
// DiagramViewportBuilder in highlighted_markdown_text.dart).
//
// Design
// ------
// * The markdown visitor emits a diagram fence as a special block; the
//   widget replaces that block's rows with this viewport. Rows outside
//   the fence stay ordinary RichText.
// * The render object measures the art's natural width (widest line,
//   Unicode-width aware) and clamps the horizontal scroll offset to
//   `max(0, naturalWidth - viewportWidth)`.
// * Drag anywhere on the art: pointer-down captures the mouse
//   (MouseTrackerAnnotation.capturing — the same mechanism the
//   scrollbar thumb uses, so the drag survives leaving the bounds),
//   pointer-move shifts the offset by the cell delta, pointer-up
//   releases. Drag is the ONLY pan gesture by design: the wheel is
//   never consumed horizontally (its scroll intent is vertical, and a
//   horizontal wheel hijack at the pan edge felt broken in practice),
//   so this render object does NOT implement
//   ScrollableRenderObjectMixin — wheel events fall through to the
//   enclosing chat ListView and scroll vertically (scroll chaining).
// * Painting: clip to the viewport rect, blit the pre-split line
//   segments at `-offset`. Per-cell writes (canvas.drawText) so CJK
//   double-width glyphs clip cleanly at the seam.
//
// Selection: _shouldHighlightMarkdownSelection in the markdown text
// widget already excludes diagram rows from selectable spans, so a
// selection drag over the canvas extends the chat selection around it
// without the two fighting over pointer state. (SelectionArea receives
// events; we only win because our annotation is deeper in the tree and
// hit-test dispatch reaches both — acceptable: the artifact the user
// grabs is the diagram.)

import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:nocterm/nocterm.dart';
// These rendering primitives are intentionally used by this custom render object.
// ignore: implementation_imports
import 'package:nocterm/src/framework/terminal_canvas.dart';
// ignore: implementation_imports
import 'package:nocterm/src/rendering/mouse_hit_test.dart';
// ignore: implementation_imports
import 'package:nocterm/src/rendering/mouse_tracker.dart';
// ignore: implementation_imports
import 'package:nocterm/src/utils/unicode_width.dart';

import '../../diagram/diagram.dart';
import '../../diagram/diagram_model.dart';
import '../../i18n/strings.dart';
import 'diagram_border_classifier.dart';
import '../../theme/crux_theme.dart';

/// The parsed + rendered diagram content a viewport breathes from.
class DiagramViewportData {
  /// Rendered art lines (warnings NOT included — the caller appends
  /// them as extra lines so they pan together with the drawing).
  final List<String> lines;

  /// Grapheme indexes that belong to a node outline. Edge strokes are left
  /// unmarked and therefore use the brighter content/line color.
  final List<Set<int>>? borderGlyphs;

  const DiagramViewportData(this.lines, {this.borderGlyphs});

  factory DiagramViewportData.inferBorders(List<String> lines) =>
      DiagramViewportData(
        lines,
        borderGlyphs: DiagramBorderClassifier.infer(lines),
      );

  bool isBorderGlyph(int line, int glyph) =>
      borderGlyphs != null &&
      line < borderGlyphs!.length &&
      borderGlyphs![line].contains(glyph);

  int get naturalWidth {
    var w = 0;
    for (final line in lines) {
      w = math.max(w, UnicodeWidth.stringWidth(line));
    }
    return w;
  }
}

/// A [Component] that builds the viewport from [data]; passed to the
/// markdown widget via `DiagramViewportBuilder` so the diagram module
/// does not depend on the widget module.
typedef DiagramViewportBuilder = Component Function(DiagramViewportData data);

/// Marker span the markdown visitor emits in place of a parseable
/// diagram fence. Renders as nothing (its text is never painted — the
/// block-slicing pass in the markdown widget pulls the whole fence out
/// of the span tree before rendering); it exists purely so the fence
/// occupies ONE span slot in `_spans`, which [sliceDiagramBlocks]
/// locates by its [fenceIndex].
class DiagramSentinelSpan extends TextSpan {
  const DiagramSentinelSpan(this.fenceIndex) : super(text: '');

  /// Which entry of the visitor's `collectedDiagrams` list this
  /// sentinel corresponds to (emission order).
  final int fenceIndex;
}

/// What the visitor records about each diagram fence it replaced:
/// the sentinel's index in the emitted span list is resolved later by
/// [sliceDiagramBlocks] (flat identity scan — cheap, fences are rare).
class DiagramFenceInfo {
  const DiagramFenceInfo({
    required this.code,
    required this.language,
    required this.data,
  });

  /// Raw fenced source (kept for diagnostics).
  final String code;

  /// Fence info string (`mermaid` / `d2` / `stateDiagram-v2`).
  final String? language;

  /// Pre-parsed viewport data at NATURAL width, resolved by the
  /// visitor BEFORE it decided to emit a sentinel (unparseable fences
  /// fall through to the plain code path instead). Null is impossible
  /// in practice; kept nullable because the slice pass drops null
  /// entries defensively.
  final DiagramViewportData? data;
}

/// One resolved diagram block: where the sentinel sits in the span
/// list and the parsed viewport data.
class DiagramBlockSlice {
  const DiagramBlockSlice({
    required this.fenceIndex,
    required this.data,
    required this.language,
  });

  /// Stable identity of the [DiagramSentinelSpan] emitted for this fence.
  /// Unlike a list position, this survives text-only span transforms.
  final int fenceIndex;

  final DiagramViewportData data;
  final String? language;
}

/// Rewrite [spans] so every [DiagramSentinelSpan] nested inside a
/// subtree becomes ONE top-level entry; its former siblings are
/// preserved as their own top-level entries. Pure list surgery — no
/// parsing. Called by `parseMarkdownToInlineSpans` right after the
/// visitor walk, so `sliceDiagramBlocks` can then locate sentinels by
/// top-level index.
List<InlineSpan> hoistDiagramSentinels(List<InlineSpan> spans) {
  var hasSentinel = false;
  for (final s in spans) {
    if (_sentinelIn(s, 0) >= 0) {
      hasSentinel = true;
      break;
    }
  }
  if (!hasSentinel) return spans;

  final work = <InlineSpan>[...spans];
  var changed = true;
  var guard = 0;
  while (changed && guard++ < 64) {
    changed = false;
    for (var i = 0; i < work.length; i++) {
      final span = work[i];
      if (span is DiagramSentinelSpan) continue;
      final fenceIdx = _sentinelIn(span, 0);
      if (fenceIdx < 0) continue;
      // This top-level entry CONTAINS a sentinel deeper inside: split
      // it around the direct-children chain holding it.
      final split = _splitAroundSentinel(span, fenceIdx);
      if (split != null) {
        work
          ..removeAt(i)
          ..insertAll(i, split);
        changed = true;
        break; // restart scan (indices shifted)
      }
    }
  }
  return work;
}

/// Slice the hoisted [spans]: pair each fence with its sentinel's
/// TOP-LEVEL index. Diagrams were already parsed by the visitor (it
/// only emits sentinels for parseable fences), so no re-parse happens
/// here; fences with null data are dropped defensively.
List<DiagramBlockSlice> sliceDiagramBlocks(
  List<InlineSpan> spans,
  List<DiagramFenceInfo> fences,
) {
  if (fences.isEmpty) return const [];
  final slices = <DiagramBlockSlice>[];
  for (var fenceIdx = 0; fenceIdx < fences.length; fenceIdx++) {
    final fence = fences[fenceIdx];
    final data = fence.data;
    if (data == null) continue;
    for (var i = 0; i < spans.length; i++) {
      final span = spans[i];
      if (span is DiagramSentinelSpan && span.fenceIndex == fenceIdx) {
        slices.add(
          DiagramBlockSlice(
            fenceIndex: fenceIdx,
            data: data,
            language: fence.language,
          ),
        );
        break;
      }
    }
  }
  return slices;
}

/// Deepest fence index of any sentinel inside [span]'s subtree, or -1.
int _sentinelIn(InlineSpan span, int depth) {
  if (depth > 8) return -1;
  if (span is DiagramSentinelSpan) return span.fenceIndex;
  final children = span is TextSpan ? span.children : null;
  if (children == null) return -1;
  for (final child in children) {
    final found = _sentinelIn(child, depth + 1);
    if (found >= 0) return found;
  }
  return -1;
}

/// Split [span] into [before, sentinel, after] when the sentinel sits
/// among [span]'s direct children. Returns null when it sits deeper,
/// in which case the caller... cannot split here — but hoisting loops
/// always reach it because the sentinel's direct parent is eventually
/// the top-level entry itself after its ancestors split first. To make
/// that true, split at the DEEPEST level first: this implementation
/// recurses to the sentinel's actual parent and splits there, wrapping
/// the outer levels back around the pieces.
List<InlineSpan>? _splitAroundSentinel(InlineSpan span, int fenceIdx) {
  if (span is! TextSpan) return null;
  final children = span.children;
  if (children == null) return null;
  final sentinelIdx = children.indexWhere(
    (c) => c is DiagramSentinelSpan && c.fenceIndex == fenceIdx,
  );
  if (sentinelIdx >= 0) {
    final sentinel = children[sentinelIdx];
    InlineSpan wrap(List<InlineSpan> list) {
      if (list.isEmpty) return const TextSpan(text: '');
      if (list.length == 1) return list.first;
      return TextSpan(children: list, style: span.style);
    }

    return [
      wrap(children.sublist(0, sentinelIdx)),
      sentinel,
      wrap(children.sublist(sentinelIdx + 1)),
    ];
  }

  // Sentinel is deeper: recurse into the child subtree that contains
  // it, split THERE, and hand the pieces back wrapped one level up —
  // the hoist loop peels the next level on a following pass.
  for (var i = 0; i < children.length; i++) {
    final child = children[i];
    if (_sentinelIn(child, 0) != fenceIdx) continue;
    final inner = _splitAroundSentinel(child, fenceIdx);
    if (inner == null) return null;
    return [TextSpan(children: inner, style: span.style)];
  }
  return null;
}

/// Parse [source] as a diagram and return viewport data, or null when
/// it cannot (yet) be parsed (streaming partials → caller falls back to
/// the raw code block).
DiagramViewportData? tryBuildDiagramViewportData(
  String code,
  String? language, {
  Strings? strings,
}) {
  final DiagramRenderResult result;
  try {
    // No maxWidth: the whole point is the natural, untruncated drawing.
    result = renderDiagram(
      code,
      const DiagramRenderOptions(),
      language: language,
    );
  } on DiagramParseException {
    return null;
  }
  final effectiveStrings = strings ?? kEnglishStrings;
  final lines = result.text.split('\n');
  for (final warning in result.warnings) {
    lines.add(
      '⚠ ${warning.message(cycleDetected: (nodes) => effectiveStrings.t('diagram.cycleWarning', {'nodes': nodes}))}',
    );
  }
  return DiagramViewportData.inferBorders(lines);
}

class DiagramViewport extends StatefulComponent {
  const DiagramViewport({required this.data, this.language, super.key});

  final DiagramViewportData data;

  /// Fence info string (`mermaid`, `d2`, …) shown in the header title.
  final String? language;

  @override
  State<DiagramViewport> createState() => _DiagramViewportState();
}

class _DiagramViewportState extends State<DiagramViewport> {
  final _controller = DiagramPanController();

  @override
  void didUpdateComponent(DiagramViewport oldComponent) {
    super.didUpdateComponent(oldComponent);
    // Content changed (e.g. the fence finished streaming): keep the
    // anchored edge rather than the raw offset so re-layout doesn't
    // leave the view stranded mid-drawing.
    _controller.setContentChanged();
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    // NOTE: intentionally NOT a LayoutBuilder here. nocterm's
    // BoxConstraints.enforce semantics differ from Flutter's, so a
    // width-tight SizedBox ancestor does NOT tighten the constraints a
    // LayoutBuilder reports (it sees the grandparent's extent). The
    // render object instead clamps to the constraints it actually
    // receives in performLayout — see [RenderDiagramViewport].
    return _DiagramViewportRenderWidget(
      controller: _controller,
      data: component.data,
      language: component.language,
      fallbackWidth: 80,
      gutterColor: theme.codeBlockGutter,
      borderColor: theme.outline,
      contentColor: theme.mdCodeBlockText,
    );
  }
}

/// Scroll position of a diagram canvas. Public (like [ScrollController])
/// so tests can assert the offset after synthetic drags.
class DiagramPanController extends ChangeNotifier {
  double _offset = 0;
  double _maxOffset = 0;
  double _vOffset = 0;
  double _maxVOffset = 0;
  int? _pinnedFrom;

  /// Current horizontal scroll offset in terminal columns (0 … maxOffset).
  double get offset => _offset;

  /// How far the drawing extends past the viewport (0 = fits).
  double get maxOffset => _maxOffset;

  /// Current vertical scroll offset in terminal rows (0 … maxVOffset).
  double get vOffset => _vOffset;

  /// How many rows the drawing extends past the viewport (0 = fits).
  double get maxVOffset => _maxVOffset;

  /// True when the canvas can pan horizontally at all.
  bool get canPan => _maxOffset > 0;

  /// True when the canvas can pan vertically.
  bool get canPanV => _maxVOffset > 0;

  /// Called by the render object whenever the viewport/content metrics
  /// change. Keeps the right/bottom edge pinned when content grows (the
  /// streaming case) if the user was already at that edge, otherwise
  /// preserves the offset.
  void applyMetrics({required double maxOffset, required double maxVOffset}) {
    final wasAtEnd = _maxOffset > 0 && _offset >= _maxOffset - 0.5;
    final wasAtVEnd = _maxVOffset > 0 && _vOffset >= _maxVOffset - 0.5;
    _maxOffset = maxOffset;
    _maxVOffset = maxVOffset;
    if (_pinnedFrom != null) {
      // Content changed this frame: keep the anchored edge.
      _offset = wasAtEnd ? maxOffset : (_offset.clamp(0, maxOffset));
      _vOffset = wasAtVEnd ? maxVOffset : (_vOffset.clamp(0, maxVOffset));
      _pinnedFrom = null;
    } else {
      _offset = _offset.clamp(0, maxOffset);
      _vOffset = _vOffset.clamp(0, maxVOffset);
    }
    notifyListeners();
  }

  /// Marks that content metrics are about to change (from didUpdate).
  void setContentChanged() => _pinnedFrom = -1;

  void jumpTo(double value) {
    _offset = value.clamp(0, _maxOffset);
    notifyListeners();
  }

  void jumpToV(double value) {
    _vOffset = value.clamp(0, _maxVOffset);
    notifyListeners();
  }
}

/// The single-child-less render proxy component. Holds the immutable
/// inputs; the render object keeps mutable interaction state.
class _DiagramViewportRenderWidget extends SingleChildRenderObjectComponent {
  const _DiagramViewportRenderWidget({
    required this.controller,
    required this.data,
    this.language,
    required this.fallbackWidth,
    required this.gutterColor,
    required this.borderColor,
    required this.contentColor,
  });

  final DiagramPanController controller;
  final DiagramViewportData data;
  final String? language;

  /// Width to use when layout constraints are unbounded (rare — a
  /// viewport outside any width-bounded ancestor).
  final int fallbackWidth;
  final Color gutterColor;
  final Color borderColor;
  final Color contentColor;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderDiagramViewport(
      controller: controller,
      data: data,
      language: language,
      fallbackWidth: fallbackWidth,
      gutterColor: gutterColor,
      borderColor: borderColor,
      contentColor: contentColor,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderDiagramViewport renderObject,
  ) {
    renderObject
      ..controller = controller
      ..data = data
      ..language = language
      ..fallbackWidth = fallbackWidth
      ..gutterColor = gutterColor
      ..borderColor = borderColor
      ..contentColor = contentColor;
  }
}

/// Render object: drag-to-pan canvas with a thin bottom-edge pan
/// indicator while scrollable. Leaf (no children). Deliberately does
/// NOT mix in ScrollableRenderObjectMixin: the wheel is never consumed
/// here (drag is the only pan gesture), so wheel events chain to the
/// enclosing chat scroll and move vertically.
class RenderDiagramViewport extends RenderObject
    implements MouseTrackerAnnotationProvider {
  // Public constructor names intentionally omit the private storage prefix.
  RenderDiagramViewport({
    required DiagramPanController controller,
    required DiagramViewportData data,
    String? language,
    required int fallbackWidth,
    required Color gutterColor,
    required Color borderColor,
    required Color contentColor,
  }) : _controller = controller,
       _data = data,
       _language = language,
       _fallbackWidth = fallbackWidth,
       _gutterColor = gutterColor,
       _borderColor = borderColor,
       _contentColor = contentColor {
    _controller.addListener(_handleControllerChanged);
    _updateAnnotation();
  }

  // Content gutters are literal: '│ ' (2 cols) left + ' │' (2 cols)
  // right, so the inner art width is viewportWidth - 4.

  DiagramPanController _controller;
  DiagramPanController get controller => _controller;
  set controller(DiagramPanController value) {
    if (_controller == value) return;
    _controller.removeListener(_handleControllerChanged);
    _controller = value;
    _controller.addListener(_handleControllerChanged);
    markNeedsPaint();
  }

  String? _language;
  String? get language => _language;
  set language(String? value) {
    if (_language == value) return;
    _language = value;
    markNeedsPaint();
  }

  DiagramViewportData _data;
  DiagramViewportData get data => _data;
  set data(DiagramViewportData value) {
    if (identical(_data, value)) return;
    _data = value;
    markNeedsLayout();
  }

  int _fallbackWidth;
  int get fallbackWidth => _fallbackWidth;
  set fallbackWidth(int value) {
    if (_fallbackWidth == value) return;
    _fallbackWidth = value;
    markNeedsLayout();
  }

  /// Width used in the most recent layout pass (constraints-bounded).
  int _effectiveViewportWidth = 80;
  int get viewportWidth => _effectiveViewportWidth;

  Color _gutterColor;
  Color get gutterColor => _gutterColor;
  set gutterColor(Color value) {
    if (_gutterColor == value) return;
    _gutterColor = value;
    markNeedsPaint();
  }

  Color _borderColor;
  Color get borderColor => _borderColor;
  set borderColor(Color value) {
    if (_borderColor == value) return;
    _borderColor = value;
    markNeedsPaint();
  }

  Color _contentColor;
  Color get contentColor => _contentColor;
  set contentColor(Color value) {
    if (_contentColor == value) return;
    _contentColor = value;
    markNeedsPaint();
  }

  // ── interaction state ──

  bool _isDragging = false;
  bool _isHovered = false;
  int? _dragStartX;
  int? _dragStartY;
  double _dragStartOffset = 0;
  double _dragStartVOffset = 0;

  MouseTrackerAnnotation? _annotation;
  bool _annotationCapturing = false;

  @override
  MouseTrackerAnnotation? get annotation => _annotation;

  void _updateAnnotation() {
    _annotation = MouseTrackerAnnotation(
      onEnter: (event) {
        _isHovered = true;
        markNeedsPaint();
        if (!event.isWheel &&
            (event.pressed || event.isPrimaryButtonDown) &&
            event.button == MouseButton.left) {
          _handlePointerDown(event);
        }
      },
      onExit: (event) {
        _isHovered = false;
        markNeedsPaint();
        // Missing release (froze, terminal ate the button-up): drop the
        // drag as soon as the cursor leaves with no button held.
        if (_isDragging && !_hasButton(event)) {
          _endDrag();
        }
      },
      onHover: (event) {
        if (event.isWheel) {
          // Wheel while dragging: the user is scrolling, not dragging —
          // drop the drag (mirrors RenderScrollbar's stuck-button
          // recovery).
          if (_isDragging) _endDrag();
          return;
        }
        if (event.button != MouseButton.left) return;

        final leftDown = event.pressed || event.isPrimaryButtonDown;
        if (leftDown) {
          if (_isDragging) {
            _handleDragMove(event);
          } else {
            _handlePointerDown(event);
          }
        } else if (_isDragging) {
          // Button RELEASE while inside the canvas. This is the normal
          // end of a drag — without it the mouse capture would leak
          // (`capturing: true` swallows every subsequent event in the
          // tracker, dead-clicking the rest of the UI), and the stale
          // _dragStartX would make the next drag jump.
          _endDrag();
        }
      },
      renderObject: this,
    );
  }

  bool _hasButton(MouseEvent event) =>
      event.pressed || event.isPrimaryButtonDown;

  void _handlePointerDown(MouseEvent event) {
    _isDragging = true;
    _dragStartX = event.x;
    _dragStartY = event.y;
    _dragStartOffset = _controller.offset;
    _dragStartVOffset = _controller.vOffset;
    _setCapturing(true);
    markNeedsPaint();
  }

  void _handleDragMove(MouseEvent event) {
    if (!_isDragging || _dragStartX == null || _dragStartY == null) {
      return;
    }
    // Pan relative to WHERE the pointer went down, 1 cell = 1 column/row.
    // Horizontal: always. Vertical: fallback only — active when a
    // bounded ancestor clipped the canvas (maxVOffset > 0). Wheel never
    // drives vertical panning; the chat list keeps it.
    final dx = (event.x - _dragStartX!).toDouble();
    _controller.jumpTo(_dragStartOffset - dx); // drag left → pan right
    if (_controller.canPanV) {
      final dy = (event.y - _dragStartY!).toDouble();
      _controller.jumpToV(_dragStartVOffset - dy); // drag up → pan down
    }
  }

  void _endDrag() {
    _isDragging = false;
    _dragStartX = null;
    _dragStartY = null;
    _setCapturing(false);
    markNeedsPaint();
  }

  void _setCapturing(bool value) {
    if (_annotationCapturing == value) return;
    _annotationCapturing = value;
    _annotation?.capturing = value;
  }

  void _handleControllerChanged() {
    markNeedsPaint();
  }

  // ── layout ──

  @override
  void performLayout() {
    // The REAL width comes from the constraints we were given (a
    // width-tight ancestor — SizedBox/Container width — produces tight
    // constraints here even though nocterm's LayoutBuilder would not
    // report them). Fall back only when unbounded.
    final maxW = constraints.maxWidth;
    _effectiveViewportWidth = maxW.isFinite
        ? maxW.floor().clamp(4, 500)
        : _fallbackWidth;

    // Preferred height: content rows + header + footer — the canvas
    // ALWAYS wants to fit the whole graph. Vertical panning exists only
    // as a FALLBACK: when a bounded ancestor (small window, cramped
    // pane) clamps the height below the graph, drag (never wheel)
    // reveals the clipped rows. maxVOffset stays 0 in the normal case.
    final contentRows = _data.lines.length;
    final wantedHeight = contentRows + 2;
    final height = constraints
        .constrain(
          Size(_effectiveViewportWidth.toDouble(), wantedHeight.toDouble()),
        )
        .height;
    final visibleRows = math.max(1, height.toInt() - 2);
    final maxV = math.max(0, contentRows - visibleRows);
    _controller.applyMetrics(
      maxOffset: math
          .max(0, _data.naturalWidth - math.max(4, _effectiveViewportWidth - 4))
          .toDouble(),
      maxVOffset: maxV.toDouble(),
    );
    size = Size(_effectiveViewportWidth.toDouble(), height);
  }

  // ── paint ──

  @override
  void paint(TerminalCanvas canvas, Offset offset) {
    super.paint(canvas, offset);
    final width = size.width.toInt();
    final height = size.height.toInt();
    if (width < 4 || height < 3) return;

    final borderStyle = TextStyle(color: _gutterColor);

    // ── header row: ╭─ <lang> ────╮ ──
    final headerTitle = '╭─ $_langLabel ';
    final headerRest = math.max(0, width - headerTitle.length - 1);
    canvas.drawText(
      offset,
      '$headerTitle${'─' * headerRest}╮',
      style: borderStyle,
    );

    // ── content rows: gutters first, then clipped panned art ──
    final contentRows = _data.lines.length;
    final visibleRows = math.min(contentRows, size.height.toInt() - 2);
    final innerWidth = width - 4; // '│ ' + ' │'
    final firstRow = _controller.vOffset.floor();
    for (var i = 0; i < visibleRows; i++) {
      final rowY = (1 + i).toDouble();
      canvas.drawText(offset + Offset(0, rowY), '│ ', style: borderStyle);
      canvas.drawText(
        offset + Offset((width - 2).toDouble(), rowY),
        ' │',
        style: borderStyle,
      );
    }
    final clipped = canvas.clip(
      Rect.fromLTWH(
        offset.dx + 2,
        offset.dy + 1,
        innerWidth.toDouble(),
        visibleRows.toDouble(),
      ),
    );
    // TerminalCanvas.clip() changes the coordinate origin to its clipped
    // area. If this viewport has scrolled partly above its parent, that area
    // is intersected with the terminal and its origin is no longer the
    // diagram's inner top-left. Keep the art in the render object's original
    // coordinate system, expressed relative to the resulting clipped canvas.
    final clippedOrigin = Offset(
      clipped.area.left - canvas.area.left,
      clipped.area.top - canvas.area.top,
    );
    final contentOrigin = offset + const Offset(2, 1) - clippedOrigin;
    final pan = -_controller.offset;
    for (var i = 0; i < visibleRows; i++) {
      final lineIdx = firstRow + i;
      if (lineIdx < 0 || lineIdx >= contentRows) continue;
      _drawPannedLine(
        clipped,
        _data.lines[lineIdx],
        lineIdx,
        i,
        pan,
        contentOrigin,
      );
    }

    _drawFooter(canvas, offset, width, height);
  }

  String get _langLabel => _language ?? 'diagram';

  void _drawFooter(
    TerminalCanvas canvas,
    Offset offset,
    int width,
    int height,
  ) {
    final footerY = (height - 1).toDouble();
    final borderStyle = TextStyle(color: _gutterColor);
    canvas.drawText(
      offset + Offset(0, footerY),
      '╰${'─' * math.max(0, width - 2)}╯',
      style: borderStyle,
    );

    final active = _isHovered || _isDragging;
    final indicatorColor = active ? _contentColor : _borderColor;

    // Vertical clipped indicator (drag-only pan, fallback when the
    // canvas doesn't fit the height): ▲ more above / ▼ more below.
    if (_controller.canPanV) {
      final vf = _controller.maxVOffset > 0
          ? (_controller.vOffset / _controller.maxVOffset).clamp(0.0, 1.0)
          : 0.0;
      final String glyph;
      if (vf <= 0.01) {
        glyph = '▼'; // at top — more rows below
      } else if (vf >= 0.99) {
        glyph = '▲'; // at bottom — more rows above
      } else {
        glyph = '↕';
      }
      canvas.drawText(
        offset + Offset(1, footerY),
        glyph,
        style: TextStyle(color: indicatorColor),
      );
    }

    if (!_controller.canPan) return;

    // Horizontal position strip on the footer: ◀ ───●─── ▶
    final fraction = _controller.maxOffset > 0
        ? (_controller.offset / _controller.maxOffset).clamp(0.0, 1.0)
        : 0.0;
    final stripWidth = math.min(12, math.max(5, width - 20));
    final stripX = width - stripWidth - 2;
    final dotIdx = (fraction * (stripWidth - 1)).round();
    final buf = List<String>.filled(stripWidth, '─');
    buf[0] = '◀';
    buf[stripWidth - 1] = '▶';
    buf[dotIdx] = '●';
    canvas.drawText(
      offset + Offset(stripX.toDouble(), footerY),
      buf.join(),
      style: TextStyle(color: indicatorColor),
    );
  }

  /// Paint one content row, split into visible segments by the pan
  /// offset. Per-cell drawText so CJK wide glyphs clip at the seam.
  void _drawPannedLine(
    TerminalCanvas clipCanvas,
    String line,
    int lineIndex,
    int row,
    double pan,
    Offset contentOrigin,
  ) {
    var x = pan; // may be negative (content shifted left)
    var glyphIndex = 0;
    for (final grapheme in line.characters) {
      final currentGlyphIndex = glyphIndex++;
      final gw = UnicodeWidth.graphemeWidth(grapheme).toDouble();
      if (gw <= 0) continue;
      final start = x;
      final end = x + gw;
      x = end;
      if (end <= 0) continue; // fully left of viewport
      // Partially visible wide glyph: paint it — the clip canvas cuts
      // the overflow column. nocterm buffers are cell-based, so draw
      // when ANY column is visible.
      if (start >= _effectiveViewportWidth) break; // right of viewport
      clipCanvas.drawText(
        contentOrigin + Offset(start, row.toDouble()),
        grapheme,
        style: TextStyle(
          color: _data.isBorderGlyph(lineIndex, currentGlyphIndex)
              ? _borderColor
              : _contentColor,
        ),
      );
      if (x >= _effectiveViewportWidth) break;
    }
  }

  // ── hit testing ──

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  bool hitTest(HitTestResult result, {required Offset position}) {
    final inside = Rect.fromLTWH(
      0,
      0,
      size.width,
      size.height,
    ).contains(position);
    if (!inside) return false;
    // During a drag we own the pointer regardless of position (capture
    // handles delivery, but the hit test still needs our entry).
    if (result is MouseHitTestResult) {
      result.addWithPosition(target: this, localPosition: position);
    }
    result.add(this);
    return true;
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    _isDragging = false;
    super.dispose();
  }
}
