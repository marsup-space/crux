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

  /// Wall-clock time the LLM was actively emitting deltas, summed across
  /// every model round of the current turn. Excludes (a) the TTFT wait
  /// before the first delta of each round, and (b) the time spent
  /// executing tools / waiting for the next round to start. Updated by
  /// `chat_service` when a round ends; combined with the in-flight round
  /// timing by `streaming_controller` to compute tok/s live.
  double cumulativeGenMs = 0.0;

  /// Estimated completion tokens (text + reasoning + tool_use input
  /// deltas) emitted by the LLM across all rounds of the current turn.
  /// Includes tool-call argument JSON, which the LLM also generated as
  /// part of its completion.
  int cumulativeCompletionTokens = 0;

  /// Wall-clock time the current LLM request round started. Null between
  /// rounds, including while local tools execute. Together with
  /// `cumulativeGenMs`, this lets the live tok/s readout include the LLM's
  /// thinking/TTFT, response streaming, and tool-call generation time while
  /// excluding local tool execution and idle UI time.
  DateTime? roundStartTime;

  /// First emitted delta time of the *current* round. This remains null
  /// while the LLM is thinking before it emits text, reasoning, or tool_use
  /// chunks. TTFT uses this boundary; tok/s uses [roundStartTime].
  DateTime? roundFirstTokenTime;

  /// True while an LLM request round is active: thinking before the first
  /// delta, streaming response/reasoning deltas, or generating tool_use
  /// chunks. False during local tool execution and the wait between rounds.
  bool roundStreaming = false;

  double tokCount;
  double streamingDurationMs;
  DateTime? _streamingStart;
  int contextTargetTokens;
  // The previously-used `contextDisplayTokens` field was the
  // lerp "displayed" value that the streaming controller
  // animated toward the target. That animation has moved
  // into the [ContextBar] widget, which now owns its own
  // displayed value in its own state — so the field is
  // gone from the runtime. Setter sites in
  // `chat_turn_orchestrator` and `session_controller` were
  // updated to drop the assignment; this is a no-op shim so
  // any persisted JSON shape that still references the field
  // doesn't break loading.
  // ignore: prefer_final_fields
  double contextDisplayTokens = 0.0;
  int turnBaseTokens;
  int accumulatedToolTokens;
  String thinkingMode;
  String? reasoningEffort;
  int? cacheHitPct;

  bool isGeneratingTldr;

  /// True while the in-flight stream is a `/btw` round (a one-shot,
  /// ephemeral side-question) rather than a normal chat turn. The
  /// chat panel uses this flag to render the boxed `BtwBubble`
  /// variant instead of the regular `StreamingBubble`, and to
  /// suppress tldr/title/auxiliary side-effects that only make sense
  /// for "real" turns. Set by `_sendBtwTurn` when the btw LLM call
  /// starts; cleared when it ends.
  bool btwMode;

  /// True when the current (or most recent) streaming response was
  /// interrupted by the user pressing ESC twice. The chat panel uses
  /// this flag to (a) show an interruption indicator in the AI message,
  /// and (b) prepend a system message on the next user input so the
  /// LLM knows its previous response was cut off. Cleared when a new
  /// turn starts (`_sendTurn`).
  bool interrupted;

  /// Number of consecutive rounds in this session where the model
  /// emitted exactly one tool call. Used by the parallel-tool-call
  /// hint feature to detect drift in long sessions: when the counter
  /// crosses the configured threshold (default 10), the chat service
  /// injects a corrective single-call hint into the LLM's next turn.
  ///
  /// Lifecycle (managed by `chat_service`):
  ///   - `+1` when a round executes exactly 1 successful tool call
  ///   - reset to `0` when a round executes ≥2 successful calls
  ///     (the model is back to batching — drift has ended)
  ///   - reset to `0` when a round executes 0 tool calls (the user
  ///     just got a plain text reply; no serialisation signal)
  ///   - reset to `0` when a new user turn starts (a `/btw`,
  ///     `/continue`, or fresh prompt resets the drift detector)
  ///
  /// In-memory only — resets to 0 on app restart. That's intentional:
  /// the drift signal is per-session, and a fresh app launch is
  /// effectively a fresh session.
  int consecutiveSingleToolCallRounds;

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
    this.turnBaseTokens = 0,
    this.accumulatedToolTokens = 0,
    this.thinkingMode = 'enabled',
    this.reasoningEffort = 'normal',
    this.cacheHitPct,
    this.isGeneratingTldr = false,
    this.btwMode = false,
    this.interrupted = false,
    this.consecutiveSingleToolCallRounds = 0,
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
    cumulativeGenMs = 0.0;
    cumulativeCompletionTokens = 0;
    roundStartTime = null;
    roundFirstTokenTime = null;
    roundStreaming = false;
    isResponding = false;
    btwMode = false;
    interrupted = false;
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
          DateTime.now().difference(_streamingStart!).inMicroseconds / 1000.0;
      _streamingStart = null;
    }
  }

  double get effectiveStreamingMs {
    var total = streamingDurationMs;
    if (_streamingStart != null) {
      total +=
          DateTime.now().difference(_streamingStart!).inMicroseconds / 1000.0;
    }
    return total;
  }
}
