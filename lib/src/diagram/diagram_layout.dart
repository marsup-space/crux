import 'dart:math' as math;

import 'package:characters/characters.dart';

// Markdown text rendering needs nocterm's internal unicode-width helpers to
// measure CJK and emoji segments for wrapping. Not re-exported publicly.
// ignore_for_file: implementation_imports
import 'package:nocterm/src/utils/unicode_width.dart';

import 'diagram_model.dart';

/// Sentinel for "no value yet" in min-tracking over ints.
const int _intMax = 1 << 62;

/// Layered layout for [DiagramGraph]: size nodes, topologically layer them
/// (breaking cycles deterministically), assign grid coordinates, and
/// compute subgraph bounding boxes.
///
/// Mutates node/subgraph geometry in place and appends warnings (cycle
/// detection) to `graph.warnings`.
const int _minNodeWidth = 5;
const int _nodeHeight = 3;
const int _minGap = 2;
const int _subgraphPadding = 2;

int displayWidthOf(String text) {
  var w = 0;
  for (final grapheme in text.characters) {
    w += UnicodeWidth.graphemeWidth(grapheme);
  }
  return w;
}

void computeLayout(DiagramGraph graph, DiagramRenderOptions options) {
  _sizeNodes(graph);
  final layers = _assignLayers(graph);
  var (hGap, vGap) = _calculateGaps(graph, layers, options);
  _assignCoordinates(graph, layers, hGap, vGap);
  _computeSubgraphBounds(graph);
  _separateSiblingSubgraphs(graph);
  // Last-resort width fit: shrink node padding, then truncate the widest
  // label lines, until the whole drawing fits the budget. Diagram rows are
  // never wrapped downstream (wrapping tears the boxes), so the layout
  // itself must guarantee the fit.
  _fitWidth(graph, layers, options, hGap, vGap);
}

/// Shrink the drawing until its total width fits [options.maxWidth].
///
/// Pass 1: re-layout with tighter node padding (labels lose their
/// centering slack). Pass 2: truncate the widest label line per node
/// (appending `…`) and re-layout. Diagram rows are never wrapped by the
/// text renderer — a wrapped row tears box borders — so this is the only
/// place the width budget can be enforced.
void _fitWidth(
  DiagramGraph graph,
  Map<String, int> layers,
  DiagramRenderOptions options,
  int hGap,
  int vGap,
) {
  final maxWidth = options.maxWidth;
  if (maxWidth == null) return;

  // The renderer adds a small left pad (labelRoom=2) and the grid keeps
  // a right pad; subtract both so the budget matches the final drawing.
  const renderOverhead = 4;
  final budget = math.max(20, maxWidth - renderOverhead);

  int totalWidth() {
    var maxX = 0;
    for (final n in graph.nodes.values) {
      maxX = math.max(maxX, n.x + n.width);
    }
    for (final sg in graph.subgraphs) {
      if (sg.width > 0) maxX = math.max(maxX, sg.x + sg.width);
    }
    return maxX;
  }

  // Pass 1: tighter node padding (labels hug their borders).
  if (totalWidth() > budget) {
    _sizeNodes(graph, tightPadding: true);
    _assignCoordinates(graph, layers, hGap, vGap);
    _computeSubgraphBounds(graph);
    _separateSiblingSubgraphs(graph);
  }

  // Pass 2: greedily truncate the WIDEST node's widest line, one node
  // per round, until it fits (or nothing left to trim). Trimming only
  // the widest offender keeps short labels intact.
  var guard = 0;
  while (totalWidth() > budget && guard++ < 64) {
    DiagramNode? widestNode;
    var widestLine = 0;
    for (final n in graph.nodes.values) {
      for (final l in n.label.split('\n')) {
        final w = displayWidthOf(l);
        if (w > widestLine) {
          widestLine = w;
          widestNode = n;
        }
      }
    }
    if (widestNode == null || !_truncateWidestLine(widestNode)) break;
    _assignCoordinates(graph, layers, hGap, vGap);
    _computeSubgraphBounds(graph);
    _separateSiblingSubgraphs(graph);
  }
}

