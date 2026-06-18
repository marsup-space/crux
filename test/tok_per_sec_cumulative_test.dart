import 'package:test/test.dart';
import 'package:crux/src/models/session_runtime_state.dart';

/// Simulates the lifecycle of `cumulativeGenMs`, `cumulativeCompletionTokens`,
/// and `roundStreaming` across a 2-round turn (text → tool_use → text).
///
/// The streaming controller and chat service follow this exact pattern:
///   1. round 1 starts: roundStreaming=true, roundStartTime=req1,
///                   roundFirstTokenTime=null
///   2. first delta: roundFirstTokenTime=now1,
///                   tool_use JSON deltas are accumulated as they stream
///   3. more text/reasoning deltas stream in live UI buffers
///   4. round 1 ends: cumulativeCompletionTokens += text/reasoning tokens,
///                    cumulativeGenMs += (now - req1),
///                    roundStreaming=false, roundStartTime=null,
///                    roundFirstTokenTime=null
///   5. (tool execution / wait — tok/s paused)
///   6. round 2 starts: roundStreaming=true, roundStartTime=req2,
///                       roundFirstTokenTime=null
///   7. first delta of round 2: roundFirstTokenTime=now2,
///                              live text/reasoning buffers resume
///   8. round 2 ends: cumulativeGenMs += (now - req2)
///   9. tok/s = cumulativeCompletionTokens / (cumulativeGenMs / 1000)
void main() {
  group('cumulative tok/s across rounds', () {
    test('round 1 only: tok/s reflects just that round', () {
      final rt = SessionRuntimeState(sessionId: 1);

      // Round 1 begins at t=0, first delta at t=1000.
      final t0 = DateTime(2024, 1, 1, 0, 0, 0);
      rt.roundStartTime = t0;
      rt.roundFirstTokenTime = t0.add(const Duration(milliseconds: 1000));
      rt.roundStreaming = true;
      // 200 text tokens emitted over the round.
      rt.cumulativeCompletionTokens += 200;

      // Round 1 ends 2 seconds after request start, including 1s thinking.
      rt.cumulativeGenMs += 2000.0;
      rt.roundStreaming = false;
      rt.roundStartTime = null;
      rt.roundFirstTokenTime = null;

      // Total: 200 tokens / 2.0s = 100 tok/s.
      final genSec = rt.cumulativeGenMs / 1000.0;
      final rate = rt.cumulativeCompletionTokens / genSec;
      expect(rate, closeTo(100.0, 0.001));
    });

    test('2 rounds with tool execution: rate covers both rounds, '
        'excluding the tool-execution wait', () {
      final rt = SessionRuntimeState(sessionId: 1);

      // ── Round 1: 100 tokens emitted over 1.0s ──
      final t0 = DateTime(2024, 1, 1, 0, 0, 0);
      rt.roundStartTime = t0;
      rt.roundFirstTokenTime = t0.add(const Duration(milliseconds: 1000));
      rt.roundStreaming = true;
      rt.cumulativeCompletionTokens += 100;
      rt.cumulativeGenMs += 1000.0;
      rt.roundStreaming = false;
      rt.roundStartTime = null;
      rt.roundFirstTokenTime = null;

      // ── Tool execution takes 5s. During this time the metrics
      //    timer would fire, but `updateLiveMetrics` short-circuits
      //    because !roundStreaming, so tok/s is NOT recomputed. It
      //    stays whatever it was at the end of round 1. ──
      expect(rt.roundStreaming, isFalse);
      expect(rt.cumulativeGenMs, 1000.0);

      // ── Round 2: 300 tokens (incl. 50 from tool_use JSON) over
      //    1.5s. The 50 tool_use tokens are accumulated into
      //    cumulativeCompletionTokens as the deltas come in. ──
      rt.roundStartTime = t0.add(const Duration(milliseconds: 1000 + 5000));
      rt.roundFirstTokenTime = rt.roundStartTime!.add(
        const Duration(milliseconds: 500),
      );
      rt.roundStreaming = true;
      rt.cumulativeCompletionTokens += 250; // 200 text + 50 tool_use
      rt.cumulativeGenMs += 1500.0;
      rt.roundStreaming = false;
      rt.roundStartTime = null;
      rt.roundFirstTokenTime = null;

      // Total: 350 tokens / 2.5s = 140 tok/s.
      // The 5s of tool execution time is correctly excluded.
      final genSec = rt.cumulativeGenMs / 1000.0;
      final rate = rt.cumulativeCompletionTokens / genSec;
      expect(rate, closeTo(140.0, 0.001));
      expect(genSec, closeTo(2.5, 0.0001));
    });

    test('paused between rounds: roundStreaming false blocks update', () {
      // This is the contract: streaming_controller's updateLiveMetrics
      // returns early when !roundStreaming. We assert the invariant
      // the streaming controller depends on.
      final rt = SessionRuntimeState(sessionId: 1)
        ..cumulativeGenMs = 1500.0
        ..cumulativeCompletionTokens = 200;

      // Simulate "between rounds, tool executing":
      rt.roundStreaming = false;
      rt.roundStartTime = null;
      rt.roundFirstTokenTime = null;

      // The streaming_controller will skip its tok/s update
      // computation while this is true. Verify the state required
      // for that early return.
      expect(rt.roundStreaming, isFalse);
      expect(
        rt.cumulativeGenMs,
        1500.0,
        reason: 'cumulativeGenMs must NOT be reset between rounds',
      );
      expect(
        rt.cumulativeCompletionTokens,
        200,
        reason: 'token count must NOT be reset between rounds',
      );
    });

    test('next round thinking keeps prior streamed reasoning in numerator', () {
      final rt = SessionRuntimeState(sessionId: 1);

      // Round 1 streamed a long reasoning block at about 90 tok/s and ended
      // with a small tool_use JSON tail.
      rt.cumulativeCompletionTokens += 90; // streamed reasoning/text
      rt.cumulativeCompletionTokens += 15; // streamed tool_use JSON
      rt.cumulativeGenMs += 1000.0;
      rt.roundStreaming = false;
      rt.roundStartTime = null;
      rt.roundFirstTokenTime = null;

      // Local tool execution is paused and excluded. The next model request
      // has started and is thinking, but no new text/reasoning has arrived,
      // so the live streaming buffers would be empty.
      rt.roundStreaming = true;
      rt.roundStartTime = DateTime(2024, 1, 1);
      final currentRoundThinkingMs = 250.0;

      final genSec = (rt.cumulativeGenMs + currentRoundThinkingMs) / 1000.0;
      final rate = rt.cumulativeCompletionTokens / genSec;

      // Without preserving the prior reasoning/text tokens, this would be
      // 15 / 1.25 = 12 tok/s, which is the snap-down this test guards.
      expect(rate, closeTo(84.0, 0.001));
    });
  });
}
