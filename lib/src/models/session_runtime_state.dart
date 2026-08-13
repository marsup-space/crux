import 'dart:async';

import 'session_runtime_sink.dart';

/// Per-session chat log display mode. New sessions open in [vibe].
/// The user can switch to [verbose] via the `/view verbose` slash command
/// or the top-right toggle button. In vibe mode the chat history renders
/// aggregated metadata boxes instead of per-call detail rows.
///
/// This is a pure viewer-mode setting — stored in-memory on
/// [SessionRuntimeState], not persisted to the database. The mode
/// resets to [vibe] on app restart.
enum ChatDisplayMode { verbose, vibe }

class SessionRuntimeState implements SessionRuntimeSink {
  @override
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

  /// Wall-clock time the LLM was actively emitting generated deltas, summed
  /// across every model round of the current agent turn. Each round starts
  /// counting at its first emitted delta, whether that delta is reasoning,
  /// response text, or tool_use JSON. Excludes TTFT, local tool execution,
  /// between-round waits, and idle UI time.
  double cumulativeGenMs = 0.0;

  /// Estimated completion tokens (text + reasoning + tool_use input
  /// deltas) emitted by the LLM across all rounds of the current turn.
  /// Includes tool-call argument JSON, which the LLM also generated as
  /// part of its completion.
  int cumulativeCompletionTokens = 0;

  /// Wall-clock time the current LLM request round started. Null between
  /// rounds, including while local tools execute. This remains useful for
  /// lifecycle/debug timing; tok/s uses [roundFirstTokenTime] instead so TTFT
  /// is excluded from the generation-rate denominator.
  DateTime? roundStartTime;

  /// First emitted delta time of the *current* round. This remains null
  /// while the LLM is thinking before it emits text, reasoning, or tool_use
  /// chunks. TTFT and tok/s both use this boundary for different purposes:
  /// TTFT measures the delay until it arrives; tok/s measures generation rate
  /// from this point until the stream ends.
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

  /// Per-session chat display mode (verbose vs vibe). See
  /// [ChatDisplayMode]. In-memory only — resets to [verbose] on
  /// app restart. Toggled by the `/view` slash command and the
  /// top-right toggle button in the chat panel.
  ChatDisplayMode chatDisplayMode;

  /// Per-session override for the LLM sampling temperature set by
  /// the `/temperature` slash command. When non-null, this wins
  /// over the model's TOML-configured `temperature` default at the
  /// API-call site (see `chat_turn_executor.dart`). User input is
  /// clamped to `[0.0, 1.0]`; `null` means "no override, use the
  /// model default". Lives on the runtime (not a widget-local
  /// state) because the chat turn executor reads it directly when
  /// constructing the stream request — and persists alongside the
  /// session so the override outlives an app restart.
  double? temperatureOverride;
  double? cacheHitPct;

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
  /// interrupted by the user clicking the toolbar's model button while
  /// it flashed mid-response. The chat panel uses
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

  /// Consecutive automatic compaction failures for this in-memory
  /// session run. Manual `/compact` is still allowed; this only gates
  /// repeated automatic attempts.
  int consecutiveCompactionFailures;

  /// User-turn counter for auto-compaction hysteresis.
  ///
  /// `0` means "no compact has happened, full auto-compact check is
  /// allowed". After a compact (success OR failure), set to `1`; each
  /// subsequent user turn increments it. While `1 <= N <= 3` the
  /// auto-compact check is skipped — gives the child session room to
  /// accumulate meaningful turns before we re-evaluate (otherwise a
  /// single 130k context could thrash through "compact → child at
  /// 130k → compact → grandchild ..." in three user turns).
  ///
  /// Reset back to `0` when the auto-compact check actually runs and
  /// decides no compact is needed (either we just exited the window
  /// at N>=4, or we never entered it).
  int turnsSinceLastCompact;

