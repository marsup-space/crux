import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/services/chat_stream_metrics.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:test/test.dart';

void main() {
  group('recordFirstModelOutput', () {
    test('freezes TTFT when the first output is a tool call', () {
      final start = DateTime(2026, 1, 1, 12);
      final firstToolDelta = start.add(const Duration(milliseconds: 250));
      final runtime = SessionRuntimeState(sessionId: 1)
        ..beginResponse(now: start)
        ..beginModelRound(now: start);
      const toolChunk = LlmChunk(
        toolUse: ToolUseChunk(
          index: 0,
          callId: 'call_1',
          name: 'read',
          inputDelta: '{"filePath":"README.md"}',
        ),
      );

      final recorded = recordFirstModelOutput(
        runtime,
        toolChunk,
        now: firstToolDelta,
      );

      expect(recorded, isTrue);
      expect(runtime.ttftReceived, isTrue);
      expect(runtime.ttftMs, 250);
      expect(runtime.firstTokenTime, firstToolDelta);
    });

    test('does not treat usage metadata as model output', () {
      final start = DateTime(2026, 1, 1, 12);
      final runtime = SessionRuntimeState(sessionId: 1)
        ..beginResponse(now: start)
        ..beginModelRound(now: start);

      final recorded = recordFirstModelOutput(
        runtime,
        const LlmChunk(completionTokens: 10),
        now: start.add(const Duration(milliseconds: 250)),
      );

      expect(recorded, isFalse);
      expect(runtime.ttftReceived, isFalse);
      expect(runtime.ttftMs, 0);
    });
  });
}
