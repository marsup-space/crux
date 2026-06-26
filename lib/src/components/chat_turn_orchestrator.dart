import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../services/auxiliary_prompts.dart';
import '../services/chat_service.dart';
import '../services/git_status_service.dart';
import '../tools/semble_warmup.dart';
import '../services/install_slug.dart';
import '../services/llm_client.dart';
import '../services/llm_error.dart';
import '../services/provider_service.dart';
import '../storage/message_store.dart';
import '../storage/session_store.dart';
import '../tools/registry.dart';
import '../tools/shell_base.dart';
import '../tools/tool_def.dart';
import '../tools/file_read_tracker.dart';
import '../utils/run_metrics.dart';
import '../utils/token_estimate.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import 'ui/toast.dart';

/// Callback type for showing a toast notification.
typedef ShowToastCallback = void Function(String message, {ToastMode mode});

/// Orchestrates chat turn lifecycle: sending messages, handling
/// streaming responses, managing interrupts, and generating TLDR
/// summaries.
///
/// This class was extracted from `_ChatPanelState` to decouple the
/// turn state machine from the UI. All methods are pure business
/// logic — they coordinate [ChatService], [SessionStore],
/// [SessionController], and [StreamingController] but never touch
/// widgets directly.
class ChatTurnOrchestrator {
  final SessionStore _store;
  final MessageStore _messageStore;
  final ChatService _chatService;
  final ProviderService _providerService;
  final SessionController _sessionController;
  final StreamingController _streamingController;
  final ToolRegistry _toolRegistry;
  final ShowToastCallback _showToast;
  final void Function() _refresh;
  final FileReadTracker _tracker;

  /// Git status service for the project root. Used to force a
  /// refresh right after the agent mutates a file via `edit` or
  /// `write`, so the right-panel git status widget doesn't have
  /// to wait up to [GitStatusService.kDefaultRefreshInterval]
  /// before reflecting the change. Owned by [ChatPanel] and
  /// outlives this orchestrator.
  final GitStatusService _gitStatusService;

  /// Per-session cancellation flags for btw turns. When the user
  /// interrupts a btw stream, the flag is set to true so the
  /// `await for` loop in [sendBtwTurn] breaks out immediately.
  final Map<int, bool> _btwCancelFlags = {};

  /// Set of session IDs that have been interrupted by the user. Used
  /// to prevent the `onComplete` / `onError` callbacks from running
  /// after an interrupt, since [interruptResponse] already handled
  /// all cleanup. Entries are removed when [sendTurn] starts a new
  /// turn for that session.
  final Set<int> _interruptedSessions = {};

  /// Per-session abort signals for currently running tool executions.
  /// When the user interrupts, [interruptResponse] calls `abort()` on
  /// each signal, which kills any running subprocesses (bash, cmd, etc.).
  final Map<int, List<AbortSignal>> _activeAbortSignals = {};
  final Set<int> _streamingGuardAbortedSessions = {};

  /// Set to `true` in [onToolExecutionStart] when any of the
  /// tool calls in the current round is a file-mutating tool
  /// (`edit` / `write`). Consumed — and cleared — in
  /// [onToolRound], which fires right after the tool round
  /// finishes and just before we go back to waiting for the
  /// LLM. We latch this across the round boundary so we can
  /// also capture batches of mixed `edit` + `read` + `grep`
  /// calls in a single round: only the mutation matters for
  /// git status.
  bool _fileMutatedThisRound = false;

  ChatTurnOrchestrator({
    required SessionStore store,
    required ChatService chatService,
    required ProviderService providerService,
    required SessionController sessionController,
    required StreamingController streamingController,
    required ToolRegistry toolRegistry,
    required ShowToastCallback showToast,
    required void Function() refresh,
    required GitStatusService gitStatusService,
    required FileReadTracker tracker,
  }) : _store = store,
       _messageStore = store.messageStore,
       _chatService = chatService,
       _providerService = providerService,
       _sessionController = sessionController,
       _tracker = tracker,
       _streamingController = streamingController,
       _toolRegistry = toolRegistry,
       _showToast = showToast,
       _refresh = refresh,
       _gitStatusService = gitStatusService;

  // ─────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────

  /// Show a toast notification via the chat panel's toast hub.
  void showToast(String message, {ToastMode mode = ToastMode.info}) {
    _showToast(message, mode: mode);
  }

  /// Whether the given session was interrupted (used by the input
  /// placeholder text).
  bool wasInterrupted(int? sessionId) {
    if (sessionId == null) return false;
    return _sessionController.runtime(sessionId).interrupted;
  }

  /// Decide whether auto-compaction should fire on this turn.
  ///
  /// Projects the next-prompt size as
  /// `session.contextTokens + incomingUserContent` (the same
  /// formula [ChatService.estimateProjectedContextTokens] uses
  /// internally) and compares it against
  /// `contextSize - reserve`. When the projection is at or below
  /// the threshold, the context has plenty of room and we should
  /// NOT compact — compacting an already-small context is pure
  /// waste (extra DB writes, lost tool_result detail, churn in
  /// the chat log).
  ///
  /// Defaults to `true` (compact) when the model config can't be
  /// resolved, so a missing model config doesn't silently disable
  /// auto-compaction — a wrong compaction is recoverable; a
  /// missed one runs the user out of context.
  bool _shouldAutoCompact({
    required Session session,
    required String incomingUserContent,
  }) {
    final modelConfig = _providerService.modelByCompositeKey(session.model);
    if (modelConfig == null) return true;

    final reserve = ChatService.computeCompactionReserveAndThreshold(
      contextSize: modelConfig.contextSize,
    );

    final projected = ChatService.estimateProjectedContextTokens(
      session: session,
      systemPrompt: session.systemPrompt,
      history: _sessionController.currentMessages,
      incomingUserContent: incomingUserContent,
      toolDefs: _toolRegistry.toApiTools(),
    );

    return projected > reserve.threshold;
  }

