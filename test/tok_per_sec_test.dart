import 'package:test/test.dart';
import 'package:crux/src/models/session_runtime_state.dart';

/// These tests focus on the `SessionRuntimeState` fields and the
/// `cumulativeGenMs` / `cumulativeCompletionTokens` / `roundStreaming`
/// semantics that the chat service and streaming controller use to
/// compute the displayed tok/s. They verify the invariants that make
/// the metric correct under multi-round tool calls.
void main() {
  group('SessionRuntimeState.resetMetrics', () {
    test('clears all tok/s tracking fields', () {
      final rt = SessionRuntimeState(sessionId: 1)
        ..tokPerSec = 42.0
        ..cumulativeGenMs = 1500.0
        ..cumulativeCompletionTokens = 120
        ..roundStartTime = DateTime(2023)
        ..roundFirstTokenTime = DateTime(2024)
        ..roundStreaming = true
        ..ttftMs = 800.0
        ..ttftReceived = true;

      rt.resetMetrics();

      expect(rt.tokPerSec, 0.0);
      expect(rt.cumulativeGenMs, 0.0);
      expect(rt.cumulativeCompletionTokens, 0);
      expect(rt.roundStartTime, isNull);
      expect(rt.roundFirstTokenTime, isNull);
      expect(rt.roundStreaming, isFalse);
      expect(rt.ttftMs, 0.0);
      expect(rt.ttftReceived, isFalse);
    });
  });

  group('round streaming semantics', () {
    test('starts with roundStreaming=false on a fresh state', () {
      final rt = SessionRuntimeState(sessionId: 1);
      expect(rt.roundStreaming, isFalse);
      expect(rt.roundStartTime, isNull);
      expect(rt.roundFirstTokenTime, isNull);
    });

    test('preserves cumulativeGenMs across round boundaries', () {
      // The streaming controller reads cumulativeGenMs even when
      // roundStreaming is false, so it must NOT be wiped between
      // rounds — only the per-round timing fields (roundStreaming,
      // roundFirstTokenTime) reset.
      final rt = SessionRuntimeState(sessionId: 1)
        ..cumulativeGenMs = 250.0
        ..cumulativeCompletionTokens = 80;

      // Simulate "between rounds, local tools executing".
      rt.roundStreaming = false;
      rt.roundStartTime = null;
      rt.roundFirstTokenTime = null;

      expect(
        rt.cumulativeGenMs,
        250.0,
        reason: 'cumulativeGenMs must persist across rounds',
      );
      expect(
        rt.cumulativeCompletionTokens,
        80,
        reason: 'cumulativeCompletionTokens must persist across rounds',
      );
    });

    test('tracks LLM round start separately from first emitted token', () {
      final rt = SessionRuntimeState(sessionId: 1);
      final roundStart = DateTime(2024, 1, 1);
      final firstToken = roundStart.add(const Duration(milliseconds: 750));

      rt.roundStartTime = roundStart;
      rt.roundStreaming = true;

      expect(
        rt.roundStartTime,
        roundStart,
        reason: 'tok/s includes active LLM thinking before first token',
      );
      expect(
        rt.roundFirstTokenTime,
        isNull,
        reason: 'TTFT boundary is still unknown before the first delta',
      );

      rt.roundFirstTokenTime = firstToken;
      expect(rt.roundFirstTokenTime, firstToken);
      expect(rt.roundStartTime, roundStart);
    });
  });
}
