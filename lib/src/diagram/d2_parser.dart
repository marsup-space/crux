import 'diagram_model.dart';

/// Parser for D2 diagram sources.
///
/// Supports: shape declarations (`id: Label`), connections (`a -> b`,
/// `a <- b`, `a <-> b`, `a -- b`) with trailing labels (`a -> b: label`),
/// quoted ids/labels, containers (`backend { api: API }`, nested),
/// `id.shape: cylinder|circle|diamond|…` overrides, and comments (`#`).
/// Style blocks and other attributes are accepted and ignored.
DiagramGraph parseD2(String source) {
  final lines = source.split('\n');
  if (lines.every((l) => l.trim().isEmpty)) {
    throw DiagramParseException('Empty diagram source');
  }

  final graph = DiagramGraph(direction: DiagramDirection.topToBottom);
  final containerStack = <String>[];
  final shapeOverrides = <String, NodeShape>{};

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    line = _stripTrailingComment(line);

    if (line == '}') {
      if (containerStack.isNotEmpty) containerStack.removeLast();
      continue;
    }

    for (final rawStmt in _splitTopLevel(line, ';')) {
      final stmt = rawStmt.trim();
      if (stmt.isEmpty) continue;

      // Container opening: "name {" or "name: Label {".
      if (stmt.endsWith('{')) {
        final head = stmt.substring(0, stmt.length - 1).trim();
        final colon = _splitLabelColon(head);
        final id = _unquote(colon?.key ?? head);
        final label = _unquote(colon?.value ?? head);
        graph.ensureSubgraph(
          id,
          label,
          parent: containerStack.isNotEmpty ? containerStack.last : null,
        );
        containerStack.add(id);
        continue;
      }

      // Shape override: `id.shape: cylinder` (also declares the node).
      final shapeMatch = RegExp(r'^(.+?)\.shape\s*:\s*(\S+)\s*$')
          .firstMatch(stmt);
      if (shapeMatch != null) {
        final id = _unquote(shapeMatch.group(1)!);
        final shape = _d2ShapeToNodeShape(shapeMatch.group(2)!);
        shapeOverrides[id] = shape;
        graph.ensureNode(
          id,
          shape: shape,
          subgraphId: containerStack.isNotEmpty ? containerStack.last : null,
        );
        continue;
      }

      // Connection?
      if (_containsConnection(stmt)) {
        _parseConnection(graph, stmt, containerStack, shapeOverrides);
        continue;
      }

      // Plain declaration: `id` or `id: Label`.
      final colon = _splitLabelColon(stmt);
      final id = _unquote(colon?.key ?? stmt);
      final label = colon?.value == null ? id : _unquote(colon!.value!);
      graph.ensureNode(
        id,
        label: label,
        shape: shapeOverrides.remove(id) ?? NodeShape.rectangle,
        subgraphId: containerStack.isNotEmpty ? containerStack.last : null,
      );
    }
  }

  if (graph.nodes.isEmpty && graph.edges.isEmpty) {
    throw DiagramParseException('No valid D2 content found');
  }

  _rebuildSubgraphMembership(graph);
  return graph;
}

void _rebuildSubgraphMembership(DiagramGraph graph) {
  for (final sg in graph.subgraphs) {
    sg.nodes.clear();
  }
  for (final node in graph.nodes.values) {
    final sgId = node.subgraphId;
    if (sgId != null) {
      graph.ensureSubgraph(sgId, sgId).nodes.add(node.id);
    }
  }
}

bool _containsConnection(String s) =>
    s.contains('->') || s.contains('<-') || s.contains('--');