  /// Send a user message. If the session is currently streaming, the
  /// message is queued instead.
  Future<void> sendMessage({
    required String text,
    required TextEditingController textController,
    List<ImageAttachment> images = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final sessionId = _sessionController.currentSessionId;
    final isResponding =
        sessionId != null && _sessionController.runtime(sessionId).isResponding;

    // When the agent is streaming, queue the user's message
    // instead of ignoring it.
    if (isResponding) {
      _sessionController.enqueueMessage(sessionId, trimmed);
      textController.clear();
      _refresh();
      return;
    }

    // Sending a "real" (non-`/btw`) message is the explicit signal
    // that the in-memory btw chain must be discarded.
    if (sessionId != null) {
      _sessionController.clearBtwTurnsFor(sessionId);
      _streamingController.clearStreamingFor(sessionId);
    }

    textController.clear();

    await sendTurn(text: trimmed, images: images);
  }

  /// Drive a single chat turn. When [text] is non-null, [text] is
  /// used as the new user prompt and is persisted to the DB and
  /// prepended to the in-memory cache. When [text] is `null`, the
  /// existing conversation history is re-submitted as-is — no new
  /// user message is added, the in-memory cache is left alone, and
  /// the LLM is called with whatever the persisted wire-format
  /// history currently ends on.
  Future<void> sendTurn({
    String? text,
    List<ImageAttachment> images = const [],
    bool allowAutoCompact = true,
  }) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    final rt = _sessionController.runtime(sessionId);
    if (rt.isResponding) return;

    if (allowAutoCompact && text != null && text.trim().isNotEmpty) {
      // Auto-compaction hysteresis: after a successful or failed
      // compact, skip the auto-compact check for the next 3 user
      // turns. Otherwise a session that just compacted would
      // trigger another one immediately, and another, etc. —
      // burning compactions with no user-facing progress. Manual
      // `/compact` bypasses this gate.
      if (rt.turnsSinceLastCompact > 0) {
        rt.turnsSinceLastCompact += 1;
        if (rt.turnsSinceLastCompact > 3) {
          rt.turnsSinceLastCompact = 0;
        }
      } else {
        final session = _sessionController.findSession(sessionId);
        if (session != null) {
          // Auto-compact threshold gate: skip the compaction pass
          // when the projected next-prompt is well below the
          // model's context limit. Without this, the compaction
          // would fire on every turn (gated only by the 3-turn
          // hysteresis) regardless of whether the context is
          // actually filling up — a regression from the old
          // LLM-summary path, where the projection-vs-threshold
          // check lived inside `maybeAutoCompactIntoChildSession`.
          // The chat-log compaction path lost that gate during
          // the refactor; this is where it belongs.
          if (!_shouldAutoCompact(
            session: session,
            incomingUserContent: text,
          )) {
            // Below threshold — fall through to the normal
            // sendTurn path. No hysteresis bump; we'll re-check
            // next turn.
          } else {
          try {
            final result = await _chatService.createChatLogCompaction(
              sessionId: sessionId,
              session: session,
              runtime: rt,
              toolRegistry: _toolRegistry,
              reason: CompactionReason.auto,
            );
            if (result != null) {
              // Replay file markers through [FileReadTracker] so
              // the read-before-write guard sees fresh mtimes
              // post-compact.
              for (final marker in result.fileMarkers) {
                await _tracker.recordRead(
                  resolvePath(marker.path, Directory.current.path),
                  marker.mtime,
                );
              }
              rt.turnsSinceLastCompact = 1;
              _showToast(
                'Context was getting full — compacted '
                '(~${result.postEstimateTokens} ← ${result.preTokens} tokens)',
                mode: ToastMode.status,
              );
              // Reload the in-memory message cache so the new
              // `role: 'compaction'` divider is visible during the
              // follow-up `sendTurn` below. Without this, the chat
              // history keeps showing the pre-compaction list and
              // the divider only appears after the next user turn.
              await _sessionController.loadMessages(sessionId);
              _refresh();
              await sendTurn(text: text, images: images, allowAutoCompact: false);
              return;
            }
            // No compact needed this turn — make sure the hysteresis
            // counter is fully reset so the next turn will re-check.
            rt.turnsSinceLastCompact = 0;
          } catch (e) {
            rt.turnsSinceLastCompact = 1;
            _showToast('Compaction failed: $e', mode: ToastMode.error);
            _refresh();
            return;
          }
          }  // close: else (shouldAutoCompact)
        }
      }
    }

    // Bump the per-run turn counter as soon as we commit to
    // the turn. The actual token usage gets recorded in the
    // `onComplete` callback below once the LLM stream ends
    // and we have the final `ChatResponse` in hand. The
    // counter is bumped up front (not on completion) so the
    // summary always reflects "the user kicked off N turns",
    // even if some of them were interrupted before any tokens
    // got reported.
    if (text != null) {
      RunMetrics.instance.recordTurnStart();
    } else {
      // `/continue`, `/retry` etc. — these are continuations
      // of an existing user message rather than a fresh
      // turn, so they don't count as a new "agent turn
      // conversation" in the run summary.
    }

    // Guard: if the chat service still considers this session active
    // (e.g. after a recent interrupt that hasn't fully propagated),
    // wait briefly for it to clear.
    if (_chatService.isStreaming(sessionId)) {
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (!_chatService.isStreaming(sessionId)) break;
      }
      if (_chatService.isStreaming(sessionId)) return;
    }

