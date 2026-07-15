// Tests for the new reasoning-phase tracking on [StreamingController].
// The previous bubble rendered `now - roundFirstTokenTime` for the
// think time, which kept ticking while tools were being written or
// executed. The controller now seeds first/last reasoning timestamps
// per round and exposes a phase-active flag so the bubble can freeze
// the time once reasoning has ended.

import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/utils/ticker_registry.dart';

void main() {
  late Directory tempDir;
  late SessionController sessionController;
  late StreamingController streaming;

  setUp(() async {
    TickerRegistry.instance.resetForTest();
    tempDir = await Directory.systemTemp.createTemp('crux_reasoning_phase_');
    final providerService = ProviderService(userProvidersDir: tempDir.path);
    final store = SessionStore(CruxDatabase());
    final tracker = FileReadTracker();
    final toolRegistry = ToolRegistry()
      ..registerDefaults(
        tracker,
        sessionStore: store,
        webProviderRegistry: WebProviderRegistry(),
      );
    sessionController = SessionController(
      store: store,
      providerService: providerService,
      chatService: ChatService(
        store,
        providerService,
        LlmClient(),
        ToolExecutor(toolRegistry),
      ),
      refresh: () {},
    );
    streaming = StreamingController(
      sessionController: sessionController,
      refresh: () {},
    );
  });

  tearDown(() async {
    streaming.dispose();
    sessionController.dispose();
    TickerRegistry.instance.resetForTest();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('first reasoning delta seeds the first/last timestamps', () {
    streaming.appendStreamingReasoning(1, 'hello');

    final first = streaming.reasoningFirstAtFor(1);
    final last = streaming.lastReasoningAtFor(1);

    expect(first, isNotNull);
    expect(last, isNotNull);
    expect(last!.isAtSameMomentAs(first!), isTrue);
    expect(streaming.isReasoningPhaseActiveFor(1), isTrue);
  });

  test('a tool chunk ends the reasoning phase but keeps the window', () {
    streaming.appendStreamingReasoning(1, 'thinking');
    final first = streaming.reasoningFirstAtFor(1);
    final lastBeforeTool = streaming.lastReasoningAtFor(1);

    streaming.updateStreamingToolCall(
      1,
      const ToolUseChunk(
        index: 0,
        callId: 'c1',
        name: 'read',
        inputDelta: '{"filePath":"a.dart"}',
      ),
    );

    expect(streaming.isReasoningPhaseActiveFor(1), isFalse);
    // Window is preserved so the bubble can render the frozen
    // duration after the model has moved on to tools.
    expect(streaming.reasoningFirstAtFor(1), first);
    expect(streaming.lastReasoningAtFor(1), lastBeforeTool);
  });

  test('a response text delta also ends the reasoning phase', () {
    streaming.appendStreamingReasoning(1, 'reasoning text');
    streaming.appendStreamingContent(1, 'hi');

    expect(streaming.isReasoningPhaseActiveFor(1), isFalse);
    expect(streaming.reasoningFirstAtFor(1), isNotNull);
    expect(streaming.lastReasoningAtFor(1), isNotNull);
  });

  test('beginWaitingForModel clears the reasoning window', () {
    streaming.appendStreamingReasoning(1, 'reasoning text');
    streaming.beginWaitingForModel(1);

    expect(streaming.reasoningFirstAtFor(1), isNull);
    expect(streaming.lastReasoningAtFor(1), isNull);
    expect(streaming.isReasoningPhaseActiveFor(1), isFalse);
  });

  test('clearStreamingFor also clears the reasoning window', () {
    streaming.appendStreamingReasoning(1, 'reasoning text');
    streaming.clearStreamingFor(1);

    expect(streaming.reasoningFirstAtFor(1), isNull);
    expect(streaming.lastReasoningAtFor(1), isNull);
    expect(streaming.isReasoningPhaseActiveFor(1), isFalse);
  });
}
