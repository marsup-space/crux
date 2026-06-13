import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/framework/terminal_canvas.dart';
import 'package:nocterm/src/rendering/mouse_tracker.dart';
import 'package:nocterm/src/utils/unicode_width.dart';

import '../utils/terminal_symbols.dart';

// Rounded-border glyphs used by the hover tooltip. These match the
// `_BorderCharacters.rounded` set in nocterm's `decorated_box.dart`
// (BoxBorderStyle.rounded), so the visual output is identical to what
// `BoxBorder.all(style: BoxBorderStyle.rounded)` would produce.
//
// We draw the border by hand rather than using a `Container` with a
// `BoxDecoration` because the tooltip is painted directly inside
// `RenderAnnotatedScrollbar.paint`, at a position derived from the
// scrollbar-internal marker coordinates (`_visibleMarkers`, `scrollbarX`,
// `markerY`). Those coordinates are only known during the paint pass; a
// `Container` would need them at layout time, which would mean hoisting
// marker-position math out of the render object and through the widget
// tree — a much bigger change than the rest of the scrollbar warrants.
const _tooltipTopLeft = '╭';
const _tooltipTopRight = '╮';
const _tooltipBottomLeft = '╰';
const _tooltipBottomRight = '╯';
const _tooltipHorizontal = '─';
const _tooltipVertical = '│';

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
    this.tooltipBackgroundColor,
    this.tooltipBorderColor,
    this.markers = const [],
  });

  final Component child;
  final ScrollController? controller;
  final bool thumbVisibility;
  final double thickness;
  final Color? trackColor;
  final Color? thumbColor;
  final Color? tooltipBackgroundColor;
  final Color? tooltipBorderColor;
  final List<ScrollbarMarker> markers;

  @override
  State<AnnotatedScrollbar> createState() => _AnnotatedScrollbarState();
}

class _AnnotatedScrollbarState extends State<AnnotatedScrollbar> {
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

  void _onHover(MouseEvent event) {
    final renderObj = _getRenderObject();
    if (renderObj == null) return;
    final hitIdx = renderObj.markerAtGlobalPosition(event.x, event.y);

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
  }

  void _onEnter(MouseEvent event) {
    _isHovered = true;
    final renderObj = _getRenderObject();
    if (renderObj == null) return;
    final hitIdx = renderObj.markerAtGlobalPosition(event.x, event.y);
    if (hitIdx != _hoveredMarkerIndex) {
      setState(() {
        _hoveredMarkerIndex = hitIdx;
      });
    }
  }

