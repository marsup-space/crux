import 'diagram_model.dart';

/// Parser for Mermaid `stateDiagram` / `stateDiagram-v2`.
///
/// Supports: transitions with labels (`Idle --> Running: start`),
/// start/end markers (`[*]`), `state "Description" as ID`, composite
/// states (`state Active { ... }`), and comments (`%%`). Direction
/// statements are accepted but ignored (composite layout is TB).
DiagramGraph parseStateDiagram(String source) {
  final lines = source.split('\n');
  if (lines.every((l) => l.trim().isEmpty)) {
    throw DiagramParseException('Empty diagram source');
  }

  final graph = DiagramGraph(direction: DiagramDirection.topToBottom);
  var foundHeader = false;
  String? currentComposite;
  var startCounter = 0;
  var endCounter = 0;

  for (var i = 0; i < lines.length; i++) {
    final lineNo = i + 1;
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('%%')) continue;

    if (!foundHeader && _headerRe.hasMatch(line)) {
      foundHeader = true;
      continue;
    }
    if (foundHeader && line.toLowerCase().startsWith('direction')) {
      continue;
    }

    if (line == '}') {
      currentComposite = null;
      continue;
    }

    // state "Description" as ID
    var m = RegExp(r'^state\s+"([^"]*)"\s+as\s+(\S+)\s*$').firstMatch(line);
    if (m != null) {
      graph.ensureNode(m.group(2)!,
          label: m.group(1)!,
          shape: NodeShape.rounded,
          subgraphId: currentComposite);
      continue;
    }

    // Composite start: state Name {
    m = RegExp(r'^state\s+(\S+)\s*\{$').firstMatch(line);
    if (m != null) {
      final id = m.group(1)!;
      graph.ensureSubgraph(id, id,
          parent: currentComposite);
      currentComposite = id;
      continue;
    }

    // Simple declaration: state ID
    m = RegExp(r'^state\s+(\S+)\s*$').firstMatch(line);
    if (m != null) {
      graph.ensureNode(m.group(1)!,
          shape: NodeShape.rounded, subgraphId: currentComposite);
      continue;
    }

    // Transition: A --> B [: label]
    m = RegExp(
            r'^(\[\*\]|[A-Za-z0-9_]+)\s*-->\s*(\[\*\]|[A-Za-z0-9_]+)(?:\s*:\s*(.*))?$')
        .firstMatch(line);
    if (m != null) {
      final fromId = _resolveRef(graph, m.group(1)!, currentComposite,
          isStart: true, counter: ++startCounter);
      final toId = _resolveRef(graph, m.group(2)!, currentComposite,
          isStart: false, counter: ++endCounter);
      final label = m.group(3)?.trim();
      graph.edges.add(DiagramEdge(
        from: fromId,
        to: toId,
        label: (label == null || label.isEmpty) ? null : label,
        semanticCycle: true,
      ));
      continue;
    }

    throw DiagramParseException("Cannot parse '$line'", line: lineNo);
  }

  if (!foundHeader) {
    throw DiagramParseException(
        "Expected 'stateDiagram' or 'stateDiagram-v2' header");
  }
  if (graph.nodes.isEmpty && graph.edges.isEmpty) {
    throw DiagramParseException('No valid state diagram content');
  }

  for (final sg in graph.subgraphs) {
    sg.nodes.clear();
  }
  for (final node in graph.nodes.values) {
    final sgId = node.subgraphId;
    if (sgId != null) {
      graph.ensureSubgraph(sgId, sgId).nodes.add(node.id);
    }
  }

  return graph;
}

final _headerRe =
    RegExp(r'^stateDiagram(?:-v2)?\s*$', caseSensitive: false);

String _resolveRef(
  DiagramGraph graph,
  String ref,
  String? composite, {
  required bool isStart,
  required int counter,
}) {
  if (ref == '[*]') {
    final id = '__${isStart ? 'start' : 'end'}$counter';
    graph.ensureNode(id,
        label: isStart ? '●' : '◉',
        shape: NodeShape.circle,
        subgraphId: composite);
    return id;
  }
  graph.ensureNode(ref, shape: NodeShape.rounded, subgraphId: composite);
  return ref;
}
