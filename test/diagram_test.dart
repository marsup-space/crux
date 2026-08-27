import 'package:crux/src/diagram/d2_parser.dart';
import 'package:crux/src/diagram/diagram.dart';
import 'package:crux/src/diagram/diagram_layout.dart';
import 'package:crux/src/diagram/diagram_model.dart';
import 'package:crux/src/diagram/mermaid_flowchart_parser.dart';
import 'package:crux/src/diagram/state_diagram_parser.dart';
import 'package:crux/src/components/ui/highlighted_markdown_text.dart';
import 'package:nocterm/nocterm.dart' hide isNotEmpty;
import 'package:test/test.dart';

void main() {
  group('mermaid flowchart parser', () {
    test('parses nodes, edges and pipe labels', () {
      final graph = parseMermaidFlowchart(
          'flowchart LR\nA[Start] --> B[Process]\nB --> C{Decision}\n'
          'C -->|Yes| D[Done]\nC -->|No| B');
      expect(graph.nodes.keys, containsAll(['A', 'B', 'C', 'D']));
      expect(graph.nodes['A']!.label, 'Start');
      expect(graph.nodes['C']!.shape, NodeShape.diamond);
      expect(graph.edges.length, 4);
      expect(
        graph.edges.any((e) => e.from == 'C' && e.to == 'D' && e.label == 'Yes'),
        isTrue,
      );
    });

    test('recognizes shape wrappers', () {
      final graph = parseMermaidFlowchart('flowchart TD\n'
          'a[(DB)] --> b((Circle))\nb --> c(Rounded)\nc --> d{Pick}');
      expect(graph.nodes['a']!.shape, NodeShape.cylinder);
      expect(graph.nodes['b']!.shape, NodeShape.circle);
      expect(graph.nodes['c']!.shape, NodeShape.rounded);
      expect(graph.nodes['d']!.shape, NodeShape.diamond);
    });

    test('parses direction', () {
      final graph = parseMermaidFlowchart('flowchart RL\nA --> B');
      expect(graph.direction, DiagramDirection.rightToLeft);
    });

    test('dotted and thick edge styles', () {
      final graph = parseMermaidFlowchart(
          'flowchart LR\nA -.-> B\nB ==> C\nC --- D');
      expect(graph.edges[0].style, EdgeStyle.dottedArrow);
      expect(graph.edges[1].style, EdgeStyle.thickArrow);
      expect(graph.edges[2].style, EdgeStyle.solidLine);
    });

    test('subgraph membership', () {
      final graph = parseMermaidFlowchart('flowchart TB\nsubgraph inner\n'
          'x[One]\ny[Two]\nend\nz[Three]');
      expect(graph.subgraphs.length, 1);
      expect(graph.subgraphs.first.nodes, containsAll(['x', 'y']));
      expect(graph.nodes['z']!.subgraphId, isNull);
    });

    test('throws without header', () {
      expect(() => parseMermaidFlowchart('A --> B'),
          throwsA(isA<DiagramParseException>()));
    });

    test('<br> in labels becomes a real line break', () {
      // Mermaid's official line-break syntax inside node labels.
      final graph = parseMermaidFlowchart(
          'flowchart TB\nA[line one<br>line two] --> B');
      expect(graph.nodes['A']!.label, 'line one\nline two');
      // Layout sizes the node for two label rows.
      computeLayout(graph, const DiagramRenderOptions());
      expect(graph.nodes['A']!.height, 4); // 2 rows + 2 borders
      // Both lines render inside the node box.
      final result = renderDiagram(
        'flowchart TB\nA[line one<br>line two] --> B',
        const DiagramRenderOptions(),
        language: 'mermaid',
      );
      expect(result.text, contains('line one'));
      expect(result.text, contains('line two'));
      expect(result.text, isNot(contains('<br>')));
    });

    test('<br/> and <br /> variants normalize too', () {
      final graph = parseMermaidFlowchart(
          'flowchart TB\nA[a<br/>b] --> B[c<br />d]');
      expect(graph.nodes['A']!.label, 'a\nb');
      expect(graph.nodes['B']!.label, 'c\nd');
    });

    test('literal \\n escape becomes a real line break', () {
      // Agents write D2-style "\n" in mermaid labels; render it as the
      // line break they intended instead of a literal backslash-n.
      final graph = parseMermaidFlowchart(
          r'flowchart LR' '\n' r'A[line one\nline two] --> B');
      expect(graph.nodes['A']!.label, 'line one\nline two');
    });

    test('surrounding quotes are stripped from labels', () {
      // Quotes are delimiters in mermaid/D2; agents often quote all
      // labels. Rendering them verbatim reads as noise.
      final graph = parseMermaidFlowchart(
          'flowchart LR\nA["quoted label"] --> B[\'single quoted\']');
      expect(graph.nodes['A']!.label, 'quoted label');
      expect(graph.nodes['B']!.label, 'single quoted');
    });

    test('later explicit label wins over an earlier bare id', () {
      final graph = parseMermaidFlowchart(
          'flowchart LR\nA --> B[Bare]\nB[Labeled] --> C');
      expect(graph.nodes['B']!.label, 'Labeled');
    });
  });

  group('state diagram parser', () {
    test('start/end markers become circle nodes', () {
      final graph = parseStateDiagram(
          'stateDiagram-v2\n[*] --> Idle\nIdle --> [*]');
      expect(graph.nodes.values.where((n) => n.shape == NodeShape.circle).length,
          2);
      expect(graph.edges.length, 2);
    });

    test('transition labels', () {
      final graph = parseStateDiagram(
          'stateDiagram-v2\nIdle --> Running: start');
      expect(graph.edges.single.label, 'start');
    });

    test('described states', () {
      final graph = parseStateDiagram(
          'stateDiagram-v2\nstate "Waiting State" as Wait\nWait --> Done');
      expect(graph.nodes['Wait']!.label, 'Waiting State');
    });

    test('transitions are semantic cycles (no warnings)', () {
      final graph = parseStateDiagram(
          'stateDiagram-v2\n[*] --> Idle\nIdle --> Running: start\n'
          'Running --> Idle: stop');
      computeLayout(graph, const DiagramRenderOptions());
      expect(graph.warnings.length, 0);
    });
  });

  group('d2 parser', () {
    test('declarations with labels', () {
      final graph = parseD2('user: User\nserver: Web Server');
      expect(graph.nodes['user']!.label, 'User');
      expect(graph.nodes['server']!.label, 'Web Server');
    });

    test('connections with trailing labels', () {
      final graph = parseD2('a -> b: request\nb <- c\nc <-> d');
      expect(graph.edges[0].label, 'request');
      // b <- c normalizes to c -> b.
      expect(graph.edges[1].from, 'c');
      expect(graph.edges[1].to, 'b');
      // Bidirectional produces both directions.
      expect(graph.edges.length, 4);
    });

    test('containers', () {
      final graph = parseD2('backend {\n  api: API\n  db: DB\n}\napi -> db');
      expect(graph.subgraphs.single.id, 'backend');
      expect(graph.nodes['api']!.subgraphId, 'backend');
    });

    test('shape overrides', () {
      final graph = parseD2('db.shape: cylinder\ndb: Database');
      expect(graph.nodes['db']!.shape, NodeShape.cylinder);
    });

    test('comments ignored', () {
      final graph = parseD2('# a comment\na -> b # trailing');
      expect(graph.edges.single.from, 'a');
    });
  });

  group('layout', () {
    test('layers follow edges', () {
      final graph = parseMermaidFlowchart('flowchart LR\nA --> B\nB --> C');
      computeLayout(graph, const DiagramRenderOptions());
      expect(graph.nodes['B']!.x, greaterThan(graph.nodes['A']!.x));
      expect(graph.nodes['C']!.x, greaterThan(graph.nodes['B']!.x));
    });

    test('cycle produces a warning', () {
      final graph =
          parseMermaidFlowchart('flowchart LR\nA --> B\nB --> C\nC --> A');
      computeLayout(graph, const DiagramRenderOptions());
      expect(graph.warnings, hasLength(1));
      expect(graph.warnings.first, isA<CycleWarning>());
    });

    test('TB direction stacks vertically', () {
      final graph = parseMermaidFlowchart('flowchart TB\nA --> B');
      computeLayout(graph, const DiagramRenderOptions());
      expect(graph.nodes['B']!.y, greaterThan(graph.nodes['A']!.y));
    });

    test('sibling containers do not overlap', () {
      final graph = parseD2('''
backend {
  api: API Server
  db: Database
}
frontend {
  web: React App
}
web -> api
api -> db
''');
      computeLayout(graph, const DiagramRenderOptions());
      final backend = graph.subgraphs.firstWhere((s) => s.id == 'backend');
      final frontend = graph.subgraphs.firstWhere((s) => s.id == 'frontend');
      final overlap = frontend.y < backend.y + backend.height &&
          backend.y < frontend.y + frontend.height;
      expect(overlap, isFalse,
          reason: 'frontend y=${frontend.y} h=${frontend.height}, '
              'backend y=${backend.y} h=${backend.height}');
    });
  });

  group('renderer', () {
    test('output contains node labels and arrows', () {
      final result = renderDiagram(
        'flowchart LR\nA[Start] --> B[End]',
        const DiagramRenderOptions(),
        language: 'mermaid',
      );
      expect(result.text, contains('Start'));
      expect(result.text, contains('End'));
      expect(result.text, contains('▶'));
    });

    test('diamond renders as decision shape', () {
      final result = renderDiagram(
        'flowchart LR\nA --> B{Choice}',
        const DiagramRenderOptions(),
        language: 'mermaid',
      );
      expect(result.text, contains('<'));
      expect(result.text, contains('>'));
    });

    test('ascii mode uses ascii glyphs', () {
      final result = renderDiagram(
        'flowchart LR\nA --> B',
        const DiagramRenderOptions(ascii: true),
        language: 'mermaid',
      );
      expect(result.text, contains('>'));
      expect(result.text, isNot(contains('▶')));
    });

    test('state diagram draws start/end pills', () {
      final result = renderDiagram(
        'stateDiagram-v2\n[*] --> Idle\nIdle --> [*]',
        const DiagramRenderOptions(),
        language: 'mermaid',
      );
      expect(result.text, contains('(●)'));
      expect(result.text, contains('(◉)'));
    });

    test('edge labels stay intact beside the path', () {
      final result = renderDiagram(
        'stateDiagram-v2\nIdle --> Running: start\nRunning --> Idle: stop',
        const DiagramRenderOptions(),
        language: 'mermaid',
      );
      // Labels must appear whole — never split by a path glyph like
      // `st│rt`. Sitting on the same LINE as the gutter is fine (that's
      // what "beside" looks like).
      expect(result.text, contains('start'));
      expect(result.text, contains('stop'));
      expect(result.text.contains('st│rt') || result.text.contains('sto│p'),
          isFalse);
    });
  });

  group('dispatch', () {
    test('isDiagramLanguage matches case-insensitively', () {
      expect(isDiagramLanguage('mermaid'), isTrue);
      expect(isDiagramLanguage('Mermaid'), isTrue);
      expect(isDiagramLanguage('d2'), isTrue);
      expect(isDiagramLanguage('dart'), isFalse);
      expect(isDiagramLanguage(null), isFalse);
    });

    test('auto-detect picks mermaid vs d2 by arrow syntax', () {
      final mermaidResult = renderDiagram(
        'A --> B',
        const DiagramRenderOptions(),
      );
      expect(mermaidResult.text, isNotEmpty);
      final d2Result = renderDiagram(
        'a -> b',
        const DiagramRenderOptions(),
      );
      expect(d2Result.text, isNotEmpty);
    });

    test('unrecognized syntax throws', () {
      expect(
        () => renderDiagram('hello world', const DiagramRenderOptions()),
        throwsA(isA<DiagramParseException>()),
      );
    });
  });

  group('markdown integration', () {
    test('diagram fence renders inside one complete bordered box', () async {
      await testNocterm('mermaid fence renders diagram', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 12,
            child: const HighlightedMarkdownText(
              '```mermaid\nflowchart LR\nA[Start] --> B[End]\n```',
            ),
          ),
        );
        final screen = tester.terminalState;
        expect(screen, containsText('Start'));
        expect(screen, containsText('End'));
        // One complete frame — header and footer present.
        expect(screen.containsText('╭─ mermaid'), isTrue);
        expect(screen.containsText('╰'), isTrue);
        // Right gutter present (not a broken open frame).
        expect(screen.containsText(' │\n'), isTrue);
      });
    });

    test('partial diagram source falls back to raw code rows', () async {
      await testNocterm('partial mermaid falls back', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 12,
            child: const HighlightedMarkdownText(
              '```mermaid\nstateDiagram-v2\n[*] -->\n```',
            ),
          ),
        );
        // Raw source visible (fallback), no crash.
        expect(tester.terminalState, containsText('stateDiagram'));
        // Fallback uses the standard bordered code block.
        expect(tester.terminalState.containsText('╭─ mermaid'), isTrue);
      });
    });

    test('non-diagram fences still render as code', () async {
      await testNocterm('dart fence still code', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: const HighlightedMarkdownText('```dart\nvoid main() {}\n```'),
          ),
        );
        expect(tester.terminalState, containsText('void main()'));
      });
    });
  });
}