/// Parse `a -> b: label` / `a <-> b <-> c` style chains.
///
/// The label always trails the *target* node (`a -> b: label`), so the
/// tokenizer splits on top-level arrows first and pulls a trailing
/// `: label` off the final node segment.
void _parseConnection(
  DiagramGraph graph,
  String stmt,
  List<String> containerStack,
  Map<String, NodeShape> shapeOverrides,
) {
  final subgraphId = containerStack.isNotEmpty ? containerStack.last : null;

  final ops = <String>[];
  final nodeTexts = <String>[];
  final buf = StringBuffer();
  var i = 0;
  var inQuote = false;
  while (i < stmt.length) {
    final c = stmt[i];
    if (c == '"') {
      inQuote = !inQuote;
      buf.write(c);
      i++;
      continue;
    }
    if (!inQuote) {
      String? op;
      if (stmt.startsWith('<->', i)) {
        op = '<->';
      } else if (stmt.startsWith('->', i)) {
        op = '->';
      } else if (stmt.startsWith('<-', i)) {
        op = '<-';
      } else if (stmt.startsWith('--', i)) {
        op = '--';
      }
      if (op != null) {
        ops.add(op);
        nodeTexts.add(buf.toString());
        buf.clear();
        i += op.length;
        continue;
      }
    }
    buf.write(c);
    i++;
  }
  nodeTexts.add(buf.toString());

  // Pull the chain label off the last node segment.
  String? chainLabel;
  var lastIdx = nodeTexts.length - 1;
  final colon = _splitLabelColon(nodeTexts[lastIdx]);
  if (colon != null && colon.value != null) {
    nodeTexts[lastIdx] = colon.key;
    chainLabel = _unquote(colon.value!);
  }

  // Resolve every node spec up front.
  final ids = <String>[];
  for (final text in nodeTexts) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) continue;
    final c = _splitLabelColon(trimmed);
    final id = _unquote(c?.key ?? trimmed);
    final label = c?.value == null ? id : _unquote(c!.value!);
    graph.ensureNode(
      id,
      label: label,
      shape: shapeOverrides.remove(id) ?? NodeShape.rectangle,
      subgraphId: subgraphId,
    );
    ids.add(id);
  }

  final label = (chainLabel == null || chainLabel.isEmpty) ? null : chainLabel;
  for (var k = 0; k < ops.length && k + 1 < ids.length; k++) {
    final style = ops[k] == '--' ? EdgeStyle.solidLine : EdgeStyle.solidArrow;
    switch (ops[k]) {
      case '<-':
        graph.edges.add(
          DiagramEdge(from: ids[k + 1], to: ids[k], label: label, style: style),
        );
        break;
      case '<->':
        graph.edges.add(
          DiagramEdge(from: ids[k], to: ids[k + 1], label: label, style: style),
        );
        graph.edges.add(
          DiagramEdge(from: ids[k + 1], to: ids[k], label: label, style: style),
        );
        break;
      default:
        graph.edges.add(
          DiagramEdge(from: ids[k], to: ids[k + 1], label: label, style: style),
        );
    }
  }
}

NodeShape _d2ShapeToNodeShape(String d2) {
  switch (d2) {
    case 'cylinder':
    case 'database':
    case 'storage':
      return NodeShape.cylinder;
    case 'circle':
      return NodeShape.circle;
    case 'diamond':
      return NodeShape.diamond;
    case 'person':
    case 'cloud':
    case 'hexagon':
    case 'queue':
    case 'package':
      return NodeShape.generic;
    default:
      return NodeShape.rectangle;
  }
}

/// Split `key: value` at the first top-level colon outside quotes and
/// brackets. Returns null when there is no colon.
({String key, String? value})? _splitLabelColon(String s) {
  var depth = 0;
  var inQuote = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '"') inQuote = !inQuote;
    if (inQuote) continue;
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
    }
    if (c == ':' && depth == 0) {
      final value = s.substring(i + 1).trim();
      return (
        key: s.substring(0, i).trim(),
        value: value.isEmpty ? null : value,
      );
    }
  }
  return null;
}

String _stripTrailingComment(String line) {
  var inQuote = false;
  for (var i = 0; i < line.length; i++) {
    if (line[i] == '"') inQuote = !inQuote;
    if (!inQuote && line[i] == '#') {
      return line.substring(0, i).trim();
    }
  }
  return line;
}

List<String> _splitTopLevel(String input, String separator) {
  final parts = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  var inQuote = false;
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (c == '"') inQuote = !inQuote;
    if (!inQuote) {
      if ('([{'.contains(c)) {
        depth++;
      } else if (')]}'.contains(c)) {
        depth = (depth - 1).clamp(0, 999);
      }
    }
    if (!inQuote && depth == 0 && input.startsWith(separator, i)) {
      parts.add(buffer.toString());
      buffer.clear();
      i += separator.length - 1;
      continue;
    }
    buffer.write(c);
  }
  parts.add(buffer.toString());
  return parts;
}

String _unquote(String s) {
  s = s.trim();
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    return s.substring(1, s.length - 1);
  }
  return s;
}
