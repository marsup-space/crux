// Tests for per-session streaming-state isolation on the real
// [StreamingController]. The original implementation kept
// `streamingContent` / `streamingReasoning` as shared `String`
// fields on the controller, so `clearStreamingFor(sessionId)` for
// session B would wipe the in-flight content for session A. The fix
// moved them into `Map<int, String>` keyed by session id; these
// tests pin that contract by driving the public API of the real
// controller.

import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/utils/ticker_registry.dart';

void main() {
  late Directory tempDir;
  late ProviderService providerService;
  late SessionStore store;
  late SessionController sessionController;
  late StreamingController streaming;

  setUp(() async {
    TickerRegistry.instance.resetForTest();
    tempDir = await Directory.systemTemp.createTemp('crux_concurrent_');
    providerService = ProviderService(userProvidersDir: tempDir.path);
    store = SessionStore(CruxDatabase());
    final toolRegistry =
        ToolRegistry()..registerDefaults(FileReadTracker(), sessionStore: store);
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
    TickerRegistry.instance.resetForTest();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('StreamingController per-session map isolation', () {
    test('content is isolated per session', () {
      streaming.appendStreamingContent(1, 'hello from session 1');
      streaming.appendStreamingContent(2, 'hello from session 2');

      expect(streaming.streamingContentFor(1), 'hello from session 1');
      expect(streaming.streamingContentFor(2), 'hello from session 2');
    });

    test('reasoning is isolated per session', () {
      streaming.appendStreamingReasoning(1, 'thinking A');
      streaming.appendStreamingReasoning(2, 'thinking B');

      expect(streaming.streamingReasoningFor(1), 'thinking A');
      expect(streaming.streamingReasoningFor(2), 'thinking B');
    });

    test('clearing one session does not affect another', () {
      streaming.appendStreamingContent(1, 'session 1 content');
      streaming.appendStreamingContent(2, 'session 2 content');
      streaming.appendStreamingReasoning(1, 'session 1 reasoning');
      streaming.appendStreamingReasoning(2, 'session 2 reasoning');

      streaming.clearStreamingFor(2);

      expect(streaming.streamingContentFor(1), 'session 1 content');
      expect(streaming.streamingReasoningFor(1), 'session 1 reasoning');
      expect(streaming.streamingContentFor(2), '');
      expect(streaming.streamingReasoningFor(2), '');
    });

    test('appending deltas to one session does not leak into another', () {
      streaming.appendStreamingContent(1, 'AAA');
      streaming.appendStreamingContent(2, 'BBB');
      streaming.appendStreamingContent(1, ' CCC');
      streaming.appendStreamingContent(2, ' DDD');

      expect(streaming.streamingContentFor(1), 'AAA CCC');
      expect(streaming.streamingContentFor(2), 'BBB DDD');
    });

    test('clear then re-append works', () {
      streaming.appendStreamingContent(1, 'first');
      streaming.clearStreamingFor(1);
      expect(streaming.streamingContentFor(1), '');

      streaming.appendStreamingContent(1, 'second');
      expect(streaming.streamingContentFor(1), 'second');
    });

    test('tool input tokens are tracked for any streaming tool', () {
      streaming.updateStreamingToolCall(
        1,
        const ToolUseChunk(
          index: 0,
          callId: '',
          name: '',
          inputDelta: '{"filePath":"lib/a.dart"',
        ),
      );
      streaming.updateStreamingToolCall(
        1,
        const ToolUseChunk(
          index: 0,
          callId: 'call_1',
          name: 'read',
          inputDelta: ',"limit":20}',
        ),
      );

      final calls = streaming.streamingToolCallsFor(1);
      expect(calls, hasLength(1));
      expect(calls.single.callId, 'call_1');
      expect(calls.single.name, 'read');
      expect(streaming.streamingToolInputTokensFor(1), greaterThan(0));
    });

    test('waiting-for-model state is cleared by the next stream delta', () {
      streaming.beginWaitingForModel(1);
      expect(streaming.waitingForModelSeconds(1), isNotNull);

      streaming.updateStreamingToolCall(
        1,
        const ToolUseChunk(
          index: 0,
          callId: 'call_1',
          name: 'grep',
          inputDelta: '{"pattern":"foo"}',
        ),
      );

      expect(streaming.waitingForModelSeconds(1), isNull);
      expect(streaming.streamingToolInputTokensFor(1), greaterThan(0));
    });

    test('executing tools state tracks running tool calls', () {
      streaming.beginExecutingTools(1, const [
        ExecutingToolCall(
          callId: 'call_bash',
          name: 'bash',
          inputPreview: 'sleep 10',
        ),
      ]);

      expect(streaming.executingToolsSeconds(1), isNotNull);
      expect(streaming.executingToolCallsFor(1), hasLength(1));
      expect(streaming.executingToolCallsFor(1).single.name, 'bash');

      streaming.finishExecutingTools(1);
      expect(streaming.executingToolsSeconds(1), isNull);
      expect(streaming.executingToolCallsFor(1), isEmpty);
    });

    test('nonexistent session returns empty string', () {
      expect(streaming.streamingContentFor(999), '');
      expect(streaming.streamingReasoningFor(999), '');
    });

    test(
      'clearStreamingFor on session B does not wipe session A (the original bug)',
      () {
        // Before the fix: streamingContent/streamingReasoning were shared
        // String fields. When the round-end path cleared them for
        // session B, it wiped session A's in-flight content.
        streaming.appendStreamingContent(1, 'session 1 streaming');
        streaming.appendStreamingReasoning(1, 'session 1 reasoning');
        streaming.appendStreamingContent(2, 'session 2 streaming');
        streaming.appendStreamingReasoning(2, 'session 2 reasoning');

        streaming.clearStreamingFor(2);

        expect(streaming.streamingContentFor(1), 'session 1 streaming');
        expect(streaming.streamingReasoningFor(1), 'session 1 reasoning');
      },
    );

    test('interleaved appends across three sessions stay isolated', () {
      for (var i = 0; i < 100; i++) {
        streaming.appendStreamingContent(1, 'A');
        streaming.appendStreamingContent(2, 'B');
        streaming.appendStreamingContent(3, 'C');
      }
      expect(streaming.streamingContentFor(1), 'A' * 100);
      expect(streaming.streamingContentFor(2), 'B' * 100);
      expect(streaming.streamingContentFor(3), 'C' * 100);
    });
  });
}