    try {
      _streamingController.clearStreamingFor(sessionId);

      // Clear the interrupted session flag — we're starting a fresh turn.
      _interruptedSessions.remove(sessionId);

      final session = _sessionController.findSession(sessionId);
      if (session != null && session.status != SessionStatus.running) {
        final updated = await _store.update(
          sessionId,
          status: SessionStatus.running,
        );
        session.status = updated.status;
        session.runningOwnerId = updated.runningOwnerId;
        session.runningHeartbeatAt = updated.runningHeartbeatAt;
        session.updatedAt = updated.updatedAt;
      }

      final toolDefsTokens = estimateToolDefsTokens(_toolRegistry.toApiTools());
      final userTokens = text == null ? 0 : estimateTokens(text);
      final turnBase =
          _sessionController.computeBaseContext(sessionId) +
          userTokens +
          toolDefsTokens;
      rt.turnBaseTokens = turnBase;
      rt.accumulatedToolTokens = 0;
      rt.contextTargetTokens = turnBase;
      rt.contextDisplayTokens = turnBase.toDouble();
      _streamingController.stopContextAnimation();

      rt.isResponding = true;
      rt.responseStartTime = DateTime.now();
      rt.ttftMs = 0.0;
      rt.ttftReceived = false;
      rt.tokPerSec = 0.0;
      rt.tokCount = 0.0;
      rt.firstTokenTime = null;
      rt.cumulativeGenMs = 0.0;
      rt.cumulativeCompletionTokens = 0;
      rt.roundStartTime = null;
      rt.roundFirstTokenTime = null;
      rt.roundStreaming = false;

      _streamingController.startMetricsTimer(sessionId);
      if (text != null) {
        // Bump updatedAt immediately so the sidebar moves the session
        // into "Today" before the first UI refresh. The DB is touched
        // again shortly by ChatService.sendMessage, but the in-memory
        // object needs the update now so the fingerprint-based cache in
        // ExtraInfoPanel invalidates on the first _refresh().
        if (session != null) {
          session.updatedAt = DateTime.now();
        }

        // If the previous response was interrupted, inject a system
        // message before the user's new input so the LLM knows its
        // prior response was cut off.
        if (rt.interrupted) {
          rt.interrupted = false;
          const interruptionNotice =
              'Your response was interrupted by user. The user is now '
              'sending a new message. Do not repeat or continue the '
              'interrupted response unless the user explicitly asks.';
          await _messageStore.addMessage(
            sessionId,
            role: 'system',
            content: interruptionNotice,
          );
        }

        final userMsg = Message(
          id: -1,
          sessionId: sessionId,
          role: 'user',
          content: text,
          images: images,
        );
        _sessionController.messageCache[sessionId] = [
          ...?_sessionController.messageCache[sessionId],
          userMsg,
        ];
        _refresh();

        // Only kick off the auxiliary title generator for genuinely
        // new user input; a continuation shouldn't change the session
        // title.
        _maybeKickOffTitleEarly(sessionId, text);
      }
    } catch (e) {
      rt.isResponding = false;
      rt.roundStreaming = false;
      rt.roundStartTime = null;
      rt.roundFirstTokenTime = null;
      _streamingController.stopMetricsTimer(sessionId);
      _streamingController.stopContextAnimation();
      _streamingController.clearStreamingFor(sessionId);
      await _sessionController.reconcileInactiveRunningSessions(refresh: false);
      _showToast('Failed to start response: $e', mode: ToastMode.error);
      _refresh();
      return;
    }

