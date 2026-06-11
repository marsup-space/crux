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

  /// First delta time of the *current* round (the round that is currently
  /// receiving deltas). Null between rounds (i.e. while the previous
  /// round is done and the next LLM call has not produced its first
  /// delta yet, or while tools are executing). Together with
  /// `cumulativeGenMs`, this lets the live tok/s readout exclude
  /// tool-execution time and the wait-for-next-round.
  DateTime? roundFirstTokenTime;

  /// True while the LLM is actively streaming deltas for the current
  /// round. False during tool execution and the wait between rounds.
  /// The metrics timer checks this so the displayed tok/s doesn't keep
  /// ticking down while we're sending a tool result back and waiting for
  /// the model to respond.
  bool roundStreaming = false;

  double tokCount;
  double streamingDurationMs;
  DateTime? _streamingStart;
  int contextTargetTokens;
  double contextDisplayTokens;
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
