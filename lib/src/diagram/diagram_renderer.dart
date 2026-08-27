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

  _Grid(this.width, this.height)
      : cells = List.filled(width * height, ' '),
        _lineFlags = List.filled(width * height, 0);

  bool inBounds(int x, int y) => x >= 0 && x < width && y >= 0 && y < height;

  String get(int x, int y) => inBounds(x, y) ? cells[y * width + x] : ' ';

  void set(int x, int y, String c) {
    if (inBounds(x, y)) cells[y * width + x] = c;
  }

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
    const labelRoom = 2;
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

    for (final edge in graph.edges) {
      _drawEdge(grid, edge, blocked);
    }

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
    Set<int> blocked,
  ) {
    final from = graph.nodes[edge.from];
    final to = graph.nodes[edge.to];
    if (from == null || to == null) return;

    final horizontal = graph.direction.isHorizontal;
    // Circles are single-row pills: always anchor to their left/right
    // sides so arrows touch the glyph instead of floating above it.
    final start = _anchorFor(from, to, horizontal, isSourceEnd: true);
    final goal = _anchorFor(to, from, horizontal, isSourceEnd: false);

    final path = _findPath(start, goal, blocked, grid);
    if (path == null) return;

    _paintPath(grid, path, edge.style, start, goal);

    if (edge.label != null && edge.label!.isNotEmpty) {
      _paintLabel(grid, path, edge.label!);
    }
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

  void _paintPath(
    _Grid grid,
    List<_Point> path,
    EdgeStyle style,
    _Point start,
    _Point goal,
  ) {
    for (var i = 0; i < path.length; i++) {
      final p = path[i];
      if (p == start || p == goal) continue;
      final prev = path[i > 0 ? i - 1 : 0];
      final next = path[i < path.length - 1 ? i + 1 : i];
      final isHorizMove = prev.y == next.y;

      if (isHorizMove) {
        grid.set(p.x, p.y, style.isDotted ? g.dottedH :
            style.isThick ? g.thickH : g.hLine);
      } else {
        grid.set(p.x, p.y, style.isDotted ? g.dottedV :
            style.isThick ? g.thickV : g.vLine);
      }
    }

    // Arrowhead at the goal end.
    if (style.isArrow && path.length >= 2) {
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
  }

  /// Place [label] near the middle of [path] without overwriting any
  /// existing glyph: tries beside/above/below the midpoint, then scans
  /// outward along the path.
  void _paintLabel(_Grid grid, List<_Point> path, String label) {
    if (path.length < 3) return;
    final w = displayWidthOf(label);
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

    for (final c in candidates) {
      if (_areaFree(grid, c.x, c.y, w)) {
        _writeText(grid, c.x, c.y, label);
        return;
      }
    }
    // Fall back to scanning along the path for any free row.
    for (var i = 1; i < path.length - 1; i++) {
      final p = path[i];
      for (final dy in [-1, 1]) {
        final lx = math.max(0, p.x - w ~/ 2);
        if (_areaFree(grid, lx, p.y + dy, w)) {
          _writeText(grid, lx, p.y + dy, label);
          return;
        }
      }
    }
    // Nowhere free: drop the label rather than corrupt the drawing.
  }

  bool _areaFree(_Grid grid, int x, int y, int width) {
    for (var dx = -1; dx <= width; dx++) {
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
        final tentative = gScore[current]! + 1;
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
