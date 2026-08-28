import 'dart:math' as math;

import 'package:characters/characters.dart';

import 'diagram_layout.dart';
import 'diagram_model.dart';

/// Character-grid renderer: draws subgraph boxes, nodes, and routes edges
/// with A* pathfinding around node obstacles, merging line junctions.
class _Grid {
  final int width;
  final int height;
  final List<String> cells;
  // Line-direction flags per cell for junction merging (bitmask:
  // 1=left 2=right 4=up 8=down).
  final List<int> _lineFlags;
  // Arm registers fed by edge painting, kept per line weight so the
  // junction pass can rebuild turns / T-joints consistently. Same
  // bitmask encoding as [_lineFlags].
  final List<int> _armPlain;
  final List<int> _armHeavy;
  final List<int> _armDotted;
  // Cells holding arrowheads (or other immutable ink): the junction
  // pass must never touch them.
  final Set<int> _protected;
  // Cells any edge stroke passed through, even arm-less ones.
  final Set<int> _touched;

  _Grid(this.width, this.height)
      : cells = List.filled(width * height, ' '),
        _lineFlags = List.filled(width * height, 0),
        _armPlain = List.filled(width * height, 0),
        _armHeavy = List.filled(width * height, 0),
        _armDotted = List.filled(width * height, 0),
        _protected = {},
        _touched = {};

  bool inBounds(int x, int y) => x >= 0 && x < width && y >= 0 && y < height;

  String get(int x, int y) => inBounds(x, y) ? cells[y * width + x] : ' ';

  void set(int x, int y, String c) {
    if (inBounds(x, y)) cells[y * width + x] = c;
  }

  void protect(int x, int y) {
    if (inBounds(x, y)) _protected.add(y * width + x);
  }

  void unprotect(int x, int y) => _protected.remove(y * width + x);

  /// Record the arms an edge stroke contributes at [p] (directions towards
  /// its neighbours) classified by line weight.
  void addArms(int x, int y, int arms, EdgeStyle style) {
    if (!inBounds(x, y)) return;
    final i = y * width + x;
    if (style.isDotted) {
      _armDotted[i] |= arms;
    } else if (style.isThick) {
      _armHeavy[i] |= arms;
    } else {
      _armPlain[i] |= arms;
    }
  }

  int arms(int x, int y) {
    final i = y * width + x;
    return _armPlain[i] | _armHeavy[i] | _armDotted[i];
  }

  /// True when every arm recorded at the cell comes from dotted edges.
  bool armsAllDotted(int x, int y) {
    final i = y * width + x;
    return (_armPlain[i] | _armHeavy[i]) == 0 && _armDotted[i] != 0;
  }

  bool armsAnyHeavy(int x, int y) {
    final i = y * width + x;
    return _armHeavy[i] != 0;
  }

  bool isProtected(int x, int y) =>
      inBounds(x, y) && _protected.contains(y * width + x);

  /// Mark a cell as edge-touched even when its arm register is empty
  /// (single-cell segments): distinguishes real line ink from leftovers.
  void touch(int x, int y) {
    if (inBounds(x, y)) _touched.add(y * width + x);
  }

  bool isTouched(int x, int y) =>
      inBounds(x, y) &&
      (_touched.contains(y * width + x) || arms(x, y) != 0);

  /// Draw a line character, merging into junction glyphs when a crossing
  /// line already occupies the cell.
  void setLine(int x, int y, bool horizontal) {
    if (!inBounds(x, y)) return;
    final i = y * width + x;
    _lineFlags[i] |= horizontal ? 0x3 : 0xC;
    final f = _lineFlags[i];
    final hasH = (f & 0x3) != 0;
    final hasV = (f & 0xC) != 0;
    cells[i] = hasH && hasV ? '┼' : (horizontal ? '─' : '│');
  }

  @override
  String toString() {
    final lines = <String>[];
    var lastNonEmpty = 0;
    for (var y = 0; y < height; y++) {
      final rowHasContent = cells
          .sublist(y * width, (y + 1) * width)
          .any((c) => c != ' ');
      if (rowHasContent) lastNonEmpty = y;
    }
    for (var y = 0; y <= lastNonEmpty; y++) {
      // Wide glyphs (CJK, emoji) occupy their cell plus a continuation
      // slot holding a filler space. Emitting both would make a real
      // terminal render each wide char at double width + one extra
      // column, breaking all alignment — so continuation slots are
      // skipped on output.
      final buffer = StringBuffer();
      var skip = 0;
      for (var x = 0; x < width; x++) {
        if (skip > 0) {
          skip--;
          continue;
        }
        final c = cells[y * width + x];
        buffer.write(c);
        final w = UnicodeWidthHelper.width(c);
        if (w > 1) skip = w - 1;
      }
      lines.add(buffer.toString().replaceFirst(RegExp(r'\s+$'), ''));
    }
    return lines.join('\n');
  }
}

/// ASCII fallback glyph sets.
class _Glyphs {
  final bool ascii;
  _Glyphs(this.ascii);

