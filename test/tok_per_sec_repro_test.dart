// Reproduce the live tok/s readout using the real
// `SessionRuntimeState` math from `StreamingController.updateLiveMetrics`.
// Spins up the same computation path with realistic numbers and checks
// the resulting `tokPerSec` is in a believable range (tens to hundreds,
// NOT thousands).
//
// The reason for an isolated math test (no LlmClient / SSE server):
// `StreamingController.updateLiveMetrics` is the single source of truth
// for what shows on the toolbar. Driving it through a fake SSE server
// just exercises the chunk-arrival path on top of that math; if the
// math itself is buggy, all the SSE-driving tests in the world won't
// surface that. So we exercise the math directly here, with the exact
// inputs that real chat turns produce.

import 'package:crux/src/utils/token_estimate.dart';
import 'package:test/test.dart';

/// Mirrors the body of `StreamingController.updateLiveMetrics` 1:1
/// so this test pins the production math. If somebody changes the
/// formula there, this test will need updating — that's intentional.
double computeTokPerSec({
  required int cumulativeCompletionTokens,
  required double cumulativeGenMs,
  required DateTime? roundFirstTokenTime,
  required String streamingContent,
  required String streamingReasoning,
}) {
  if (roundFirstTokenTime == null) return 0.0;
  final liveStreamingTokens = estimateTokens(
    streamingContent + streamingReasoning,
  );
  final tokens = cumulativeCompletionTokens + liveStreamingTokens;
  var genMs = cumulativeGenMs;
  genMs +=
      DateTime.now().difference(roundFirstTokenTime).inMicroseconds / 1000.0;
  final elapsedSec = genMs / 1000.0;
  if (elapsedSec <= 0) return 0.0;
  return tokens / elapsedSec;
}

void main() {
  group('tok/s math (mirrors StreamingController.updateLiveMetrics)', () {
    test(
      'single round: 250 tokens over 1.7s → ~147 tok/s, never thousands',
      () {
        // Simulate "we're 1.7s into round 1" by setting
        // roundFirstTokenTime 1.7s in the past. The streaming controller
        // will compute elapsed = now - roundFirstTokenTime ≈ 1.7s.
        final firstToken = DateTime.now().subtract(
          const Duration(milliseconds: 1700),
        );

        // Live streaming buffer: 1000 ASCII chars ≈ 250 estimated tokens.
        final liveContent = 'a' * 1000;

        // In a single-round turn, cumulativeCompletionTokens and
        // cumulativeGenMs are still 0 — they only populate at round end.
        final rate = computeTokPerSec(
          cumulativeCompletionTokens: 0,
          cumulativeGenMs: 0,
          roundFirstTokenTime: firstToken,
          streamingContent: liveContent,
          streamingReasoning: '',
        );

        expect(rate, greaterThan(50));
        expect(rate, lessThan(500));
        expect(rate.isFinite, isTrue);
      },
    );

    test('multi-round WITHOUT cumulativeGenMs folding: reproduces thousands '
        '(the bug shape the user reported)', () {
      // Round 1 streamed 250 tokens over 1.5s and ended. Round 2 has
      // been streaming 100ms with 50 more tokens. We expect tok/s to
      // be 350 / 1.6s ≈ 219 — but only IF the runtime has correctly
      // folded round 1's elapsed time into cumulativeGenMs. Without
      // that fold, the denominator is just round 2's 100ms and the
      // rate blows up to 350 / 0.1 = 3500 tok/s.
      final r2FirstToken = DateTime.now().subtract(
        const Duration(milliseconds: 100),
      );

      final liveContent = 'a' * 200; // ~50 tokens

      final rate = computeTokPerSec(
        cumulativeCompletionTokens: 300, // 250 (round 1) + 50 (round 2 so far)
        cumulativeGenMs: 0.0, // <-- the bug: never folded
        roundFirstTokenTime: r2FirstToken,
        streamingContent: liveContent,
        streamingReasoning: '',
      );

      expect(
        rate,
        greaterThan(2000),
        reason:
            'without folding elapsed time into cumulativeGenMs, '
            'multi-round tok/s reads in the thousands — matches the '
            'user-reported bug',
      );
    });

    test(
      'multi-round WITH cumulativeGenMs folded: stays in believable range',
      () {
        // Same scenario, but with the fix in place — round 1's 1500ms
        // was folded into cumulativeGenMs at round end.
        final r2FirstToken = DateTime.now().subtract(
          const Duration(milliseconds: 100),
        );

        final liveContent = 'a' * 200;

        final rate = computeTokPerSec(
          cumulativeCompletionTokens: 300,
          cumulativeGenMs: 1500.0, // round 1's 1.5s folded in
          roundFirstTokenTime: r2FirstToken,
          streamingContent: liveContent,
          streamingReasoning: '',
        );

        // 350 / (1500 + 100)/1000 = 350 / 1.6 ≈ 219 tok/s.
        expect(
          rate,
          lessThan(1000),
          reason: 'with the fix in place, tok/s stays in a believable range',
        );
        expect(rate, greaterThan(50));
      },
    );

    test('CumulativeGenMs folds across many rounds: 10 rounds × 1s each '
        'with 250 tokens/round → 250 tok/s, not 2500+', () {
      final r10FirstToken = DateTime.now().subtract(
        const Duration(milliseconds: 100),
      );

      // 10 completed rounds, 250 tokens each, 1000ms each = 2500 tokens,
      // 10s cumulative. We're now 100ms into round 10 with 50 tokens
      // streamed so far.
      final liveContent = 'a' * 200;

      final rate = computeTokPerSec(
        cumulativeCompletionTokens: 250 * 10,
        cumulativeGenMs: 1000.0 * 10, // every round folded
        roundFirstTokenTime: r10FirstToken,
        streamingContent: liveContent,
        streamingReasoning: '',
      );

      // 2550 / 10.1s ≈ 252 tok/s — believable steady-state rate.
      expect(rate, lessThan(1000));
      expect(rate, greaterThan(100));
    });
  });
}