  void _onExit(MouseEvent event) {
    _isHovered = false;
    _isLeftButtonDown = false;
    if (_hoveredMarkerIndex != null) {
      setState(() {
        _hoveredMarkerIndex = null;
      });
    }
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
    return MouseRegion(
      opaque: false,
      onHover: _onHover,
      onEnter: _onEnter,
      onExit: _onExit,
      child: _AnnotatedScrollbarRenderObjectWidget(
        key: _renderKey,
        controller: _controller,
        thumbVisibility: component.thumbVisibility,
        thickness: component.thickness,
        trackColor: component.trackColor,
        thumbColor: component.thumbColor,
        tooltipBackgroundColor: component.tooltipBackgroundColor,
        tooltipBorderColor: component.tooltipBorderColor,
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
    this.tooltipBackgroundColor,
    this.tooltipBorderColor,
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
  final Color? tooltipBackgroundColor;
  final Color? tooltipBorderColor;
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
      tooltipBackgroundColor: tooltipBackgroundColor,
      tooltipBorderColor: tooltipBorderColor,
      markers: markers,
      hoveredMarkerIndex: hoveredMarkerIndex,
      isScrollbarHovered: isScrollbarHovered,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, RenderAnnotatedScrollbar renderObject) {
    final theme = TuiTheme.of(context);
    renderObject
      ..controller = controller
      ..thumbVisibility = thumbVisibility
      ..thickness = thickness
      ..trackColor = trackColor ?? theme.surface
      ..thumbColor = thumbColor ?? theme.onSurface
      ..tooltipBackgroundColor = tooltipBackgroundColor
      ..tooltipBorderColor = tooltipBorderColor
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
    Color? tooltipBackgroundColor,
    Color? tooltipBorderColor,
    List<ScrollbarMarker> markers = const [],
    int? hoveredMarkerIndex,
    bool isScrollbarHovered = false,
  })  : _markers = markers,
        _hoveredMarkerIndex = hoveredMarkerIndex,
        _isScrollbarHovered = isScrollbarHovered,
        _tooltipBackgroundColor = tooltipBackgroundColor,
        _tooltipBorderColor = tooltipBorderColor;

  double get minimumThumbHeight => 2.0;

  Color? _tooltipBackgroundColor;
  Color? get tooltipBackgroundColor => _tooltipBackgroundColor;
  set tooltipBackgroundColor(Color? value) {
    if (_tooltipBackgroundColor == value) return;
    _tooltipBackgroundColor = value;
    markNeedsPaint();
  }

  Color? _tooltipBorderColor;
  Color? get tooltipBorderColor => _tooltipBorderColor;
  set tooltipBorderColor(Color? value) {
    if (_tooltipBorderColor == value) return;
    _tooltipBorderColor = value;
    markNeedsPaint();
  }

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

  @override
  MouseTrackerAnnotation? get annotation {
    final parent = super.annotation;
    if (parent == null) return null;
    _customAnnotation ??= MouseTrackerAnnotation(
      onEnter: parent.onEnter,
      onExit: parent.onExit,
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

  void _handleHover(MouseEvent event) {
    final parent = super.annotation;
    if (parent == null) return;
    final ctrl = controller;
    if (ctrl == null || !thumbVisibility) {
      parent.onHover?.call(event);
      return;
    }
    if (ctrl.maxScrollExtent <= 0 || size.height < 3) {
      parent.onHover?.call(event);
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
            isReversed
                ? ctrl.scrollToEnd()
                : ctrl.scrollToStart();
            return;
          } else if (localY >= trackEnd) {
            isReversed
                ? ctrl.scrollToStart()
                : ctrl.scrollToEnd();
            return;
          }
        }
      } else if (!leftDown && _isLeftButtonPressed) {
        _isLeftButtonPressed = false;
      }
    }

    parent.onHover?.call(event);
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
    if (_hoveredMarkerIndex != null) {
      _paintTooltip(canvas, offset);
    }
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

  void _paintTooltip(TerminalCanvas canvas, Offset offset) {
    if (_hoveredMarkerIndex == null) return;
    if (_hoveredMarkerIndex! >= _markers.length) return;

    final marker = _markers[_hoveredMarkerIndex!];
    final label = marker.label;
    if (label == null || label.isEmpty) return;

    double? markerY;
    for (final (idx, y) in _visibleMarkers) {
      if (idx == _hoveredMarkerIndex) {
        markerY = y;
        break;
      }
    }
    if (markerY == null) return;

    final scrollbarX = size.width - thickness;
    final maxTooltipWidth = math.min(
      (scrollbarX - 1).toInt(),
      (size.width / 2).floor(),
    );
    if (maxTooltipWidth <= 0) return;

    const maxLines = 4;
    // Reserve 2 columns for the left/right border.
    final innerWidth = maxTooltipWidth - 2;
    if (innerWidth <= 0) return;

    final lines = _wrapText(label, innerWidth);
    final trimmedLines = lines.length > maxLines
        ? [...lines.sublist(0, maxLines - 1), '${lines[maxLines - 1]}…']
        : lines;

    // Vertical layout:
    //   row 0: top border (╭──…──╮)
    //   rows 1..N: content lines (│…│)
    //   row N+1: bottom border (╰──…──╯)
    // The content is anchored to the marker row (markerY), so the top border
    // sits one row above the marker, and the content lines start at markerY.
    final topY = markerY - 1;
    if (topY < 0) return;

    var tooltipLineCount = trimmedLines.length;
    // Clamp the number of content lines to whatever fits before the bottom.
    final maxBottomY = size.height - 1; // reserve 1 row for the bottom border
    if (markerY + tooltipLineCount > maxBottomY) {
      tooltipLineCount = (maxBottomY - markerY).toInt();
    }
    if (tooltipLineCount <= 0) return;

    final effectiveLines = trimmedLines.sublist(0, tooltipLineCount);
    final bgColor = tooltipBackgroundColor ?? const Color(0x21222C);
    final borderColor = tooltipBorderColor ?? const Color(0x6272A4);

    final rightEdge = scrollbarX - 1;
    final tooltipX = rightEdge - maxTooltipWidth;

    // Top border: ╭──…──╮
    final topRow = '$_tooltipTopLeft${_tooltipHorizontal * innerWidth}$_tooltipTopRight';
    canvas.fillRect(
      Rect.fromLTWH(
        offset.dx + tooltipX,
        offset.dy + topY,
        maxTooltipWidth.toDouble(),
        1.0,
      ),
      ' ',
      style: TextStyle(backgroundColor: bgColor),
    );
    canvas.drawText(
      offset + Offset(tooltipX.toDouble(), topY),
      topRow,
      style: TextStyle(color: borderColor, backgroundColor: bgColor),
    );

    // Content rows: │<padded text>│
    for (var lineIdx = 0; lineIdx < effectiveLines.length; lineIdx++) {
      final line = effectiveLines[lineIdx];
      final lineY = markerY + lineIdx.toDouble();

      canvas.fillRect(
        Rect.fromLTWH(
          offset.dx + tooltipX,
          offset.dy + lineY,
          maxTooltipWidth.toDouble(),
          1.0,
        ),
        ' ',
        style: TextStyle(backgroundColor: bgColor),
      );

      // Side borders.
      canvas.drawText(
        offset + Offset(tooltipX.toDouble(), lineY),
        _tooltipVertical,
        style: TextStyle(color: borderColor, backgroundColor: bgColor),
      );
      canvas.drawText(
        offset + Offset((tooltipX + maxTooltipWidth - 1).toDouble(), lineY),
        _tooltipVertical,
        style: TextStyle(color: borderColor, backgroundColor: bgColor),
      );

      canvas.drawText(
        offset + Offset((tooltipX + 1).toDouble(), lineY),
        line,
        style: TextStyle(
          color: marker.color,
          backgroundColor: bgColor,
        ),
      );
    }

    // Bottom border: ╰──…──╯
    final bottomY = markerY + tooltipLineCount;
    if (bottomY < size.height) {
      final bottomRow =
          '$_tooltipBottomLeft${_tooltipHorizontal * innerWidth}$_tooltipBottomRight';
      canvas.fillRect(
        Rect.fromLTWH(
          offset.dx + tooltipX,
          offset.dy + bottomY,
          maxTooltipWidth.toDouble(),
          1.0,
        ),
        ' ',
        style: TextStyle(backgroundColor: bgColor),
      );
      canvas.drawText(
        offset + Offset(tooltipX.toDouble(), bottomY),
        bottomRow,
        style: TextStyle(color: borderColor, backgroundColor: bgColor),
      );
    }
  }

  List<String> _wrapText(String text, int maxWidth) {
    if (maxWidth <= 0) return [];
    final words = text.split(RegExp(r'\s+'));
    final lines = <String>[];
    var currentLine = '';

    for (final word in words) {
      if (word.isEmpty) continue;
      final wordWidth = UnicodeWidth.stringWidth(word);

      if (currentLine.isEmpty) {
        if (wordWidth <= maxWidth) {
          currentLine = word;
        } else {
          currentLine = _truncateToWidth(word, maxWidth);
        }
      } else {
        final combinedWidth =
            UnicodeWidth.stringWidth(currentLine) + 1 + wordWidth;
        if (combinedWidth <= maxWidth) {
          currentLine = '$currentLine $word';
        } else {
          lines.add(currentLine);
          if (wordWidth <= maxWidth) {
            currentLine = word;
          } else {
            currentLine = _truncateToWidth(word, maxWidth);
          }
        }
      }
    }

    if (currentLine.isNotEmpty) {
      lines.add(currentLine);
    }

    return lines;
  }

  String _truncateToWidth(String text, int maxWidth) {
    if (maxWidth <= 1) return '…';
    final targetWidth = maxWidth - 1;
    var width = 0;
    final buffer = StringBuffer();
    for (final char in text.characters) {
      final charWidth = UnicodeWidth.stringWidth(char);
      if (width + charWidth > targetWidth) break;
      buffer.write(char);
      width += charWidth;
    }
    return '$buffer…';
  }
}
