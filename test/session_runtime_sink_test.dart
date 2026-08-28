import 'package:test/test.dart';

import 'package:crux/src/models/session_runtime_sink.dart';
import 'package:crux/src/models/session_runtime_state.dart';

void main() {
  test('SessionRuntimeState implements SessionRuntimeSink', () {
    final runtime = SessionRuntimeState(sessionId: 1);
    expect(runtime, isA<SessionRuntimeSink>());
  });

  test('beginResponse resets prior turn metrics and marks response active', () {
    final start = DateTime(2026, 1, 1, 12);
    final runtime = SessionRuntimeState(sessionId: 1)
      ..tokPerSec = 42
      ..ttftReceived = true
      ..tokCount = 99
      ..roundStreaming = true
      ..interrupted = true;

    runtime.beginResponse(now: start, btwMode: true);

    expect(runtime.isResponding, isTrue);
    expect(runtime.responseStartTime, start);
    expect(runtime.btwMode, isTrue);
    expect(runtime.interrupted, isFalse);
    expect(runtime.tokPerSec, 0);
    expect(runtime.tokCount, 0);
    expect(runtime.ttftReceived, isFalse);
    expect(runtime.roundStreaming, isFalse);
  });

  test(
      'beginResponse clears last-round provider usage so a stale value from '
      'a prior turn never leaks into a new interrupted turn', () {
    final runtime = SessionRuntimeState(sessionId: 1)
      ..lastRoundPromptTokens = 1234
      ..lastRoundCompletionTokens = 567
      ..lastRoundReasoningTokens = 89;

    runtime.beginResponse(now: DateTime(2026, 1, 1, 12));

    expect(runtime.lastRoundPromptTokens, 0);
    expect(runtime.lastRoundCompletionTokens, 0);
    expect(runtime.lastRoundReasoningTokens, 0);
  });

  test('recordFirstToken captures TTFT once', () {
    final start = DateTime(2026, 1, 1, 12);
    final first = start.add(const Duration(milliseconds: 250));
    final second = start.add(const Duration(milliseconds: 500));
    final runtime = SessionRuntimeState(sessionId: 1)
      ..beginResponse(now: start)
      ..beginModelRound(now: start);

    runtime.recordFirstToken(first);
    runtime.recordFirstToken(second);

    expect(runtime.roundFirstTokenTime, first);
    expect(runtime.firstTokenTime, first);
    expect(runtime.ttftReceived, isTrue);
    expect(runtime.ttftMs, 250);
  });

  test('finishModelRound can accumulate generation time', () {
    final start = DateTime(2026, 1, 1, 12);
    final first = start.add(const Duration(milliseconds: 100));
    final end = start.add(const Duration(milliseconds: 1100));
    final runtime = SessionRuntimeState(sessionId: 1)
      ..beginResponse(now: start)
      ..beginModelRound(now: start);
    runtime.recordFirstToken(first);

    runtime.finishModelRound(now: end, accumulateGeneration: true);

    expect(runtime.cumulativeGenMs, 1000);
    expect(runtime.roundStreaming, isFalse);
    expect(runtime.roundStartTime, isNull);
    expect(runtime.roundFirstTokenTime, isNull);
  });

  test('context and cache helpers update derived fields', () {
    final runtime = SessionRuntimeState(sessionId: 1);

    runtime.updateContext(
      turnBaseTokens: 100,
      accumulatedToolTokens: 25,
      targetTokens: 125,
    );
    runtime.recordCacheHitPct(hitTokens: 95, missTokens: 5);

    expect(runtime.turnBaseTokens, 100);
    expect(runtime.accumulatedToolTokens, 25);
    expect(runtime.contextTargetTokens, 125);
    expect(runtime.cacheHitPct, 95.0);

    runtime.recordCacheHitPct(hitTokens: 0, missTokens: 0);
    expect(runtime.cacheHitPct, isNull);
  });

  test('finishResponse clears active round state and records interruption', () {
    final start = DateTime(2026, 1, 1, 12);
    final runtime = SessionRuntimeState(sessionId: 1)
      ..beginResponse(now: start)
      ..beginModelRound(now: start);

    runtime.finishResponse(interrupted: true);

    expect(runtime.isResponding, isFalse);
    expect(runtime.roundStreaming, isFalse);
    expect(runtime.roundStartTime, isNull);
    expect(runtime.roundFirstTokenTime, isNull);
    expect(runtime.interrupted, isTrue);
  });
}