  /// Number of consecutive shell-tool fallback violations in this
  /// session. Powers the `shell-tool fallback` guard in
  /// `lib/src/tools/shell_guard.dart` — catches the model using
  /// `bash`/`cmd`/`powershell` for operations that have a dedicated
  /// tool (any Tier 1 or Tier 2 tool — `semantic_search`,
  /// `find_similar_code`, `webfetch`, `read`, `write`, `edit`,
  /// `grep`, `glob`) and escalates through three tiers: mild
  /// (run + reminder), firm (run + firmer reminder), reject
  /// (block the call).
  ///
  /// Lifecycle (managed by `ShellBase` and `chat_service`):
  ///   - `+1` when a shell call is detected as a fallback violation
  ///     (see `shell_guard.dart` for the detection rules)
  ///   - reset to `0` when a "proper" tool call succeeds — i.e. one
  ///   of the Tier 1 or Tier 2 tools listed above.
  ///     The chat service does this reset after each tool round so
  ///     a single `read` between two bash+cat fallbacks breaks the
  ///     streak.
  ///   - reset to `0` when a new user turn starts (the drift
  ///     detector is per-attempt; a fresh prompt is a fresh slate)
  ///
  /// In-memory only — resets to 0 on app restart. That matches the
  /// parallel-call drift detector's behaviour: the signal is
  /// session-scoped and a fresh app launch is effectively a fresh
  /// session.
  int consecutiveShellViolations;

  /// Whether the one-shot `semantic_search` preference hint has been
  /// appended to a `grep` or `glob` tool result in this session.
  /// Gates the hint in `lib/src/services/prompts/semantic_search_hint.dart`
  /// — fires once per session to teach the LLM that `semantic_search`
  /// is the preferred surface for "how does X work" / "find code
  /// that does X" questions, returning ranked snippets in one
  /// call instead of the grep+read dance.
  ///
  /// Lifecycle (managed by `chat_service`):
  ///   - set to `true` by the chat service after the first
  ///     successful `grep` or `glob` tool call in the session
  ///   - never reset within a session (one-shot per chat)
  ///   - reset to `false` when the runtime is constructed (i.e.
  ///     on app launch or when a new chat starts a fresh runtime)
  ///
  /// In-memory only — same persistence model as the parallel-call
  /// and shell-guard counters. The hint is genuinely per-session,
  /// so resetting it on app launch is the desired behaviour: a
  /// fresh chat should see the hint on its first grep/glob use.
  bool hasShownsemanticSearchHint;

  /// The most recent context-size threshold (in tokens) at which
  /// the `semantic_search` preference hint re-fired. Initial 0
  /// (no threshold fire yet). Bumps to 200_000 / 400_000 /
  /// 600_000 as the LLM's context crosses each boundary.
  ///
  /// Pairs with [hasShownsemanticSearchHint] which gates the initial
  /// one-shot. After the initial fire, this field gates the
  /// threshold re-fires — the chat service finds the next
  /// unsatisfied threshold via `nextsemanticSearchHintThreshold` and
  /// appends the hint to the next grep/glob result when found.
  /// Each threshold fires at most once per session.
  ///
  /// In-memory only — resets to 0 when the runtime is constructed
  /// (on app launch or when a new chat starts a fresh runtime).
  int semanticSearchHintLastThreshold;

