// Reach into nocterm's `lib/src/` to implement custom mouse-capture semantics
// for the annotated scrollbar (overriding `MouseTrackerAnnotation` and
// `TerminalCanvas` paint hooks). These symbols are intentionally not part of
// nocterm's public surface but are stable internal contracts used by the
// scrollbar's render object.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/framework/terminal_canvas.dart';
import 'package:nocterm/src/rendering/mouse_tracker.dart';

import '../utils/terminal_symbols.dart';

class ScrollbarMarker {
  const ScrollbarMarker({
    required this.itemIndex,
    required this.color,
    this.label,
  });

  final int itemIndex;

  final Color color;

  final String? label;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScrollbarMarker &&
          runtimeType == other.runtimeType &&
          itemIndex == other.itemIndex &&
          color == other.color &&
          label == other.label;

  @override
  int get hashCode => Object.hash(itemIndex, color, label);
}

class AnnotatedScrollbar extends StatefulComponent {
  const AnnotatedScrollbar({
    super.key,
    required this.child,
    this.controller,
    this.thumbVisibility = false,
    this.thickness = 1.0,
    this.trackColor,
    this.thumbColor,
    this.markers = const [],
  });

  final Component child;
  final ScrollController? controller;
  final bool thumbVisibility;
  final double thickness;
  final Color? trackColor;
  final Color? thumbColor;
  final List<ScrollbarMarker> markers;

  @override
  State<AnnotatedScrollbar> createState() => _AnnotatedScrollbarState();
}