  late final hLine = ascii ? '-' : '─';
  late final vLine = ascii ? '|' : '│';
  late final dottedH = ascii ? '.' : '┄';
  late final dottedV = ascii ? ':' : '┆';
  late final thickH = ascii ? '=' : '═';
  late final thickV = ascii ? 'H' : '║';
  late final cross = ascii ? '+' : '┼';
  late final arrowRight = ascii ? '>' : '▶';
  late final arrowLeft = ascii ? '<' : '◀';
  late final arrowDown = ascii ? 'v' : '▼';
  late final arrowUp = ascii ? '^' : '▲';
  late final cornerTL = ascii ? '+' : '┌';
  late final cornerTR = ascii ? '+' : '┐';
  late final cornerBL = ascii ? '+' : '└';
  late final cornerBR = ascii ? '+' : '┘';
  // Rounded elbows for edge turns (arms extend right+down, left+down,
  // right+up, left+up respectively).
  late final roundTL = ascii ? '+' : '╭';
  late final roundTR = ascii ? '+' : '╮';
  late final roundBL = ascii ? '+' : '╰';
  late final roundBR = ascii ? '+' : '╯';
  // Heavy elbows so thick-edge turns keep the line weight.
  late final heavyTL = ascii ? '+' : '┏';
  late final heavyTR = ascii ? '+' : '┓';
  late final heavyBL = ascii ? '+' : '┗';
  late final heavyBR = ascii ? '+' : '┛';

  /// Junction glyphs indexed by arm bitmask (bits: L=1 R=2 U=4 D=8,
  /// meaning an arm extends in that direction from this cell).
  /// Turns keep the rounded elbows the stroke pass drew; T-joints and
  /// crosses use the square box-drawing merges (Unicode has no rounded
  /// T forms — the usual CLI convention, e.g. git graph renderers).
  static const _junctionGlyphs = <int, String>{
    3: '─', 12: '│',
    5: '┘', 6: '└', 9: '┐', 10: '┌',
    7: '┴', 11: '┬', 13: '┤', 14: '├',
    15: '┼',
  };
  static const _junctionHeavy = <int, String>{
    3: '═', 12: '║',
    5: '┛', 6: '┗', 9: '┓', 10: '┏',
    7: '┻', 11: '┳', 13: '┫', 14: '┣',
    15: '╋',
  };
  static const _junctionDotted = <int, String>{
    3: '┄', 12: '┆',
    5: '╯', 6: '╰', 9: '╮', 10: '╭',
    7: '┄', 11: '┄', 13: '┆', 14: '┆',
    15: '┼',
  };

  late final junctionGlyphs =
      ascii ? const <int, String>{} : _junctionGlyphs;
  late final junctionHeavy =
      ascii ? const <int, String>{} : _junctionHeavy;
  late final junctionDotted =
      ascii ? const <int, String>{} : _junctionDotted;

  late final dot = ascii ? '*' : '●';
  late final endDot = ascii ? '@' : '◉';
}

class DiagramRenderer {
  final DiagramGraph graph;
  final DiagramRenderOptions options;

  // Private type in a public field is deliberate: the glyph set is an
  // implementation detail of this renderer.
  // ignore: library_private_types_in_public_api
  final _Glyphs g;

  DiagramRenderer(this.graph, this.options) : g = _Glyphs(options.ascii);

  String render() {
    if (graph.nodes.isEmpty) return '';

    // Shift geometry so there is room above/left for edge labels and
    // diamond apexes; the grid itself gets extra padding on every side.
    // The left pad is small on purpose: edge labels sit BESIDE vertical
    // segments mid-drawing, not at x=0, so a huge fixed indent just
    // wastes width budget (and pushed wide LR chains past the limit).
    const labelRoom = 6;
    var minX = 1 << 60;
    var minY = 1 << 60;
    for (final n in graph.nodes.values) {
      minX = math.min(minX, n.x);
      minY = math.min(minY, n.y);
    }
    for (final sg in graph.subgraphs) {
      if (sg.width <= 0) continue;
      minX = math.min(minX, sg.x);
      minY = math.min(minY, sg.y);
    }
    final shiftX = labelRoom - minX;
    final shiftY = 2 - minY;
    if (shiftX > 0 || shiftY > 0) {
      for (final n in graph.nodes.values) {
        n.x += math.max(0, shiftX);
        n.y += math.max(0, shiftY);
      }
      for (final sg in graph.subgraphs) {
        sg.x += math.max(0, shiftX);
        sg.y += math.max(0, shiftY);
      }
    }

    var maxX = 0;
    var maxY = 0;
    for (final n in graph.nodes.values) {
      maxX = math.max(maxX, n.x + n.width);
      maxY = math.max(maxY, n.y + n.height);
    }
    for (final sg in graph.subgraphs) {
      if (sg.width <= 0) continue;
      maxX = math.max(maxX, sg.x + sg.width);
      maxY = math.max(maxY, sg.y + sg.height);
    }

    final grid = _Grid(maxX + labelRoom, maxY + 4);

    final labeledSubgraphs = <DiagramSubgraph>[];
    for (final sg in graph.subgraphs) {
      if (sg.width > 0 && sg.height > 0 && sg.label.isNotEmpty) {
        labeledSubgraphs.add(sg);
      }
      if (sg.width > 0 && sg.height > 0) _drawSubgraph(grid, sg);
    }

    final blocked = <int>{};
    for (final n in graph.nodes.values) {
      _drawNode(grid, n);
      for (var dy = 0; dy < n.height; dy++) {
        for (var dx = 0; dx < n.width; dx++) {
          blocked.add((n.y + dy) * grid.width + (n.x + dx));
        }
      }
    }

    // Port ownership per target, decided up front: among the LR edges
    // converging on one target, the one whose source midline is nearest
    // the target's midline draws the full port leg with the arrowhead;
    // all others stop on the trunk. Without this, a "same-row only"
    // rule leaves NO owner when no edge is exactly level with the
    // target (box heights differ) — the port leg goes undrawn and the
    // line into the target breaks.
    final portOwner = <DiagramEdge, bool>{};
    final byTarget = <String, List<DiagramEdge>>{};
    for (final edge in graph.edges) {
      byTarget.putIfAbsent(edge.to, () => []).add(edge);
    }
    byTarget.forEach((_, edges) {
      if (edges.length == 1) {
        portOwner[edges.single] = true;
        return;
      }
      final target = graph.nodes[edges.first.to];
      if (target == null) return;
      final targetMid = target.y + target.height ~/ 2;
      DiagramEdge? best;
      var bestDist = 1 << 30;
      for (final e in edges) {
        final src = graph.nodes[e.from];
        if (src == null) continue;
        final d = (src.y + src.height ~/ 2 - targetMid).abs();
        if (d < bestDist) {
          bestDist = d;
          best = e;
        }
      }
      for (final e in edges) {
        portOwner[e] = identical(e, best);
      }
    });

    for (final edge in graph.edges) {
      _drawEdge(grid, edge, blocked, isPortOwner: portOwner[edge] ?? true);
    }

    // One junction pass after ALL edges: rebuild every line cell from the
    // merged arm registers so turns stay rounded and T-junctions grow a
    // connecting bar instead of overwriting each other.
    _composeJunctions(grid);

    // Subgraph labels go on last: edges are drawn over borders, and the
    // label must win that fight — so the clean-stretch scan also runs now.
    for (final sg in labeledSubgraphs) {
      final x2 = sg.x + sg.width - 1;
      final lw = displayWidthOf(sg.label);
      var best = -1;
      for (var x = sg.x + 2; x + lw < x2; x++) {
        var ok = true;
        for (var dx = 0; dx < lw; dx++) {
          final c = grid.get(x + dx, sg.y);
          if (c != g.hLine && c != ' ') {
            ok = false;
            break;
          }
        }
        if (ok) {
          best = x;
          break;
        }
      }
      if (best >= 0) {
        _writeText(grid, best, sg.y, sg.label);
      } else {
        // Last resort: claim the top-left border even if an edge crosses
        // it — a readable label beats an unbroken line.
        _writeText(grid, sg.x + 2, sg.y, sg.label);
      }
    }

    return grid.toString();
  }

