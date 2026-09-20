// Custom mouse-capture semantics for the round-limit slider (drag by
// holding the left button and moving over the track). These symbols
// are nocterm internals — same stable contracts the annotated
// scrollbar uses (`MouseTrackerAnnotation`, `TerminalCanvas`).
// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api

import 'dart:async';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/framework/terminal_canvas.dart';
import 'package:nocterm/src/rendering/mouse_hit_test.dart';
import 'package:nocterm/src/rendering/mouse_tracker.dart';

import '../../theme/crux_theme.dart';

/// A horizontal draggable bar that picks an integer within [min]..[max]
/// (default 32..100) or the "unlimited" end state.
///
/// Rendered as a single row: a track (`─` with `├ ┼ ┤` stops at the
/// min / midpoint / max) whose last cell is the `∞` end state, plus a
/// `█` thumb at the current value. Drag (press and move) to set; the
/// far-right `∞` cell means no cap (null). The whole track is a
/// click/drag target — a press on the track jumps the thumb there.
///
/// [value] `null` = unlimited. [onChanged] fires while dragging and on
/// every click, so the owner can mark its copy-on-edit state dirty.
class RoundLimitSlider extends SingleChildRenderObjectComponent {
  /// Current value; `null` = unlimited.
  final int? value;

  /// Fired whenever the value changes via mouse interaction.
  final ValueChanged<int?> onChanged;

  final int min;
  final int max;

  const RoundLimitSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 32,
    this.max = 100,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    final theme = CruxTheme.of(context);
    return _RenderRoundLimitSlider(
      value,
      min,
      max,
      onChanged,
      theme.onSurfaceDim,
      theme.accent,
      theme.foreground,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderRoundLimitSlider renderObject,
  ) {
    final theme = CruxTheme.of(context);
    renderObject
      ..value = value
      ..min = min
      ..max = max
      ..onChanged = onChanged
      ..trackColor = theme.onSurfaceDim
      ..thumbColor = theme.accent
      ..hoverTrackColor = theme.foreground;
  }
}

