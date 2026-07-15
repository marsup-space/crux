import 'dart:async';
import '../services/llm_client.dart';
import '../utils/token_estimate.dart';
import 'session_controller.dart';
// The mirror calls into StreamingCubit, which uses its own copies
// of the tool-call value classes (StreamingToolCall,
// ExecutingToolCall, StreamingToolAbortInfo). Import them with a
// prefix to avoid the name collision with the controller's local
// copies. A future slice will deduplicate the class definitions.
import 'streaming_cubit.dart' as cubit;

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
  final StreamingToolAbortInfo? abortInfo;

  const StreamingToolCall({
    required this.callId,
    required this.name,
    required this.accumulatedInputJson,
    this.abortInfo,
  });

  /// Rough token-count of the in-flight input. Cheap to compute
  /// (no JSON parsing) and good enough for "this is growing"
  /// preview labels.
  int get estimatedInputTokens => estimateTokens(accumulatedInputJson);

  StreamingToolCall copyWith({
    String? callId,
    String? name,
    String? accumulatedInputJson,
    StreamingToolAbortInfo? abortInfo,
  }) {
    return StreamingToolCall(
      callId: callId ?? this.callId,
      name: name ?? this.name,
      accumulatedInputJson: accumulatedInputJson ?? this.accumulatedInputJson,
      abortInfo: abortInfo ?? this.abortInfo,
    );
  }
}

class StreamingToolAbortInfo {
  final String reason;

  /// Estimated token count of this tool call's streamed
  /// `input_delta` at the moment the guard fired.
  final int abortedInputTokensEstimate;

  const StreamingToolAbortInfo({
    required this.reason,
    required this.abortedInputTokensEstimate,
  });
}

class ExecutingToolCall {
  final String callId;
  final String name;
  final String inputPreview;

  const ExecutingToolCall({
    required this.callId,
    required this.name,
    required this.inputPreview,
  });
}

class StreamingController {
  final SessionController _sessionController;
  final void Function() _refresh;

  final Map<int, String> _streamingContent = {};
  final Map<int, String> _streamingReasoning = {};
  final Map<int, DateTime> _waitingForModelSince = {};
  final Map<int, DateTime> _executingToolsSince = {};
  final Map<int, List<ExecutingToolCall>> _executingToolCalls = {};

  /// Timestamp of the first reasoning delta of the current round. Reset
  /// on every [beginWaitingForModel] and stays populated through the
  /// rest of the round so the vibe streaming bubble can freeze the
  /// `think` time once reasoning has ended. Without this, the live
  /// `think` row kept ticking the wall clock while tools were being
  /// written or executed.
  final Map<int, DateTime> _reasoningFirstAt = {};

  /// Timestamp of the most recent reasoning delta. Combined with
  /// [_reasoningFirstAt] this gives the total reasoning time of the
  /// current round, even after the model has stopped emitting
  /// reasoning text.
  final Map<int, DateTime> _lastReasoningAt = {};

