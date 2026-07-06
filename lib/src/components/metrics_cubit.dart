import 'package:bloc/bloc.dart';

import '../models/session_runtime_sink.dart';
import '../models/session_runtime_state.dart';

class MetricsSessionState {
  const MetricsSessionState({
    this.tokPerSec = 0.0,
    this.ttftMs = 0.0,
    this.ttftReceived = false,
    this.responseStartTime,
    this.contentStartTime,
    this.firstTokenTime,
    this.cumulativeGenMs = 0.0,
    this.cumulativeCompletionTokens = 0,
    this.roundStartTime,
    this.roundFirstTokenTime,
    this.roundStreaming = false,
    this.contextTargetTokens = 0,
    this.turnBaseTokens = 0,
    this.accumulatedToolTokens = 0,
    this.cacheHitPct,
  });

  final double tokPerSec;
  final double ttftMs;
  final bool ttftReceived;
  final DateTime? responseStartTime;
  final DateTime? contentStartTime;
  final DateTime? firstTokenTime;
  final double cumulativeGenMs;
  final int cumulativeCompletionTokens;
  final DateTime? roundStartTime;
  final DateTime? roundFirstTokenTime;
  final bool roundStreaming;
  final int contextTargetTokens;
  final int turnBaseTokens;
  final int accumulatedToolTokens;
  final double? cacheHitPct;

  double get thinkingDurationMs {
    if (responseStartTime == null) return 0;
    final end = contentStartTime ?? DateTime.now();
    return end.difference(responseStartTime!).inMicroseconds / 1000.0;
  }

  MetricsSessionState copyWith({
    double? tokPerSec,
    double? ttftMs,
    bool? ttftReceived,
    Object? responseStartTime = _unset,
    Object? contentStartTime = _unset,
    Object? firstTokenTime = _unset,
    double? cumulativeGenMs,
    int? cumulativeCompletionTokens,
    Object? roundStartTime = _unset,
    Object? roundFirstTokenTime = _unset,
    bool? roundStreaming,
    int? contextTargetTokens,
    int? turnBaseTokens,
    int? accumulatedToolTokens,
    Object? cacheHitPct = _unset,
  }) {
    return MetricsSessionState(
      tokPerSec: tokPerSec ?? this.tokPerSec,
      ttftMs: ttftMs ?? this.ttftMs,
      ttftReceived: ttftReceived ?? this.ttftReceived,
      responseStartTime: identical(responseStartTime, _unset)
          ? this.responseStartTime
          : responseStartTime as DateTime?,
      contentStartTime: identical(contentStartTime, _unset)
          ? this.contentStartTime
          : contentStartTime as DateTime?,
      firstTokenTime: identical(firstTokenTime, _unset)
          ? this.firstTokenTime
          : firstTokenTime as DateTime?,
      cumulativeGenMs: cumulativeGenMs ?? this.cumulativeGenMs,
      cumulativeCompletionTokens:
          cumulativeCompletionTokens ?? this.cumulativeCompletionTokens,
      roundStartTime: identical(roundStartTime, _unset)
          ? this.roundStartTime
          : roundStartTime as DateTime?,
      roundFirstTokenTime: identical(roundFirstTokenTime, _unset)
          ? this.roundFirstTokenTime
          : roundFirstTokenTime as DateTime?,
      roundStreaming: roundStreaming ?? this.roundStreaming,
      contextTargetTokens: contextTargetTokens ?? this.contextTargetTokens,
      turnBaseTokens: turnBaseTokens ?? this.turnBaseTokens,
      accumulatedToolTokens:
          accumulatedToolTokens ?? this.accumulatedToolTokens,
      cacheHitPct: identical(cacheHitPct, _unset)
          ? this.cacheHitPct
          : cacheHitPct as double?,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is MetricsSessionState &&
        other.tokPerSec == tokPerSec &&
        other.ttftMs == ttftMs &&
        other.ttftReceived == ttftReceived &&
        other.responseStartTime == responseStartTime &&
        other.contentStartTime == contentStartTime &&
        other.firstTokenTime == firstTokenTime &&
        other.cumulativeGenMs == cumulativeGenMs &&
        other.cumulativeCompletionTokens == cumulativeCompletionTokens &&
        other.roundStartTime == roundStartTime &&
        other.roundFirstTokenTime == roundFirstTokenTime &&
        other.roundStreaming == roundStreaming &&
        other.contextTargetTokens == contextTargetTokens &&
        other.turnBaseTokens == turnBaseTokens &&
        other.accumulatedToolTokens == accumulatedToolTokens &&
        other.cacheHitPct == cacheHitPct;
  }

  @override
  int get hashCode => Object.hash(
    tokPerSec,
    ttftMs,
    ttftReceived,
    responseStartTime,
    contentStartTime,
    firstTokenTime,
    cumulativeGenMs,
    cumulativeCompletionTokens,
    roundStartTime,
    roundFirstTokenTime,
    roundStreaming,
    contextTargetTokens,
    turnBaseTokens,
    accumulatedToolTokens,
    cacheHitPct,
  );
}

class MetricsCubitState {
  MetricsCubitState({Map<int, MetricsSessionState> sessions = const {}})
    : sessions = Map.unmodifiable(sessions);

