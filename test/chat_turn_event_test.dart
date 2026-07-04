import 'package:test/test.dart';

import 'package:crux/src/models/message.dart';
import 'package:crux/src/services/chat_turn_event.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/llm_error.dart';
import 'package:crux/src/tools/tool_def.dart';

String describeEvent(ChatTurnEvent event) {
  return switch (event) {
    ChatTurnDelta() => 'delta',
    ChatTurnReasoningDelta() => 'reasoning',
    ChatTurnChunk() => 'chunk',
    ChatTurnStatusChanged() => 'status',
    ChatTurnToolRoundCompleted() => 'tool-round',
    ChatTurnToolUseDelta() => 'tool-use',
    ChatTurnToolExecutionStarted() => 'tool-start',
    ChatTurnStreamingGuardAborted() => 'streaming-guard-abort',
    ChatTurnAbortSignalRegistered() => 'abort-signal',
    ChatTurnQueueDrainRequested() => 'queue-drain',
    ChatTurnCompleted() => 'complete',
    ChatTurnFailed() => 'failed',
  };
}

void expectTurnIdentity(ChatTurnEvent event) {
  expect(event.sessionId, 7);
  expect(event.turnId, 42);
}

void main() {
  test('all events carry session and turn identity', () {
    final signal = AbortSignal(sessionId: 7);
    final error = LlmError(
      kind: LlmErrorKind.network,
      vendor: LlmVendor.openai,
      message: 'network',
    );
    final events = <ChatTurnEvent>[
      const ChatTurnDelta(sessionId: 7, turnId: 42, delta: 'a'),
      const ChatTurnReasoningDelta(sessionId: 7, turnId: 42, reasoning: 'r'),
      const ChatTurnChunk(sessionId: 7, turnId: 42),
      const ChatTurnStatusChanged(sessionId: 7, turnId: 42, status: 'waiting'),
      const ChatTurnToolRoundCompleted(
        sessionId: 7,
        turnId: 42,
        toolResultTokens: 12,
      ),
      const ChatTurnToolUseDelta(
        sessionId: 7,
        turnId: 42,
        chunk: ToolUseChunk(callId: 'call_1', name: 'read'),
      ),
      const ChatTurnToolExecutionStarted(
        sessionId: 7,
        turnId: 42,
        toolCalls: [
          ToolCallData(callId: 'call_1', name: 'read', input: {'path': 'a'}),
        ],
      ),
      const ChatTurnStreamingGuardAborted(
        sessionId: 7,
        turnId: 42,
        index: 0,
        callId: 'call_1',
        name: 'write',
        filePath: 'lib/a.dart',
        reason: 'guard',
        abortedInputTokensEstimate: 8,
      ),
      ChatTurnAbortSignalRegistered(sessionId: 7, turnId: 42, signal: signal),
      const ChatTurnQueueDrainRequested(sessionId: 7, turnId: 42),
      const ChatTurnCompleted(
        sessionId: 7,
        turnId: 42,
        promptTokens: 10,
        completionTokens: 3,
        promptCacheHitTokens: 2,
        promptCacheMissTokens: 8,
        queuedMessage: 'next',
      ),
      ChatTurnFailed(sessionId: 7, turnId: 42, error: error),
    ];

    for (final event in events) {
      expectTurnIdentity(event);
      expect(describeEvent(event), isNotEmpty);
    }
  });

  test('payload fields preserve callback data', () {
    final toolChunk = const ToolUseChunk(
      index: 1,
      callId: 'call_b',
      name: 'grep',
      inputDelta: '{"pattern":"TODO"}',
    );
    final toolUse = ChatTurnToolUseDelta(
      sessionId: 1,
      turnId: 2,
      chunk: toolChunk,
    );
    expect(toolUse.chunk, same(toolChunk));

    const toolStarted = ChatTurnToolExecutionStarted(
      sessionId: 1,
      turnId: 2,
      toolCalls: [
        ToolCallData(
          callId: 'call_b',
          name: 'grep',
          input: {'pattern': 'TODO'},
        ),
      ],
    );
    expect(toolStarted.toolCalls.single.callId, 'call_b');
    expect(toolStarted.toolCalls.single.input, {'pattern': 'TODO'});

    const guard = ChatTurnStreamingGuardAborted(
      sessionId: 1,
      turnId: 2,
      index: 3,
      callId: 'call_c',
      name: 'edit',
      filePath: 'lib/file.dart',
      reason: 'read-before-write',
      abortedInputTokensEstimate: 21,
    );
    expect(guard.filePath, 'lib/file.dart');
    expect(guard.abortedInputTokensEstimate, 21);

    const completed = ChatTurnCompleted(
      sessionId: 1,
      turnId: 2,
      promptTokens: 100,
      completionTokens: 20,
      promptCacheHitTokens: 80,
      promptCacheMissTokens: 20,
      queuedMessage: 'queued',
    );
    expect(completed.promptTokens, 100);
    expect(completed.queuedMessage, 'queued');
  });
}