class _AnnotatedScrollbarState extends State<AnnotatedScrollbar>
    with HintStateMixin<AnnotatedScrollbar> {
  ScrollController? _controller;
  int? _hoveredMarkerIndex;
  bool _isHovered = false;
  bool _isLeftButtonDown = false;
  final _renderKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _controller = component.controller;
  }

  @override
  void didUpdateComponent(AnnotatedScrollbar oldWidget) {
    super.didUpdateComponent(oldWidget);
    if (component.controller != oldWidget.controller) {
      _controller = component.controller;
    }
  }

  // The scrollbar's tooltip is anchored to the hovered marker, not
  // the mouse cursor. The default mixin behavior (follow-the-mouse)
  // would put the tooltip on top of the scrollbar, which is exactly
  // where the marker is — close, but not what we want. The
  // The marker tooltip should appear *to the left* of the marker
  // (between the chat content and the scrollbar thumb), not above
  // or below. The default placement ([HintPlacement.above]) would
  // drop the tooltip into the chat history, which is the wrong
  // place to anchor a scroll-bar hint.
  @override
  HintPlacement get hintPlacement => HintPlacement.left;

  // The marker labels are short and the user expects the tooltip
  // to appear immediately when the cursor crosses a marker — the
  // 500 ms default would make the scroll bar feel sluggish. The
  // tooltips for the *toolbar* items below use the default 500 ms
  // (see the chat toolbar's [Hinted] wrappers), which is the
  // conventional tooltip feel for hoverable buttons.
  @override
  Duration get hintDelay => Duration.zero;

  @override
  String? get hintContent {
    final idx = _hoveredMarkerIndex;
    if (idx == null) return null;
    final markers = component.markers;
    if (idx < 0 || idx >= markers.length) return null;
    return markers[idx].label;
  }

  @override
  Color? get hintColor {
    final idx = _hoveredMarkerIndex;
    if (idx == null) return null;
    final markers = component.markers;
    if (idx < 0 || idx >= markers.length) return null;
    return markers[idx].color;
  }

  /// The bounds of the marker's cell, in the [HintOverlay]'s local
  /// coordinate system. The resolver uses this to anchor the
  /// tooltip *next to* the marker (via the [hintPlacement] of
  /// [HintPlacement.left] above) rather than directly on top of it
  /// or below it.
  ///
  /// When no marker is hovered the [hintContent] returns `null`
  /// anyway, so the bounds don't matter — the controller hides the
  /// hint before the resolver ever sees it.
  @override
  Rect hintSourceBounds(MouseEvent event) {
    final idx = _hoveredMarkerIndex;
    final renderObj = _getRenderObject();
    if (idx == null || renderObj == null) {
      // Fall back to a 1×1 rect at the mouse — same as the
      // default. Shouldn't be hit in practice (the hint is hidden
      // when there's no marker), but a no-op fallback keeps the
      // type honest.
      return Rect.fromLTWH(event.x.toDouble(), event.y.toDouble(), 1, 1);
    }
    // The marker is rendered at column `scrollbarX` (= size.width −
    // thickness) in the render object's local frame. Per the
    // invariant documented on [HintStateMixin.hintPosition], the
    // render object's local frame *is* the overlay's local frame
    // when the state passes a hint from inside the overlay's
    // subtree (which is the only case where this state is mounted).
    return renderObj.markerSourceBounds(idx) ??
        Rect.fromLTWH(event.x.toDouble(), event.y.toDouble(), 1, 1);
  }

  // Pin the tooltip's outer width to the space between the chat
  // content and the scrollbar thumb. Without this, the overlay's
  // default width (40 cells) is used, which is wider than the
  // available space for most terminals — the right edge of the
  // tooltip would no longer sit flush against the thumb, and the
  // word-wrapping would happen at a width that doesn't match the
  // layout the scroll bar was sized for.
  @override
  int? get hintMaxWidth {
    final w = _getRenderObject()?.getMarkerMaxTooltipWidth() ?? 0;
    return w > 0 ? w : null;
  }

  // The mouse handlers are all overridden so the state can keep
  // [_isHovered] and [_hoveredMarkerIndex] in sync with the render
  // object before delegating to the mixin. The mixin's
  // [HintStateMixin.onHintEnter] / [onHintHover] / [onHintExit] read
  // the (now-updated) [hintContent] / [hintColor] / [hintPosition]
  // getters and push the result to the [HintController]. Because
  // [HintStateMixin.buildWithHint] always installs a [MouseRegion]
  // (even when [hintContent] is currently null), these overrides
  // are guaranteed to fire on the very first hover — no parallel
  // inner [MouseRegion] needed.
  @override
  void onHintEnter(MouseEvent event) {
    setState(() {
      _isHovered = true;
      _isLeftButtonDown = event.pressed || event.isPrimaryButtonDown;
      final renderObj = _getRenderObject();
      if (renderObj == null) return;
      _hoveredMarkerIndex = renderObj.markerAtGlobalPosition(event.x, event.y);
    });
    super.onHintEnter(event);
  }

  @override
  void onHintHover(MouseEvent event) {
    final renderObj = _getRenderObject();
    final hitIdx = renderObj?.markerAtGlobalPosition(event.x, event.y);
    if (hitIdx != _hoveredMarkerIndex) {
      setState(() {
        _hoveredMarkerIndex = hitIdx;
      });
    }

    final leftDown = event.pressed || event.isPrimaryButtonDown;
    if (leftDown && !_isLeftButtonDown && hitIdx != null) {
      _jumpToMarker(hitIdx);
    }
    _isLeftButtonDown = leftDown;

    super.onHintHover(event);
  }

  @override
  void onHintExit(MouseEvent event) {
    if (_isHovered || _hoveredMarkerIndex != null) {
      setState(() {
        _isHovered = false;
        _isLeftButtonDown = false;
        _hoveredMarkerIndex = null;
      });
    }
    super.onHintExit(event);
  }

  void _jumpToMarker(int markerIndex) {
    final ctrl = _controller;
    if (ctrl == null) return;
    final itemIndex = component.markers[markerIndex].itemIndex;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final info = ctrl.getItemIndexOffsetAndExtent(itemIndex);
      if (info != null) {
        ctrl.jumpTo(info.$1);
      }
    });
  }

  RenderAnnotatedScrollbar? _getRenderObject() {
    final ctx = _renderKey.currentContext;
    if (ctx is Element) {
      final ro = ctx.renderObject;
      if (ro is RenderAnnotatedScrollbar) return ro;
    }
    return null;
  }

  @override
  Component build(BuildContext context) {
    return buildWithHint(
      _AnnotatedScrollbarRenderObjectWidget(
        key: _renderKey,
        controller: _controller,
        thumbVisibility: component.thumbVisibility,
        thickness: component.thickness,
        trackColor: component.trackColor,
        thumbColor: component.thumbColor,
        markers: component.markers,
        hoveredMarkerIndex: _hoveredMarkerIndex,
        isScrollbarHovered: _isHovered,
        child: component.child,
      ),
    );
  }
}