    _chatService
        .sendMessage(
          sessionId: sessionId,
          userContent: text,
          images: images,
          session: _sessionController.currentSession,
          runtime: rt,
          onDelta: (delta) {
            if (_interruptedSessions.contains(sessionId)) return;
            if (_streamingController.streamingContentFor(sessionId).isEmpty) {
              rt.contentStartTime = DateTime.now();
            }
            _streamingController.appendStreamingContent(sessionId, delta);
          },
          onReasoning: (reasoning) {
            if (_interruptedSessions.contains(sessionId)) return;
            _streamingController.appendStreamingReasoning(sessionId, reasoning);
          },
          onChunk: () {
            if (_interruptedSessions.contains(sessionId)) return;
            final streamingTokens =
                estimateTokens(
                  _streamingController.streamingContentFor(sessionId) +
                      _streamingController.streamingReasoningFor(sessionId),
                ) +
                _streamingController.streamingToolInputTokensFor(sessionId);
            // The context bar's [ContextBar] widget polls
            // `rt.contextTargetTokens` on every frame and starts
            // its own lerp animation when the value changes, so
            // we don't need to call `_refresh()` to drive that
            // animation. The streaming bubble's [StreamingBubble]
            // widget polls the streaming controller on its own
            // 33ms timer and rebuilds itself. Calling `_refresh()`
            // here used to cause a 30ms full-layout pass on every
            // 16ms chunk, which is what was killing streaming
            // performance on sessions with hundreds of messages.
            rt.contextTargetTokens =
                rt.turnBaseTokens + rt.accumulatedToolTokens + streamingTokens;
            if (!_streamingController.contextAnimTimerIsActive()) {
              _streamingController.startContextAnimation();
            }
          },
          onToolRound: (int toolResultTokens) async {
            if (_interruptedSessions.contains(sessionId)) return;
            final streamingTokens =
                estimateTokens(
                  _streamingController.streamingContentFor(sessionId) +
                      _streamingController.streamingReasoningFor(sessionId),
                ) +
                _streamingController.streamingToolInputTokensFor(sessionId);
            rt.accumulatedToolTokens += streamingTokens + toolResultTokens;
            rt.contextTargetTokens =
                rt.turnBaseTokens + rt.accumulatedToolTokens;
            rt.contextDisplayTokens = rt.contextTargetTokens.toDouble();
            if (_streamingGuardAbortedSessions.remove(sessionId)) {
              final transition = Completer<void>();
              NoctermScheduler.instance.once(
                (_) {
                  if (!transition.isCompleted) transition.complete();
                },
                owner: this,
                name: 'streamingGuardAbortTransition',
                delay: const Duration(milliseconds: 64),
                priority: SchedulePriority.animation,
              );
              await transition.future;
              if (_interruptedSessions.contains(sessionId)) return;
              _streamingController.clearStreamingFor(sessionId);
              await _sessionController.loadMessages(sessionId);
              if (_interruptedSessions.contains(sessionId)) return;
              _streamingController.beginWaitingForModel(sessionId);
              return;
            }
            _streamingController.clearStreamingFor(sessionId);
            await _sessionController.loadMessages(sessionId);
            if (_interruptedSessions.contains(sessionId)) return;
            // If the round included an `edit` or `write`, the
            // working tree just changed. Kick off a fire-and-forget
            // git-status refresh *now* — the user is about to
            // stare at the right panel while waiting for the LLM,
            // and we don't want them to see stale counts for up
            // to a minute. [GitStatusService.refresh] is internally
            // guarded by an `_refreshing` flag so multiple rapid
            // tool rounds collapse into a single in-flight fetch.
            if (_fileMutatedThisRound) {
              _fileMutatedThisRound = false;
              unawaited(_gitStatusService.refresh());
              // Re-index any files changed by the tool round, so the
              // next `semantic_search` is fresh. Idempotent /
              // non-blocking — same fire-and-forget pattern as
              // git-status above. The SembleWarmup class is internal
              // infra — the tool surface name is `semantic_search`.
              SembleWarmup.instance.refresh(Directory.current.path);
            }
            _streamingController.beginWaitingForModel(sessionId);
          },
          onToolUse: (ToolUseChunk chunk) {
            if (_interruptedSessions.contains(sessionId)) return;
            _streamingController.updateStreamingToolCall(sessionId, chunk);
          },
          onToolExecutionStart: (toolCalls) {
            if (_interruptedSessions.contains(sessionId)) return;
            final streamingTokens =
                estimateTokens(
                  _streamingController.streamingContentFor(sessionId) +
                      _streamingController.streamingReasoningFor(sessionId),
                ) +
                _streamingController.streamingToolInputTokensFor(sessionId);
            rt.accumulatedToolTokens += streamingTokens;
            rt.contextTargetTokens =
                rt.turnBaseTokens + rt.accumulatedToolTokens;
            rt.contextDisplayTokens = rt.contextTargetTokens.toDouble();
            final projectPath =
                _sessionController.findSession(sessionId)?.projectPath ??
                _sessionController.currentSession.projectPath;
            // Latch a "file was mutated" flag if any call in this
            // round is a file-mutating tool. We only care about
            // `edit` and `write` — `bash` / `cmd` are out of scope
            // because they may or may not touch the working tree
            // and we don't want to fire a `git status` on every
            // shell command. Consumed in [onToolRound] below.
            _fileMutatedThisRound = toolCalls.any(
              (c) => c.name == 'edit' || c.name == 'write',
            );
            _streamingController.beginExecutingTools(sessionId, [
              for (final call in toolCalls)
                ExecutingToolCall(
                  callId: call.callId,
                  name: call.name,
                  inputPreview: _toolExecutionPreview(call, projectPath),
                ),
            ]);
          },
          onStreamingGuardAbort: (event) {
            if (_interruptedSessions.contains(sessionId)) return;
            _streamingGuardAbortedSessions.add(sessionId);
            _streamingController.markStreamingToolCallAborted(
              sessionId,
              index: event.index,
              callId: event.callId,
              name: event.name,
              reason: event.reason,
              abortedInputTokensEstimate: event.abortedInputTokensEstimate,
            );
          },
          onQueueDrain: () => _sessionController.drainMessageQueue(sessionId),
          onAbortSignal: (signal) {
            _activeAbortSignals.putIfAbsent(sessionId, () => []).add(signal);
          },
          onComplete: (response) async {
            if (_interruptedSessions.contains(sessionId)) {
              _interruptedSessions.remove(sessionId);
              _activeAbortSignals.remove(sessionId);
              return;
            }

            // The agent turn is done. Fire a final fire-and-forget
            // git-status refresh to catch any working-tree mutations
            // the agent made via `bash` / `cmd` — e.g. `git mv`,
            // `mv foo bar`, `rm foo`, `echo x > foo`. The per-round
            // latch above deliberately skips those because we can't
            // reliably know whether a shell call touched the tree,
            // but at turn end we *do* know the agent is done mutating
            // and the working tree is in its final state.
            //
            // [GitStatusService.refresh] is internally guarded by an
            // `_refreshing` flag, so this call is free when a refresh
            // is already in flight (e.g. we just refreshed after the
            // last `edit`/`write` round). When the only mutations came
            // from `bash`, no earlier refresh fired and this one is
            // what actually catches the change.
            unawaited(_gitStatusService.refresh());

            // Roll the per-turn token usage into the
            // per-run aggregator. Done before the rest of
            // the completion bookkeeping so the counters
            // are accurate even if a later step (TLDR
            // generation, queued-message drain) throws —
            // the user already paid for these tokens.
            //
            // Interrupted turns are filtered out above (the
            // early return path), so the values here are
            // always the *final* usage reported by the
            // LLM's `usage` block, not partial numbers
            // from a cancelled stream.
            RunMetrics.instance.recordTurnUsage(
              tokensIn: response.promptTokens,
              tokensOut: response.completionTokens,
              cacheHit: response.promptCacheHitTokens,
              cacheMiss: response.promptCacheMissTokens,
            );

            await _sessionController.reconcileInactiveRunningSessions(
              refresh: false,
            );

            // The chat service sets SessionStatus.done on completion. We
            // override to idle for *every* session that completes — current
            // *and* background — so the sidebar doesn't display a lingering
            // non-idle status (running / done) for a turn that already
            // finished. Previously this only ran for the current session,
            // which left background sessions stuck showing the "done" (✦)
            // indicator in the sidebar until the user manually switched to
            // them, even though the response was complete and a TLDR
            // (fire-and-forget) was already being generated.
            final session = _sessionController.findSession(sessionId);
            if (session != null && session.status == SessionStatus.done) {
              session.status = SessionStatus.idle;
              session.updatedAt = DateTime.now();
              await _store.update(sessionId, status: SessionStatus.idle);
            }

            // Refresh immediately so the session list picks up the status
            // change (idle/done) without waiting for the rest of the
            // completion work (message reloads, optional title/tldr
            // generation, queued-message drain, etc.).
            _refresh();

            _streamingController.clearStreamingFor(sessionId);
            _streamingController.stopMetricsTimer(sessionId);
            _activeAbortSignals.remove(sessionId);
            rt.turnBaseTokens = 0;
            rt.accumulatedToolTokens = 0;
            final msgs = await _messageStore.getMessages(sessionId);
            _sessionController.messageCache[sessionId] = msgs;
            if (response.promptTokens + response.completionTokens > 0) {
              final finalTokens = _sessionController.computeBaseContext(
                sessionId,
              );
              rt.contextTargetTokens = finalTokens;
              rt.contextDisplayTokens = finalTokens.toDouble();
              _streamingController.stopContextAnimation();
            }
            final hit = response.promptCacheHitTokens;
            final miss = response.promptCacheMissTokens;
            // Use hit+miss as the denominator — those are the tokens that
            // the cache machinery actually counted.  hit/(hit+miss) is the
            // canonical hit rate;  using promptTokens risks a mismatch when
            // the API doesn't classify every input token into hit or miss.
            final cacheTotal = hit + miss;
            if (cacheTotal > 0) {
              // Store as decimal percentage (e.g. 85.3) so the UI can show
              // one decimal place.  The `round()` used before threw away
              // precision and collapsed 99.5% into "100%" — misleading.
              rt.cacheHitPct = ((hit / cacheTotal) * 1000).roundToDouble() / 10.0;
            } else {
              rt.cacheHitPct = null;
            }
            _refresh();
            if (_sessionController.currentSession.title == 'New Session') {
              _sessionController.generateTitle(sessionId);
            }
            final lastAiMsg = msgs.lastWhere(
              (m) => m.role == 'ai',
              orElse: () => Message(
                id: -1,
                sessionId: sessionId,
                role: 'ai',
                content: '',
              ),
            );
            if (lastAiMsg.id > 0 && lastAiMsg.content.isNotEmpty) {
              // Walk msgs backwards from the last AI row to find the
              // user question that triggered this response. The
              // auxiliary model uses it to focus the summary on what
              // the user actually asked and to pick the right
              // language. Stops at lastAiMsg itself (any user rows
              // *after* it would be unrelated).
              String? lastUserContent;
              final lastAiIndex = msgs.indexOf(lastAiMsg);
              if (lastAiIndex > 0) {
                for (var i = lastAiIndex - 1; i >= 0; i--) {
                  if (msgs[i].role == 'user') {
                    lastUserContent = msgs[i].content;
                    break;
                  }
                }
              }
              maybeGenerateTldr(
                sessionId,
                lastAiMsg,
                userQuestion: lastUserContent,
              );
            }
            // If the user queued a message during the final response,
            // persist it and kick off a new turn.
            if (response.queuedMessage != null &&
                response.queuedMessage!.isNotEmpty) {
              await _messageStore.addMessage(
                sessionId,
                role: 'user',
                content: response.queuedMessage!,
              );
              final updatedMsgs = await _messageStore.getMessages(sessionId);
              _sessionController.messageCache[sessionId] = updatedMsgs;
              _refresh();
              await sendTurn(text: null);
            }
          },
          onError: (error) {
            if (_interruptedSessions.contains(sessionId)) {
              _activeAbortSignals.remove(sessionId);
              return;
            }
            _streamingController.stopMetricsTimer(sessionId);
            _sessionController
                .reconcileInactiveRunningSessions(refresh: false)
                .then((changed) {
                  if (changed) _refresh();
                });
            // Persist the error as a `stream_error` system bubble so
            // it stays at the end of the chat until the user submits
            // a new message. `chat_service.sendMessage` clears any
            // prior `stream_error` rows at the start of each new
            // turn, so the bubble disappears naturally on retry —
            // either replaced by an `ai` response (success) or by a
            // fresh `stream_error` bubble (failure).
            //
            // Use the structured LlmError for the body so the
            // bubble can render a vendor-specific hint and a Retry
            // button when `kind.isRetriable`.
            _messageStore
                .addMessage(
              sessionId,
              role: 'stream_error',
              content: error.toUserMessage(),
              error: error.toJson(),
              model: _sessionController.currentSession.model,
            )
                .then((persisted) {
              // Mirror the new row into the in-memory cache so the
              // chat history paints the bubble without waiting for
              // a refetch. `addMessage` returns the persisted row;
              // the cache is the message list the chat history
              // widget reads from.
              final cache = _sessionController.messageCache[sessionId];
              if (cache != null) {
                cache.add(persisted);
              }
              _refresh();
            });
            _showToast(error.toUserMessage(), mode: ToastMode.error);
          },
          onStatus: (status) {
            if (_interruptedSessions.contains(sessionId)) return;
            _showToast(status, mode: ToastMode.info);
          },
        )
        .catchError((e) {
          if (!_interruptedSessions.contains(sessionId)) {
            _showToast('Unhandled error: $e', mode: ToastMode.error);
          }
          rt.isResponding = false;
          _streamingController.stopMetricsTimer(sessionId);
          _streamingController.clearStreamingFor(sessionId);
          _activeAbortSignals.remove(sessionId);
          _sessionController
              .reconcileInactiveRunningSessions(refresh: false)
              .then((changed) {
                if (changed) _refresh();
              });
          _refresh();
        });
  }

  Future<void> compactCurrentSession() async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) {
      _showToast('No active session', mode: ToastMode.error);
      return;
    }
    final rt = _sessionController.runtime(sessionId);
    if (rt.isResponding) {
      _showToast('Cannot compact while AI is responding');
      return;
    }
    final session = _sessionController.findSession(sessionId);
    if (session == null) {
      _showToast('No active session', mode: ToastMode.error);
      return;
    }
    try {
      _showToast('Compacting context...', mode: ToastMode.status);
      // In-place chat-log compaction: no child session, the
      // compaction marker is appended to THIS session's history
      // and the wire layer skips everything older than it.
      final result = await _chatService.createChatLogCompaction(
        sessionId: sessionId,
        session: session,
        runtime: rt,
        toolRegistry: _toolRegistry,
        reason: CompactionReason.manual,
      );
      if (result == null) {
        _showToast('Nothing to compact', mode: ToastMode.status);
        return;
      }
      // Replay the file markers through [FileReadTracker] so the
      // read-before-write guard sees fresh mtimes — the chat log
      // summarised these files via `read files:`, and the agent
      // should be able to edit them straight away without re-reading.
      for (final marker in result.fileMarkers) {
        await _tracker.recordRead(
          resolvePath(marker.path, Directory.current.path),
          marker.mtime,
        );
      }
      _showToast(
        'Compacted — ${result.sourceEndMessageId - result.sourceStartMessageId + 1} messages '
        '(~${result.postEstimateTokens} ← ${result.preTokens} tokens)',
        mode: ToastMode.status,
      );
      // Reload the in-memory message cache so the new
      // `role: 'compaction'` message shows up in the chat
      // history on the next rebuild. Without this the UI keeps
      // showing the pre-compaction list until the next user
      // turn triggers a reload somewhere else — the divider
      // would only appear after the user submitted again,
      // which is exactly the bug we're fixing here.
      await _sessionController.loadMessages(sessionId);
      _refresh();
    } catch (e) {
      _showToast('Compaction failed: $e', mode: ToastMode.error);
    }
  }

  /// Drive a single `/btw` turn. Nothing is written to the database.
  Future<void> sendBtwTurn(String prompt) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    final rt = _sessionController.runtime(sessionId);
    if (rt.isResponding) return;

    // Resolve the provider / model for the current session.
    final session = _sessionController.currentSession;
    final compositeKey = session.model;
    final slashIndex = compositeKey.indexOf('/');
    final providerName = slashIndex > 0
        ? compositeKey.substring(0, slashIndex)
        : '';
    final modelId = slashIndex > 0
        ? compositeKey.substring(slashIndex + 1)
        : compositeKey;
    final provider = _providerService.providerByName(providerName);
    final apiKey = _providerService.getApiKey(providerName);
    if (provider == null || apiKey == null || apiKey.isEmpty) {
      _showToast(
        'No API key for provider "$providerName". Use /provider to connect.',
        mode: ToastMode.error,
      );
      return;
    }

    // Build the wire message list for this btw call.
    // Include the system prompt so the prefix matches the main turn's
    // prefix — DeepSeek prompt-caching requires an exact prefix match.
    final history = await _messageStore.getMessages(sessionId);
    final wireFamily = provider.wireFamily;
    final apiMessages = <Map<String, dynamic>>[
      ...ChatService.buildApiMessages(
        history,
        wireFamily,
        systemPrompt: session.systemPrompt,
      ),
    ];
    final priorBtw = _sessionController.btwTurnsFor(sessionId);
    for (final t in priorBtw) {
      apiMessages.add({
        'role': 'user',
        'content': btwRenderUserMessage(t.userText),
      });
      apiMessages.add({
        'role': 'assistant',
        'content': t.aiText.isEmpty ? null : t.aiText,
      });
    }
    apiMessages.add({'role': 'user', 'content': btwRenderUserMessage(prompt)});

    // Same response-state plumbing as the regular chat turn.
    _streamingController.clearStreamingFor(sessionId);
    rt.isResponding = true;
    rt.btwMode = true;
    rt.responseStartTime = DateTime.now();
    rt.ttftMs = 0.0;
    rt.ttftReceived = false;
    rt.tokPerSec = 0.0;
    rt.tokCount = 0.0;
    rt.firstTokenTime = null;
    rt.cumulativeGenMs = 0.0;
    rt.cumulativeCompletionTokens = 0;
    rt.roundStartTime = DateTime.now();
    rt.roundFirstTokenTime = null;
    rt.roundStreaming = true;
    rt.startStreamingTimer();
    _streamingController.startMetricsTimer(sessionId);
    _sessionController.appendPendingBtwTurn(sessionId, prompt);
    _refresh();

    final llmClient = LlmClient();
    final buffer = StringBuffer();
    LlmError? streamError;

    // Btw turns don't go through ChatService.sendMessage, so
    // they don't get a ChatResponse with the final token
    // counts — we have to capture them straight from the
    // streaming chunks. The LLM only emits these in its
    // `usage` block (usually on the last chunk), so the
    // values stay 0 for the bulk of the stream and snap to
    // the real numbers at the end.
    int btwTokensIn = 0;
    int btwTokensOut = 0;
    int btwCacheHit = 0;
    int btwCacheMiss = 0;

    try {
      final modelConfig = provider.modelById(modelId);
      final stream = llmClient.streamChat(
        endpointUrl: provider.endpointUrl,
        config: provider,
        apiKey: apiKey,
        modelId: modelId,
        messages: List<Map<String, dynamic>>.from(apiMessages),
        thinkingMode: rt.thinkingMode,
        reasoningEffort: rt.reasoningEffort,
        thinkingBudget: modelConfig?.thinkingBudget,
        maxTokens: modelConfig?.maxTokens,
        userId: '${InstallSlug.slug}-$sessionId',
      );
      var firstTokenEver = true;
      await for (final chunk in stream) {
        if (_btwCancelFlags[sessionId] == true) {
          _btwCancelFlags.remove(sessionId);
          break;
        }
        if (chunk.error != null) {
          streamError = chunk.error;
          break;
        }
        // Capture the LLM-reported usage. The `usage` block
        // is the only authoritative source of token counts —
        // we don't try to estimate from deltas because the
        // accumulated completion tokens would double-count
        // any reasoning or tool-call JSON the LLM emitted
        // alongside the visible text.
        if (chunk.promptTokens != null) btwTokensIn = chunk.promptTokens!;
        if (chunk.completionTokens != null) {
          btwTokensOut = chunk.completionTokens!;
        }
        if (chunk.promptCacheHitTokens != null) {
          btwCacheHit = chunk.promptCacheHitTokens!;
        }
        if (chunk.promptCacheMissTokens != null) {
          btwCacheMiss = chunk.promptCacheMissTokens!;
        }
        final deltaText = chunk.textDelta;
        final deltaReasoning = chunk.reasoningContent;
        if (deltaText != null || deltaReasoning != null) {
          rt.roundFirstTokenTime ??= DateTime.now();
          if (firstTokenEver && (deltaText != null || deltaReasoning != null)) {
            final now = DateTime.now();
            final elapsed =
                now.difference(rt.responseStartTime!).inMicroseconds / 1000.0;
            rt.ttftMs = elapsed;
            rt.ttftReceived = true;
            rt.firstTokenTime = now;
            firstTokenEver = false;
          }
          if (deltaText != null) {
            buffer.write(deltaText);
            _streamingController.appendStreamingContent(sessionId, deltaText);
            if (_streamingController.streamingContentFor(sessionId).isEmpty) {
              rt.contentStartTime = DateTime.now();
            }
            _sessionController.updateLastBtwTurnAiText(
              sessionId,
              buffer.toString(),
            );
          }
          if (deltaReasoning != null) {
            _streamingController.appendStreamingReasoning(
              sessionId,
              deltaReasoning,
            );
          }
          _refresh();
        }
      }
    } catch (e) {
      streamError = classifyThrownError(e, providerName: provider.name);
    } finally {
      llmClient.dispose();
    }

    // If the user interrupted this btw turn, interruptResponse already
    // handled all cleanup. Skip the normal post-stream cleanup.
    // We still record any usage the LLM reported before the
    // interrupt — the prompt was sent and (often) the cache
    // was hit, so the tokens were spent.
    if (rt.interrupted && !rt.isResponding) {
      RunMetrics.instance.recordBtwUsage(
        tokensIn: btwTokensIn,
        tokensOut: btwTokensOut,
        cacheHit: btwCacheHit,
        cacheMiss: btwCacheMiss,
      );
      return;
    }

    if (rt.roundStreaming && rt.roundFirstTokenTime != null) {
      rt.cumulativeGenMs +=
          DateTime.now().difference(rt.roundFirstTokenTime!).inMicroseconds /
          1000.0;
    }
    rt.roundStreaming = false;
    rt.roundStartTime = null;
    rt.roundFirstTokenTime = null;
    rt.pauseStreamingTimer();
    _streamingController.stopMetricsTimer(sessionId);
    rt.isResponding = false;
    rt.btwMode = false;

    if (streamError != null) {
      _streamingController.clearStreamingFor(sessionId);
      final turns = _sessionController.btwTurnsFor(sessionId);
      if (turns.isNotEmpty && turns.last.aiText.isEmpty) {
        _sessionController.clearBtwTurnsFor(sessionId);
        if (turns.length > 1) {
          for (var i = 0; i < turns.length - 1; i++) {
            _sessionController.appendPendingBtwTurn(
              sessionId,
              turns[i].userText,
            );
            _sessionController.updateLastBtwTurnAiText(
              sessionId,
              turns[i].aiText,
            );
          }
        }
      }
      _showToast(streamError.toUserMessage(), mode: ToastMode.error);
      // Still roll whatever usage the LLM did report into
      // the per-run totals — the user paid for the prompt
      // even if the response errored out before completing.
      RunMetrics.instance.recordBtwUsage(
        tokensIn: btwTokensIn,
        tokensOut: btwTokensOut,
        cacheHit: btwCacheHit,
        cacheMiss: btwCacheMiss,
      );
      _refresh();
      return;
    }

    final responseText = buffer.toString();
    _streamingController.clearStreamingFor(sessionId);
    assert(responseText.isNotEmpty || streamError == null);

    // Drain any messages the user queued while the btw was streaming.
    // These are "real" messages, so they clear the btw chain and
    // start a normal turn — same as if the user had typed them
    // after the btw finished.
    final queued = _sessionController.drainMessageQueue(sessionId);
    if (queued != null && queued.isNotEmpty) {
      _sessionController.clearBtwTurnsFor(sessionId);
      _refresh();
      // Hand the captured usage to the run aggregator
      // *before* we kick off the next turn, so the
      // queued turn's eventual completion is its own
      // line item in the summary (added via
      // `recordTurnUsage` in its own onComplete).
      RunMetrics.instance.recordBtwUsage(
        tokensIn: btwTokensIn,
        tokensOut: btwTokensOut,
        cacheHit: btwCacheHit,
        cacheMiss: btwCacheMiss,
      );
      await sendTurn(text: queued);
      return;
    }

    RunMetrics.instance.recordBtwUsage(
      tokensIn: btwTokensIn,
      tokensOut: btwTokensOut,
      cacheHit: btwCacheHit,
      cacheMiss: btwCacheMiss,
    );
    _refresh();
  }

  /// Interrupt the currently streaming response.
  void interruptResponse({required TextEditingController textController}) {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    final rt = _sessionController.runtime(sessionId);
    if (!rt.isResponding) return;

    final isBtw = rt.btwMode;

    // 1. Cancel the stream.
    if (isBtw) {
      _btwCancelFlags[sessionId] = true;
    } else {
      _chatService.cancelStream(sessionId);
    }

    // Abort any running tool processes.
    ShellProcessRegistry.instance.killAll(sessionId);
    final signals = _activeAbortSignals.remove(sessionId);
    if (signals != null) {
      for (final signal in signals) {
        signal.abort();
      }
    }

    // 2. Capture whatever was streamed so far.
    final partialContent = _streamingController.streamingContentFor(sessionId);
    final partialReasoning = _streamingController.streamingReasoningFor(
      sessionId,
    );

    // 3. Clear streaming state immediately.
    _streamingController.clearStreamingFor(sessionId);
    _streamingController.stopMetricsTimer(sessionId);
    _streamingController.stopContextAnimation();

    // 4. Reset the responding state and mark as interrupted.
    rt.isResponding = false;
    rt.btwMode = false;
    rt.interrupted = true;
    rt.roundStreaming = false;
    rt.roundStartTime = null;
    rt.roundFirstTokenTime = null;
    rt.pauseStreamingTimer();
    rt.cancelTimers();

    // Mark this session as interrupted so the onComplete / onError
    // callbacks in sendTurn know to skip their work.
    _interruptedSessions.add(sessionId);

    // Recompute context tracking from persisted messages.
    final baseTokens = _sessionController.computeBaseContext(sessionId);
    rt.contextTargetTokens = baseTokens;
    rt.contextDisplayTokens = baseTokens.toDouble();

    if (isBtw) {
      // Clean up the in-memory btw chain.
      final turns = _sessionController.btwTurnsFor(sessionId);
      if (turns.isNotEmpty && turns.last.aiText.isEmpty) {
        _sessionController.clearBtwTurnsFor(sessionId);
        if (turns.length > 1) {
          for (var i = 0; i < turns.length - 1; i++) {
            _sessionController.appendPendingBtwTurn(
              sessionId,
              turns[i].userText,
            );
            _sessionController.updateLastBtwTurnAiText(
              sessionId,
              turns[i].aiText,
            );
          }
        }
      }
    } else {
      // Persist the partial AI message (if any content was generated).
      if (partialContent.isNotEmpty || partialReasoning.isNotEmpty) {
        final interruptedContent = partialContent.isNotEmpty
            ? '$partialContent\n\n*[Response interrupted by user]*'
            : '*[Response interrupted by user]*';

        _messageStore
            .addMessage(
              sessionId,
              role: 'ai',
              content: interruptedContent,
              reasoningContent: partialReasoning,
            )
            .then((_) {
              _sessionController
                  .loadMessages(sessionId)
                  .then((_) => _refresh());
            });
      }

      // Drain any queued messages back into the input field.
      final queue = _sessionController.messageQueueFor(sessionId);
      if (queue.isNotEmpty) {
        final queuedTexts = queue.messages.map((m) => m.content).join('\n');
        final currentInput = textController.text;
        final newInput = currentInput.isEmpty
            ? queuedTexts
            : '$queuedTexts\n$currentInput';
        textController.text = newInput;
        textController.selection = TextSelection.collapsed(
          offset: newInput.length,
        );
        _sessionController.clearMessageQueue(sessionId);
      }

      // Update session status.
      final session = _sessionController.currentSession;
      _store.update(sessionId, status: SessionStatus.interrupted);
      session.status = SessionStatus.interrupted;
    }

    _showToast('Response interrupted', mode: ToastMode.status);
    _refresh();
  }

  /// Return the most recent user-role message in the current session,
  /// or `null` if there isn't one.
  Future<Message?> findLastUserMessage() async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return null;
    final messages = await _messageStore.getMessages(sessionId);
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == 'user') return messages[i];
    }
    return null;
  }

  /// Delete every persisted message in the current session from
  /// [fromId] onwards and reload the in-memory cache.
  Future<void> deleteMessagesFrom(int fromId) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    await _messageStore.deleteMessagesFrom(sessionId, fromId);
    _sessionController.clearBtwTurnsFor(sessionId);
    await _sessionController.loadMessages(sessionId);
    _refresh();
  }

  /// Maybe generate a TLDR summary for the given AI message.
  ///
  /// [userQuestion] is the user-role message that preceded
  /// [aiMsg]. When provided it is sent to the auxiliary model
  /// alongside the response so the summary can prioritize what
  /// actually answers the user's question and so the summary's
  /// language can follow the user's input language (see
  /// [tldrSystemPromptFor]). Pass null when the AI message has
  /// no real preceding user turn (e.g. synthetic bubbles) — the
  /// summarizer falls back to the response alone in that case.
  Future<void> maybeGenerateTldr(
    int sessionId,
    Message aiMsg, {
    bool force = false,
    TldrDetail detail = TldrDetail.defaultLevel,
    String? userQuestion,
  }) async {
    final rt = _sessionController.runtime(sessionId);
    final hasAuxModel =
        _providerService.auxiliaryModel != null &&
        _providerService.auxiliaryModel != 'none';

    if (!hasAuxModel) {
      if (force) {
        _showToast(
          'No auxiliary model — set one with /auxiliary',
          mode: ToastMode.error,
        );
      }
      _refresh();
      return;
    }

    if (!force) {
      final threshold = _providerService.tldrThreshold;
      if (aiMsg.content.length < threshold) return;
      if (aiMsg.tldr.isNotEmpty) return;
    } else if (rt.isGeneratingTldr) {
      return;
    }

    // Manual regeneration: clear the cached tldr on the in-memory
    // message so the bubble re-enters its generating state immediately.
    if (force && aiMsg.tldr.isNotEmpty) {
      await _messageStore.updateMessageTldr(aiMsg.id, '');
      final msgs = _sessionController.messageCache[sessionId];
      if (msgs != null) {
        for (var i = 0; i < msgs.length; i++) {
          if (msgs[i].id == aiMsg.id) {
            msgs[i] = msgs[i].copyWith(tldr: '');
            break;
          }
        }
      }
    }

    rt.isGeneratingTldr = true;
    _refresh();

    try {
      final tldrText = await _chatService.generateTldr(
        aiMsg.content,
        userQuestion: userQuestion,
        detail: detail,
      );
      if (tldrText != null && tldrText.isNotEmpty) {
        await _messageStore.updateMessageTldr(aiMsg.id, tldrText);
        final msgs = _sessionController.messageCache[sessionId];
        if (msgs != null) {
          for (var i = 0; i < msgs.length; i++) {
            if (msgs[i].id == aiMsg.id) {
              msgs[i] = msgs[i].copyWith(tldr: tldrText);
              break;
            }
          }
        }
      }
    } finally {
      rt.isGeneratingTldr = false;
      _refresh();
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Private helpers
  // ─────────────────────────────────────────────────────────────────────

  /// Returns true when the session's chat model and the configured
  /// auxiliary model resolve to the same provider/model.
  String _toolExecutionPreview(ToolCallData call, String projectPath) {
    const priorityKeys = [
      'filePath',
      'path',
      'command',
      'query',
      'url',
      'directory',
      'pattern',
    ];
    for (final key in priorityKeys) {
      final value = call.input[key];
      if (value == null) continue;
      final text = value.toString();
      if (text.isEmpty) continue;
      final display = (key == 'command' || key == 'query' || key == 'url')
          ? text
          : relativePath(text, projectPath);
      return _truncateToolPreview(display);
    }
    if (call.input.isEmpty) return '';
    return _truncateToolPreview(call.input.values.first.toString());
  }

  String _truncateToolPreview(String value) {
    const max = 60;
    if (value.length <= max) return value;
    return '${value.substring(0, max - 3)}...';
  }

  /// Returns true when the session's chat model and the configured
  /// auxiliary model resolve to the same provider/model.
  bool _shouldDeferTitleToAfterResponse() {
    final session = _sessionController.currentSession;
    if (session.id == 0) return true;
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == null || auxKey == 'none') return true;
    return session.model == auxKey;
  }

  /// Fire-and-forget title generation right after the user submits
  /// their message, but only when the auxiliary model is configured
  /// AND is on a different provider/model than the main chat.
  void _maybeKickOffTitleEarly(int sessionId, String userContent) {
    if (_sessionController.currentSession.title != 'New Session') return;
    if (_shouldDeferTitleToAfterResponse()) return;
    _sessionController.generateTitle(sessionId, userContent: userContent);
  }
}