  /// True while the LLM is actively emitting reasoning text for the
  /// current round. Flipped to false the moment a tool call, tool
  /// execution, or response text delta arrives. The vibe streaming
  /// bubble freezes the think time while this is false.
  final Map<int, bool> _reasoningPhaseActive = {};

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
    _waitingForModelSince.remove(sessionId);
    _clearExecutingTools(sessionId);
    _endReasoningPhase(sessionId);
    _streamingContent[sessionId] = (_streamingContent[sessionId] ?? '') + delta;
    // Mirror to StreamingCubit so chat_panel consumers can
    // subscribe to the streaming text without going through this
    // controller. The cubit is a passive mirror — its value
    // matches `_streamingContent[sessionId]` after this call.
    _sessionController.streamingCubit.appendStreamingContent(sessionId, delta);
  }

  void appendStreamingReasoning(int sessionId, String delta) {
    _waitingForModelSince.remove(sessionId);
    _clearExecutingTools(sessionId);
    final now = DateTime.now();
    _reasoningFirstAt.putIfAbsent(sessionId, () => now);
    _lastReasoningAt[sessionId] = now;
    _reasoningPhaseActive[sessionId] = true;
    _streamingReasoning[sessionId] =
        (_streamingReasoning[sessionId] ?? '') + delta;
    _sessionController.streamingCubit.appendStreamingReasoning(
      sessionId,
      delta,
    );
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
    _waitingForModelSince.remove(sessionId);
    _clearExecutingTools(sessionId);
    _endReasoningPhase(sessionId);
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
      perSession[chunk.index] = existing.copyWith(
        callId: existing.callId.isEmpty ? chunk.callId : existing.callId,
        name: existing.name.isEmpty ? chunk.name : existing.name,
        accumulatedInputJson: existing.accumulatedInputJson + chunk.inputDelta,
      );
    }
    _sessionController.streamingCubit.updateStreamingToolCall(sessionId, chunk);
  }

  void beginWaitingForModel(int sessionId) {
    _streamingContent.remove(sessionId);
    _streamingReasoning.remove(sessionId);
    _streamingToolCalls.remove(sessionId);
    _clearExecutingTools(sessionId);
    _reasoningFirstAt.remove(sessionId);
    _lastReasoningAt.remove(sessionId);
    _reasoningPhaseActive.remove(sessionId);
    _waitingForModelSince[sessionId] = DateTime.now();
    _sessionController.streamingCubit.beginWaitingForModel(sessionId);
    _refresh();
  }

  double? waitingForModelSeconds(int sessionId) {
    final since = _waitingForModelSince[sessionId];
    if (since == null) return null;
    return DateTime.now().difference(since).inMilliseconds / 1000.0;
  }

  void beginExecutingTools(int sessionId, List<ExecutingToolCall> calls) {
    _streamingContent.remove(sessionId);
    _streamingReasoning.remove(sessionId);
    _streamingToolCalls.remove(sessionId);
    _waitingForModelSince.remove(sessionId);
    _endReasoningPhase(sessionId);
    _executingToolsSince[sessionId] = DateTime.now();
    _executingToolCalls[sessionId] = calls;
    _sessionController.streamingCubit.beginExecutingTools(sessionId, [
      for (final c in calls)
        cubit.ExecutingToolCall(
          callId: c.callId,
          name: c.name,
          inputPreview: c.inputPreview,
        ),
    ]);
    _refresh();
  }

  double? executingToolsSeconds(int sessionId) {
    final since = _executingToolsSince[sessionId];
    if (since == null) return null;
    return DateTime.now().difference(since).inMilliseconds / 1000.0;
  }

  List<ExecutingToolCall> executingToolCallsFor(int sessionId) {
    return _executingToolCalls[sessionId] ?? const [];
  }

  void finishExecutingTools(int sessionId) {
    if (!_executingToolsSince.containsKey(sessionId) &&
        !_executingToolCalls.containsKey(sessionId)) {
      return;
    }
    _clearExecutingTools(sessionId);
    _sessionController.streamingCubit.finishExecutingTools(sessionId);
    _refresh();
  }

  int streamingToolInputTokensFor(int sessionId) {
    final perSession = _streamingToolCalls[sessionId];
    if (perSession == null || perSession.isEmpty) return 0;
    return perSession.values.fold<int>(
      0,
      (sum, call) => sum + call.estimatedInputTokens,
    );
  }

  bool hasLiveStreamingFor(int sessionId) {
    return (_streamingContent[sessionId]?.isNotEmpty ?? false) ||
        (_streamingReasoning[sessionId]?.isNotEmpty ?? false) ||
        (_streamingToolCalls[sessionId]?.isNotEmpty ?? false) ||
        (_executingToolCalls[sessionId]?.isNotEmpty ?? false);
  }

  void markStreamingToolCallAborted(
    int sessionId, {
    required int index,
    required String callId,
    required String name,
    required String reason,
    required int abortedInputTokensEstimate,
  }) {
    final perSession = _streamingToolCalls.putIfAbsent(
      sessionId,
      () => <int, StreamingToolCall>{},
    );
    final existing = perSession[index];
    final abortInfo = StreamingToolAbortInfo(
      reason: reason,
      abortedInputTokensEstimate: abortedInputTokensEstimate,
    );
    perSession[index] = existing == null
        ? StreamingToolCall(
            callId: callId,
            name: name,
            accumulatedInputJson: '',
            abortInfo: abortInfo,
          )
        : existing.copyWith(
            callId: existing.callId.isEmpty ? callId : existing.callId,
            name: existing.name.isEmpty ? name : existing.name,
            abortInfo: abortInfo,
          );
    _sessionController.streamingCubit.markStreamingToolCallAborted(
      sessionId,
      index: index,
      callId: callId,
      name: name,
      reason: reason,
      abortedInputTokensEstimate: abortedInputTokensEstimate,
    );
    _refresh();
  }

  bool hasStreamingToolAbort(int sessionId) {
    final perSession = _streamingToolCalls[sessionId];
    if (perSession == null) return false;
    return perSession.values.any((tc) => tc.abortInfo != null);
  }

  /// First reasoning delta of the current reasoning phase, or
  /// null if the round hasn't started reasoning yet. Used by
  /// [VibeStreamingBubble] to freeze the `think` time once
  /// reasoning has ended and the model has moved on to tool calls,
  /// tool execution, or response prose.
  DateTime? reasoningFirstAtFor(int sessionId) => _reasoningFirstAt[sessionId];

  /// Last reasoning delta within the current round. Combined with
  /// [reasoningFirstAtFor] this gives the total reasoning time,
  /// even after the model has stopped emitting reasoning text.
  DateTime? lastReasoningAtFor(int sessionId) => _lastReasoningAt[sessionId];

  /// True while the LLM is still emitting reasoning text for the
  /// current round. Flipped to false the moment a tool call,
  /// tool execution, or response text delta arrives. The vibe
  /// streaming bubble uses this to decide whether the `think`
  /// time should tick live or freeze at the last value.
  bool isReasoningPhaseActiveFor(int sessionId) =>
      _reasoningPhaseActive[sessionId] ?? false;

  /// Mark the current round's reasoning phase as ended. Called by
  /// tool/content/response transitions so the think time freezes
  /// and subsequent reasoning deltas (rare but possible) start a
  /// fresh phase. The fields stay populated so the frozen
  /// [reasoningFirstAtFor] - [lastReasoningAtFor] window still
  /// reports the correct duration.
  void _endReasoningPhase(int sessionId) {
    _reasoningPhaseActive[sessionId] = false;
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
    _waitingForModelSince.remove(sessionId);
    _clearExecutingTools(sessionId);
    _reasoningFirstAt.remove(sessionId);
    _lastReasoningAt.remove(sessionId);
    _reasoningPhaseActive.remove(sessionId);
    _sessionController.streamingCubit.clearStreamingFor(sessionId);
  }

  void _clearExecutingTools(int sessionId) {
    _executingToolsSince.remove(sessionId);
    _executingToolCalls.remove(sessionId);
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
    // HOTFIX (reverts part of slice 26): the metrics fields
    // (responseStartTime, ttftReceived, roundStreaming, etc.) are
    // NOT mirrored to MetricsCubit anywhere — the cubit's
    // responseStartTime stays null even when rt.responseStartTime
    // is set. Reading these from the cubit made the early-return
    // checks fire on every tick, so tok/s and the context-bar
    // projection never computed. Keep reading the metrics fields
    // from the runtime (the write-side SSoT) and only use the
    // cubit for fields that ARE mirrored — the streaming content
    // and reasoning, which have had mirror calls since slices
    // 23 + 24. The proper full migration requires mirror sites at
    // every rt-field-mutation location (orchestrator sendTurn,
    // onComplete, onToolRound, chat_turn_executor per-delta,
    // btw_turn_handler start/end, tldr_handler). That's a follow-up
    // slice; for now, read from rt for the unmirrored fields.
    final rt = _sessionController.runtime(sessionId);
    if (!rt.isResponding || rt.responseStartTime == null) return;

    final elapsedMs =
        DateTime.now().difference(rt.responseStartTime!).inMicroseconds /
        1000.0;

    if (!rt.ttftReceived) {
      rt.ttftMs = elapsedMs;
    }

    // Mirror the live TTFT (and contextTargetTokens, which the
    // orchestrator updates per chunk) into MetricsCubit BEFORE the
    // second early-return. The next early-return pauses tok/s when
    // we're between model rounds (before the first delta, during
    // local tool execution, between LLM requests), but the live TTFT
    // timer must keep ticking through those gaps — that's the
    // "start ticking when the turn begins, stop after receiving the
    // first token" feature. Without this pre-early-return mirror, the
    // display would only see the latest ttftMs when a model round
    // is actually streaming, missing the gaps between rounds.
    _sessionController.metricsCubit.replaceSessionState(
      sessionId,
      _sessionController.metricsCubit.state
          .sessionState(sessionId)
          .copyWith(
            ttftMs: rt.ttftMs,
            ttftReceived: rt.ttftReceived,
            contextTargetTokens: rt.contextTargetTokens,
          ),
    );

    // Pause tok/s while we're outside active token generation. That means:
    // before the first model delta arrives, during local tool execution,
    // between LLM requests, and during idle UI time.
    if (!rt.roundStreaming || rt.roundFirstTokenTime == null) return;

    // Streaming content / reasoning ARE mirrored (slices 23 + 24),
    // so the cubit is the read-side SSoT for those.
    final streaming = _sessionController.streamingCubit.state;
    final liveStreamingTokens = estimateTokens(
      streaming.streamingContentFor(sessionId) +
          streaming.streamingReasoningFor(sessionId),
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
    // Mirror the live metrics into MetricsCubit so any subscriber
    // (e.g. metrics_display reading from the cubit instead of the
    // runtime) sees the fresh values. copyWith preserves the other
    // fields the cubit carries (contextTargetTokens seeded at
    // runtime() creation and at completeSwitchSession, cacheHitPct
    // mirrored at onComplete, etc.) — a wholesale MetricsSessionState
    // constructor would zero those on every tick and clobber the
    // context bar's current token count.
    _sessionController.metricsCubit.replaceSessionState(
      sessionId,
      _sessionController.metricsCubit.state
          .sessionState(sessionId)
          .copyWith(
            tokPerSec: rt.tokPerSec,
            ttftMs: rt.ttftMs,
            ttftReceived: rt.ttftReceived,
            // Mirror contextTargetTokens too — the orchestrator
            // updates rt.contextTargetTokens per chunk during
            // streaming (onChunk / onToolRound / onToolExecutionStart
            // / onComplete) and the context bar reads from the
            // cubit. Without this mirror, the bar stays frozen at
            // its seeded value for the whole turn and the lerp
            // animation never starts.
            contextTargetTokens: rt.contextTargetTokens,
          ),
    );
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