class _AnnotatedScrollbarRenderObjectWidget
    extends SingleChildRenderObjectComponent {
  _AnnotatedScrollbarRenderObjectWidget({
    super.key,
    required this.controller,
    required this.thumbVisibility,
    required this.thickness,
    this.trackColor,
    this.thumbColor,
    required this.markers,
    required this.hoveredMarkerIndex,
    required this.isScrollbarHovered,
    required super.child,
  });

  final ScrollController? controller;
  final bool thumbVisibility;
  final double thickness;
  final Color? trackColor;
  final Color? thumbColor;
  final List<ScrollbarMarker> markers;
  final int? hoveredMarkerIndex;
  final bool isScrollbarHovered;

  @override
  RenderObject createRenderObject(BuildContext context) {
    final theme = TuiTheme.of(context);
    return RenderAnnotatedScrollbar(
      controller: controller,
      thumbVisibility: thumbVisibility,
      thickness: thickness,
      trackColor: trackColor ?? theme.surface,
      thumbColor: thumbColor ?? theme.onSurface,
      markers: markers,
      hoveredMarkerIndex: hoveredMarkerIndex,
      isScrollbarHovered: isScrollbarHovered,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAnnotatedScrollbar renderObject,
  ) {
    final theme = TuiTheme.of(context);
    renderObject
      ..controller = controller
      ..thumbVisibility = thumbVisibility
      ..thickness = thickness
      ..trackColor = trackColor ?? theme.surface
      ..thumbColor = thumbColor ?? theme.onSurface
      ..markers = markers
      ..hoveredMarkerIndex = hoveredMarkerIndex
      ..isScrollbarHovered = isScrollbarHovered;
  }
}

class RenderAnnotatedScrollbar extends RenderScrollbar {
  RenderAnnotatedScrollbar({
    super.controller,
    required super.thumbVisibility,
    required super.thickness,
    required super.trackColor,
    required super.thumbColor,
    this._markers = const [],
    this._hoveredMarkerIndex,
    this._isScrollbarHovered = false,
  });

  @override
  double get minimumThumbHeight => 2.0;

  List<ScrollbarMarker> _markers;
  List<ScrollbarMarker> get markers => _markers;
  set markers(List<ScrollbarMarker> value) {
    if (_markers == value) return;
    _markers = value;
    markNeedsPaint();
  }

  int? _hoveredMarkerIndex;
  int? get hoveredMarkerIndex => _hoveredMarkerIndex;
  set hoveredMarkerIndex(int? value) {
    if (_hoveredMarkerIndex == value) return;
    _hoveredMarkerIndex = value;
    markNeedsPaint();
  }

  bool _isScrollbarHovered;
  bool get isScrollbarHovered => _isScrollbarHovered;
  set isScrollbarHovered(bool value) {
    if (_isScrollbarHovered == value) return;
    _isScrollbarHovered = value;
    markNeedsPaint();
  }

  Offset _myPaintOffset = Offset.zero;
  final List<(int, double)> _visibleMarkers = [];
  MouseTrackerAnnotation? _customAnnotation;
  bool _isLeftButtonPressed = false;
  StreamSubscription<MouseEvent>? _globalMouseSubscription;

  @override
  MouseTrackerAnnotation? get annotation {
    final parent = super.annotation;
    if (parent == null) return null;
    _customAnnotation ??= MouseTrackerAnnotation(
      onEnter: _handleEnter,
      onExit: _handleExit,
      onHover: _handleHover,
      renderObject: this,
    );
    // Propagate the capturing state from the parent (RenderScrollbar)
    // so that mouse capture during scrollbar dragging works correctly.
    // Without this, the custom annotation always reports capturing=false,
    // and the MouseTracker delivers hover events to other widgets (like
    // the right-hand session panel) while the user is dragging the thumb.
    _customAnnotation!.capturing = parent.capturing;
    return _customAnnotation;
  }

  void _syncCapturingFrom(MouseTrackerAnnotation parent) {
    _customAnnotation?.capturing = parent.capturing;
  }

  void _clearCaptureOnGlobalMouseUp(MouseEvent event) {
    if (event.button != MouseButton.left || event.pressed) return;
    if (!_isLeftButtonPressed && !(_customAnnotation?.capturing ?? false)) {
      return;
    }
    _isLeftButtonPressed = false;
    releaseMouseCapture();
    _customAnnotation?.capturing = false;
  }

  void _handleEnter(MouseEvent event) {
    final parent = super.annotation;
    if (parent == null) return;
    parent.onEnter?.call(event);
    _syncCapturingFrom(parent);
  }

  void _handleExit(MouseEvent event) {
    final parent = super.annotation;
    if (parent == null) return;
    parent.onExit?.call(event);
    _syncCapturingFrom(parent);
  }

  void _handleHover(MouseEvent event) {
    final parent = super.annotation;
    if (parent == null) return;
    final ctrl = controller;
    if (ctrl == null || !thumbVisibility) {
      parent.onHover?.call(event);
      _syncCapturingFrom(parent);
      return;
    }
    if (ctrl.maxScrollExtent <= 0 || size.height < 3) {
      parent.onHover?.call(event);
      _syncCapturingFrom(parent);
      return;
    }

    final leftDown = event.pressed || event.isPrimaryButtonDown;
    if (event.button == MouseButton.left || event.isPrimaryButtonDown) {
      if (leftDown && !_isLeftButtonPressed) {
        _isLeftButtonPressed = true;
        final localX = event.x.toDouble() - _myPaintOffset.dx;
        final localY = event.y.toDouble() - _myPaintOffset.dy;
        final scrollbarX = size.width - thickness;
        if (localX >= scrollbarX) {
          final hasArrows = size.height >= 3;
          final trackStart = hasArrows ? 1.0 : 0.0;
          final trackEnd = hasArrows ? size.height - 1 : size.height;
          final isReversed = ctrl.isReversed;
          if (localY < trackStart) {
            isReversed ? ctrl.scrollToEnd() : ctrl.scrollToStart();
            return;
          } else if (localY >= trackEnd) {
            isReversed ? ctrl.scrollToStart() : ctrl.scrollToEnd();
            return;
          }
        }
      } else if (!leftDown && _isLeftButtonPressed) {
        _isLeftButtonPressed = false;
      }
    }

    parent.onHover?.call(event);
    _syncCapturingFrom(parent);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _globalMouseSubscription = NoctermBinding.instance.mouseEvents.listen(
      _clearCaptureOnGlobalMouseUp,
    );
  }

  @override
  void detach() {
    _globalMouseSubscription?.cancel();
    _globalMouseSubscription = null;
    releaseMouseCapture();
    _customAnnotation?.capturing = false;
    super.detach();
  }

  @override
  void paint(TerminalCanvas canvas, Offset offset) {
    _myPaintOffset = offset;
    _visibleMarkers.clear();
    super.paint(canvas, offset);
    if (controller == null || !thumbVisibility) return;
    if (controller!.maxScrollExtent <= 0) return;
    if (_markers.isEmpty) return;
    _paintMarkers(canvas, offset);
    // The hover tooltip is no longer painted here — it now flows
    // through the app-wide [HintOverlay] (see
    // [_AnnotatedScrollbarState.onHintHover] and
    // [getMarkerTooltipGlobalPosition] below).
  }

  int? markerAtGlobalPosition(int globalX, int globalY) {
    final localX = globalX.toDouble() - _myPaintOffset.dx;
    final localY = globalY.toDouble() - _myPaintOffset.dy;
    final scrollbarX = size.width - thickness;

    if (localX < scrollbarX - 0.5) return null;

    for (final (markerIdx, markerY) in _visibleMarkers) {
      if ((localY - markerY).abs() < 0.5) {
        return markerIdx;
      }
    }
    return null;
  }

  /// Returns the outer width (including the border) that a tooltip
  /// for this scrollbar should be pinned to. The tooltip fills
  /// exactly the space between the chat content and the scrollbar
  /// thumb, capped at half the scrollbar's width so it never
  /// reaches the opposite edge of the terminal.
  ///
  /// Returns 0 when the scrollbar is too narrow to host a tooltip
  /// at all (callers should treat that as "no tooltip possible").
  int getMarkerMaxTooltipWidth() {
    final scrollbarX = size.width - thickness;
    final maxTooltipWidth = math.min(
      (scrollbarX - 1).toInt(),
      (size.width / 2).floor(),
    );
    return maxTooltipWidth < 3 ? 0 : maxTooltipWidth;
  }

  /// Returns the position at which a tooltip for [markerIndex] should
  /// be drawn, in the **HintOverlay's local coordinate system** (i.e.
  /// relative to the top-left of the [HintOverlay]'s `Stack`).
  ///
  /// The tooltip is placed to the left of the scrollbar (in the area
  /// typically occupied by chat content), one row above the marker
  /// itself, so the top of the bordered tooltip sits flush with the
  /// marker row. The tooltip's outer width is
  /// [getMarkerMaxTooltipWidth], which the [_AnnotatedScrollbarState]
  /// passes to the [HintController] as the `maxWidth` so the
  /// tooltip's content word-wraps to fit the same width.
  ///
  /// The position is returned in the overlay's local space, not in
  /// absolute terminal coordinates, because the [HintOverlay] uses
  /// the value as the `Positioned` widget's `left`/`top` — which
  /// are interpreted in the Stack's local frame. The Stack's paint
  /// offset is added by the framework during paint, so we must not
  /// add [_myPaintOffset] here (doing so would shift the tooltip by
  /// the render object's terminal position *twice* — once by us,
  /// once by the Stack's paint pass).
  ///
  /// In practice, the render object that owns [_myPaintOffset] and
  /// the HintOverlay's Stack sit at the same terminal position
  /// (the AnnotatedScrollbar's render object is a descendant of the
  /// Stack's child, and every component in the chain — the
  /// `HintOverlay`, the `ChatPanel`'s `LayoutBuilder`, the chat
  /// history's `Stack`, the `SelectionArea`, and the scroll bar's
  /// own `MouseRegion` — has zero paint offset relative to its
  /// parent). That equality is what makes "return the local
  /// coordinates" equivalent to "return the offset the user
  /// expects" for the actual app.
  ///
  /// Returns the bounds (in the render object's local coordinate
  /// system) of the cell that paints [markerIndex], or `null` if
  /// the marker isn't currently visible (e.g. it's hidden by the
  /// thumb). The state passes this to [HintController.show] as the
  /// hint's [HintController.activeSourceBounds], which the
  /// [HintOverlay] uses to anchor the tooltip on the marker.
  ///
  /// The marker is always a single cell wide (`thickness` is the
  /// scrollbar's rightmost column) and 1 cell tall. The vertical
  /// position is the marker's actual y in [_visibleMarkers]; the
  /// horizontal position is always `size.width - thickness` (the
  /// scrollbar's column).
  Rect? markerSourceBounds(int markerIndex) {
    double? markerY;
    for (final (idx, y) in _visibleMarkers) {
      if (idx == markerIndex) {
        markerY = y;
        break;
      }
    }
    if (markerY == null) return null;
    final scrollbarX = size.width - thickness;
    return Rect.fromLTWH(scrollbarX.toDouble(), markerY, 1, 1);
  }

  static Color _dimColor(Color color, double factor) {
    return Color.fromARGB(
      (color.alpha * factor).round().clamp(0, 255),
      color.red,
      color.green,
      color.blue,
    );
  }

  void _paintMarkers(TerminalCanvas canvas, Offset offset) {
    final ctrl = controller!;
    final scrollbarX = size.width - thickness;
    final scrollbarHeight = size.height;
    final hasArrows = scrollbarHeight >= 3;
    final trackStart = hasArrows ? 1.0 : 0.0;
    final trackEnd = hasArrows ? scrollbarHeight - 1 : scrollbarHeight;
    final trackHeight = trackEnd - trackStart;
    final totalExtent = ctrl.maxScrollExtent + ctrl.viewportDimension;

    final scrollFraction = ctrl.viewportDimension / totalExtent;
    final thumbHeight = math.min(
      trackHeight,
      math.max(minimumThumbHeight, trackHeight * scrollFraction),
    );
    final isReversed = ctrl.isReversed;
    double thumbOffset;
    if (isReversed) {
      final scrollOff = 1.0 - (ctrl.offset / ctrl.maxScrollExtent);
      thumbOffset = trackStart + scrollOff * (trackHeight - thumbHeight);
    } else {
      final scrollOff = ctrl.offset / ctrl.maxScrollExtent;
      thumbOffset = trackStart + scrollOff * (trackHeight - thumbHeight);
    }
    final thumbStart = thumbOffset.toInt();
    final thumbEnd = math.min(
      (thumbOffset + thumbHeight).toInt(),
      trackEnd.toInt(),
    );

    final occupiedY = <int, (int, double)>{};
    for (var i = 0; i < _markers.length; i++) {
      final marker = _markers[i];
      final info = ctrl.getItemIndexOffsetAndExtent(marker.itemIndex);
      if (info == null) continue;
      final (itemOffset, _) = info;
      final fraction = (itemOffset / totalExtent).clamp(0.0, 1.0);
      final markerY = trackStart + fraction * trackHeight;
      final yInt = markerY.round();
      if (yInt < trackStart.toInt() || yInt >= trackEnd.toInt()) continue;

      if (yInt >= thumbStart && yInt < thumbEnd) continue;

      occupiedY[yInt] = (i, markerY);
    }

    for (final yInt in occupiedY.keys) {
      final (i, _) = occupiedY[yInt]!;

      _visibleMarkers.add((i, yInt.toDouble()));

      Color markerColor;
      if (i == _hoveredMarkerIndex) {
        markerColor = _markers[i].color;
      } else if (_isScrollbarHovered) {
        markerColor = _dimColor(_markers[i].color, 0.6);
      } else {
        markerColor = _dimColor(_markers[i].color, 0.3);
      }

      canvas.drawText(
        offset + Offset(scrollbarX, yInt.toDouble()),
        terminalSymbol('◆', '*'),
        style: TextStyle(color: markerColor),
      );
    }
  }

  // The hover tooltip used to be drawn by [_paintTooltip] here, but
  // it now flows through the app-wide [HintOverlay]. All this code
  // needs is [getMarkerTooltipGlobalPosition] above, which the
  // [_AnnotatedScrollbarState] uses to position the hint next to the
  // marker.
}
