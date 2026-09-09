import 'package:crux/src/components/metrics_cubit.dart';
import 'package:crux/src/models/session_runtime_state.dart';
import 'package:test/test.dart';

void main() {
  group('MetricsCubit', () {
    test('records TTFT on first token and live TTFT before it', () {
      final cubit = MetricsCubit();
      addTearDown(cubit.close);
      final start = DateTime(2026);

      cubit.beginResponse(1, now: start);
      cubit.updateLiveMetrics(
        sessionId: 1,
        liveStreamingTokens: 0,
        now: start.add(const Duration(milliseconds: 250)),
      );
      expect(cubit.state.sessionState(1).ttftMs, 250);
      expect(cubit.state.sessionState(1).ttftReceived, isFalse);

      cubit.recordFirstToken(1, start.add(const Duration(milliseconds: 400)));
      expect(cubit.state.sessionState(1).ttftMs, 400);
      expect(cubit.state.sessionState(1).ttftReceived, isTrue);
      expect(cubit.state.sessionState(1).firstTokenTime, isNotNull);
    });

    test('computes tok/s from generation time and excludes TTFT', () {
      final cubit = MetricsCubit();
      addTearDown(cubit.close);
      final start = DateTime(2026);
      final firstToken = start.add(const Duration(seconds: 2));

      cubit.beginResponse(1, now: start);
      cubit.beginModelRound(1, now: start);
      cubit.recordFirstToken(1, firstToken);
      cubit.updateLiveMetrics(
        sessionId: 1,
        liveStreamingTokens: 100,
        now: firstToken.add(const Duration(seconds: 1)),
      );

      expect(cubit.state.sessionState(1).tokPerSec, 100);
    });

    test('accumulates generation duration across completed rounds', () {
      final cubit = MetricsCubit();
      addTearDown(cubit.close);
      final start = DateTime(2026);

      cubit.beginResponse(1, now: start);
      cubit.beginModelRound(1, now: start);
      cubit.recordFirstToken(1, start);
      cubit.addCompletionTokens(1, 200);
      cubit.finishModelRound(
        sessionId: 1,
        now: start.add(const Duration(seconds: 2)),
        accumulateGeneration: true,
      );

      cubit.beginModelRound(1, now: start.add(const Duration(seconds: 5)));
      cubit.recordFirstToken(1, start.add(const Duration(seconds: 5)));
      cubit.updateLiveMetrics(
        sessionId: 1,
        liveStreamingTokens: 100,
        now: start.add(const Duration(seconds: 6)),
      );

      expect(cubit.state.sessionState(1).cumulativeGenMs, 2000);
      expect(cubit.state.sessionState(1).tokPerSec, 100);
    });

    test('updates context and cache hit metrics', () {
      final cubit = MetricsCubit();
      addTearDown(cubit.close);

      cubit.updateContext(
        sessionId: 1,
        turnBaseTokens: 100,
        accumulatedToolTokens: 25,
        targetTokens: 125,
      );
      cubit.recordCacheHitPct(sessionId: 1, hitTokens: 95, missTokens: 5);

      final state = cubit.state.sessionState(1);
      expect(state.turnBaseTokens, 100);
      expect(state.accumulatedToolTokens, 25);
      expect(state.contextTargetTokens, 125);
      expect(state.cacheHitPct, 95.0);

      cubit.recordCacheHitPct(sessionId: 1, hitTokens: 0, missTokens: 0);
      expect(cubit.state.sessionState(1).cacheHitPct, isNull);
    });

    test('runtime sink adapter updates cubit metrics without mirroring runtime metrics', () {
      final cubit = MetricsCubit();
      addTearDown(cubit.close);
      final runtime = SessionRuntimeState(sessionId: 1);
      final sink = cubit.runtimeSinkFor(1, runtime);
      final start = DateTime(2026);
      final content = start.add(const Duration(milliseconds: 150));
      final first = start.add(const Duration(milliseconds: 200));

      sink.beginResponse(now: start);
      sink.updateContext(
        turnBaseTokens: 100,
        accumulatedToolTokens: 10,
        targetTokens: 110,
      );
      sink.beginModelRound(now: start);
      sink.recordContentStarted(content);
      sink.recordFirstToken(first);
      sink.addCompletionTokens(20);
      sink.finishModelRound(
        now: first.add(const Duration(milliseconds: 800)),
        accumulateGeneration: true,
      );
      sink.recordCacheHitPct(hitTokens: 8, missTokens: 2);

      final metrics = cubit.state.sessionState(1);
      expect(metrics.contentStartTime, content);
      expect(metrics.ttftMs, 200);
      expect(metrics.cumulativeCompletionTokens, 20);
      expect(metrics.cumulativeGenMs, 800);
      expect(metrics.contextTargetTokens, 110);
      expect(metrics.cacheHitPct, 80.0);
      expect(runtime.contentStartTime, isNull);
      expect(runtime.ttftMs, 0);
      expect(runtime.cumulativeCompletionTokens, 0);
      expect(runtime.contextTargetTokens, 0);
      expect(runtime.cacheHitPct, isNull);
    });

    test('runtime sink adapter marks round first delta without TTFT', () {
      final cubit = MetricsCubit();
      addTearDown(cubit.close);
      final runtime = SessionRuntimeState(sessionId: 1);
      final sink = cubit.runtimeSinkFor(1, runtime);
      final start = DateTime(2026);
      final toolDelta = start.add(const Duration(milliseconds: 100));

      sink.beginResponse(now: start);
      sink.beginModelRound(now: start);
      sink.recordRoundFirstToken(toolDelta);

      expect(runtime.roundFirstTokenTime, isNull);
      expect(cubit.state.sessionState(1).roundFirstTokenTime, toolDelta);
      expect(cubit.state.sessionState(1).ttftReceived, isFalse);
    });

    test(
      'runtime sink adapter resets response metrics and preserves context',
      () {
        final cubit = MetricsCubit();
        addTearDown(cubit.close);
        final runtime = SessionRuntimeState(sessionId: 1);
        final sink = cubit.runtimeSinkFor(1, runtime);
        final start = DateTime(2026);
        final first = start.add(const Duration(milliseconds: 50));

        sink.beginResponse(now: start);
        sink.updateContext(
          turnBaseTokens: 100,
          accumulatedToolTokens: 25,
          targetTokens: 125,
        );
        sink.beginModelRound(now: start);
        sink.recordFirstToken(first);
        sink.addCompletionTokens(3);

        sink.resetMetrics();

        final metrics = cubit.state.sessionState(1);
        expect(metrics.responseStartTime, isNull);
        expect(metrics.roundStreaming, isFalse);
        expect(metrics.cumulativeCompletionTokens, 0);
        expect(metrics.contextTargetTokens, 125);
        expect(runtime.responseStartTime, isNull);
        expect(runtime.roundStreaming, isFalse);
        expect(runtime.cumulativeCompletionTokens, 0);
        expect(runtime.contextTargetTokens, 0);
      },
    );
  });
}