  final Map<int, MetricsSessionState> sessions;

  MetricsSessionState sessionState(int sessionId) {
    return sessions[sessionId] ?? const MetricsSessionState();
  }

  MetricsCubitState copyWith({Map<int, MetricsSessionState>? sessions}) {
    return MetricsCubitState(sessions: sessions ?? this.sessions);
  }

  @override
  bool operator ==(Object other) {
    return other is MetricsCubitState && _mapEquals(other.sessions, sessions);
  }

  @override
  int get hashCode => _mapHash(sessions);
}

class MetricsCubit extends Cubit<MetricsCubitState> {
  MetricsCubit({MetricsCubitState? initialState})
    : super(initialState ?? MetricsCubitState());

  SessionRuntimeSink runtimeSinkFor(
    int sessionId,
    SessionRuntimeState runtime,
  ) {
    return MetricsRuntimeSink(
      sessionId: sessionId,
      cubit: this,
      runtime: runtime,
    );
  }

  void beginResponse(int sessionId, {DateTime? now}) {
    _put(
      sessionId,
      MetricsSessionState(responseStartTime: now ?? DateTime.now()),
    );
  }

  void beginModelRound(int sessionId, {DateTime? now}) {
    final current = state.sessionState(sessionId);
    _put(
      sessionId,
      current.copyWith(
        roundStartTime: now ?? DateTime.now(),
        roundFirstTokenTime: null,
        roundStreaming: true,
      ),
    );
  }

  void recordFirstToken(int sessionId, DateTime now) {
    final current = state.sessionState(sessionId);
    if (current.ttftReceived || current.responseStartTime == null) {
      if (current.roundFirstTokenTime == null) {
        _put(sessionId, current.copyWith(roundFirstTokenTime: now));
      }
      return;
    }
    _put(
      sessionId,
      current.copyWith(
        ttftMs:
            now.difference(current.responseStartTime!).inMicroseconds / 1000.0,
        ttftReceived: true,
        firstTokenTime: now,
        roundFirstTokenTime: current.roundFirstTokenTime ?? now,
      ),
    );
  }

  void recordRoundFirstToken(int sessionId, DateTime now) {
    final current = state.sessionState(sessionId);
    if (current.roundFirstTokenTime != null) return;
    _put(sessionId, current.copyWith(roundFirstTokenTime: now));
  }

  void recordContentStarted(int sessionId, {DateTime? now}) {
    final current = state.sessionState(sessionId);
    if (current.contentStartTime != null) return;
    _put(sessionId, current.copyWith(contentStartTime: now ?? DateTime.now()));
  }

  void addCompletionTokens(int sessionId, int estimatedTokens) {
    if (estimatedTokens <= 0) return;
    final current = state.sessionState(sessionId);
    _put(
      sessionId,
      current.copyWith(
        cumulativeCompletionTokens:
            current.cumulativeCompletionTokens + estimatedTokens,
      ),
    );
  }

  void finishModelRound({
    required int sessionId,
    DateTime? now,
    bool accumulateGeneration = false,
  }) {
    final current = state.sessionState(sessionId);
    var cumulativeGenMs = current.cumulativeGenMs;
    if (accumulateGeneration &&
        current.roundStreaming &&
        current.roundFirstTokenTime != null) {
      cumulativeGenMs +=
          (now ?? DateTime.now())
              .difference(current.roundFirstTokenTime!)
              .inMicroseconds /
          1000.0;
    }
    _put(
      sessionId,
      current.copyWith(
        cumulativeGenMs: cumulativeGenMs,
        roundStartTime: null,
        roundFirstTokenTime: null,
        roundStreaming: false,
      ),
    );
  }

  /// Computes tok/s and live TTFT from values already held in the
  /// cubit state. This is the "cubit-only" version of the live-metrics
  /// tick; it is exercised directly in unit tests and will become the
  /// production path once all metric fields are mirrored from the
  /// runtime into the cubit. Today, production code still calls
  /// [StreamingController.updateLiveMetrics] (which reads the runtime
  /// as the write-side SSoT and mirrors the result here), so changes
  /// to this method do not affect the live UI until the mirror slice
  /// lands.
  void updateLiveMetrics({
    required int sessionId,
    required int liveStreamingTokens,
    DateTime? now,
  }) {
    final current = state.sessionState(sessionId);
    final responseStart = current.responseStartTime;
    final sampleTime = now ?? DateTime.now();
    if (responseStart == null) return;

    var next = current;
    if (!current.ttftReceived) {
      next = next.copyWith(
        ttftMs: sampleTime.difference(responseStart).inMicroseconds / 1000.0,
      );
    }
    if (!current.roundStreaming || current.roundFirstTokenTime == null) {
      _put(sessionId, next);
      return;
    }

    final tokens = current.cumulativeCompletionTokens + liveStreamingTokens;
    final genMs =
        current.cumulativeGenMs +
        sampleTime.difference(current.roundFirstTokenTime!).inMicroseconds /
            1000.0;
    if (genMs <= 0) {
      _put(sessionId, next);
      return;
    }
    _put(sessionId, next.copyWith(tokPerSec: tokens / (genMs / 1000.0)));
  }