class _RenderRoundLimitSlider extends RenderObject
    implements MouseTrackerAnnotationProvider {
  _RenderRoundLimitSlider(
    this._value,
    this._min,
    this._max,
    this._onChanged,
    this._trackColor,
    this._thumbColor,
    this._hoverTrackColor,
  ) {
    _annotation = MouseTrackerAnnotation(
      onEnter: _handleEnter,
      onExit: _handleExit,
      onHover: _handleHover,
      renderObject: this,
    );
  }

  int? _value;
  int _min;
  int _max;
  ValueChanged<int?> _onChanged;
  Color _trackColor;
  Color _thumbColor;
  Color _hoverTrackColor;

  late final MouseTrackerAnnotation _annotation;

  int? get value => _value;
  set value(int? newValue) {
    if (_value == newValue) return;
    _value = newValue;
    markNeedsPaint();
  }

  int get min => _min;
  set min(int newValue) {
    if (_min == newValue) return;
    _min = newValue;
    markNeedsPaint();
  }

  int get max => _max;
  set max(int newValue) {
    if (_max == newValue) return;
    _max = newValue;
    markNeedsPaint();
  }

  ValueChanged<int?> get onChanged => _onChanged;
  set onChanged(ValueChanged<int?> value) {
    if (_onChanged == value) return;
    _onChanged = value;
  }

  Color get trackColor => _trackColor;
  set trackColor(Color value) {
    if (_trackColor == value) return;
    _trackColor = value;
    markNeedsPaint();
  }

  Color get thumbColor => _thumbColor;
  set thumbColor(Color value) {
    if (_thumbColor == value) return;
    _thumbColor = value;
    markNeedsPaint();
  }

  Color get hoverTrackColor => _hoverTrackColor;
  set hoverTrackColor(Color value) {
    if (_hoverTrackColor == value) return;
    _hoverTrackColor = value;
    markNeedsPaint();
  }

  @override
  MouseTrackerAnnotation? get annotation => _annotation;

  Offset _paintOffset = Offset.zero;
  bool _isHovered = false;
  bool _isLeftButtonPressed = false;
  bool _isDragging = false;
  StreamSubscription<MouseEvent>? _globalMouseSubscription;

  // ── Mouse handling ─────────────────────────────────────────────

  void _handleEnter(MouseEvent event) {
    _isHovered = true;
    markNeedsPaint();
    if (_isDragging) _dragTo(event);
  }

  void _handleExit(MouseEvent event) {
    _isHovered = false;
    markNeedsPaint();
    if (_isDragging && !(event.pressed || event.isPrimaryButtonDown)) {
      _endDrag();
    }
  }

  void _handleHover(MouseEvent event) {
    // A wheel event is the user scrolling, not dragging — release any
    // stuck drag and ignore.
    if (event.isWheel) {
      if (_isDragging) _endDrag();
      return;
    }
    final leftDown = event.pressed || event.isPrimaryButtonDown;
    if (event.button == MouseButton.left || event.isPrimaryButtonDown) {
      if (leftDown && !_isLeftButtonPressed) {
        _isLeftButtonPressed = true;
        _startDrag(event);
      } else if (leftDown && _isDragging) {
        _dragTo(event);
      } else if (!leftDown && _isLeftButtonPressed) {
        _endDrag();
      }
    }
  }

  void _startDrag(MouseEvent event) {
    _isDragging = true;
    _annotation.capturing = true;
    _setValueFrom(event);
  }

  void _dragTo(MouseEvent event) {
    if (!_isDragging) return;
    _setValueFrom(event);
  }

  void _endDrag() {
    if (!_isDragging && !_isLeftButtonPressed) return;
    _isDragging = false;
    _isLeftButtonPressed = false;
    _annotation.capturing = false;
    markNeedsPaint();
  }

  void _setValueFrom(MouseEvent event) {
    final localX = event.x.toDouble() - _globalPaintOffset().dx;
    final next = _valueAt(localX);
    if (next != _value) {
      _onChanged(next);
      // The owner's setState repaints via updateRenderObject; paint the
      // new thumb this frame already so the drag feels immediate.
      _value = next;
      markNeedsPaint();
    }
  }

  /// The slider's top-left in ROOT cell coordinates. The `offset` we
  /// receive in [paint] is only relative to our immediate parent — and
  /// inside a scroll view it is relative to the viewport's content
  /// origin, because `RenderSingleChildScrollView` paints its child at
  /// `Offset.zero + scrollOffset`, dropping the accumulated offset.
  /// Sum every ancestor's `BoxParentData.offset` to rebuild the global
  /// position the mouse tracker reports in `MouseEvent.x/y`.
  Offset _globalPaintOffset() {
    var total = _paintOffset;
    var node = parent;
    while (node != null) {
      final pd = node.parentData;
      if (pd is BoxParentData) {
        total += pd.offset;
      }
      node = node.parent;
    }
    return total;
  }

  /// Release held on ANY left-button release, even when the cursor has
  /// left the slider mid-drag (the tracker's capture keeps motion
  /// events flowing; a lost release would otherwise leave the drag
  /// stuck). Belt-and-braces on top of [_handleHover].
  void _clearCaptureOnGlobalMouseUp(MouseEvent event) {
    if (event.button != MouseButton.left || event.pressed) return;
    if (!_isDragging && !_isLeftButtonPressed) return;
    _endDrag();
  }

  // ── Value geometry ─────────────────────────────────────────────

  /// Cells: [0, width-2] map to [min..max], the last cell (width-1) is
  /// the `∞` unlimited end state. 0 when the track is too narrow to
  /// host a finite range (the whole row is then just the `∞` cell).
  int _finiteCellCount(int width) => width <= 2 ? 0 : width - 2;

  /// The cell the thumb should sit in for the current value.
  int _thumbCell(int width) {
    final finite = _finiteCellCount(width);
    if (_value == null) return width - 1;
    if (finite <= 0) return 0;
    final fraction = (_value! - _min) / (_max - _min);
    return (fraction * finite).round().clamp(0, finite);
  }

  /// Resolve a drag position (local track x) to a value.
  int? _valueAt(double localX) {
    final width = size.width.floor();
    final finite = _finiteCellCount(width);
    if (finite <= 0) return _value;
    if (localX >= width - 1) return null; // the ∞ end state
    final fraction = (localX / finite).clamp(0.0, 1.0);
    final v = _min + (fraction * (_max - _min)).round();
    return v.clamp(_min, _max);
  }

  // ── Render object plumbing ──────────────────────────────────────

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
    _endDrag();
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.constrain(Size(constraints.maxWidth, 1));
  }

  @override
  bool hitTest(HitTestResult result, {required Offset position}) {
    if (!Rect.fromLTWH(0, 0, size.width, size.height).contains(position)) {
      return false;
    }
    if (annotation != null && result is MouseHitTestResult) {
      result.addWithPosition(target: this, localPosition: position);
    }
    return true;
  }

  @override
  void paint(TerminalCanvas canvas, Offset offset) {
    super.paint(canvas, offset);
    _paintOffset = offset;
    final width = size.width.floor();
    if (width <= 0 || size.height < 1) return;

    final trackColor = _isHovered || _isDragging
        ? _hoverTrackColor
        : _trackColor;
    final thumbCell = _thumbCell(width);
    final unlimitedSelected = _value == null;

    for (var x = 0; x < width; x++) {
      if (x == width - 1) {
        // The `∞` end state — bright when selected, dim otherwise.
        canvas.drawText(
          offset + Offset(x.toDouble(), 0),
          '∞',
          style: TextStyle(
            color: unlimitedSelected ? _thumbColor : trackColor,
            fontWeight: unlimitedSelected ? FontWeight.bold : null,
          ),
        );
        continue;
      }
      if (x == thumbCell) {
        canvas.drawText(
          offset + Offset(x.toDouble(), 0),
          '█',
          style: TextStyle(color: _thumbColor),
        );
        continue;
      }
      canvas.drawText(
        offset + Offset(x.toDouble(), 0),
        _tickFor(x, width),
        style: TextStyle(color: trackColor),
      );
    }
  }

  /// Track glyph: `├` at the min end, `┼` at the midpoint, `┤` at the
  /// max end (when the track is wide enough for them to be distinct),
  /// plain `─` between.
  String _tickFor(int x, int width) {
    final finite = _finiteCellCount(width);
    if (x == 0) return '├';
    if (x == finite) return '┤';
    final mid = (finite / 2).round();
    if (mid > 0 && mid < finite && x == mid) return '┼';
    return '─';
  }
}
