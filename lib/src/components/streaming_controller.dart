import 'dart:async';
import '../services/llm_client.dart';
import '../utils/frame_profiler.dart';
import '../utils/token_estimate.dart';
import 'session_controller.dart';

/// Snapshot of an in-progress tool call as it streams in from the
/// LLM. The LLM emits `tool_use` chunks one at a time, each carrying
/// a delta of the input JSON. We accumulate the JSON per call index
/// so the streaming bubble can render a live preview without
/// requiring the full call to have arrived.
///
/// The accumulated JSON is intentionally kept as a raw string
/// (rather than a parsed `Map`) because the input is rarely
/// well-formed until the close braces land — `jsonDecode` would
/// throw on every intermediate chunk. Consumers that want a richer
/// preview (e.g. extracting the key arg of `read` / `bash`) should
/// pass the raw JSON to [ToolDef.streamingLabel] which knows how to
/// degrade gracefully on partial input.
class StreamingToolCall {
  final String callId;
  final String name;
  final String accumulatedInputJson;

  const StreamingToolCall({
    required this.callId,
    required this.name,
    required this.accumulatedInputJson,
  });

  /// Rough token-count of the in-flight input. Cheap to compute
  /// (no JSON parsing) and good enough for "this is growing"
  /// preview labels.
  int get estimatedInputTokens => estimateTokens(accumulatedInputJson);
}

class StreamingController {
  final SessionController _sessionController;
  final void Function() _refresh;

  final Map<int, String> _streamingContent = {};
  final Map<int, String> _streamingReasoning = {};

  /// Per-session, per-tool-call-index accumulator for streaming
  /// `tool_use` chunks. Keyed first by session id, then by the
  /// `index` field the LLM emits on the chunk (parallel calls
  /// share a session but live at different indices). Cleared on
  /// round end and turn end via [clearStreamingFor].
  final Map<int, Map<int, StreamingToolCall>> _streamingToolCalls = {};

  bool contextBarHovered = false;

  String streamingContentFor(int sessionId) =>
      _streamingContent[sessionId] ?? '';
  String streamingReasoningFor(int sessionId) =>
      _streamingReasoning[sessionId] ?? '';

  void appendStreamingContent(int sessionId, String delta) {
    _streamingContent[sessionId] =
        (_streamingContent[sessionId] ?? '') + delta;
  }

  void appendStreamingReasoning(int sessionId, String delta) {
    _streamingReasoning[sessionId] =
        (_streamingReasoning[sessionId] ?? '') + delta;
  }

  /// Fold a [ToolUseChunk] from the LLM into the per-session,
  /// per-index in-progress tool call. The first chunk for a given
  /// index seeds the call (id, name) and the input accumulator;
  /// subsequent chunks append to the input. The bubble pulls the
  /// accumulated snapshot via [streamingToolCallsFor].
  ///
  /// Note: we don't trigger a refresh here — `onChunk` (the
  /// `text_delta` handler) is what calls `setState`, so the
  /// controller's update piggybacks on the existing render tick.
  void updateStreamingToolCall(int sessionId, ToolUseChunk chunk) {
    final perSession = _streamingToolCalls.putIfAbsent(
      sessionId,
      () => <int, StreamingToolCall>{},
    );
    final existing = perSession[chunk.index];
    if (existing == null) {
      perSession[chunk.index] = StreamingToolCall(
        callId: chunk.callId,
        name: chunk.name,
        accumulatedInputJson: chunk.inputDelta,
      );
    } else {
      perSession[chunk.index] = StreamingToolCall(
        callId: existing.callId,
        name: existing.name,
        accumulatedInputJson: existing.accumulatedInputJson + chunk.inputDelta,
      );
    }
  }

  /// Snapshot of in-progress tool calls for a session, in the
  /// order the LLM declared them (i.e. by chunk index). Empty
  /// if the round hasn't emitted any `tool_use` deltas yet, or
  /// if [clearStreamingFor] has been called since the last round.
  List<StreamingToolCall> streamingToolCallsFor(int sessionId) {
    final perSession = _streamingToolCalls[sessionId];
    if (perSession == null || perSession.isEmpty) return const [];
    final keys = perSession.keys.toList()..sort();
    return [for (final k in keys) perSession[k]!];
  }

  void clearStreamingFor(int sessionId) {
    _streamingContent.remove(sessionId);
    _streamingReasoning.remove(sessionId);
    _streamingToolCalls.remove(sessionId);
  }

