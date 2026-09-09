import 'diagram_layout.dart';
import 'diagram_model.dart';
import 'd2_parser.dart';
import 'mermaid_flowchart_parser.dart';
import 'state_diagram_parser.dart';
import 'diagram_renderer.dart';

export 'diagram_model.dart' show DiagramRenderResult, DiagramRenderOptions;

/// Languages this module can render, matched case-insensitively against
/// fenced-code-block info strings.
const diagramLanguages = {'mermaid', 'd2', 'stateDiagram-v2', 'stateDiagram'};

bool isDiagramLanguage(String? language) {
  if (language == null) return false;
  return diagramLanguages.contains(language.toLowerCase());
}

/// Parse + layout + render [source] into terminal text.
///
/// [language] selects the parser when given (`mermaid`, `d2`); otherwise
/// the format is auto-detected from the source itself.
///
/// Throws [DiagramParseException] when the source cannot be parsed —
/// callers decide how to degrade (usually: fall back to plain code block).
DiagramRenderResult renderDiagram(
  String source,
  DiagramRenderOptions options, {
  String? language,
}) {
  final graph = _parse(source, language);
  computeLayout(graph, options);
  final text = renderDiagramGraph(graph, options);
  return DiagramRenderResult(text: text, warnings: graph.warnings);
}

DiagramGraph _parse(String source, String? language) {
  final lang = language?.toLowerCase();
  if (lang == 'd2') return parseD2(source);
  if (lang == 'mermaid') {
    // Mermaid covers flowcharts and state diagrams; pick by header.
    final trimmed = source.trim().toLowerCase();
    if (trimmed.startsWith('statediagram')) return parseStateDiagram(source);
    return parseMermaidFlowchart(source);
  }
  return _parseAutoDetected(source);
}

DiagramGraph _parseAutoDetected(String source) {
  final trimmed = source.trim();
  final lower = trimmed.toLowerCase();

  if (lower.startsWith('statediagram')) return parseStateDiagram(source);
  if (lower.startsWith('flowchart') || lower.startsWith('graph')) {
    return parseMermaidFlowchart(source);
  }

  // Arrow-shape disambiguation: mermaid uses `-->`, D2 uses `->`.
  final mermaidish =
      trimmed.contains('-->') ||
      trimmed.contains('-.->') ||
      trimmed.contains('==>');
  if (mermaidish) {
    return parseMermaidFlowchart(source, requireHeader: false);
  }

  final d2ish = RegExp(
    r'^\s*\S+\s*(->|<->|<-)\s*\S+',
    multiLine: true,
  ).hasMatch(trimmed);
  if (d2ish) return parseD2(source);

  throw DiagramParseException(
    'Unrecognized diagram syntax (expected mermaid or D2)',
  );
}
