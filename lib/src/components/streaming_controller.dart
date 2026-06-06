import 'dart:async';
import '../utils/token_estimate.dart';
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

    // Pause tok/s while we're between rounds — that is, after the
    // previous round's stream has ended and before the next round's
    // first delta arrives. This covers (a) the TTFT wait at the
    // start of a new round, (b) tool execution, and (c) the network
    // round-trip sending the tool result back. Without this check,
    // the displayed rate would keep ticking down through all of
    // those phases, which is misleading.
    if (!rt.roundStreaming) return;

    // Live numerator: estimated tokens for the streaming text +
    // reasoning, plus the tool_use JSON deltas the LLM emitted in
    // earlier chunks of this turn (already accumulated into
    // rt.cumulativeCompletionTokens by chat_service). Including
    // tool_use is what makes tok/s reflect the LLM's actual
    // generation rate for an agentic turn, not just the visible
    // text rate.
    final liveStreamingTokens = estimateTokens(
      streamingContent + streamingReasoning,
    );
    final tokens = rt.cumulativeCompletionTokens + liveStreamingTokens;

    // Live denominator: cumulative gen time of all completed rounds
    // plus the wall-clock time elapsed in the current round since
    // its first delta. Excludes TTFT (the wait before the round's
    // first delta) and the time spent on tool execution / waiting
    // for the next round.
    var genMs = rt.cumulativeGenMs;
    if (rt.roundFirstTokenTime != null) {
      genMs +=
          DateTime.now().difference(rt.roundFirstTokenTime!).inMicroseconds /
          1000.0;
    } else {
      // Race during the first tick after roundStreaming flipped on
      // but roundFirstTokenTime hadn't been written yet. Fall back
      // to elapsed-since-responseStart to avoid a negative or huge
      // denominator.
      genMs = elapsedMs;
    }

    final elapsedSec = genMs / 1000.0;
    if (elapsedSec > 0) {
      rt.tokPerSec = tokens / elapsedSec;
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