/// Shorten [node]'s widest label line by one grapheme (plus an ellipsis
/// on first trim). Returns false when nothing can be trimmed further.
bool _truncateWidestLine(DiagramNode node) {
  final lines = node.label.split('\n');
  var widestIdx = -1;
  var widest = 0;
  for (var i = 0; i < lines.length; i++) {
    final w = displayWidthOf(lines[i]);
    if (w > widest) {
      widest = w;
      widestIdx = i;
    }
  }
  if (widestIdx < 0 || widest <= 4) return false;
  final chars = lines[widestIdx].characters.toList();
  final hadEllipsis = chars.isNotEmpty && chars.last == '…';
  if (hadEllipsis && chars.length <= 5) return false;
  // Remove trailing graphemes until at least 2 columns are freed.
  var removed = 0;
  while (chars.length > (hadEllipsis ? 5 : 1) && removed < 2) {
    final last = chars.removeLast();
    removed += UnicodeWidth.graphemeWidth(last);
  }
  if (chars.isEmpty) return false;
  if (!hadEllipsis) chars.add('…');
  lines[widestIdx] = chars.join();
  node.label = lines.join('\n');
  // Re-measure the node from its (now shorter) label.
  _sizeOneNode(node, tightPadding: true);
  return true;
}

void _sizeOneNode(DiagramNode node, {bool tightPadding = false}) {
  final lines = node.label.split('\n');
  var maxLine = 0;
  for (final l in lines) {
    maxLine = math.max(maxLine, displayWidthOf(l));
  }
  // Padding is the label slack INSIDE the two border columns; the node
  // width always includes both borders, so the minimum is maxLine + 2.
  // tightPadding=1 keeps one slack column; 2 keeps the comfortable two.
  final padding = (tightPadding ? 1 : 2) + 2;
  node.width = math.max(maxLine + padding, _minNodeWidth);
  node.height = lines.length > 1 ? lines.length + 2 : _nodeHeight;
  if (node.shape == NodeShape.diamond) {
    node.width += 2;
    node.height = math.max(node.height, 3);
  }
  if (node.shape == NodeShape.cylinder) {
    node.height = math.max(node.height, 5);
  }
  if (node.shape == NodeShape.circle) {
    node.width = math.max(node.width, 3);
    node.height = math.max(node.height, 3);
  }
}

