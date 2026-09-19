import 'package:crux/src/components/vibe_box_data.dart';
import 'package:crux/src/components/vibe_segment_bubble.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/utils/subagent_meta.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

Message _msg(
  String role,
  String content, {
  String meta = '',
  String callId = '',
  List<ToolCallData> toolCalls = const [],
}) => Message(
  id: 1,
  sessionId: 1,
  role: role,
  content: content,
  meta: meta,
  toolCallId: callId,
  toolCalls: toolCalls,
);

void main() {
  final registry = ToolRegistry();

  test('agentBubble metadata round-trips through the meta blob', () {
    final meta = agentBubbleMetadata(
      direction: AgentBubbleDirection.toAgent,
      agentId: 'worker-0a1b2c3d4e5f60718293a4b5c6d7e8f9',
      agentName: 'pavo',
      kind: 'send',
      message: 'fix the login bug\nthen run tests',
    );
    // Serialize the way chat_turn_executor does (nested object literal).
    String esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final blob =
        '{${meta.entries.map((e) {
          final v = e.value as Map<String, dynamic>;
          return '"${e.key}":{${v.entries.map((i) => '"${i.key}":"${esc(i.value.toString())}"').join(',')}}';
        }).join(',')}}';

    final parsed = parseAgentBubble(blob);
    expect(parsed, isNotNull);
    expect(parsed!.direction, AgentBubbleDirection.toAgent);
    expect(parsed.agentId, 'worker-0a1b2c3d4e5f60718293a4b5c6d7e8f9');
    // The persisted name is the stable constellation id, not a display name —
    // the renderer localizes it at draw time.
    expect(parsed.agentName, 'pavo');
    expect(parsed.kind, 'send');
    // Newlines collapse to spaces at build time.
    expect(parsed.message, 'fix the login bug then run tests');
  });

  test('agentBubble without a name (legacy rows) parses to null agentName', () {
    final parsed = parseAgentBubble(
      '{"agentBubble":{"dir":"from","agentId":"worker-0a1b2c3d4e5f60718293a4b5c6d7e8f9","kind":"report","msg":"done"}}',
    );
    expect(parsed, isNotNull);
    expect(parsed!.agentName, isNull);
  });

  test('abbreviateAgentId folds durable ids', () {
    expect(
      abbreviateAgentId('worker-0a1b2c3d4e5f60718293a4b5c6d7e8f9'),
      'w:0a1b2c3d',
    );
    expect(abbreviateAgentId('fork-12345678abcd'), 'f:12345678');
    expect(abbreviateAgentId('short-id'), 'short-id');
  });

  test('walker folds agentBubble tool results into the agents box', () {
    final callId = 'call-1';
    final toolCall = _msg(
      'tool_call',
      '',
      toolCalls: [
        ToolCallData(
          callId: callId,
          name: 'send_worker',
          input: const {'workerId': 'worker-x', 'message': 'hi'},
        ),
      ],
    );
    final result = _msg(
      'tool',
      'Queued instruction.',
      callId: callId,
      meta: '{"agentBubble":{"dir":"to","agentId":"worker-0a1b2c3d4e5f60718293a4b5c6d7e8f9","kind":"send","msg":"hi"}}',
    );
    final segments = walkSegments(
      [_msg('user', 'go'), toolCall, result, _msg('ai', 'done')],
      {callId: result},
      registry,
    );
    expect(segments, hasLength(1));
    final agents = segments.first.agents;
    expect(agents, isNotNull);
    expect(agents!.entries, hasLength(1));
    expect(agents.entries.first.kind, 'send');
    // The send_worker call must NOT appear in the tools box.
    expect(segments.first.tools, isNull);
  });

  test('walker folds worker report rows mid-segment without a new turn', () {
    final report = _msg(
      'user',
      '',
      meta: '{"agentBubble":{"dir":"from","agentId":"worker-0a1b2c3d4e5f60718293a4b5c6d7e8f9","kind":"report","msg":"done"}}',
    );
    final segments = walkSegments(
      [_msg('user', 'go'), report, _msg('ai', 'ok')],
      const {},
      registry,
    );
    expect(segments, hasLength(1));
    final agents = segments.first.agents;
    expect(agents, isNotNull);
    expect(agents!.entries.first.direction, AgentBubbleDirection.fromAgent);
    expect(agents.entries.first.kind, 'report');
  });

  test('agents box caps at 6 rows with overflow', () {
    final rows = List.generate(
      8,
      (i) => _msg(
        'user',
        '',
        meta:
            '{"agentBubble":{"dir":"from","agentId":"worker-$i","kind":"report"}}',
      ),
    );
    final segments = walkSegments(
      [_msg('user', 'go'), ...rows, _msg('ai', 'ok')],
      const {},
      registry,
    );
    final agents = segments.first.agents!;
    expect(agents.entries, hasLength(6));
    expect(agents.overflowCount, 2);
  });

  group('agents box rendering', () {
    const workerId = 'worker-0a1b2c3d4e5f60718293a4b5c6d7e8f9';

    VibeSegment segmentWith(
      List<AgentBubblePayload> entries, {
      int overflow = 0,
    }) => VibeSegment(
      userMessage: _msg('user', 'go'),
      agents: AgentsBoxData(entries: entries, overflowCount: overflow),
      prose: _msg('ai', 'ok'),
    );

    Future<void> pump(NoctermTester tester, VibeSegment segment) async {
      await tester.pumpComponent(
        CruxTheme(
          data: CruxThemeData.draculaFallback,
          child: Container(
            width: 100,
            height: 12,
            child: VibeSegmentBubble(segment: segment),
          ),
        ),
      );
    }

    test('renders one row per payload inside the box', () async {
      // Regression: the box lays its rows out with unbounded width, so the
      // verbose `Row` + `Expanded` layout used by AgentBubble threw
      // "children have non-zero flex but incoming width constraints are
      // unbounded" and left the whole box blank — an empty frame next to
      // the think box. The inline rendering must put the row on screen.
      await testNocterm('agents box rows', (tester) async {
        await pump(
          tester,
          segmentWith([
            const AgentBubblePayload(
              direction: AgentBubbleDirection.toAgent,
              agentId: workerId,
              kind: 'spawn',
              message: 'code statistics',
            ),
            const AgentBubblePayload(
              direction: AgentBubbleDirection.toAgent,
              agentId: workerId,
              kind: 'assign',
              message: '统计代码规模',
            ),
            const AgentBubblePayload(
              direction: AgentBubbleDirection.fromAgent,
              agentId: workerId,
              kind: 'report',
              message: 'done: 412 files',
            ),
          ]),
        );

        final screen = tester.terminalState.getText();
        // Historical rows predate agentName and keep their existing short-ID
        // fallback, so old persisted histories remain recognizable.
        expect(screen, contains('spawned w:0a1b2c3d'));
        expect(screen, contains('assigned w:0a1b2c3d'));
        // Direction glyphs: ❱ commander→worker, ❰ worker→commander.
        expect(screen, contains('❱'));
        expect(screen, contains('❰'));
        expect(screen, contains('code statistics'));
        expect(screen, contains('统计代码规模'));
        expect(screen, contains('done: 412 files'));
      });
    });

    test('renders localized constellation names from persisted ids', () async {
      // Rows persisted after the agentName field carry the stable
      // constellation id; the bubble renders the display name of the active
      // Strings locale (kEnglishStrings here → the English name).
      await testNocterm('agents box localized names', (tester) async {
        await pump(
          tester,
          segmentWith([
            const AgentBubblePayload(
              direction: AgentBubbleDirection.toAgent,
              agentId: workerId,
              agentName: 'pavo',
              kind: 'spawn',
              message: 'code statistics',
            ),
            const AgentBubblePayload(
              direction: AgentBubbleDirection.fromAgent,
              agentId: workerId,
              agentName: 'corona-australis',
              kind: 'report',
              message: 'done',
            ),
          ]),
        );

        final screen = tester.terminalState.getText();
        expect(screen, contains('spawned Pavo'));
        expect(screen, contains('reported Corona Australis'));
      });
    });

    test('falls back to the short ID for unnamed legacy rows', () async {
      await testNocterm('agents box legacy label', (tester) async {
        await pump(
          tester,
          segmentWith([
            const AgentBubblePayload(
              direction: AgentBubbleDirection.fromAgent,
              agentId: workerId,
              kind: 'report',
              message: 'done',
            ),
          ]),
        );

        final screen = tester.terminalState.getText();
        expect(screen, contains('reported w:0a1b2c3d'));
      });
    });

    test('clips a long message to the inline column budget', () async {
      final long = 'refactor the entire widget tree ' * 8;
      await testNocterm('agents box clipping', (tester) async {
        await pump(
          tester,
          segmentWith([
            AgentBubblePayload(
              direction: AgentBubbleDirection.toAgent,
              agentId: workerId,
              agentName: 'pavo',
              kind: 'send',
              message: long,
            ),
          ]),
        );

        final screen = tester.terminalState.getText();
        expect(screen, contains('sent Pavo: refactor the entire widget'));
        expect(screen, contains('…'));
        expect(screen, isNot(contains(long.trim())));
      });
    });

    test('renders the overflow tail', () async {
      await testNocterm('agents box overflow', (tester) async {
        await pump(
          tester,
          segmentWith([
            const AgentBubblePayload(
              direction: AgentBubbleDirection.fromAgent,
              agentId: workerId,
              kind: 'report',
              message: 'done',
            ),
          ], overflow: 3),
        );

        expect(tester.terminalState.getText(), contains('+3 more'));
      });
    });
  });
}