  /// The set of skill names currently "loaded" into this session's
  /// active context. A skill is added in two ways:
  ///
  ///   1. The user types a `$<skill-name>` chip in a chat input
  ///      and submits it. The chip-substitution step in
  ///      `chat_turn_orchestrator.sendTurn` adds every resolved
  ///      name from the chip-expansion result.
  ///   2. The LLM calls the `skill` tool with a valid name — the
  ///      tool adds the resolved name on success (failure paths
  ///      don't touch the set).
  ///
  /// The set persists for the lifetime of the session — across
  /// compactions, because the LLM still has the skill's content
  /// via the bottom-of-log summary (`SkillTool.extractPruneSummary`
  /// routes the body into `skill-bodies` and survives a compact).
  /// Each new session starts empty. App restart clears the set
  /// (it's in-memory only).
  ///
  /// Read by [LoadedSkillChips] (rendered inline in the chat
  /// toolbar) so the user can see at a glance which skills are
  /// currently contributing to the displayed context — the chip
  /// row reads as "what's loaded into this session" leading into
  /// the context bar's "how full is it".
  Set<String> loadedSkillNames = <String>{};

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
    this.chatDisplayMode = ChatDisplayMode.vibe,
    this.temperatureOverride,
    this.cacheHitPct,
    this.isGeneratingTldr = false,
    this.btwMode = false,
    this.interrupted = false,
    this.consecutiveSingleToolCallRounds = 0,
    this.consecutiveCompactionFailures = 0,
    this.turnsSinceLastCompact = 0,
    this.consecutiveShellViolations = 0,
    this.hasShownsemanticSearchHint = false,
    this.semanticSearchHintLastThreshold = 0,
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

  @override
  void resetMetrics({
    int? turnBaseTokens,
    int? accumulatedToolTokens,
    int? targetTokens,
  }) {
    final savedTurnBase = turnBaseTokens ?? this.turnBaseTokens;
    final savedAccumulated =
        accumulatedToolTokens ?? this.accumulatedToolTokens;
    final savedTarget = targetTokens ?? contextTargetTokens;

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

    this.turnBaseTokens = savedTurnBase;
    this.accumulatedToolTokens = savedAccumulated;
    contextTargetTokens = savedTarget;
  }

  @override
  void beginResponse({DateTime? now, bool btwMode = false}) {
    resetMetrics();
    isResponding = true;
    responseStartTime = now ?? DateTime.now();
    this.btwMode = btwMode;
    interrupted = false;
  }

  @override
  void beginModelRound({DateTime? now}) {
    roundStartTime = now ?? DateTime.now();
    roundStreaming = true;
  }

  @override
  void recordContentStarted(DateTime now) {
    if (contentStartTime != null) return;
    contentStartTime = now;
  }

  @override
  void recordFirstToken(DateTime now) {
    final start = responseStartTime;
    if (start == null) return;
    if (!ttftReceived) {
      ttftMs = now.difference(start).inMicroseconds / 1000.0;
      ttftReceived = true;
      firstTokenTime = now;
    }
    roundFirstTokenTime ??= now;
  }

  @override
  void recordRoundFirstToken(DateTime now) {
    roundFirstTokenTime ??= now;
  }

  @override
  void addCompletionTokens(int estimatedTokens) {
    if (estimatedTokens <= 0) return;
    cumulativeCompletionTokens += estimatedTokens;
  }

  @override
  void finishModelRound({DateTime? now, bool accumulateGeneration = false}) {
    final end = now ?? DateTime.now();
    if (accumulateGeneration && roundStreaming && roundFirstTokenTime != null) {
      cumulativeGenMs +=
          end.difference(roundFirstTokenTime!).inMicroseconds / 1000.0;
    }
    roundStartTime = null;
    roundFirstTokenTime = null;
    roundStreaming = false;
  }

  @override
  void finishResponse({bool interrupted = false}) {
    pauseStreamingTimer();
    isResponding = false;
    this.interrupted = interrupted;
    roundStreaming = false;
    roundStartTime = null;
    roundFirstTokenTime = null;
    if (!interrupted) btwMode = false;
  }

  @override
  void updateContext({
    int? turnBaseTokens,
    int? accumulatedToolTokens,
    int? targetTokens,
  }) {
    if (turnBaseTokens != null) this.turnBaseTokens = turnBaseTokens;
    if (accumulatedToolTokens != null) {
      this.accumulatedToolTokens = accumulatedToolTokens;
    }
    if (targetTokens != null) contextTargetTokens = targetTokens;
  }

  @override
  void recordCacheHitPct({required int hitTokens, required int missTokens}) {
    final total = hitTokens + missTokens;
    cacheHitPct = total > 0
        ? ((hitTokens / total) * 1000).roundToDouble() / 10.0
        : null;
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