/// Node-level layout ignores containers, so sibling subgraphs can end up
/// overlapping. Push colliding siblings apart along the flow axis
/// (downwards for TB, rightwards for LR); ancestor/descendant pairs are
/// left nested on purpose.
void _separateSiblingSubgraphs(DiagramGraph graph) {
  for (var pass = 0; pass <= graph.subgraphs.length; pass++) {
    var anyShift = false;
    final sgs = graph.subgraphs.where((s) => s.width > 0).toList()
      ..sort((a, b) => a.y != b.y ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
    for (var i = 0; i < sgs.length; i++) {
      for (var j = i + 1; j < sgs.length; j++) {
        final a = sgs[i];
        final b = sgs[j];
        if (_isAncestor(graph, a, b) || _isAncestor(graph, b, a)) continue;
        if (!(_rectsOverlap(a, b))) continue;
        final verticalFlow = !graph.direction.isHorizontal;
        final dy = verticalFlow ? a.y + a.height + 1 - b.y : 0;
        final dx = verticalFlow ? 0 : a.x + a.width + 1 - b.x;
        if (dy > 0 || dx > 0) {
          _shiftSubgraph(graph, b, dy, dx);
          anyShift = true;
        }
      }
    }
    if (!anyShift) break;
    _computeSubgraphBounds(graph);
  }
}

bool _isAncestor(
  DiagramGraph graph,
  DiagramSubgraph ancestor,
  DiagramSubgraph node,
) {
  var parent = node.parent;
  var guard = 0;
  while (parent != null && guard++ < 64) {
    if (parent == ancestor.id) return true;
    DiagramSubgraph? next;
    for (final s in graph.subgraphs) {
      if (s.id == parent) {
        next = s;
        break;
      }
    }
    if (next == null) return false;
    parent = next.parent;
  }
  return false;
}

bool _rectsOverlap(DiagramSubgraph a, DiagramSubgraph b) {
  return a.x < b.x + b.width &&
      b.x < a.x + a.width &&
      a.y < b.y + b.height &&
      b.y < a.y + a.height;
}

void _shiftSubgraph(DiagramGraph graph, DiagramSubgraph sg, int dy, int dx) {
  // Collect every node whose subgraph chain contains [sg].
  final descendants = <String>{
    for (final s in graph.subgraphs)
      if (_chainContains(s, sg.id, graph)) s.id,
  };
  for (final node in graph.nodes.values) {
    if (node.subgraphId != null && descendants.contains(node.subgraphId)) {
      node.y += dy;
      node.x += dx;
    }
  }
}

bool _chainContains(DiagramSubgraph sg, String ancestorId, DiagramGraph graph) {
  if (sg.id == ancestorId) return true;
  var current = sg;
  var guard = 0;
  while (current.parent != null && guard++ < 64) {
    if (current.parent == ancestorId) return true;
    DiagramSubgraph? next;
    for (final s in graph.subgraphs) {
      if (s.id == current.parent) {
        next = s;
        break;
      }
    }
    if (next == null) return false;
    current = next;
  }
  return false;
}

void _sizeNodes(DiagramGraph graph, {bool tightPadding = false}) {
  for (final node in graph.nodes.values) {
    _sizeOneNode(node, tightPadding: tightPadding);
  }
}

/// Kahn's algorithm with deterministic cycle breaking: when the queue
/// drains with nodes remaining, force-process the stuck node that appears
/// earliest as an edge source (preserving the author's flow direction).
Map<String, int> _assignLayers(DiagramGraph graph) {
  final nodeLayers = <String, int>{};
  final inDegree = <String, int>{};
  final processed = <String>{};

  for (final id in graph.nodes.keys) {
    inDegree[id] = 0;
    nodeLayers[id] = 0;
  }
  for (final edge in graph.edges) {
    if (!inDegree.containsKey(edge.to)) continue;
    inDegree[edge.to] = inDegree[edge.to]! + 1;
  }

  // First-appearance-as-source index for deterministic cycle breaking.
  final firstFromIdx = <String, int>{};
  for (var i = 0; i < graph.edges.length; i++) {
    firstFromIdx.putIfAbsent(graph.edges[i].from, () => i);
  }

  // Edges whose cycles are intentional (state-diagram transitions) do not
  // participate in cycle warnings.
  final warnedEdges = graph.edges.where((e) => !e.semanticCycle).toList();

  final queue = <String>[];
  final zeroIn = inDegree.entries.where((e) => e.value == 0).map((e) => e.key).toList()
    ..sort();
  queue.addAll(zeroIn);

  final cycleNodes = <String>{};

  while (true) {
    while (queue.isNotEmpty) {
      final u = queue.removeAt(0);
      if (processed.contains(u)) continue;
      processed.add(u);
      final neighbors = <String>{
        for (final e in graph.edges)
          if (e.from == u && !processed.contains(e.to)) e.to,
      }.toList()
        ..sort();
      for (final v in neighbors) {
        final uLayer = nodeLayers[u] ?? 0;
        nodeLayers[v] = math.max(nodeLayers[v] ?? 0, uLayer + 1);
        final deg = inDegree[v]!;
        if (deg > 0) inDegree[v] = deg - 1;
        if (inDegree[v] == 0 && !processed.contains(v)) queue.add(v);
      }
    }
    if (processed.length >= graph.nodes.length) break;

    // Cycle: collect stuck nodes that have outgoing edges to stuck nodes.
    final stuck = inDegree.keys
        .where((id) => !processed.contains(id))
        .toList()
      ..sort();
    final stuckSet = stuck.toSet();
    for (final n in stuck) {
      final hasOutgoingToStuck = warnedEdges
          .any((e) => e.from == n && stuckSet.contains(e.to));
      if (hasOutgoingToStuck) cycleNodes.add(n);
    }
    stuck.sort((a, b) {
      final fa = firstFromIdx[a] ?? _intMax;
      final fb = firstFromIdx[b] ?? _intMax;
      return fa != fb ? fa.compareTo(fb) : a.compareTo(b);
    });
    if (stuck.isEmpty) break;
    inDegree[stuck.first] = 0;
    queue.add(stuck.first);
  }

  if (cycleNodes.isNotEmpty) {
    final sorted = cycleNodes.toList()..sort();
    graph.warnings.add(CycleWarning(sorted));
  }
  return nodeLayers;
}

(int, int) _calculateGaps(
  DiagramGraph graph,
  Map<String, int> layers,
  DiagramRenderOptions options,
) {
  // Tight defaults: 8/4 left awkward blank rows between arrows and nodes
  // in chain diagrams. vGap=3 gives an edge exactly one shaft row plus
  // the arrowhead row — no blank line between box and arrow.
  final hGap = 4;
  final vGap = 3;
  final maxWidth = options.maxWidth;
  if (maxWidth == null) return (hGap, vGap);

  final byLayer = <int, List<String>>{};
  var maxLayer = 0;
  layers.forEach((id, layer) {
    byLayer.putIfAbsent(layer, () => []).add(id);
    maxLayer = math.max(maxLayer, layer);
  });
  for (final list in byLayer.values) {
    list.sort();
  }

  // Horizontal layouts spend budget left-to-right; vertical ones spend
  // it within a layer (nodes side by side). Both can overflow.
  var totalWidth = 0;
  if (graph.direction.isHorizontal) {
    for (var l = 0; l <= maxLayer; l++) {
      final ids = byLayer[l] ?? const [];
      var layerMax = 0;
      for (final id in ids) {
        layerMax = math.max(layerMax, graph.nodes[id]?.width ?? 0);
      }
      totalWidth += layerMax;
    }
    totalWidth += maxLayer * hGap;
    if (totalWidth > maxWidth && maxLayer > 0) {
      final nodeWidth = totalWidth - maxLayer * hGap;
      final availableForGaps = math.max(0, maxWidth - nodeWidth);
      final newGap = math.max(_minGap, availableForGaps ~/ maxLayer);
      return (newGap, vGap);
    }
  } else {
    for (var l = 0; l <= maxLayer; l++) {
      final ids = byLayer[l] ?? const [];
      var layerTotal = 0;
      for (final id in ids) {
        layerTotal += (graph.nodes[id]?.width ?? 0) + hGap;
      }
      totalWidth = math.max(totalWidth, math.max(0, layerTotal - hGap));
    }
    if (totalWidth > maxWidth) {
      // Vertical flow: shrink the horizontal gap between side-by-side
      // nodes; the vertical gap stays (it separates flow steps).
      return (math.min(hGap, _minGap), vGap);
    }
  }
  return (hGap, vGap);
}

void _assignCoordinates(
  DiagramGraph graph,
  Map<String, int> nodeLayers,
  int hGap,
  int vGap,
) {
  final direction = graph.direction;
  final byLayer = <int, List<String>>{};
  var maxLayer = 0;
  nodeLayers.forEach((id, layer) {
    byLayer.putIfAbsent(layer, () => []).add(id);
    maxLayer = math.max(maxLayer, layer);
  });
  for (final list in byLayer.values) {
    list.sort();
  }

  final layerWidths = <int, int>{};
  final layerHeights = <int, int>{};
  for (var l = 0; l <= maxLayer; l++) {
    final ids = byLayer[l] ?? const [];
    var maxW = 0;
    var maxH = 0;
    var totalW = 0;
    var totalH = 0;
    for (final id in ids) {
      final n = graph.nodes[id]!;
      maxW = math.max(maxW, n.width);
      maxH = math.max(maxH, n.height);
      totalW += n.width + hGap;
      totalH += n.height + vGap;
    }
    if (direction.isHorizontal) {
      layerWidths[l] = maxW;
      layerHeights[l] = math.max(0, totalH - vGap);
    } else {
      layerWidths[l] = math.max(0, totalW - hGap);
      layerHeights[l] = maxH;
    }
  }

  final maxTotalWidth = layerWidths.values.fold(0, math.max);
  final maxTotalHeight = layerHeights.values.fold(0, math.max);

  if (direction.isHorizontal) {
    var currentX = 0;
    for (var l = 0; l <= maxLayer; l++) {
      final layerIdx =
          direction == DiagramDirection.rightToLeft ? maxLayer - l : l;
      final ids = byLayer[layerIdx] ?? const [];
      final layerH = layerHeights[layerIdx] ?? 0;
      var startY = math.max(0, (maxTotalHeight - layerH)) ~/ 2;
      for (final id in ids) {
        final node = graph.nodes[id]!;
        node.x = currentX;
        node.y = startY;
        startY += node.height + vGap;
      }
      currentX += (layerWidths[layerIdx] ?? 0) + hGap;
    }
  } else {
    var currentY = 0;
    for (var l = 0; l <= maxLayer; l++) {
      final layerIdx =
          direction == DiagramDirection.bottomToTop ? maxLayer - l : l;
      final ids = byLayer[layerIdx] ?? const [];
      final layerW = layerWidths[layerIdx] ?? 0;
      var startX = math.max(0, (maxTotalWidth - layerW)) ~/ 2;
      for (final id in ids) {
        final node = graph.nodes[id]!;
        node.x = startX;
        node.y = currentY;
        startX += node.width + hGap;
      }
      currentY += (layerHeights[layerIdx] ?? 0) + vGap;
    }
  }
}

void _computeSubgraphBounds(DiagramGraph graph) {
  final count = graph.subgraphs.length;
  final processed = <String>{};
  final hasChildren = <String>{
    for (final sg in graph.subgraphs)
      if (sg.parent != null) sg.parent!,
  };

  // Leaf-first passes until stable (handles arbitrary nesting depth).
  for (var pass = 0; pass <= count; pass++) {
    for (final sg in graph.subgraphs) {
      if (processed.contains(sg.id)) continue;
      final childrenDone = graph.subgraphs
          .where((c) => c.parent == sg.id)
          .every((c) => processed.contains(c.id));
      if (!childrenDone) continue;

      var minX = _intMax;
      var minY = _intMax;
      var maxX = 0;
      var maxY = 0;
      for (final nodeId in sg.nodes) {
        final n = graph.nodes[nodeId];
        if (n == null) continue;
        minX = math.min(minX, n.x);
        minY = math.min(minY, n.y);
        maxX = math.max(maxX, n.x + n.width);
        maxY = math.max(maxY, n.y + n.height);
      }
      for (final child in graph.subgraphs) {
        if (child.parent != sg.id) continue;
        if (child.width <= 0 || child.height <= 0) continue;
        minX = math.min(minX, child.x);
        minY = math.min(minY, child.y);
        maxX = math.max(maxX, child.x + child.width);
        maxY = math.max(maxY, child.y + child.height);
      }
      if (minX != _intMax) {
        // Keep negative offsets intact — the renderer shifts the whole
        // scene into positive coordinates; clamping here would break the
        // wall-to-node padding relationship.
        sg.x = minX - _subgraphPadding;
        sg.y = minY - _subgraphPadding - 1;
        sg.width = (maxX - minX) + _subgraphPadding * 2;
        sg.height = (maxY - minY) + _subgraphPadding * 2 + 1;
      }
      processed.add(sg.id);
    }
    if (processed.length >= count) break;
  }
  // Silence unused warning for hasChildren (kept for clarity of the
  // leaf-first invariant).
  assert(hasChildren.isNotEmpty || count == 0 || true);
}