  void updateContext({
    required int sessionId,
    int? turnBaseTokens,
    int? accumulatedToolTokens,
    int? targetTokens,
  }) {
    final current = state.sessionState(sessionId);
    _put(
      sessionId,
      current.copyWith(
        turnBaseTokens: turnBaseTokens,
        accumulatedToolTokens: accumulatedToolTokens,
        contextTargetTokens: targetTokens,
      ),
    );
  }

  void recordCacheHitPct({
    required int sessionId,
    required int hitTokens,
    required int missTokens,
  }) {
    final total = hitTokens + missTokens;
    _put(
      sessionId,
      state
          .sessionState(sessionId)
          .copyWith(
            cacheHitPct: total > 0
                ? ((hitTokens / total) * 1000).roundToDouble() / 10.0
                : null,
          ),
    );
  }

  void resetSession(int sessionId) {
    _put(sessionId, const MetricsSessionState());
  }

  void replaceSessionState(int sessionId, MetricsSessionState value) {
    _put(sessionId, value);
  }

  void removeSession(int sessionId) {
    emit(state.copyWith(sessions: _withoutKey(state.sessions, sessionId)));
  }

  void _put(int sessionId, MetricsSessionState value) {
    emit(state.copyWith(sessions: {...state.sessions, sessionId: value}));
  }
}

class MetricsRuntimeSink implements SessionRuntimeSink {
  MetricsRuntimeSink({
    required this.sessionId,
    required MetricsCubit cubit,
    required SessionRuntimeState runtime,
  }) : _cubit = cubit,
       _runtime = runtime;

  @override
  final int sessionId;

  final MetricsCubit _cubit;
  final SessionRuntimeState _runtime;

  @override
  void resetMetrics({
    int? turnBaseTokens,
    int? accumulatedToolTokens,
    int? targetTokens,
  }) {
    final current = _cubit.state.sessionState(sessionId);
    _runtime.resetMetrics();
    _cubit.replaceSessionState(
      sessionId,
      MetricsSessionState(
        turnBaseTokens: turnBaseTokens ?? current.turnBaseTokens,
        accumulatedToolTokens:
            accumulatedToolTokens ?? current.accumulatedToolTokens,
        contextTargetTokens: targetTokens ?? current.contextTargetTokens,
      ),
    );
  }

  @override
  void beginResponse({DateTime? now, bool btwMode = false}) {
    _cubit.beginResponse(sessionId, now: now);
    _runtime.isResponding = true;
    _runtime.btwMode = btwMode;
    _runtime.interrupted = false;
    _runtime.tokCount = 0.0;
  }

  @override
  void beginModelRound({DateTime? now}) {
    _runtime.startStreamingTimer();
    _cubit.beginModelRound(sessionId, now: now);
  }

  @override
  void recordContentStarted(DateTime now) {
    _cubit.recordContentStarted(sessionId, now: now);
  }

  @override
  void recordFirstToken(DateTime now) {
    _cubit.recordFirstToken(sessionId, now);
  }

  @override
  void recordRoundFirstToken(DateTime now) {
    _cubit.recordRoundFirstToken(sessionId, now);
  }

  @override
  void addCompletionTokens(int estimatedTokens) {
    _cubit.addCompletionTokens(sessionId, estimatedTokens);
  }

  @override
  void finishModelRound({DateTime? now, bool accumulateGeneration = false}) {
    _runtime.pauseStreamingTimer();
    _cubit.finishModelRound(
      sessionId: sessionId,
      now: now,
      accumulateGeneration: accumulateGeneration,
    );
  }

  @override
  void finishResponse({bool interrupted = false}) {
    _runtime.pauseStreamingTimer();
    _cubit.finishModelRound(sessionId: sessionId);
    _runtime.isResponding = false;
    _runtime.interrupted = interrupted;
    if (!interrupted) _runtime.btwMode = false;
  }

  @override
  void updateContext({
    int? turnBaseTokens,
    int? accumulatedToolTokens,
    int? targetTokens,
  }) {
    _cubit.updateContext(
      sessionId: sessionId,
      turnBaseTokens: turnBaseTokens,
      accumulatedToolTokens: accumulatedToolTokens,
      targetTokens: targetTokens,
    );
  }

  @override
  void recordCacheHitPct({required int hitTokens, required int missTokens}) {
    _cubit.recordCacheHitPct(
      sessionId: sessionId,
      hitTokens: hitTokens,
      missTokens: missTokens,
    );
  }
}

const _unset = Object();

Map<K, V> _withoutKey<K, V>(Map<K, V> source, K key) {
  final next = Map<K, V>.from(source)..remove(key);
  return next;
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}

int _mapHash<K, V>(Map<K, V> map) {
  return Object.hashAllUnordered(
    map.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}