  void _drawSubgraph(_Grid grid, DiagramSubgraph sg) {
    final x2 = sg.x + sg.width - 1;
    final y2 = sg.y + sg.height - 1;
    for (var x = sg.x; x <= x2; x++) {
      grid.set(x, sg.y, g.hLine);
      grid.set(x, y2, g.hLine);
    }
    for (var y = sg.y; y <= y2; y++) {
      grid.set(sg.x, y, g.vLine);
      grid.set(x2, y, g.vLine);
    }
    grid.set(sg.x, sg.y, g.cornerTL);
    grid.set(x2, sg.y, g.cornerTR);
    grid.set(sg.x, y2, g.cornerBL);
    grid.set(x2, y2, g.cornerBR);
  }

  void _drawNode(_Grid grid, DiagramNode n) {
    switch (n.shape) {
      case NodeShape.circle:
        _drawCircle(grid, n);
        break;
      case NodeShape.diamond:
        _drawDiamond(grid, n);
        break;
      case NodeShape.cylinder:
        _drawCylinder(grid, n);
        break;
      case NodeShape.rounded:
        _drawBox(grid, n, rounded: true);
        break;
      case NodeShape.rectangle:
      case NodeShape.generic:
        _drawBox(grid, n);
        break;
    }
  }

  void _drawBox(_Grid grid, DiagramNode n, {bool rounded = false}) {
    final x2 = n.x + n.width - 1;
    final y2 = n.y + n.height - 1;
    final tl = rounded ? '╭' : g.cornerTL;
    final tr = rounded ? '╮' : g.cornerTR;
    final bl = rounded ? '╰' : g.cornerBL;
    final br = rounded ? '╯' : g.cornerBR;
    for (var x = n.x + 1; x < x2; x++) {
      grid.set(x, n.y, g.hLine);
      grid.set(x, y2, g.hLine);
    }
    for (var y = n.y + 1; y < y2; y++) {
      grid.set(n.x, y, g.vLine);
      grid.set(x2, y, g.vLine);
    }
    grid.set(n.x, n.y, tl);
    grid.set(x2, n.y, tr);
    grid.set(n.x, y2, bl);
    grid.set(x2, y2, br);

    final lines = n.label.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final rowY = n.y + 1 + i;
      final w = displayWidthOf(lines[i]);
      // Clamp the centering offset so an over-wide label can never
      // overwrite the border columns.
      final inner = math.max(0, n.width - 2);
      final offset = math.max(0, math.min(inner - w, (inner - w) ~/ 2));
      _writeText(grid, n.x + 1 + offset, rowY, lines[i]);
    }
  }

  void _drawCircle(_Grid grid, DiagramNode n) {
    final label = n.label;
    final w = displayWidthOf(label);
    final cx = n.x + (n.width - w) ~/ 2;
    final cy = n.y + n.height ~/ 2;
    grid.set(cx - 1, cy, '(');
    _writeText(grid, cx, cy, label);
    grid.set(cx + w, cy, ')');
  }

  void _drawDiamond(_Grid grid, DiagramNode n) {
    // Three-row mermaid-style diamond (apexes inset 1 from < >):
    //   /  \
    //  <Ab>
    //   \  /
    final cy = n.y + n.height ~/ 2;
    grid.set(n.x + 1, n.y, '/');
    grid.set(n.x + n.width - 2, n.y, '\\');
    grid.set(n.x, cy, '<');
    final w = displayWidthOf(n.label);
    _writeText(grid, n.x + 1 + math.max(0, (n.width - 2 - w) ~/ 2), cy,
        n.label);
    grid.set(n.x + n.width - 1, cy, '>');
    grid.set(n.x + 1, n.y + n.height - 1, '\\');
    grid.set(n.x + n.width - 2, n.y + n.height - 1, '/');
  }

  void _drawCylinder(_Grid grid, DiagramNode n) {
    // Four-row database form:
    //   ____
    //  /    \
    //  |label|
    //  \____/
    final x2 = n.x + n.width - 1;
    final cy = n.y + n.height ~/ 2;
    // Top underscore row.
    for (var x = n.x + 1; x < x2; x++) {
      grid.set(x, n.y, '_');
    }
    // Upper ellipse sides.
    grid.set(n.x, n.y + 1, '/');
    grid.set(x2, n.y + 1, '\\');
    // Walls + label.
    grid.set(n.x, cy, '|');
    grid.set(x2, cy, '|');
    _writeText(grid, n.x + 1, cy, n.label);
    // Extra wall rows for multi-line labels.
    for (var y = n.y + 2; y < n.y + n.height - 1; y++) {
      if (y == cy) continue;
      grid.set(n.x, y, '|');
      grid.set(x2, y, '|');
    }
    // Bottom curve.
    grid.set(n.x, n.y + n.height - 1, '\\');
    for (var x = n.x + 1; x < x2; x++) {
      grid.set(x, n.y + n.height - 1, '_');
    }
    grid.set(x2, n.y + n.height - 1, '/');
  }

  void _writeText(_Grid grid, int x, int y, String text) {
    var cx = x;
    for (final grapheme in text.characters) {
      grid.set(cx, y, grapheme);
      cx += UnicodeWidthHelper.width(grapheme);
    }
  }

  void _drawEdge(
    _Grid grid,
    DiagramEdge edge,
    Set<int> blocked, {
    required bool isPortOwner,
  }) {
    final from = graph.nodes[edge.from];
    final to = graph.nodes[edge.to];
    if (from == null || to == null) return;

    final horizontal = graph.direction.isHorizontal;
    final out = _RouteOut()..isPortOwner = isPortOwner;
    var path = _routeEdge(
        grid, from, to, horizontal, blocked, edge.style,
        out: out);
    if (path == null) return;

    // Termination baked by the router: an off-midline Z arrival wants to
    // stop on the trunk (no port leg). Only override that when this edge
    // WON port ownership — it draws the leg and the arrowhead regardless
    // of row alignment, otherwise no one would and the line would break.
    var suppressArrowhead =
        out.terminatesOnTrunkWithoutArrow && !isPortOwner;
    // No subnet trimming: the path already ends ON the trunk at the mid
    // row — dropping the tip cell would break the shaft one cell short
    // of the owner's port row (a visible gap). Suppressing the
    // arrowhead is enough; the junction pass turns that cell into ┤.
    _paintPath(grid, path, edge.style, suppressArrowhead: suppressArrowhead);

    if (edge.label != null && edge.label!.isNotEmpty) {
      _paintLabel(grid, path, edge.label!);
    }
  }

  /// Route an edge using canonical shapes first (straight run, then L
  /// bend at the source row × target column), so everyday edges get
  /// predictable, glyph-friendly geometry. Only genuinely blocked cases
  /// fall back to A*, seeded padding the search around existing ink.
  List<_Point>? _routeEdge(
    _Grid grid,
    DiagramNode from,
    DiagramNode to,
    bool horizontal,
    Set<int> blocked,
    EdgeStyle style, {
    _RouteOut? out,
  }) {
    // Circle pills: a horizontal anchor is only right when flow is
    // horizontal or the pill sits BESIDE its peer. In vertical layouts
    // pills stack in one column — route through their top/bottom ports
    // instead, otherwise every edge U-turns around the pill.
    if (from.shape == NodeShape.circle || to.shape == NodeShape.circle) {
      final stacked = !horizontal &&
          !(from.x + from.width <= to.x || to.x + to.width <= from.x);
      if (!stacked) {
        final start =
            _anchorFor(from, to, true, isSourceEnd: true);
        final goal = _anchorFor(to, from, true, isSourceEnd: false);
        return _findPath(start, goal, blocked, grid);
      }
      // fall through to the vertical-flow branches below.
    }
    if (!horizontal) {
      // Vertical flow: leave source bottom centre, enter target top
      // centre. Fixed-receptor entry keeps every arrowhead pointing down.
      final start = _Point(
          from.x + from.width ~/ 2, from.y + from.height);
      var goal = _Point(to.x + to.width ~/ 2, to.y - 1);
      final direct = _tryStraightDown(grid, start, goal, blocked);
      if (direct != null) return direct;
      // Back edge (target above source): deterministic outer corridor
      // below every node — drop out of source bottom, run the outside
      // lane, rise into target's bottom border. The terminal segment
      // travels upward, so the arrowhead points INTO the node.
      if (to.y < from.y) {
        var laneY = 0;
        var rightMost = 0;
        var leftMost = 1 << 30;
        for (final n in graph.nodes.values) {
          laneY = math.max(laneY, n.y + n.height);
          rightMost = math.max(rightMost, n.x + n.width);
          leftMost = math.min(leftMost, n.x);
        }
        laneY += 1;
        final sy0 = from.y + from.height;
        final sx = from.x + from.width ~/ 2;
        final gy = to.y + to.height ~/ 2;
        // Source may itself sit on the bottom lane (last node): drop to
        // a level clear of everything first.
        var sy = sy0 + 1;
        for (final n in graph.nodes.values) {
          if (n.x <= sx && sx < n.x + n.width) {
            sy = math.max(sy, sy0);
          }
        }
        // Riser outside the target wall; prefer the side with headroom,
        // keep both columns inside the drawn grid.
        final rightRiser = math.min(rightMost + 1, grid.width - 1);
        final leftRiser = math.max(leftMost - 1, 0);
        for (final rx in [rightRiser, leftRiser]) {
          if (rx < 0 || rx >= grid.width) continue;
          final entryX = rx == rightRiser ? to.x + to.width : to.x - 1;
          if (entryX < 0 || entryX >= grid.width || entryX == sx) continue;
          final wps = [
            _Point(sx, sy),
            _Point(sx, laneY),
            _Point(rx, laneY),
            _Point(rx, gy),
            _Point(entryX, gy),
          ];
          // Final approach terminates ON the target's border column —
          // judge that leg open when every cell BEFORE the port is free
          // (_segmentOpen ignores the endpoint by design).
          final ok = _segmentClear(grid, wps[0], wps[1], blocked) &&
              _segmentClear(grid, wps[1], wps[2], blocked) &&
              _segmentClear(grid, wps[2], wps[3], blocked) &&
              _segmentOpen(grid, wps[3], wps[4], blocked);
          // Guard the whole polyline in one sweep (shared corners).
          if (ok) return _expand(wps);
        }
        return _findPath(
            _Point(sx, sy),
            _Point(to.x + to.width ~/ 2, to.y - 1),
            blocked,
            grid);
      }
      final bendY = math.min(start.y + 1, goal.y - 1);
      for (final by in [bendY, start.y, goal.y - 1]) {
        if (by <= start.y || by >= goal.y) continue;
        final elbow = _Point(goal.x, by);
        if (_segmentClear(grid, start, _Point(start.x, by), blocked) &&
            _segmentClear(grid, elbow, goal, blocked)) {
          return _expand([start, _Point(start.x, by), elbow, goal]);
        }
      }
      return _findPath(start, goal, blocked, grid);
    }
    // Horizontal flow: side receptors OUTSIDE the facing walls (never on
    // the blocked border cells). Flushness comes from _paintPath drawing
    // the port cells themselves, not from putting ports on the wall.
    final aheadX = from.x + from.width <= to.x;
    if (aheadX) {
      final start = _Point(from.x + from.width, from.y + from.height ~/ 2);
      final goal = _Point(to.x - 1, to.y + to.height ~/ 2);
      if (start.y == goal.y) {
        if (_segmentClear(grid, start, goal, blocked)) {
          // Same-row edge: the straight shot into the target port. It
          // owns the arrowhead; inbound edges on other rows merge into
          // its shaft with T-glyphs instead of duelling for the port.
          for (final q in _hRun(start.y, start.x, goal.x)) {
            grid.touch(q.x, q.y);
            grid.addArms(q.x, q.y, 0x3, style);
          }
          return [start, ..._hRun(start.y, start.x, goal.x), goal];
        }
      } else {
        // Z route: run horizontally PAST the source first, then drop in
        // a shared trunk beside the target. Trunk candidates are ordered
        // target-side first, so multiple inbound edges converge on one
        // riser column (schematic style) instead of each source curving
        // immediately after leaving its box.
        final trunks = <int>[
          goal.x - 1,
          goal.x - 2,
          goal.x + 1,
          start.x + 1,
          start.x - 1,
        ];
        // Port ownership is decided up front (isPortOwner): the owner
        // draws the full Z with the port leg + arrowhead even if its
        // row is off the target midline; everyone else stops on the
        // trunk at the target mid row so the junction pass can weld a
        // ┤ into the owner's shaft (or the owner's port leg — either
        // way the merge glyph sits where strokes actually cross).
        for (final bx in trunks) {
          if (bx <= start.x || bx >= goal.x) continue;
          final e1 = _Point(bx, start.y);
          final e2 = _Point(bx, goal.y);
          if (_segmentClear(grid, start, e1, blocked) &&
              _segmentClear(grid, e1, e2, blocked) &&
              _segmentClear(grid, e2, goal, blocked)) {
            if (out != null && !out.isPortOwner) {
              out.terminatesOnTrunkWithoutArrow = true;
              // Down the trunk to the target mid row, but NO port leg.
              return _expand([start, e1, _Point(bx, goal.y)]);
            }
            // _expand already includes start; a duplicate here would
            // read as a zero-length leg and paint a phantom elbow at
            // the box exit.
            return _expand([start, e1, e2, goal]);
          }
        }
      }
    }
    final startH = _anchorFor(from, to, true, isSourceEnd: true);
    final goalH = _anchorFor(to, from, true, isSourceEnd: false);
    return _findPath(startH, goalH, blocked, grid);
  }

  /// All cells between two points on a shared row/column (inclusive),
  /// walking the straight segment; null when not aligned.
  List<_Point>? _segment(_Point a, _Point b) {
    if (a.y == b.y) {
      final step = b.x > a.x ? 1 : -1;
      return [
        for (var x = a.x; x != b.x + step; x += step) _Point(x, a.y),
      ];
    }
    if (a.x == b.x) {
      final step = b.y > a.y ? 1 : -1;
      return [
        for (var y = a.y; y != b.y + step; y += step) _Point(a.x, y),
      ];
    }
    return null;
  }

  /// Expand a waypoint polyline into the full cell sequence: consecutive
  /// waypoints must share a row or column; intermediate cells and the far
  /// endpoint of each leg are included, so corners land in the path.
  List<_Point> _expand(List<_Point> waypoints) {
    final out = <_Point>[];
    for (var i = 0; i < waypoints.length - 1; i++) {
      final leg = _segment(waypoints[i], waypoints[i + 1]);
      if (leg == null) return waypoints;
      out.addAll(leg.length > 1 ? leg.sublist(1) : leg);
    }
    return [waypoints.first, ...out];
  }

  bool _segmentClear(
    _Grid grid,
    _Point a,
    _Point b,
    Set<int> blocked,
  ) {
    final cells = _segment(a, b);
    if (cells == null) return false;
    for (final p in cells) {
      if (!_free(grid, p, blocked)) return false;
    }
    return true;
  }

  /// Like [_segmentClear] but tolerates a blocked endpoint — used for
  /// final approaches that terminate ON the target's border port cell.
  bool _segmentOpen(
    _Grid grid,
    _Point a,
    _Point b,
    Set<int> blocked,
  ) {
    final cells = _segment(a, b);
    if (cells == null || cells.length < 2) return false;
    for (final p in cells.sublist(0, cells.length - 1)) {
      if (!_free(grid, p, blocked)) return false;
    }
    return true;
  }

  /// Cells of a straight vertical drop, endpoints excluded.
  List<_Point> _vDrop(int x, int y0, int y1) {
    final pts = <_Point>[];
    final step = y1 >= y0 ? 1 : -1;
    for (var y = y0 + step; step > 0 ? y < y1 : y > y1; y += step) {
      pts.add(_Point(x, y));
    }
    return pts;
  }

  /// Cells of a horizontal run, endpoints excluded.
  List<_Point> _hRun(int y, int x0, int x1) {
    final pts = <_Point>[];
    final step = x1 >= x0 ? 1 : -1;
    for (var x = x0 + step; step > 0 ? x < x1 : x > x1; x += step) {
      pts.add(_Point(x, y));
    }
    return pts;
  }

  /// Straight vertical run when both columns match and nothing blocks it.
  List<_Point>? _tryStraightDown(
    _Grid grid,
    _Point start,
    _Point goal,
    Set<int> blocked,
  ) {
    if (start.x != goal.x || goal.y <= start.y) return null;
    for (var y = start.y + 1; y < goal.y; y++) {
      if (!_free(grid, _Point(start.x, y), blocked)) return null;
    }
    return [start, ..._vDrop(start.x, start.y, goal.y), goal];
  }

  /// Compute the grid point where an edge leaves [source] (or arrives at
  /// it, when `source: false`) facing [other].
  _Point _anchorFor(
    DiagramNode source,
    DiagramNode other,
    bool horizontal, {
    required bool isSourceEnd,
  }) {
    final mine = horizontal ? source.x : source.y;
    final theirs = horizontal ? other.x : other.y;
    final ahead = mine <= theirs;
    if (horizontal) {
      return ahead
          ? _Point(source.x + source.width, source.y + source.height ~/ 2)
          : _Point(source.x - 1, source.y + source.height ~/ 2);
    }
    return ahead
        ? _Point(source.x + source.width ~/ 2, source.y + source.height)
        : _Point(source.x + source.width ~/ 2, source.y - 1);
  }

  /// Arm masks towards a neighbouring cell (matches [_lineFlags]).
  static int _armToward(_Point from, _Point to) {
    if (to.x > from.x) return 2;
    if (to.x < from.x) return 1;
    if (to.y > from.y) return 8;
    return 4;
  }

  void _paintPath(
    _Grid grid,
    List<_Point> path,
    EdgeStyle style, {
    bool suppressArrowhead = false,
  }) {
    for (var i = 0; i < path.length; i++) {
      final p = path[i];
      // The first cell (the source port) IS drawn: it sits outside the
      // box wall and must touch the border so no gap column appears.
      // The last cell carries the arrowhead (or the arrival port when
      // suppressed) and is drawn in the terminal phase below.
      if (i == path.length - 1) continue;
      final next = path[i < path.length - 1 ? i + 1 : i];
      // The source port (i == 0) has no real predecessor — treat its
      // entry direction as the direction towards next. Without this the
      // self-fallback prev makes inHoriz false and the port paints an
      // elbow right at the box exit.
      final refPrev = i > 0 ? path[i - 1] : next;
      final inHoriz = refPrev.y == p.y && refPrev.x != p.x;
      final outHoriz = next.y == p.y && next.x != p.x;

      // Direction flags entering (from refPrev) and leaving (to next).
      final enter = inHoriz
          ? (refPrev.x < p.x ? 1 : 2)
          : (refPrev.y < p.y ? 4 : 8);
      final exit = outHoriz ? (next.x > p.x ? 2 : 1) : (next.y > p.y ? 8 : 4);
      final selfArms = _armToward(p, refPrev) | _armToward(p, next);

      // Register: full arms here, plus the RECIPROCAL arm at each
      // neighbour pointing back along the same stroke — a later
      // T-junction cell can then see the stem and grow its bar to MEET
      // it. (Never mirror: that swaps axes and pollutes straight runs
      // with phantom cross arms.)
      grid.touch(p.x, p.y);
      grid.addArms(p.x, p.y, selfArms, style);
      void mate(_Point q) =>
          grid.addArms(q.x, q.y, _armToward(q, p), style);
      mate(refPrev);
      mate(next);

      // A turn combines one horizontal and one vertical arm; straight
      // runs stay plain lines. Dotted edges keep their dash glyphs.
      final isTurn = inHoriz != outHoriz;
      if (style.isDotted) {
        grid.set(p.x, p.y, inHoriz ? g.dottedH : g.dottedV);
      } else {
        final straightGlyph = inHoriz ?
            (style.isThick ? g.thickH : g.hLine) :
            (style.isThick ? g.thickV : g.vLine);
        grid.set(
            p.x, p.y, isTurn ? _elbow(style, enter | exit) : straightGlyph);
      }
    }

    // Arrowhead at the goal end; both endpoints are sealed afterwards so
    // the junction pass never redraws ink that abuts a node border.
    if (style.isArrow && !suppressArrowhead && path.length >= 2) {
      final last = path.last;
      final beforeLast = path[path.length - 2];
      String head;
      if (last.x > beforeLast.x) {
        head = g.arrowRight;
      } else if (last.x < beforeLast.x) {
        head = g.arrowLeft;
      } else if (last.y > beforeLast.y) {
        head = g.arrowDown;
      } else {
        head = g.arrowUp;
      }
      grid.set(last.x, last.y, head);
    }
    if (path.isNotEmpty) {
      final first = path.first;
      final last = path.last;
      grid.protect(first.x, first.y);
      // A suppressed tip is a trunk crossing cell — it MUST stay open to
      // the junction pass so other strokes' arms can weld a T there.
      if (!suppressArrowhead) grid.protect(last.x, last.y);
    }
  }

  /// Elbow glyph for a turn cell given its arm bitmask (same encoding as
  /// [_Grid._lineFlags]: 1=left 2=right 4=up 8=down).
  String _elbow(EdgeStyle style, int arms) {
    final hasR = (arms & 2) != 0;
    final hasD = (arms & 8) != 0;
    if (style.isThick) {
      if (hasD) return hasR ? g.heavyTL : g.heavyTR;
      return hasR ? g.heavyBL : g.heavyBR;
    }
    if (hasD) return hasR ? g.roundTL : g.roundTR;
    return hasR ? g.roundBL : g.roundBR;
  }

  /// Rebuild every edge-touched cell from the merged arm registers.
  ///
  /// Runs once after all edges are painted, so shared cells merge into
  /// proper junction glyphs instead of whichever edge painted last:
  /// - protected cells (arrowheads, node-adjacent endpoints) stay put;
  /// - one horizontal + one vertical arm → keep the rounded elbow the
  ///   stroke pass chose (pure turns only — Unicode has no rounded T);
  /// - anything else (T, cross, straightened residue) → recomposed from
  ///   the weight-appropriate junction table so half-arm stubs from
  ///   adjacent edges grow bars that MEET each other.
  void _composeJunctions(_Grid grid) {
    const keepUnwritten = {
      '─', '│', '┄', '┆', '═', '║', '+',
      '╭', '╮', '╰', '╯', '┏', '┓', '┗', '┛',
      '┌', '┐', '└', '┘', '┬', '┴', '├', '┤', '┼',
      '┳', '┻', '┣', '┫', '╋',
    };
    for (var y = 0; y < grid.height; y++) {
      for (var x = 0; x < grid.width; x++) {
        if (!grid.isTouched(x, y) || grid.isProtected(x, y)) continue;
        // Only rewrite cells that ALREADY carry stroke ink: blank
        // neighbours collect spurious half-arm registrations (mate()
        // stamps outside the stroke), and label characters may likewise
        // sit on registered-but-empty cells — neither may be regenerated.
        final cur = grid.get(x, y);
        if (!keepUnwritten.contains(cur)) continue;
        final f = grid.arms(x, y);
        if (f == 0) continue;
        final popCount = switch (f) {
          0 => 0,
          _ => (f & 1) + ((f >> 1) & 1) + ((f >> 2) & 1) + ((f >> 3) & 1),
        };
        const hBits = 0x3, vBits = 0xC;
        final isTurnShape =
            (f & hBits) != 0 && (f & vBits) != 0 && popCount == 2;
        if (isTurnShape) continue; // stroke pass already drew the elbow
        final table = grid.armsAllDotted(x, y)
            ? g.junctionDotted
            : grid.armsAnyHeavy(x, y)
                ? g.junctionHeavy
                : g.junctionGlyphs;
        final glyph = table[f];
        if (glyph != null) grid.set(x, y, glyph);
      }
    }
  }

  /// Place [label] near the middle of [path]. Multi-line labels render
  /// as stacked rows (all sharing one anchor row, anchored on the path
  /// side); single-line keeps the old beside/above behaviour.
  void _paintLabel(_Grid grid, List<_Point> path, String label) {
    if (path.length < 3) return;
    final rows = label.split('\n');
    final w =
        rows.map(displayWidthOf).fold(0, math.max);
    final midIdx = path.length ~/ 2;
    final mid = path[midIdx];
    final prev = path[midIdx - 1];

    // Vertical segment → label sits left of the line; horizontal → above.
    // Clamp inside the grid; prefer whichever side actually fits.
    final candidates = prev.x == mid.x
        ? [
            _Point(math.max(0, mid.x - w - 1), mid.y),
            _Point(mid.x + 2, mid.y),
            _Point(math.max(0, mid.x - w - 1), mid.y - 1),
            _Point(mid.x + 2, mid.y - 1),
          ]
        : [
            _Point(math.max(0, mid.x - w ~/ 2), mid.y - 1),
            _Point(math.max(0, mid.x - w ~/ 2), mid.y + 1),
            _Point(mid.x + 2, mid.y),
            _Point(math.max(0, mid.x - w - 2), mid.y),
          ];

    bool place(_Point c) {
      // Every row must fit; rows stack downward and stay in bounds.
      for (var r = 0; r < rows.length; r++) {
        final y = c.y + r;
        if (!grid.inBounds(c.x, y) || !_areaFree(grid, c.x, y, w)) {
          return false;
        }
      }
      for (var r = 0; r < rows.length; r++) {
        _writeText(grid, c.x, c.y + r, rows[r]);
      }
      return true;
    }

    for (final c in candidates) {
      if (place(c)) return;
    }
    // Fall back to scanning along the path for any free row.
    for (var i = 1; i < path.length - 1; i++) {
      final p = path[i];
      for (final dy in [-1, 1]) {
        final lx = math.max(0, p.x - w ~/ 2);
        if (place(_Point(lx, p.y + dy))) return;
      }
    }
    // Last resort: sit ON the corridor, overwriting plain line glyphs
    // only — a readable label beats an unbroken line, but never stomp
    // arrows, node borders, elbows or other text.
    for (final c in candidates.followedBy([
      for (var i = 1; i < path.length - 1; i++)
        _Point(math.max(0, path[i].x - w ~/ 2), path[i].y),
    ])) {
      var overwriteOk = true;
      for (var r = 0; r < rows.length && overwriteOk; r++) {
        for (var dx = 0; dx < w; dx++) {
          final ch = grid.get(c.x + dx, c.y + r);
          if (ch != ' ' &&
              !_isPlainLineGlyph(ch) &&
              !grid.isProtected(c.x + dx, c.y + r)) {
            overwriteOk = false;
            break;
          }
        }
      }
      if (!overwriteOk) continue;
      for (var r = 0; r < rows.length; r++) {
        _writeText(grid, c.x, c.y + r, rows[r]);
      }
      return;
    }
    // Nowhere free: drop the label rather than corrupt the drawing.
  }

  bool _isPlainLineGlyph(String ch) => const {
        '─', '│', '┄', '┆', '═', '║',
      }.contains(ch);

  bool _areaFree(_Grid grid, int x, int y, int width) {
    for (var dx = -1; dx <= width; dx++) {
      if (!grid.inBounds(x + dx, y)) return false;
      if (grid.get(x + dx, y) != ' ') return false;
    }
    return true;
  }

  /// A* over 4-connected free cells. Nodes are obstacles except their
  /// border-adjacent entry/exit points.
  List<_Point>? _findPath(
    _Point start,
    _Point goal,
    Set<int> blocked,
    _Grid grid,
  ) {
    if (!_free(grid, start, blocked) || !_free(grid, goal, blocked)) {
      return null;
    }
    final open = HeapPriorityQueue<_AStarNode>((a, b) {
      final byF = a.f.compareTo(b.f);
      return byF != 0 ? byF : a.serial.compareTo(b.serial);
    });
    final cameFrom = <_Point, _Point>{};
    final gScore = <_Point, int>{};
    gScore[start] = 0;
    var serial = 0;
    open.add(_AStarNode(start, _heuristic(start, goal), serial++));

    while (open.isNotEmpty) {
      final current = open.removeFirst().pos;
      if (current == goal) {
        final path = <_Point>[current];
        var pos = current;
        while (cameFrom.containsKey(pos)) {
          pos = cameFrom[pos]!;
          path.add(pos);
        }
        return path.reversed.toList();
      }
      for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final nx = current.x + dx;
        final ny = current.y + dy;
        final np = _Point(nx, ny);
        if (!_free(grid, np, blocked)) continue;
        // Occupied ink costs extra so detours around earlier strokes
        // beat ploughing through their corridors.
        final cost =
            grid.isTouched(nx, ny) || grid.get(nx, ny) != ' ' ? 4 : 1;
        final tentative = gScore[current]! + cost;
        if (tentative < (gScore[np] ?? 1 << 30)) {
          cameFrom[np] = current;
          gScore[np] = tentative;
          open.add(_AStarNode(np, tentative + _heuristic(np, goal), serial++));
        }
      }
    }
    return null;
  }

  static int _heuristic(_Point a, _Point b) =>
      (a.x - b.x).abs() + (a.y - b.y).abs();

  bool _free(_Grid grid, _Point p, Set<int> blocked) {
    if (!grid.inBounds(p.x, p.y)) return false;
    return !blocked.contains(p.y * grid.width + p.x);
  }
}

