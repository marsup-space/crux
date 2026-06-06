import 'dart:async';

class SessionRuntimeState {
  final int sessionId;

  bool isResponding;
  Timer? responseTimer;
  Timer? metricsTimer;
  double tokPerSec;
  double ttftMs;
  bool ttftReceived;
  DateTime? responseStartTime;
  DateTime? contentStartTime;
  /// Wall-clock time of the first text or reasoning delta on the current
  /// turn. Used to compute tok/s as `tokens / (now - firstTokenTime)`,
  /// which excludes the TTFT wait. Without this, the tok/s denominator
  /// includes the time spent waiting for the model to start emitting,
  /// which deflates the rate significantly for thinking-mode models
  /// (e.g. MiniMax, where TTFT can be 5–15s of thinking preambles).
  /// Reset to null at the start of each turn.
  DateTime? firstTokenTime;
  double tokCount;
  double streamingDurationMs;
  DateTime? _streamingStart;
  int contextTargetTokens;
  double contextDisplayTokens;
  String thinkingMode;
  String? reasoningEffort;
  int? cacheHitPct;

  bool isGeneratingTldr;

  SessionRuntimeState({
    required this.sessionId,
    this.isResponding = false,
    this.tokPerSec = 0.0,
    this.ttftMs = 0.0,
    this.ttftReceived = false,
    this.responseStartTime,
    this.contentStartTime,
    this.firstTokenTime,
    this.tokCount = 0.0,
    this.streamingDurationMs = 0.0,
    this.contextTargetTokens = 0,
    this.contextDisplayTokens = 0.0,
    this.thinkingMode = 'enabled',
    this.reasoningEffort = 'normal',
    this.cacheHitPct,
    this.isGeneratingTldr = false,
  });

  double get thinkingDurationMs {
    if (responseStartTime == null) return 0;
    final end = contentStartTime ?? DateTime.now();
    return end.difference(responseStartTime!).inMicroseconds / 1000.0;
  }

  void cancelTimers() {
    responseTimer?.cancel();
    responseTimer = null;
    metricsTimer?.cancel();
    metricsTimer = null;
  }

  void resetMetrics() {
    tokPerSec = 0.0;
    ttftMs = 0.0;
    ttftReceived = false;
    tokCount = 0.0;
    streamingDurationMs = 0.0;
    _streamingStart = null;
    responseStartTime = null;
    contentStartTime = null;
    firstTokenTime = null;
    isResponding = false;
    cancelTimers();
  }

  void startStreamingTimer() {
    // Reset the per-turn accumulator: a fresh turn must NOT inherit
    // streamingDurationMs from prior turns, otherwise the tok/s
    // denominator compounds across turns within a session and the
    // reported rate drifts downward with every new turn.
    streamingDurationMs = 0.0;
    _streamingStart = DateTime.now();
  }

  void pauseStreamingTimer() {
    if (_streamingStart != null) {
      streamingDurationMs +=
          DateTime.now().difference(_streamingStart!).inMicroseconds /
          1000.0;
      _streamingStart = null;
    }
  }

  double get effectiveStreamingMs {
    var total = streamingDurationMs;
    if (_streamingStart != null) {
      total +=
          DateTime.now().difference(_streamingStart!).inMicroseconds /
          1000.0;
    }
    return total;
  }
}