  // The metricsTimer was previously held here in a per-session
  // map and called `_refresh()` (chat-panel-wide setState) on
  // every 50ms tick. That responsibility now lives in
  // [MetricsDisplay] (see components/metrics_display.dart),
  // which owns its own 50ms Timer and rebuilds only itself.
  // The legacy `startMetricsTimer` / `stopMetricsTimer` API
  // is preserved as a no-op shim so existing callers in
  // `chat_panel.dart` and `chat_turn_orchestrator.dart` don't
  // have to be updated — the widget picks up the "isResponding
  // changed" signal through its own `didUpdateComponent`.
  final Map<int, Timer> _metricsTimers = {};
  // Context bar animation was moved to [ContextBar] in
  // components/context_bar.dart. The bar now owns its own
  // 16ms lerp Timer, so the streaming controller no longer
  // needs to call `_refresh()` (chat-panel-wide setState)
  // every tick. The legacy `startContextAnimation` /
  // `stopContextAnimation` / `contextAnimTimerIsActive` API
  // is kept as a no-op shim so chat_turn_orchestrator and
  // other callers don't need to be updated, but they no
  // longer have any effect — the real animation lives in
  // the widget that actually paints the bar.
  Timer? _contextAnimTimer;
  DateTime? _lastContextTick;
  static const double _contextLerpSpeed = 6.0;

  StreamingController({
    required SessionController sessionController,
    required void Function() refresh,
  }) : _sessionController = sessionController,
       _refresh = refresh;

  /// No-op legacy API. The metrics display is now driven
  /// by the [MetricsDisplay] widget, which owns its own
  /// 50ms Timer and reads the runtime's `tokPerSec` /
  /// `ttftMs` from its own state — no chat-panel-wide
  /// `_refresh()` happens on every tick. The [updateLiveMetrics]
  /// method is still public and is still the right thing
  /// for the widget to call on each tick; what's gone is
  /// the chat-panel-wide `setState` that used to follow it.
  void startMetricsTimer(int sessionId) {
    // Intentionally empty — MetricsDisplay handles its own
    // timer based on `rt.isResponding` changes detected via
    // its own `didUpdateComponent`.
  }

  void stopMetricsTimer(int sessionId) {
    // Intentionally empty.
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

    // Pause tok/s while we're outside active token generation. That means:
    // before the first model delta arrives, during local tool execution,
    // between LLM requests, and during idle UI time.
    if (!rt.roundStreaming || rt.roundFirstTokenTime == null) return;

    // Live numerator: completed text/reasoning/tool_use tokens from prior
    // rounds, plus tool_use JSON deltas already emitted in this round, plus
    // the current round's still-buffered streaming text/reasoning. Including
    // tool_use is what makes tok/s reflect the LLM's actual generation rate
    // for an agentic turn, not just the visible text rate.
    final liveStreamingTokens = estimateTokens(
      streamingContentFor(sessionId) + streamingReasoningFor(sessionId),
    );
    final tokens = rt.cumulativeCompletionTokens + liveStreamingTokens;

    // Live denominator: cumulative generated-token time of all completed
    // rounds plus the current round's elapsed time since its first emitted
    // token/delta. The first delta can be reasoning, response text, or
    // tool_use JSON. This excludes TTFT, local tool execution, between-round
    // waits, and idle UI time.
    var genMs = rt.cumulativeGenMs;
    genMs +=
        DateTime.now().difference(rt.roundFirstTokenTime!).inMicroseconds /
        1000.0;

    final elapsedSec = genMs / 1000.0;
    if (elapsedSec > 0) {
      rt.tokPerSec = tokens / elapsedSec;
    }
  }

  /// No-op legacy API. The real context-bar animation lives
  /// in the [ContextBar] widget now (it owns its own Timer
  /// and only rebuilds itself). This is kept as a stub so
  /// callers in `chat_turn_orchestrator` don't need to be
  /// touched; they were calling it on every chunk arrival
  /// to kick off the lerp, and the new [ContextBar] handles
  /// "target changed → restart animation" itself via its
  /// own `didUpdateComponent`/build path.
  void startContextAnimation() {
    // Intentionally empty.
  }

  void stopContextAnimation() {
    // Intentionally empty.
  }

  bool contextAnimTimerIsActive() => false;

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