class _RouteOut {
  /// Router reports: this arrival terminates ON the trunk (off-midline
  /// Z route), so the caller must not paint an arrowhead at the tip.
  bool terminatesOnTrunkWithoutArrow = false;

  /// Set by the caller before routing: did THIS edge win port ownership
  /// for the target? The owner always draws the full port leg.
  bool isPortOwner = true;
}

class _Point {
  final int x;
  final int y;
  const _Point(this.x, this.y);

  @override
  bool operator ==(Object other) => other is _Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

class _AStarNode {
  final _Point pos;
  final int f;
  final int serial; // insertion order — deterministic tie-breaking
  _AStarNode(this.pos, this.f, this.serial);
}

/// Minimal binary-heap priority queue (avoids adding package deps).
class HeapPriorityQueue<T> {
  final int Function(T, T) compare;
  final List<T> _heap = [];

  HeapPriorityQueue(this.compare);

  bool get isNotEmpty => _heap.isNotEmpty;

  void add(T item) {
    _heap.add(item);
    var i = _heap.length - 1;
    while (i > 0) {
      final parent = (i - 1) ~/ 2;
      if (compare(_heap[i], _heap[parent]) >= 0) break;
      _swap(i, parent);
      i = parent;
    }
  }

  T removeFirst() {
    final first = _heap[0];
    final last = _heap.removeLast();
    if (_heap.isNotEmpty) {
      _heap[0] = last;
      var i = 0;
      while (true) {
        final l = i * 2 + 1;
        final r = i * 2 + 2;
        var smallest = i;
        if (l < _heap.length && compare(_heap[l], _heap[smallest]) < 0) {
          smallest = l;
        }
        if (r < _heap.length && compare(_heap[r], _heap[smallest]) < 0) {
          smallest = r;
        }
        if (smallest == i) break;
        _swap(i, smallest);
        i = smallest;
      }
    }
    return first;
  }

  void _swap(int a, int b) {
    final t = _heap[a];
    _heap[a] = _heap[b];
    _heap[b] = t;
  }
}

/// Thin wrapper so the renderer can measure grapheme widths without
/// importing nocterm internals in every file.
class UnicodeWidthHelper {
  static int width(String grapheme) => displayWidthOf(grapheme);
}

String renderDiagramGraph(DiagramGraph graph, DiagramRenderOptions options) {
  return DiagramRenderer(graph, options).render();
}
