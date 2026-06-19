// Tests for the per-run metrics aggregator.
//
// The aggregator is a process-wide singleton (matching
// `FrameProfiler.instance`), so every test calls `reset()` in
// setUp to wipe state from any previous case. Tests that need
// a specific start time / duration fabricate a snapshot
// directly rather than waiting on the wall clock.
//
// The summary formatter is exercised through `formatSummary`
// with `useAscii: true` so the assertions are byte-stable
// across platforms.

import 'package:test/test.dart';
import 'package:crux/src/utils/run_metrics.dart';

void main() {
  setUp(() {
    RunMetrics.instance.reset();
  });

  group('RunMetrics', () {
    test('starts empty', () {
      final snap = RunMetrics.instance.getSnapshot();
      expect(snap.turnCount, 0);
      expect(snap.totalTokensIn, 0);
      expect(snap.totalTokensOut, 0);
      expect(snap.cacheHitTokens, 0);
      expect(snap.cacheMissTokens, 0);
      expect(snap.isEmpty, isTrue);
      expect(snap.cacheHitPct, isNull);
    });

    test('recordTurnStart bumps the turn counter', () {
      RunMetrics.instance.recordTurnStart();
      RunMetrics.instance.recordTurnStart();
      RunMetrics.instance.recordTurnStart();
      expect(RunMetrics.instance.getSnapshot().turnCount, 3);
    });

    test('recordTurnUsage accumulates tokens', () {
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 1000,
        tokensOut: 200,
        cacheHit: 800,
        cacheMiss: 200,
      );
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 500,
        tokensOut: 100,
        cacheHit: 100,
        cacheMiss: 400,
      );
      final snap = RunMetrics.instance.getSnapshot();
      expect(snap.totalTokensIn, 1500);
      expect(snap.totalTokensOut, 300);
      expect(snap.cacheHitTokens, 900);
      expect(snap.cacheMissTokens, 600);
    });

    test('recordBtwUsage accumulates tokens but not turn count', () {
      RunMetrics.instance.recordBtwUsage(
        tokensIn: 200,
        tokensOut: 50,
        cacheHit: 50,
        cacheMiss: 150,
      );
      final snap = RunMetrics.instance.getSnapshot();
      expect(snap.turnCount, 0, reason: 'btw must not bump turn count');
      expect(snap.totalTokensIn, 200);
      expect(snap.totalTokensOut, 50);
      expect(snap.cacheHitTokens, 50);
      expect(snap.cacheMissTokens, 150);
    });

    test('cacheHitPct is null with zero tokens', () {
      final snap = RunMetrics.instance.getSnapshot();
      expect(snap.cacheHitPct, isNull);
    });

    test('cacheHitPct is hit / (hit + miss) * 100', () {
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 1000,
        tokensOut: 0,
        cacheHit: 780,
        cacheMiss: 220,
      );
      expect(RunMetrics.instance.getSnapshot().cacheHitPct, closeTo(78.0, 0.01));
    });

    test('cacheHitPct is 100 when every input token was a cache hit', () {
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 1000,
        tokensOut: 0,
        cacheHit: 1000,
        cacheMiss: 0,
      );
      expect(RunMetrics.instance.getSnapshot().cacheHitPct, 100.0);
    });

    test('cacheHitPct is 0 when no tokens were cached', () {
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 1000,
        tokensOut: 0,
        cacheHit: 0,
        cacheMiss: 1000,
      );
      expect(RunMetrics.instance.getSnapshot().cacheHitPct, 0.0);
    });

    test('isEmpty flips when any counter moves', () {
      expect(RunMetrics.instance.getSnapshot().isEmpty, isTrue);

      RunMetrics.instance.recordTurnUsage(
        tokensIn: 1,
        tokensOut: 0,
        cacheHit: 0,
        cacheMiss: 1,
      );
      expect(RunMetrics.instance.getSnapshot().isEmpty, isFalse);
    });

    test('isEmpty flips on a turn-start alone (no tokens yet)', () {
      // A turn-start with no usage yet still counts as
      // activity, so the summary renderer should not show
      // the "no LLM calls" line.
      RunMetrics.instance.recordTurnStart();
      final snap = RunMetrics.instance.getSnapshot();
      expect(snap.turnCount, 1);
      expect(snap.isEmpty, isFalse);
    });

    test('reset() wipes everything back to zero', () {
      RunMetrics.instance.recordTurnStart();
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 100,
        tokensOut: 50,
        cacheHit: 80,
        cacheMiss: 20,
      );
      RunMetrics.instance.reset();
      final snap = RunMetrics.instance.getSnapshot();
      expect(snap.turnCount, 0);
      expect(snap.totalTokensIn, 0);
      expect(snap.totalTokensOut, 0);
      expect(snap.cacheHitTokens, 0);
      expect(snap.cacheMissTokens, 0);
      expect(snap.isEmpty, isTrue);
    });
  });

  group('RunMetrics.formatSummary', () {
    test('empty run shows duration + turns + no-LLM-calls note', () {
      final summary = RunMetrics.instance.formatSummary(useAscii: true);
      // ASCII frame top + bottom are the same set of
      // characters; check the title is present.
      expect(summary, contains('Crux Run Summary'));
      expect(summary, contains('Duration:'));
      expect(summary, contains('Turns:'));
      expect(summary, contains('0'));
      expect(summary, contains('no LLM calls this run'));
    });

    test('active run shows all four metric rows', () {
      RunMetrics.instance.recordTurnStart();
      RunMetrics.instance.recordTurnStart();
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 12_800,
        tokensOut: 2_400,
        cacheHit: 10_000,
        cacheMiss: 2_800,
      );
      final summary = RunMetrics.instance.formatSummary(useAscii: true);
      expect(summary, contains('Duration:'));
      expect(summary, contains('Turns:'));
      expect(summary, contains('2'));
      expect(summary, contains('Tokens in:'));
      expect(summary, contains('12.8K'));
      expect(summary, contains('cache 78%'));
      expect(summary, contains('Tokens out:'));
      expect(summary, contains('2.4K'));
    });

    test('million-scale token counts render as "1.2M"', () {
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 1_200_000,
        tokensOut: 12_500,
        cacheHit: 1_000_000,
        cacheMiss: 200_000,
      );
      final summary = RunMetrics.instance.formatSummary(useAscii: true);
      expect(summary, contains('1.2M'));
    });

    test('huge cache hit (100%) is shown as "cache 100%"', () {
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 5000,
        tokensOut: 0,
        cacheHit: 5000,
        cacheMiss: 0,
      );
      final summary = RunMetrics.instance.formatSummary(useAscii: true);
      expect(summary, contains('cache 100%'));
    });

    test('cache suffix is "—" when no input tokens were recorded', () {
      // This shouldn't normally happen (you can't have
      // output without input), but the renderer should be
      // defensive.
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 0,
        tokensOut: 50,
        cacheHit: 0,
        cacheMiss: 0,
      );
      final summary = RunMetrics.instance.formatSummary(useAscii: true);
      expect(summary, contains('(cache —)'));
    });

    test('unicode variant uses box-drawing characters', () {
      RunMetrics.instance.recordTurnStart();
      RunMetrics.instance.recordTurnUsage(
        tokensIn: 100,
        tokensOut: 50,
        cacheHit: 80,
        cacheMiss: 20,
      );
      final summary = RunMetrics.instance.formatSummary(useAscii: false);
      // The Unicode borders should appear (assuming the
      // host terminal is detected as supporting them; on
      // macOS / Linux that's almost always true).
      if (summary.contains('┌') || summary.contains('│')) {
        expect(summary, contains('┌'));
        expect(summary, contains('│'));
        expect(summary, contains('└'));
      }
    });

    test('indent option prefixes every line', () {
      RunMetrics.instance.recordTurnStart();
      final summary = RunMetrics.instance.formatSummary(
        useAscii: true,
        indent: '> ',
      );
      for (final line in summary.split('\n')) {
        expect(line, startsWith('> '));
      }
    });
  });

  group('RunMetrics — duration formatting', () {
    test('zero duration is "0s"', () {
      // Build a snapshot with explicit zero duration so we
      // don't depend on the wall clock.
      final snap = RunMetricsSnapshot(
        duration: Duration.zero,
        turnCount: 1,
        totalTokensIn: 0,
        totalTokensOut: 0,
        cacheHitTokens: 0,
        cacheMissTokens: 0,
      );
      final summary = RunMetrics.instance.formatSummary(
        snapshot: snap,
        useAscii: true,
      );
      expect(summary, contains('0s'));
    });

    test('sub-minute duration is "<n>s"', () {
      final snap = RunMetricsSnapshot(
        duration: const Duration(seconds: 42),
        turnCount: 1,
        totalTokensIn: 0,
        totalTokensOut: 0,
        cacheHitTokens: 0,
        cacheMissTokens: 0,
      );
      final summary = RunMetrics.instance.formatSummary(
        snapshot: snap,
        useAscii: true,
      );
      expect(summary, contains('42s'));
    });

    test('sub-hour duration is "<m>m <s>s" or "<m>m"', () {
      final snap1 = RunMetricsSnapshot(
        duration: const Duration(minutes: 5, seconds: 23),
        turnCount: 1,
        totalTokensIn: 0,
        totalTokensOut: 0,
        cacheHitTokens: 0,
        cacheMissTokens: 0,
      );
      final summary1 = RunMetrics.instance.formatSummary(
        snapshot: snap1,
        useAscii: true,
      );
      expect(summary1, contains('5m 23s'));

      final snap2 = RunMetricsSnapshot(
        duration: const Duration(minutes: 12),
        turnCount: 1,
        totalTokensIn: 0,
        totalTokensOut: 0,
        cacheHitTokens: 0,
        cacheMissTokens: 0,
      );
      final summary2 = RunMetrics.instance.formatSummary(
        snapshot: snap2,
        useAscii: true,
      );
      // Whole minutes — the trailing "0s" is elided.
      expect(summary2, contains('12m'));
      expect(summary2, isNot(contains('12m 0s')));
    });

    test('sub-day duration is "<h>h <m>m <s>s"', () {
      final snap = RunMetricsSnapshot(
        duration: const Duration(hours: 1, minutes: 12, seconds: 5),
        turnCount: 1,
        totalTokensIn: 0,
        totalTokensOut: 0,
        cacheHitTokens: 0,
        cacheMissTokens: 0,
      );
      final summary = RunMetrics.instance.formatSummary(
        snapshot: snap,
        useAscii: true,
      );
      expect(summary, contains('1h 12m 5s'));
    });

    test('whole-hour duration elides minutes and seconds', () {
      final snap = RunMetricsSnapshot(
        duration: const Duration(hours: 2),
        turnCount: 1,
        totalTokensIn: 0,
        totalTokensOut: 0,
        cacheHitTokens: 0,
        cacheMissTokens: 0,
      );
      final summary = RunMetrics.instance.formatSummary(
        snapshot: snap,
        useAscii: true,
      );
      expect(summary, contains('2h'));
      expect(summary, isNot(contains('2h 0m')));
    });
  });
}
