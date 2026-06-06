import 'dart:async';
import 'session_controller.dart';

class StreamingController {
  final SessionController _sessionController;
  final void Function() _refresh;

  String streamingContent = '';
  String streamingReasoning = '';
  bool contextBarHovered = false;

  final Map<int, Timer> _metricsTimers = {};
  Timer? _contextAnimTimer;
  DateTime? _lastContextTick;
  static const double _contextLerpSpeed = 6.0;

  StreamingController({
    required SessionController sessionController,
    required void Function() refresh,
  }) : _sessionController = sessionController,
       _refresh = refresh;

  void startMetricsTimer(int sessionId) {
    stopMetricsTimer(sessionId);
    _metricsTimers[sessionId] = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) {
        updateLiveMetrics(sessionId);
        _refresh();
      },
    );
  }

  void stopMetricsTimer(int sessionId) {
    _metricsTimers[sessionId]?.cancel();
    _metricsTimers.remove(sessionId);
  }

  void updateLiveMetrics(int sessionId) {
    final rt = _sessionController.runtime(sessionId);
    if (!rt.isResponding || rt.responseStartTime == null) return;

    final elapsedMs =
        DateTime.now().difference(rt.responseStartTime!).inMicroseconds /
        1000.0;

    if (!rt.ttftReceived) {
      rt.ttftMs = elapsedMs;
    }

    final contentChars = streamingContent.length;
    final reasoningChars = streamingReasoning.length;
    final totalChars = contentChars + reasoningChars;
    if (totalChars > 0 && rt.ttftReceived) {
      final estimatedTokens = (totalChars / 3.5).ceil();
      // Measure tok/s as "tokens per second of generation" — i.e. from
      // first-token-arrival to now. Using rt.effectiveStreamingMs here
      // would include the TTFT wait, which deflates the rate
      // significantly for thinking-mode providers (e.g. MiniMax, where
      // TTFT includes a long thinking preamble before the first text
      // delta). If firstTokenTime is somehow null here (race during the
      // first tick), fall back to elapsedMs-since-responseStart.
      final firstT = rt.firstTokenTime;
      final genMs = firstT != null
          ? DateTime.now().difference(firstT).inMicroseconds / 1000.0
          : elapsedMs;
      final elapsedSec = genMs / 1000.0;
      if (elapsedSec > 0) {
        rt.tokPerSec = estimatedTokens / elapsedSec;
      }
    }
  }

  void startContextAnimation() {
    if (_contextAnimTimer != null) return;
    _lastContextTick = DateTime.now();
    _contextAnimTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = DateTime.now();
      final deltaTime =
          now.difference(_lastContextTick!).inMilliseconds / 1000.0;
      _lastContextTick = now;

      final currentSessionId = _sessionController.currentSessionId;
      if (currentSessionId == null) return;
      final rt = _sessionController.runtime(currentSessionId);
      final diff = rt.contextTargetTokens - rt.contextDisplayTokens;
      if (diff.abs() < 0.5) {
        rt.contextDisplayTokens = rt.contextTargetTokens.toDouble();
        stopContextAnimation();
        _refresh();
        return;
      }

      rt.contextDisplayTokens += diff * (deltaTime * _contextLerpSpeed);
      _refresh();
    });
  }

  void stopContextAnimation() {
    _contextAnimTimer?.cancel();
    _contextAnimTimer = null;
    _lastContextTick = null;
  }

  bool contextAnimTimerIsActive() => _contextAnimTimer != null;

  String formatTtft(double ms) {
    if (ms >= 1000) {
      final sec = ms / 1000.0;
      return '${sec.toStringAsFixed(2)}s';
    }
    return '${ms.round()}ms';
  }

  void dispose() {
    for (final timer in _metricsTimers.values) {
      timer.cancel();
    }
    _metricsTimers.clear();
    _contextAnimTimer?.cancel();
  }
}
