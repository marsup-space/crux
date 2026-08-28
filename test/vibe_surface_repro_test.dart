import 'dart:convert';

import 'package:crux/src/components/vibe_box_data.dart';
import 'package:crux/src/components/vibe_segment_bubble.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/services/a2ui/models.dart';
import 'package:crux/src/services/a2ui/surface_catalog.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/surface_tool.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

/// Reproduction of ses://5047: the agent called the `surface` tool
/// (plus a bash call before it), the user saw the tools box
/// ("surface x1: 12 tokens") but NO rendered surface.
Message _userMsg(String content, {int id = 1}) =>
    Message(id: id, sessionId: 1, role: 'user', content: content);

Message _toolCallMsg({
  int id = 3,
  String content = '',
  List<ToolCallData> toolCalls = const [],
}) => Message(
  id: id,
  sessionId: 1,
  role: 'tool_call',
  content: content,
  toolCalls: toolCalls,
);

Message _toolResultMsg({
  int id = 4,
  String toolCallId = 'call-1',
  String content = '',
}) => Message(
  id: id,
  sessionId: 1,
  role: 'tool',
  content: content,
  toolCallId: toolCallId,
);

void main() {
  // The exact shape of the ses://5047 turn: bash call (with prose),
  // result, surface call (with prose), result, final ai prose.
  final surfacePayload = {
    'surfaceId': 'gold_price',
    'catalogId': 'crux/1.0/chat',
    'components': [
      {
        'id': 'root',
        'component': 'Column',
        'children': ['title', 'price'],
      },
      {'id': 'title', 'component': 'Text', 'text': 'GOLD PRICE'},
      {'id': 'price', 'component': 'Text', 'text': '\$4629.60 / oz'},
    ],
    'dataModel': {},
  };

  final messages = [
    _userMsg('创建一个金价的 surface 给我看看', id: 1),
    _toolCallMsg(
      id: 2,
      content: '我来为你创建一个金价 surface',
      toolCalls: [
        ToolCallData(
          callId: 'call-bash',
          name: 'bash',
          input: {'command': 'curl -s https://api.gold-api.com/price/XAU'},
        ),
      ],
    ),
    _toolResultMsg(id: 3, toolCallId: 'call-bash', content: '{"price":4629}'),
    _toolCallMsg(
      id: 4,
      content: '拿到了 USD/oz 价格，给你 surface',
      toolCalls: [
        ToolCallData(
          callId: 'call-surface',
          name: 'surface',
          input: {'surface': surfacePayload},
        ),
      ],
    ),
    _toolResultMsg(
      id: 5,
      toolCallId: 'call-surface',
      content: 'Surface "gold_price" created (3 components).',
    ),
    Message(id: 6, sessionId: 1, role: 'ai', content: '金价 surface 已创建。'),
  ];

  group('ses://5047 repro — surface tool call in vibe segment', () {
    test('walker collects the surface tool call', () {
      final segments = walkSegments(
        messages,
        {
          for (final m in messages.where((m) => m.role == 'tool'))
            m.toolCallId!: m,
        },
        ToolRegistry(),
      );

      // The turn fans into 3 segments (bash+prose, surface+prose, ai).
      expect(segments.length, 3, reason: 'bash close, surface close, ai close');
      final surfaceSeg = segments[1];
      expect(surfaceSeg.surfaceToolCalls.length, 1,
          reason: 'surface tool call must be preserved on its segment');
      expect(surfaceSeg.surfaceToolCalls.first.name, 'surface');
      expect(surfaceSeg.surfaceToolCalls.first.callId, 'call-surface');
    });

    test('walker survives DB round-trip of the tool call input', () {
      // Simulate persistence: the tool_call message is serialized and
      // restored. jsonDecode produces Map<String, dynamic> for nested
      // maps — surfaceFromToolCall requires exactly that type.
      final tc = messages
          .firstWhere((m) => m.id == 4)
          .toolCalls
          .first;
      final restored = ToolCallData.fromJson(
        jsonDecode(jsonEncode(tc.toJson())) as Map<String, dynamic>,
      );
      expect(restored.input['surface'], isA<Map<String, dynamic>>());
    });

    test('VibeSegmentBubble renders the surface inline', () async {
      final resultsByCallId = {
        for (final m in messages.where((m) => m.role == 'tool'))
          m.toolCallId!: m,
      };
      final segments = walkSegments(messages, resultsByCallId, ToolRegistry());
      final catalog = createBasicCatalog();

      await testNocterm('vibe surface inline', (tester) async {
      await tester.pumpComponent(
        CruxTheme(
          data: CruxThemeData.draculaFallback,
          child: VibeSegmentBubble(
            segment: segments[1],
            surfaceCatalog: catalog,
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.terminalState.findText('GOLD PRICE').isNotEmpty,
        isTrue,
        reason: 'surface content must render in the vibe segment',
      );
      expect(
        tester.terminalState.findText('\$4629.60 / oz').isNotEmpty,
        isTrue,
      );
      }, size: const Size(80, 24));
    });

    test('failed surface call is NOT collected (no red bubble)', () {
      // ses://5048: a surface call with a missing surfaceId fails at
      // execute time ("Invalid surface: could not parse"). The walker
      // must not hand it to SurfaceBubble — the tool-result row already
      // shows the error; a red panel next to the retried success is
      // noise.
      final failedCall = ToolCallData(
        callId: 'call-surface-bad',
        name: 'surface',
        input: {
          'surface': {
            'catalogId': 'crux/1.0/chat',
            'components': [
              {'id': 'root', 'component': 'Text', 'text': 'x'},
            ],
            // NOTE: no surfaceId — CreateSurface.fromJson returns null.
          },
        },
      );
      final msgs = [
        _userMsg('再来一个', id: 1),
        _toolCallMsg(id: 2, content: '创建', toolCalls: [failedCall]),
        Message(
          id: 3,
          sessionId: 1,
          role: 'tool',
          content: 'Invalid surface: could not parse.',
          toolCallId: 'call-surface-bad',
          error: 'Invalid surface: could not parse.',
        ),
        Message(id: 4, sessionId: 1, role: 'ai', content: '重试成功。'),
      ];
      final segments = walkSegments(
        msgs,
        {for (final m in msgs.where((m) => m.role == 'tool')) m.toolCallId!: m},
        ToolRegistry(),
      );
      final seg = segments.firstWhere(
        (s) => s.surfaceToolCalls.isNotEmpty || s.tools != null,
      );
      expect(
        seg.surfaceToolCalls,
        isEmpty,
        reason: 'failed surface calls must not render as red bubbles',
      );
    });
  });

  group('ses://5047 repro — provider-mangled payload (the real bug)', () {
    // The EXACT payload persisted in ses://5047 message #326565:
    // MiniMax-M3 via OpenRouter serialized the tool-call arguments with
    // every array wrapped as {"item": [...]} and numbers as strings.
    // The strict `is List` checks silently dropped children → the
    // surface rendered EMPTY (the user saw "nothing").
    final mangledPayload = {
      'surfaceId': 'gold_price',
      'catalogId': 'crux/1.0/chat',
      'components': [
        {
          'id': 'root',
          'component': 'Column',
          'children': {
            'item': ['title', 'usd_row', 'cny_row'],
          },
        },
        {'id': 'title', 'component': 'Text', 'text': '🥇 Gold Price (XAU)'},
        {
          'id': 'usd_row',
          'component': 'Row',
          'gap': '2',
          'children': {
            'item': ['usd_label', 'usd_price'],
          },
        },
        {'id': 'usd_label', 'component': 'Text', 'text': 'USD / oz:'},
        {'id': 'usd_price', 'component': 'Text', 'text': '\$4629.60'},
        {
          'id': 'cny_row',
          'component': 'Row',
          'gap': '2',
          'children': {
            'item': ['cny_label', 'cny_price'],
          },
        },
        {'id': 'cny_label', 'component': 'Text', 'text': 'CNY / oz:'},
        {'id': 'cny_price', 'component': 'Text', 'text': '¥32870'},
      ],
      'dataModel': {},
    };

    test('unwrapListProperty normalizes the {"item": [...]} wrapper', () {
      final mangled = {
        'item': ['a', 'b'],
      };
      expect(unwrapListProperty(mangled), ['a', 'b']);
      expect(unwrapListProperty(['a', 'b']), ['a', 'b'], reason: 'list passthrough');
      expect(unwrapListProperty('["x","y"]'), ['x', 'y'], reason: 'JSON string');
      expect(unwrapListProperty(42), 42, reason: 'non-list passthrough');
    });

    test('coerceIntProperty accepts stringified numbers', () {
      expect(coerceIntProperty('2', 1), 2);
      expect(coerceIntProperty(3, 1), 3);
      expect(coerceIntProperty('abc', 1), 1);
      expect(coerceIntProperty(null, 1), 1);
    });

    test('SurfaceTool accepts the mangled payload (validate passes)', () async {
      final catalog = createBasicCatalog();
      final tool = SurfaceTool(catalog: catalog);
      final result = await tool.execute(
        {'surface': mangledPayload},
        _FakeToolContext(),
      );
      expect(
        result.title,
        isNot('Error'),
        reason: 'the mangled payload must not be rejected at create time',
      );
    });

    test('VibeSegmentBubble renders the mangled surface non-empty', () async {
      final resultsByCallId = {
        for (final m in messages.where((m) => m.role == 'tool'))
          m.toolCallId!: m,
      };
      // Swap the clean payload for the real mangled one.
      final mangledMessages = messages.map((m) {
        if (m.id != 4) return m;
        return m.copyWith(
          toolCalls: [
            ToolCallData(
              callId: 'call-surface',
              name: 'surface',
              input: {'surface': mangledPayload},
            ),
          ],
        );
      }).toList();
      final segments = walkSegments(
        mangledMessages,
        resultsByCallId,
        ToolRegistry(),
      );
      final catalog = createBasicCatalog();

      await testNocterm('mangled surface renders', (tester) async {
        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: VibeSegmentBubble(
              segment: segments[1],
              surfaceCatalog: catalog,
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.terminalState.findText('🥇 Gold Price (XAU)').isNotEmpty,
          isTrue,
          reason: 'Column children must survive the {"item": [...]} wrapper',
        );
        expect(
          tester.terminalState.findText('USD / oz:').isNotEmpty,
          isTrue,
          reason: 'Row children must survive the wrapper + string gap',
        );
      }, size: const Size(80, 24));
    });
  });
}

class _FakeToolContext implements ToolContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
