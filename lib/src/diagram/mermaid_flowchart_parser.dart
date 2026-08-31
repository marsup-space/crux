import 'diagram_model.dart';

/// Parser for Mermaid flowchart syntax (`flowchart LR`, `graph TD`).
///
/// Supports: node shapes (rectangle, rounded, circle, diamond, cylinder,
/// stadium/subroutine/hexagon mapped to generic), edge styles (`-->`,
/// `---`, `-.->`, `==>`, labelled variants via `|label|` or `--text-->`),
/// reverse/bidirectional arrows (`<--`, `<-->`), subgraphs (including
/// nesting), and comments (`%%`). `classDef`/`style`/`click` lines are
/// accepted and ignored — the character grid has no per-node color budget.
///
/// When [requireHeader] is false (auto-detection path), a missing
/// `flowchart`/`graph` header defaults to TB instead of throwing.
DiagramGraph parseMermaidFlowchart(String source,
    {bool requireHeader = true}) {
  final lines = source.split('\n');
  if (lines.every((l) => l.trim().isEmpty)) {
    throw DiagramParseException('Empty diagram source');
  }

  final graph = DiagramGraph();
  var foundHeader = false;

  // Open subgraph nesting, innermost last.
  final subgraphStack = <String>[];

  for (var i = 0; i < lines.length; i++) {
    final lineNo = i + 1;
    var line = lines[i].trim();
    if (line.isEmpty || line.startsWith('%%')) continue;

    if (!foundHeader &&
        (line.toLowerCase().startsWith('flowchart') ||
            line.toLowerCase().startsWith('graph'))) {
      foundHeader = true;
      final keyword =
          line.toLowerCase().startsWith('flowchart') ? 'flowchart' : 'graph';
      final m = RegExp(r'(LR|RL|TB|TD|BT)', caseSensitive: false)
          .firstMatch(line.substring(keyword.length));
      if (m != null) {
        graph.direction = DiagramDirection.parse(m.group(1)!);
      }
      // Statements may follow on the same line after the header.
      line = line.substring(keyword.length + (m?.end ?? 0)).trim();
      if (line.isEmpty) continue;
    }

    if (line.toLowerCase().startsWith('subgraph')) {
      final rest = line.substring(8).trim();
      String id;
      String label;
      final titled = RegExp(r'^(\S+)\s+\[(.+)\]$').firstMatch(rest);
      final boxed = RegExp(r'^\[(.+)\]$').firstMatch(rest);
      if (titled != null) {
        id = titled.group(1)!;
        label = titled.group(2)!;
      } else if (boxed != null) {
        id = boxed.group(1)!;
        label = id;
      } else {
        id = rest.isEmpty ? '__sg${graph.subgraphs.length}' : rest;
        label = rest;
      }
      graph.ensureSubgraph(id, label,
          parent: subgraphStack.isNotEmpty ? subgraphStack.last : null);
      subgraphStack.add(id);
      continue;
    }

    if (line == 'end') {
      if (subgraphStack.isNotEmpty) subgraphStack.removeLast();
      continue;
    }

    if (RegExp(r'^(classDef|class|style|click|linkStyle)\b',
            caseSensitive: false)
        .hasMatch(line)) {
      continue;
    }

    for (final statement in _splitTopLevel(line, ';')) {
      final stmt = statement.trim();
      if (stmt.isEmpty) continue;
      _parseStatement(graph, stmt, subgraphStack, lineNo);
    }
  }

  if (!foundHeader && requireHeader) {
    throw DiagramParseException("Expected a 'flowchart' or 'graph' header");
  }

  // Rebuild direct membership lists from node declarations.
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

void _parseStatement(
  DiagramGraph graph,
  String statement,
  List<String> subgraphStack,
  int lineNo,
) {
  if (!_containsEdgeOperator(statement)) {
    final node = _parseNodeToken(statement, 0);
    if (node == null) {
      throw DiagramParseException("Cannot parse '$statement'", line: lineNo);
    }
    graph.ensureNode(
      node.id,
      label: node.label,
      shape: node.shape,
      subgraphId: subgraphStack.isNotEmpty ? subgraphStack.last : null,
    );
    return;
  }
  _parseEdgeChain(graph, statement, subgraphStack);
}

bool _containsEdgeOperator(String s) =>
    s.contains('-->') ||
    s.contains('---') ||
    s.contains('-.') ||
    s.contains('==>') ||
    s.contains('===') ||
    s.contains('<--');

/// Split on [separator] only where it sits outside quotes and brackets.
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

const _openToClose = {'(': ')', '[': ']', '{': '}'};

/// Read a balanced bracket group starting at [start]; returns its inner
/// content (without the outer brackets), or null when unbalanced.
String? _readBalanced(String s, int start) {
  final open = s[start];
  final close = _openToClose[open];
  if (close == null) return null;
  var depth = 0;
  var inQuote = false;
  for (var i = start; i < s.length; i++) {
    final c = s[i];
    if (c == '"') inQuote = !inQuote;
    if (inQuote) continue;
    if (c == open) depth++;
    if (c == close) {
      depth--;
      if (depth == 0) return s.substring(start + 1, i);
    }
  }
  return null;
}

({String id, String label, NodeShape shape})? _parseNodeToken(
  String s,
  int start,
) {
  var i = start;
  while (i < s.length && s[i] == ' ') {
    i++;
  }
  if (i >= s.length) return null;

  // Identifier: quoted, or a run of characters that stops at whitespace,
  // shape delimiters, and anything that begins an edge operator.
  String id;
  if (s[i] == '"') {
    final close = s.indexOf('"', i + 1);
    if (close == -1) return null;
    id = s.substring(i + 1, close);
    i = close + 1;
  } else {
    final b = StringBuffer();
    while (i < s.length) {
      final c = s[i];
      if (c == ' ' ||
          c == '(' ||
          c == '[' ||
          c == '{' ||
          c == '"' ||
          c == '|' ||
          c == ';' ||
          c == '<' ||
          s.startsWith('--', i) ||
          s.startsWith('==', i) ||
          s.startsWith('-.', i)) {
        break;
      }
      b.write(c);
      i++;
    }
    id = b.toString();
  }
  if (id.isEmpty) return null;

  var shape = NodeShape.rectangle;
  var label = id;

  if (i < s.length && _openToClose.containsKey(s[i])) {
    final wrapped = _readWrapped(s, i);
    if (wrapped != null) {
      final resolved = _resolveShape(wrapped);
      shape = resolved.shape;
      label = resolved.label;
    }
  }
  return (id: id, label: label, shape: shape);
}

/// Read a balanced bracket group starting at [start], INCLUDING the
/// outer brackets (`{Decision}` stays `{Decision}`).
String? _readWrapped(String s, int start) {
  final open = s[start];
  final close = _openToClose[open];
  if (close == null) return null;
  var depth = 0;
  var inQuote = false;
  for (var i = start; i < s.length; i++) {
    final c = s[i];
    if (c == '"') inQuote = !inQuote;
    if (inQuote) continue;
    if (c == open) depth++;
    if (c == close) {
      depth--;
      if (depth == 0) return s.substring(start, i + 1);
    }
  }
  return null;
}

({NodeShape shape, String label}) _resolveShape(String wrapped) {
  // Most specific wrappers first.
  if (wrapped.startsWith('[(') && wrapped.endsWith(')]')) {
    return (
      shape: NodeShape.cylinder,
      label: wrapped.substring(2, wrapped.length - 2)
    );
  }
  if (wrapped.startsWith('((') && wrapped.endsWith('))')) {
    return (
      shape: NodeShape.circle,
      label: wrapped.substring(2, wrapped.length - 2)
    );
  }
  if (wrapped.startsWith('[[') && wrapped.endsWith(']]')) {
    return (
      shape: NodeShape.generic,
      label: wrapped.substring(2, wrapped.length - 2)
    );
  }
  if (wrapped.startsWith('{{') && wrapped.endsWith('}}')) {
    return (
      shape: NodeShape.generic,
      label: wrapped.substring(2, wrapped.length - 2)
    );
  }
  if (wrapped.startsWith('([') && wrapped.endsWith('])')) {
    return (
      shape: NodeShape.generic,
      label: wrapped.substring(2, wrapped.length - 2)
    );
  }
  if (wrapped.startsWith('(') && wrapped.endsWith(')')) {
    return (
      shape: NodeShape.rounded,
      label: wrapped.substring(1, wrapped.length - 1)
    );
  }
  if (wrapped.startsWith('{') && wrapped.endsWith('}')) {
    return (
      shape: NodeShape.diamond,
      label: wrapped.substring(1, wrapped.length - 1)
    );
  }
  if (wrapped.startsWith('[') && wrapped.endsWith(']')) {
    return (
      shape: NodeShape.rectangle,
      label: wrapped.substring(1, wrapped.length - 1)
    );
  }
  return (shape: NodeShape.rectangle, label: wrapped);
}

void _parseEdgeChain(
  DiagramGraph graph,
  String statement,
  List<String> subgraphStack,
) {
  final subgraphId = subgraphStack.isNotEmpty ? subgraphStack.last : null;
  var pos = 0;

  // First node anchors the chain.
  final first = _parseNodeToken(statement, pos);
  if (first == null) return;
  graph.ensureNode(first.id,
      label: first.label, shape: first.shape, subgraphId: subgraphId);
  var prevId = first.id;
  pos = _scanPastNode(statement, pos);

  while (true) {
    while (pos < statement.length && statement[pos] == ' ') {
      pos++;
    }
    if (pos >= statement.length) break;

    // One edge operator...
    final edge = _parseEdgeOperator(statement, pos);
    if (edge == null) break;
    pos = edge.nextPos;

    // Optional pipe label directly after the operator (`|text|`).
    String? label = edge.label;
    final pipe =
        RegExp(r'\s*\|([^|]*)\|').firstMatch(statement.substring(pos));
    if (pipe != null && pipe.start == 0) {
      label ??= pipe.group(1)?.trim();
      pos += pipe.end;
    }
    while (pos < statement.length && statement[pos] == ' ') {
      pos++;
    }

    // ...then exactly one node token closes it.
    final next = _parseNodeToken(statement, pos);
    if (next == null) break;
    graph.ensureNode(next.id,
        label: next.label, shape: next.shape, subgraphId: subgraphId);

    final (from, to) = edge.reverse ? (next.id, prevId) : (prevId, next.id);
    graph.edges.add(DiagramEdge(
        from: from, to: to, label: label, style: edge.style));
    if (edge.bidirectional) {
      graph.edges.add(DiagramEdge(
          from: next.id, to: prevId, label: label, style: edge.style));
    }

    prevId = next.id;
    pos = _scanPastNode(statement, pos);
  }
}

/// Advance [pos] past one complete node token (identifier + shape wrapper).
int _scanPastNode(String s, int pos) {
  var i = pos;
  while (i < s.length && s[i] == ' ') {
    i++;
  }
  if (i < s.length && s[i] == '"') {
    final close = s.indexOf('"', i + 1);
    return close == -1 ? s.length : close + 1;
  }
  // Consume the identifier run.
  while (i < s.length) {
    final c = s[i];
    if (c == ' ' ||
        c == '(' ||
        c == '[' ||
        c == '{' ||
        c == '"' ||
        c == '|' ||
        c == ';' ||
        c == '<' ||
        s.startsWith('--', i) ||
        s.startsWith('==', i) ||
        s.startsWith('-.', i)) {
      break;
    }
    i++;
  }
  // Skip whitespace between identifier and a following shape wrapper —
  // `A [label]` is legal mermaid, and without this the wrapper was
  // left unconsumed, making the NEXT _parseNodeToken read the wrapper
  // text as a node id (e.g. the chain `A[B] --> C` mis-parsed).
  while (i < s.length && s[i] == ' ') {
    i++;
  }
  if (i < s.length && _openToClose.containsKey(s[i])) {
    final inner = _readBalanced(s, i);
    if (inner != null) {
      // Skip the wrapper itself: re-scan from the opening bracket.
      var depth = 0;
      var j = i;
      var inQuote = false;
      final open = s[i];
      final close = _openToClose[open]!;
      while (j < s.length) {
        final c = s[j];
        if (c == '"') inQuote = !inQuote;
        if (!inQuote) {
          if (c == open) depth++;
          if (c == close) {
            depth--;
            if (depth == 0) return j + 1;
          }
        }
        j++;
      }
    }
  }
  return i;
}

class _EdgeToken {
  final EdgeStyle style;
  final String? label;
  final bool reverse;
  final bool bidirectional;
  final int nextPos;
  _EdgeToken(this.style, this.label, this.reverse, this.bidirectional,
      this.nextPos);
}

_EdgeToken? _parseEdgeOperator(String s, int pos) {
  final rest = s.substring(pos);

  // Bidirectional / reversed arrows.
  if (rest.startsWith('<-->')) {
    return _EdgeToken(EdgeStyle.solidArrow, null, false, true, pos + 4);
  }
  if (rest.startsWith('<--')) {
    return _EdgeToken(EdgeStyle.solidArrow, null, true, false, pos + 3);
  }

  // Dotted family.
  var m = RegExp(r'^-\.\s*"([^"]*)"\s*\.+-+>').firstMatch(rest);
  if (m != null) {
    return _EdgeToken(EdgeStyle.dottedArrow, m.group(1)!, false, false,
        pos + m.end);
  }
  m = RegExp(r'^-\.([^|]*?)\.+-+>').firstMatch(rest);
  if (m != null) {
    return _EdgeToken(
        EdgeStyle.dottedArrow, m.group(1)!.trim(), false, false, pos + m.end);
  }
  if (rest.startsWith('-.->')) {
    return _EdgeToken(EdgeStyle.dottedArrow, null, false, false, pos + 4);
  }
  if (rest.startsWith('->')) {
    return _EdgeToken(EdgeStyle.solidArrow, null, false, false, pos + 2);
  }
  if (rest.startsWith('-.-')) {
    return _EdgeToken(EdgeStyle.dottedLine, null, false, false, pos + 3);
  }

  // Thick family.
  m = RegExp(r'^==\s*"([^"]*)"\s*==+>').firstMatch(rest);
  if (m != null) {
    return _EdgeToken(
        EdgeStyle.thickArrow, m.group(1)!, false, false, pos + m.end);
  }
  m = RegExp(r'^==([^|]*?)==+>').firstMatch(rest);
  if (m != null) {
    return _EdgeToken(
        EdgeStyle.thickArrow, m.group(1)!.trim(), false, false, pos + m.end);
  }
  if (rest.startsWith('==>')) {
    return _EdgeToken(EdgeStyle.thickArrow, null, false, false, pos + 3);
  }
  if (rest.startsWith('===')) {
    return _EdgeToken(EdgeStyle.thickLine, null, false, false, pos + 3);
  }

  // Solid family. Plain `-->` MUST be tested before the labelled form
  // `--text-->`: the labelled regex `--([^|]*?)--+>` backtracks across
  // arbitrary text and, on a chain like `A --> B[...] --> C`, once
  // swallows `-> B[...] --` as a "label", collapsing the chain to
  // `A -> C` and DROPPING node B (this really happened). Mermaid label
  // text may not contain `>` or start with `-`, which the restricted
  // character class now enforces.
  if (rest.startsWith('-->')) {
    return _EdgeToken(EdgeStyle.solidArrow, null, false, false, pos + 3);
  }
  m = RegExp(r'^--\s*"([^"]*)"\s*--+>').firstMatch(rest);
  if (m != null) {
    return _EdgeToken(
        EdgeStyle.solidArrow, m.group(1)!, false, false, pos + m.end);
  }
  m = RegExp(r'^--([^|>\-][^|>]*?)--+>').firstMatch(rest);
  if (m != null) {
    return _EdgeToken(
        EdgeStyle.solidArrow, m.group(1)!.trim(), false, false, pos + m.end);
  }
  if (rest.startsWith('---')) {
    return _EdgeToken(EdgeStyle.solidLine, null, false, false, pos + 3);
  }
  if (rest.startsWith('--')) {
    return _EdgeToken(EdgeStyle.solidLine, null, false, false, pos + 2);
  }
  return null;
}
