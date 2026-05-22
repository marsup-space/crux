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
  double tokCount;
  int contextTargetTokens;
  double contextDisplayTokens;
  String thinkingMode;
  String? reasoningEffort;

  SessionRuntimeState({
    required this.sessionId,
    this.isResponding = false,
    this.tokPerSec = 0.0,
    this.ttftMs = 0.0,
    this.ttftReceived = false,
    this.responseStartTime,
    this.contentStartTime,
    this.tokCount = 0.0,
    this.contextTargetTokens = 0,
    this.contextDisplayTokens = 0.0,
    this.thinkingMode = 'enabled',
    this.reasoningEffort,
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
    responseStartTime = null;
    contentStartTime = null;
    isResponding = false;
    cancelTimers();
  }
}
