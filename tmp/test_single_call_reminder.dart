// Standalone test for the single-tool-call reminder feature.
//
// Goal: prove that after exactly 10 consecutive single-tool-call rounds,
// Crux's chat_service gate fires and the reminder is correctly injected
// into the last tool's content on both OpenAI and Anthropic wire formats.
//
// We don't need a running chat_service — we drive the *same* helpers
// chat_service drives (`renderParallelSingleCallHintEmbedded` and
// `injectParallelSingleCallHintIntoLastTool`) and replicate the exact
// modulo gate from chat_service.dart:884-888:
//
//   hintEnabled &&
//   successfulCalls == 1 &&
//   runtime.consecutiveSingleToolCallRounds > 0 &&
//   runtime.consecutiveSingleToolCallRounds % hintSingleThreshold == 0
//
// Run with: dart run tmp/test_single_call_reminder.dart

import 'package:crux/src/services/prompts/praise_prompts.dart';

void main() {
  const hintEnabled = true;
  const hintSingleThreshold = 10;
  var counter = 0;

  print('━' * 72);
  print('Round-by-round counter + gate simulation (threshold = 10)');
  print('━' * 72);
  print('Round │ counter │ 1 successful call? │ counter > 0 │ counter % 10 == 0 │ FIRES?');
  print('──────┼─────────┼────────────────────┼─────────────┼───────────────────┼───────');

  // Simulate 25 single-tool-call rounds so we see the rhythm (10, 20 fire;
  // 11–19, 21–24 don't).
  for (var round = 1; round <= 25; round++) {
    final successfulCalls = 1;
    if (successfulCalls == 1) {
      counter += 1;
    } else {
      counter = 0;
    }

    final gatePositive = counter > 0;
    final gateModulo = counter % hintSingleThreshold == 0;
    final fires =
        hintEnabled && successfulCalls == 1 && gatePositive && gateModulo;

    print(
      '${round.toString().padLeft(5)} │ '
      '${counter.toString().padLeft(7)} │ '
      '${successfulCalls.toString().padLeft(18)} │ '
      '${gatePositive.toString().padLeft(11)} │ '
      '${gateModulo.toString().padLeft(17)} │ '
      '${fires ? "🔥 FIRE" : "  -"}',
    );
  }

  // Now actually drive the injection at round 10 with realistic wire-format
  // messages, on both protocols, and print the resulting tool content so
  // we can see the reminder sitting inside the last tool's `content` field.

  print('');
  print('━' * 72);
  print('OpenAI wire format: round-10 fire');
  print('━' * 72);

  final openAiMessages = <Map<String, dynamic>>[
    {
      'role': 'assistant',
      'content': null,
      'tool_calls': [
        {'id': 'call_abc123', 'type': 'function', 'function': {'name': 'read', 'arguments': '{"filePath": "lib/main.dart"}'}},
      ],
    },
    {
      'role': 'tool',
      'tool_call_id': 'call_abc123',
      'content': '// main.dart — actual tool output\nvoid main() { runApp(MyApp()); }',
    },
  ];

  print('Before injection — last tool content:');
  print('  ${openAiMessages.last['content']}');
  print('Total messages: ${openAiMessages.length}');

  injectParallelSingleCallHintIntoLastTool(
    openAiMessages,
    isAnthropic: false,
    consecutiveCount: 10,
  );

  print('');
  print('After injection — last tool content:');
  print('  ${openAiMessages.last['content']}');
  print('Total messages: ${openAiMessages.length} (should still be 2 — no new message added)');
  print('Last message role: ${openAiMessages.last['role']} (should still be "tool")');

  print('');
  print('━' * 72);
  print('Anthropic wire format: round-10 fire');
  print('━' * 72);

  final anthropicMessages = <Map<String, dynamic>>[
    {
      'role': 'assistant',
      'content': [
        {'type': 'tool_use', 'id': 'toolu_xyz', 'name': 'read', 'input': {'filePath': 'lib/main.dart'}},
      ],
    },
    {
      'role': 'user',
      'content': [
        {
          'type': 'tool_result',
          'tool_use_id': 'toolu_xyz',
          'content': '// main.dart — actual tool output\nvoid main() { runApp(MyApp()); }',
        },
      ],
    },
  ];

  print('Before injection — last tool_result block content:');
  final anthropicBlocksBefore = anthropicMessages.last['content'] as List;
  print('  ${(anthropicBlocksBefore.last as Map)['content']}');
  print('Total messages: ${anthropicMessages.length}');

  injectParallelSingleCallHintIntoLastTool(
    anthropicMessages,
    isAnthropic: true,
    consecutiveCount: 10,
  );

  print('');
  print('After injection — last tool_result block content:');
  final anthropicBlocksAfter = anthropicMessages.last['content'] as List;
  print('  ${(anthropicBlocksAfter.last as Map)['content']}');
  print('Total messages: ${anthropicMessages.length} (should still be 2)');
  print('Last message role: ${anthropicMessages.last['role']} (should still be "user")');
  print('Number of tool_result blocks: ${anthropicBlocksAfter.length} (should still be 1 — no sibling text block added)');

  // Bonus: verify the round-9 case does NOT fire — counter=9 fails the
  // modulo gate. This is the case the existing tests pin down, but worth
  // showing here too because the user's question is specifically about
  // the "after exactly 10" boundary.

  print('');
  print('━' * 72);
  print('Boundary check: round 9 does NOT fire (counter = 9, 9 % 10 != 0)');
  print('━' * 72);

  final round9OpenAi = <Map<String, dynamic>>[
    {'role': 'assistant', 'content': null, 'tool_calls': []},
    {'role': 'tool', 'tool_call_id': 'x', 'content': 'plain tool output'},
  ];

  final round9Counter = 9;
  final round9Fires =
      hintEnabled && 1 == 1 && round9Counter > 0 && round9Counter % 10 == 0;
  print('counter = 9, counter % 10 = ${round9Counter % 10}, gate fires = $round9Fires');
  print('(Expected: false — the reminder does NOT fire at round 9.)');

  // And round 11 — to show the rhythm is 10, 20, 30 (not 10, 11, 12…).
  final round11Counter = 11;
  final round11Fires =
      hintEnabled && 1 == 1 && round11Counter > 0 && round11Counter % 10 == 0;
  print('counter = 11, counter % 10 = ${round11Counter % 10}, gate fires = $round11Fires');
  print('(Expected: false — rhythm is 10, 20, 30, …)');
}