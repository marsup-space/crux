/// Core data model shared by every diagram front-end (Mermaid flowchart,
/// Mermaid state diagram, D2) and the layout/render back-end.
///
/// All three syntaxes normalize into one [DiagramGraph]; layout and
/// rendering only ever see this model.
library;

/// Flow direction of the whole diagram.
enum DiagramDirection {
  leftToRight,
  rightToLeft,
  topToBottom,
  bottomToTop;

  bool get isHorizontal =>
      this == DiagramDirection.leftToRight ||
      this == DiagramDirection.rightToLeft;

  static DiagramDirection parse(String raw) {
    switch (raw.trim().toUpperCase()) {
      case 'LR':
        return DiagramDirection.leftToRight;
      case 'RL':
        return DiagramDirection.rightToLeft;
      case 'BT':
        return DiagramDirection.bottomToTop;
      case 'TB':
      case 'TD':
      default:
        return DiagramDirection.topToBottom;
    }
  }
}

/// Visual shape of a node. Only shapes that carry meaning in a character
/// grid get distinct drawings; exotic D2 shapes degrade to rounded boxes.
enum NodeShape {
  /// `[label]`
  rectangle,

  /// `(label)`
  rounded,

  /// `((label))` / start-end markers
  circle,

  /// `{label}` — decision points
  diamond,

  /// `[(label)]` / `db.shape: cylinder`
  cylinder,

  /// Everything else (stadium, hexagon, cloud, person, …)
  generic,
}

/// Line style of an edge.
enum EdgeStyle {
  solidArrow,
  solidLine,
  dottedArrow,
  dottedLine,
  thickArrow,
  thickLine;

  bool get isArrow =>
      this == EdgeStyle.solidArrow ||
      this == EdgeStyle.dottedArrow ||
      this == EdgeStyle.thickArrow;

  bool get isDotted =>
      this == EdgeStyle.dottedArrow || this == EdgeStyle.dottedLine;

  bool get isThick =>
      this == EdgeStyle.thickArrow || this == EdgeStyle.thickLine;
}

/// A group box drawn behind a set of nodes (mermaid `subgraph`,
/// state-diagram composite state, D2 container).
class DiagramSubgraph {
  final String id;
  final String label;
  final String? parent;

  /// Member node ids (direct members only, not descendants).
  final List<String> nodes = [];

  /// Computed bounds in grid coordinates (layout fills these in).
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;

  DiagramSubgraph({required this.id, required this.label, this.parent});
}

/// A positioned, sized node. Layout mutates [x]/[y]/[width]/[height].
class DiagramNode {
  final String id;
  String label;
  NodeShape shape;
  String? subgraphId;

  int width = 0;
  int height = 0;
  int x = 0;
  int y = 0;

  DiagramNode({
    required this.id,
    required this.label,
    this.shape = NodeShape.rectangle,
    this.subgraphId,
  });
}

/// A directed (or undirected) connection between two nodes.
class DiagramEdge {
  final String from;
  final String to;
  final String? label;
  final EdgeStyle style;

  /// True when this edge is a state-diagram self-transition or back-edge
  /// that carries normal semantics (no cycle warning should be raised).
  ///
  /// Set by parsers whose syntax makes cycles intentional (state
  /// diagrams); flowchart/D2 leave it false.
  final bool semanticCycle;

  DiagramEdge({
    required this.from,
    required this.to,
    this.label,
    this.style = EdgeStyle.solidArrow,
    this.semanticCycle = false,
  });
}

/// Structured warning produced while parsing or laying out.
sealed class DiagramWarning {
  String message({
    String Function(String nodes)? cycleDetected,
    String Function(String feature)? unsupportedFeature,
  });
}

class CycleWarning extends DiagramWarning {
  final List<String> nodes;
  CycleWarning(this.nodes);

  @override
  String message({cycleDetected, unsupportedFeature}) =>
      cycleDetected?.call(nodes.join(', ')) ??
      'Cycle detected involving: ${nodes.join(', ')}';
}

class UnsupportedFeatureWarning extends DiagramWarning {
  final String feature;
  UnsupportedFeatureWarning(this.feature);

  @override
  String message({cycleDetected, unsupportedFeature}) =>
      unsupportedFeature?.call(feature) ??
      "Unsupported feature '$feature' skipped";
}

/// The whole graph: nodes (insertion-ordered), edges, subgraphs, direction.
class DiagramGraph {
  DiagramDirection direction;
  final Map<String, DiagramNode> nodes = <String, DiagramNode>{};
  final List<DiagramEdge> edges = [];
  final List<DiagramSubgraph> subgraphs = [];
  final List<DiagramWarning> warnings = [];

  DiagramGraph({this.direction = DiagramDirection.topToBottom});

  /// Get-or-create a node with [id]. Returns the existing node untouched
  /// when present (first declaration wins, matching mermaid behavior).
  DiagramNode ensureNode(
    String id, {
    String? label,
    NodeShape shape = NodeShape.rectangle,
    String? subgraphId,
  }) {
    final existing = nodes[id];
    if (existing != null) return existing;
    final node = DiagramNode(
      id: id,
      label: label ?? id,
      shape: shape,
      subgraphId: subgraphId,
    );
    nodes[id] = node;
    return node;
  }

  DiagramSubgraph ensureSubgraph(String id, String label, {String? parent}) {
    for (final sg in subgraphs) {
      if (sg.id == id) return sg;
    }
    final sg = DiagramSubgraph(id: id, label: label, parent: parent);
    subgraphs.add(sg);
    return sg;
  }
}

/// Thrown when a diagram source cannot be parsed. The message is shown to
/// the user in place of the rendered graph, so keep it actionable.
class DiagramParseException implements Exception {
  final String message;
  final int line;
  DiagramParseException(this.message, {this.line = 1});

  @override
  String toString() => 'line $line: $message';
}

/// Rendering knobs.
class DiagramRenderOptions {
  /// ASCII-only characters (`+--|>` instead of box drawing).
  final bool ascii;

  /// Hard width budget in terminal columns; layout shrinks gaps to fit.
  final int? maxWidth;

  const DiagramRenderOptions({this.ascii = false, this.maxWidth});
}

/// Result of a successful parse+layout+render pass.
class DiagramRenderResult {
  final String text;
  final List<DiagramWarning> warnings;
  const DiagramRenderResult({required this.text, required this.warnings});
}
