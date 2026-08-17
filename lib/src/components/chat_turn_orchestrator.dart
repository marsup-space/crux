import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import '../models/plan_selection.dart';
import '../services/plan_mode_controller.dart';
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../services/auxiliary_prompts.dart';
import '../services/chat_service.dart';
import '../services/git_status_service.dart';
import '../services/llm_client.dart';
import '../services/provider_service.dart';
import '../services/skills/skill_discovery.dart';
import '../storage/message_store.dart';
import '../storage/session_store.dart';
import '../tools/ask_tool.dart';
import '../tools/file_read_tracker.dart';
import '../tools/registry.dart';
import '../tools/shell_base.dart';
import '../tools/tool_def.dart';
import '../utils/run_metrics.dart';
import '../utils/skill_chip_substitution.dart';
import '../utils/session_mention.dart';
import '../utils/token_estimate.dart';
import 'btw_turn_handler.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import 'tldr_handler.dart';
import 'ui/toast.dart';

typedef ShowToastCallback = void Function(String message, {ToastMode mode});

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
  final Strings _strings;

  final GitStatusService _gitStatusService;
  final BtwTurnHandler _btwHandler;
  final TldrHandler _tldrHandler;

  /// The per-session plan-mode controller, read to inject the
  /// `<plan-context>` block into the LLM-bound text (§5 P3d). Null in
  /// tests; then no plan block is emitted.
  final PlanModeController? planModeController;

  /// When non-null, an in-flight `ask` tool call holds a completer that
  /// blocks the turn. Interrupting the turn must resolve that completer
  /// (with the dismiss sentinel) or [AskTool.execute] hangs forever —
  /// the turn executor is parked on `await executeTool(...)` and can't
  /// reach its own cancel checks.
  final PendingAskCubit? _pendingAskCubit;

  /// Provides the completed mention chips for the current input, so
  /// [sendTurn] can rewrite `#<id>:<title>` chips to `ses://<id>`.
  /// Null in tests / non-input paths (chips only exist when the user
  /// picked a mention via the chat input's overlay).
  final List<MentionChip> Function()? _mentionChipsProvider;

  final Map<int, bool> _btwCancelFlags = {};
  final Set<int> _interruptedSessions = {};
  final Map<int, List<AbortSignal>> _activeAbortSignals = {};
  final Set<int> _streamingGuardAbortedSessions = {};
  bool _fileMutatedThisRound = false;

  ChatTurnOrchestrator({
    required SessionStore store,
    required ChatService chatService,
    required ProviderService providerService,
    required SessionController sessionController,
    required StreamingController streamingController,
    required this._toolRegistry,
    required ShowToastCallback showToast,
    required void Function() refresh,
    required this._gitStatusService,
    required this._tracker,
    this._pendingAskCubit,
    this._mentionChipsProvider,
    this.planModeController,
    Strings strings = kEnglishStrings,
  }) : _store = store,
       _messageStore = store.messageStore,
       _chatService = chatService,
       _providerService = providerService,
       _sessionController = sessionController,
       _streamingController = streamingController,
       _showToast = showToast,
       _strings = strings,
       _refresh = refresh,
       _btwHandler = BtwTurnHandler(
         sessionController: sessionController,
         streamingController: streamingController,
         providerService: providerService,
         messageStore: store.messageStore,
         showToast: showToast,
         refresh: refresh,
       ),
       _tldrHandler = TldrHandler(
         sessionController: sessionController,
         providerService: providerService,
         chatService: chatService,
         messageStore: store.messageStore,
         showToast: showToast,
         refresh: refresh,
       );

  void showToast(String message, {ToastMode mode = ToastMode.info}) {
    _showToast(message, mode: mode);
  }

  bool wasInterrupted(int? sessionId) {
    if (sessionId == null) return false;
    return _sessionController.runtime(sessionId).interrupted;
  }

  bool _shouldAutoCompact({
    required Session session,
    required String incomingUserContent,
  }) {
    final modelConfig = _providerService.modelByCompositeKey(session.model);
    if (modelConfig == null) return true;

    final reserve = computeCompactionReserveAndThreshold(
      contextSize: modelConfig.contextSize,
    );

    final projected = estimateProjectedContextTokens(
      session: session,
      systemPrompt: session.systemPrompt,
      history: _sessionController.currentMessages,
      incomingUserContent: incomingUserContent,
      toolDefs: _toolRegistry.toApiTools(),
    );

    return projected > reserve.threshold;
  }

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

    if (isResponding) {
      _sessionController.enqueueMessage(sessionId, trimmed);
      textController.clear();
      _refresh();
      return;
    }

    if (sessionId != null) {
      _sessionController.clearBtwTurnsFor(sessionId);
      _streamingController.clearStreamingFor(sessionId);
    }

    textController.clear();

    await sendTurn(text: trimmed, images: images);
  }

  /// Build the `<plan-context>` block appended to the LLM-bound user
  /// text while plan mode is active (design doc §5 P3d). Returns null
  /// when plan mode is off. The visible bubble never shows this; only
  /// the LLM sees it.
  String? _buildPlanContextBlock(int sessionId) {
    final controller = planModeController;
    if (controller == null || !controller.active) return null;

    final buf = StringBuffer('<plan-context>\n');
    buf.writeln('plan_path: ${controller.planDocPath}');
    buf.writeln(
      'mode: ${controller.viewMode == PlanViewMode.follow ? 'follow' : 'free'}',
    );
    buf.writeln('viewing_version: ${controller.viewingVersion}');
    buf.writeln('head_version: ${controller.headVersion}');
    // Record the approved gate state on every turn so the context
    // reflects whether the edit/write/shell guards are currently armed.
    buf.writeln('approved: ${controller.approved}');

    final viewport = controller.viewportSourceLines();
    if (viewport != null) {
      buf.writeln('viewport_lines: ${viewport.$1}..${viewport.$2}');
    }

    // A revert is a real mutation (§9.3): tell the agent to re-read the
    // plan before editing, then clear the pending event so it fires
    // exactly once.
    final revert = controller.pendingRevert;
    if (revert != null) {
      buf.writeln('reverted_to: ${revert.toVersion}');
      buf.writeln(
        'note: the plan was reverted to v${revert.toVersion} — re-read '
        'the plan before editing (your next edit must match the '
        'reverted content).',
      );
      controller.clearPendingRevert();
    }

    final selection = controller.selection;
    if (selection != null && selection.text.isNotEmpty) {
      buf.writeln('selection:');
      buf.writeln('  from_version: ${selection.fromVersion}');
      buf.writeln('  lines: ${selection.startLine}..${selection.endLine}');
      buf.writeln('  cols: ${selection.startCol}..${selection.endCol}');
      buf.writeln('  text: |-');
      for (final line in selection.text.split('\n')) {
        buf.writeln('    $line');
      }
    }

    buf.write('</plan-context>');
    return buf.toString();
  }

  Future<void> sendTurn({
    String? text,
    List<ImageAttachment> images = const [],
    bool allowAutoCompact = true,
  }) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    final rt = _sessionController.runtime(sessionId);
    if (rt.isResponding) return;

    // Compute the LLM-bound expansion of any `$<skill>` chips but
    // keep `text` as the user's raw input for the message bubble.
    // The chat log shows the chip (`$gitnexus-exploring`); only
    // the LLM sees the expanded form with the body appended.
    String? llmText;
    if (text != null && text.isNotEmpty) {
      final session = _sessionController.currentSession;
      // Rewrite session-mention chips FIRST, on the raw text, so the
      // recorded chip offsets still line up. Skill expansion below may
      // strip leading `$` chars (shifting offsets) but never touches
      // the `#`/`ses://` tokens, so doing the chip rewrite before it
      // keeps multi-mention messages correct.
      final chips = _mentionChipsProvider?.call() ?? const <MentionChip>[];
      final mentionRewritten = rewriteSessionMentionsFromChips(text, chips);
      // Chat mode is workspace-free: don't discover or expand skills
      // (there's no project to attach them to, and the minimal prompt
      // never advertises a skill vocabulary). A bare chip-less pass
      // keeps the typed text as the LLM message.
      final expansion = session.isChat
          ? expandSkillChips(
              input: mentionRewritten,
              available: const [],
              alreadyLoaded: rt.loadedSkillNames,
            )
          : expandSkillChips(
              input: mentionRewritten,
              available: discoverSkills(cwd: session.projectPath),
              alreadyLoaded: rt.loadedSkillNames,
            );
      llmText = expansion.userMessage;
      // Mirror the resolved chip names onto the runtime so the
      // [ContextBar] hover hint can show the currently-loaded
      // skill list. We track names only (not full [SkillInfo])
      // because the hint just needs to enumerate them. Late
      // arrivals (the LLM calling `skill` during the turn) are
      // appended by [SkillTool.execute] directly into the same
      // set; the union is what the hint renders.
      if (expansion.includedSkills.isNotEmpty) {
        rt.loadedSkillNames.addAll(expansion.includedSkills);
      }

      // Plan-mode context injection (design doc §5 P3d): when plan
      // mode is active, every user message carries a structured
      // <plan-context> block describing the plan path, view mode,
      // viewport line range, current selection, and any pending
      // revert — the LLM reads it, the visible bubble never shows it.
      final planBlock = _buildPlanContextBlock(sessionId);
      if (planBlock != null) {
        llmText = '$llmText\n\n$planBlock';
      }
    }

    if (allowAutoCompact && text != null && text.trim().isNotEmpty) {
      if (rt.turnsSinceLastCompact > 0) {
        rt.turnsSinceLastCompact += 1;
        if (rt.turnsSinceLastCompact > 3) {
          rt.turnsSinceLastCompact = 0;
        }
      } else {
        final session = _sessionController.findSession(sessionId);
        if (session != null) {
          if (!_shouldAutoCompact(
            session: session,
            incomingUserContent: text,
          )) {
            // Below threshold — fall through
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
                // ContextBar reads MetricsCubit, while the compaction service
                // updates the legacy runtime. Keep the read-side target in sync.
                _sessionController.metricsCubit.updateContext(
                  sessionId: sessionId,
                  targetTokens: result.postEstimateTokens,
                );
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
                await _sessionController.loadMessages(sessionId);
                _refresh();
                await sendTurn(
                  text: text,
                  images: images,
                  allowAutoCompact: false,
                );
                return;
              }
              rt.turnsSinceLastCompact = 0;
            } catch (e) {
              rt.turnsSinceLastCompact = 1;
              _showToast(_strings.t('chat.compact.failed', {'error': '$e'}), mode: ToastMode.error);
              _refresh();
              return;
            }
          }
        }
      }
    }

    if (text != null) {
      RunMetrics.instance.recordTurnStart();
    }

    if (_chatService.isStreaming(sessionId)) {
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (!_chatService.isStreaming(sessionId)) break;
      }
      if (_chatService.isStreaming(sessionId)) return;
    }

    try {
      _streamingController.clearStreamingFor(sessionId);
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
      // Mirror the flag flip into ChatTurnCubit so subscribers
      // (chat_history's streaming-bubble visibility check) see the
      // turn kickoff immediately.
      _sessionController.mirrorTurnFlags(sessionId);
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
        if (session != null) {
          session.updatedAt = DateTime.now();
        }

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
        // Append the persisted user message to the in-memory cache.
        // Route through putCachedMessages so the cubit's messageCache
        // snapshot sees the new entry — otherwise chat_history keeps
        // showing the pre-append messages until the next round
        // complete (which re-fetches and mirrors via its own write).
        _sessionController.putCachedMessages(sessionId, [
          ...?_sessionController.messageCache[sessionId],
          userMsg,
        ]);
        _refresh();

        _maybeKickOffTitleEarly(sessionId, text);
      }
    } catch (e) {
      rt.isResponding = false;
      _sessionController.mirrorTurnFlags(sessionId);
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
          userContent: llmText ?? text,
          images: images,
          session: _sessionController.currentSession,
          runtime: rt,
          onDelta: (delta) {
            if (_interruptedSessions.contains(sessionId)) return;
            if (_sessionController.streamingCubit.state
                .streamingContentFor(sessionId)
                .isEmpty) {
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
                  _sessionController.streamingCubit.state.streamingContentFor(
                        sessionId,
                      ) +
                      _sessionController.streamingCubit.state
                          .streamingReasoningFor(sessionId),
                ) +
                _sessionController.streamingCubit.state
                    .streamingToolInputTokensFor(sessionId);
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
                  _sessionController.streamingCubit.state.streamingContentFor(
                        sessionId,
                      ) +
                      _sessionController.streamingCubit.state
                          .streamingReasoningFor(sessionId),
                ) +
                _sessionController.streamingCubit.state
                    .streamingToolInputTokensFor(sessionId);
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
            if (_fileMutatedThisRound) {
              _fileMutatedThisRound = false;
              unawaited(_gitStatusService.refresh());
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
                  _sessionController.streamingCubit.state.streamingContentFor(
                        sessionId,
                      ) +
                      _sessionController.streamingCubit.state
                          .streamingReasoningFor(sessionId),
                ) +
                _sessionController.streamingCubit.state
                    .streamingToolInputTokensFor(sessionId);
            rt.accumulatedToolTokens += streamingTokens;
            rt.contextTargetTokens =
                rt.turnBaseTokens + rt.accumulatedToolTokens;
            rt.contextDisplayTokens = rt.contextTargetTokens.toDouble();
            final projectPath =
                _sessionController.findSession(sessionId)?.projectPath ??
                _sessionController.currentSession.projectPath;
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

            unawaited(_gitStatusService.refresh());

            RunMetrics.instance.recordTurnUsage(
              tokensIn: response.promptTokens,
              tokensOut: response.completionTokens,
              cacheHit: response.promptCacheHitTokens,
              cacheMiss: response.promptCacheMissTokens,
            );

            await _sessionController.reconcileInactiveRunningSessions(
              refresh: false,
            );

            await _sessionController.setSessionStatus(
              sessionId,
              SessionStatus.done,
            );

            _refresh();

            _streamingController.clearStreamingFor(sessionId);
            _streamingController.stopMetricsTimer(sessionId);
            _activeAbortSignals.remove(sessionId);
            rt.turnBaseTokens = 0;
            rt.accumulatedToolTokens = 0;
            // Flip isResponding + the per-round lifecycle fields on
            // normal completion. The catch (line 302) and interrupt
            // (line 642) paths already do this, but the normal
            // completion path didn't — so chat_history's
            // rt.isResponding stayed true after a clean turn and the
            // streaming bubble kept rendering (showing empty content
            // since the streaming buffer is already cleared). This
            // also keeps the cubit-subscribed rebuilding paths in
            // lockstep when a future slice migrates chat_history's
            // isStreaming read off the runtime.
            rt.isResponding = false;
            rt.btwMode = false;
            rt.interrupted = false;
            rt.roundStreaming = false;
            rt.roundStartTime = null;
            rt.roundFirstTokenTime = null;
            // Mirror the flag reset into ChatTurnCubit so the
            // streaming bubble disappears on normal completion.
            _sessionController.mirrorTurnFlags(sessionId);
            final msgs = await _messageStore.getMessages(sessionId);
            _sessionController.putCachedMessages(sessionId, msgs);
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
            final cacheTotal = hit + miss;
            if (cacheTotal > 0) {
              rt.cacheHitPct =
                  ((hit / cacheTotal) * 100000).roundToDouble() / 1000.0;
            } else {
              rt.cacheHitPct = null;
            }
            // Mirror cacheHitPct into MetricsCubit so subscribers
            // (e.g. metrics_display's hover state) see the fresh
            // value at the same time the runtime does. Replaces the
            // existing MetricsSessionState for this session (the
            // cubit's state-level equality skips redundant emits if
            // the value didn't change).
            _sessionController.metricsCubit.replaceSessionState(
              sessionId,
              _sessionController.metricsCubit.state
                  .sessionState(sessionId)
                  .copyWith(cacheHitPct: rt.cacheHitPct),
            );
            _refresh();
            final currentTitle = _sessionController.currentSession.title;
            if (currentTitle == 'New Session' || currentTitle == 'New Chat') {
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
              _tldrHandler.maybeGenerateTldr(
                sessionId,
                lastAiMsg,
                userQuestion: lastUserContent,
              );
            }
            if (response.queuedMessage != null &&
                response.queuedMessage!.isNotEmpty) {
              await _messageStore.addMessage(
                sessionId,
                role: 'user',
                content: response.queuedMessage!,
              );
              final updatedMsgs = await _messageStore.getMessages(sessionId);
              _sessionController.putCachedMessages(sessionId, updatedMsgs);
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
            _messageStore
                .addMessage(
                  sessionId,
                  role: 'stream_error',
                  content: error.toUserMessage(),
                  error: error.toJson(),
                  model: _sessionController.currentSession.model,
                )
                .then((persisted) {
                  final cache = _sessionController.messageCache[sessionId];
                  if (cache != null) {
                    // Rebuild the list rather than mutating in place so the
                    // SessionCubit's BlocSelector (which compares by list
                    // identity) actually fires for the appended error row.
                    _sessionController.putCachedMessages(sessionId, [
                      ...cache,
                      persisted,
                    ]);
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
          _sessionController.mirrorTurnFlags(sessionId);
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
      // ContextBar reads MetricsCubit, while the compaction service updates
      // the legacy runtime. Mirror the compacted target before refreshing.
      _sessionController.metricsCubit.updateContext(
        sessionId: sessionId,
        targetTokens: result.postEstimateTokens,
      );
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
      await _sessionController.loadMessages(sessionId);
      _refresh();
    } catch (e) {
      _showToast(_strings.t('chat.compact.failed', {'error': '$e'}), mode: ToastMode.error);
    }
  }

  Future<void> sendBtwTurn(String prompt) async {
    await _btwHandler.sendBtwTurn(prompt);
  }

  /// Cancel the turn that is currently parked on an in-flight `ask`
  /// form, without any of the interrupt fanfare (no toast, no
  /// "[Response interrupted by user]" marker, no `interrupted` session
  /// status). Used when the user dismisses the form: they want to go
  /// back to the plain input box and type a free-form message, so the
  /// turn must unwind WITHOUT delivering a tool result to the model —
  /// otherwise the agent would immediately generate another reply off
  /// the `(dismissed)` sentinel instead of waiting for the user.
  ///
  /// Mechanics: same abort path as [interruptResponse]. The pending
  /// ask's completer resolves via [PendingAskCubit.clearFor] (with the
  /// dismiss sentinel, but nothing reads it — the executor hits its
  /// post-tool-execution cancel check at chat_turn_executor.dart and
  /// returns before persisting anything or calling onComplete/onError).
  void cancelAskTurn(int sessionId) {
    final rt = _sessionController.runtime(sessionId);
    if (!rt.isResponding) return;

    _chatService.cancelStream(sessionId);

    ShellProcessRegistry.instance.killAll(sessionId);
    final signals = _activeAbortSignals.remove(sessionId);
    if (signals != null) {
      for (final signal in signals) {
        signal.abort();
      }
    }

    // Resolve the ask completer so the executor's `await executeTool`
    // unblocks and reaches the cancel check. This also emits the empty
    // PendingAskState, so the input region swaps back from the AskForm
    // to the normal ChatInput.
    _pendingAskCubit?.clearFor(sessionId);

    // Silence every turn callback for the remainder of this turn —
    // the executor's own cancel path never calls onComplete/onError,
    // but a provider stream event could still race in before the
    // unwind lands.
    _interruptedSessions.add(sessionId);

    _streamingController.clearStreamingFor(sessionId);
    _streamingController.stopMetricsTimer(sessionId);
    _streamingController.stopContextAnimation();

    rt.isResponding = false;
    rt.roundStreaming = false;
    rt.roundStartTime = null;
    rt.roundFirstTokenTime = null;
    rt.pauseStreamingTimer();
    _sessionController.mirrorTurnFlags(sessionId);

    // Next user message must not get the "your response was
    // interrupted" preamble — from the user's perspective nothing was
    // interrupted; they simply chose not to answer the form.
    rt.interrupted = false;

    _refresh();
  }

  void interruptResponse({required TextEditingController textController}) {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    final rt = _sessionController.runtime(sessionId);
    if (!rt.isResponding) return;

    final isBtw = rt.btwMode;

    if (isBtw) {
      _btwCancelFlags[sessionId] = true;
    } else {
      _chatService.cancelStream(sessionId);
    }

    ShellProcessRegistry.instance.killAll(sessionId);
    final signals = _activeAbortSignals.remove(sessionId);
    if (signals != null) {
      for (final signal in signals) {
        signal.abort();
      }
    }

    // Drop any in-flight `ask` form. The turn executor is blocked on
    // its completer; without this, the turn hangs forever instead of
    // unwinding. The cubit resolves the completer with the dismiss
    // sentinel so executor's `await executeTool(...)` returns.
    _pendingAskCubit?.clearFor(sessionId);

    final partialContent = _sessionController.streamingCubit.state
        .streamingContentFor(sessionId);
    final partialReasoning = _sessionController.streamingCubit.state
        .streamingReasoningFor(sessionId);

    _streamingController.clearStreamingFor(sessionId);
    _streamingController.stopMetricsTimer(sessionId);
    _streamingController.stopContextAnimation();

    rt.isResponding = false;
    rt.btwMode = false;
    rt.interrupted = true;
    rt.roundStreaming = false;
    rt.roundStartTime = null;
    rt.roundFirstTokenTime = null;
    rt.pauseStreamingTimer();
    rt.cancelTimers();
    // Mirror the interrupt into ChatTurnCubit so subscribers see the
    // phase transition (responding → interrupted) immediately.
    _sessionController.mirrorTurnFlags(sessionId);

    _interruptedSessions.add(sessionId);

    final baseTokens = _sessionController.computeBaseContext(sessionId);
    rt.contextTargetTokens = baseTokens;
    rt.contextDisplayTokens = baseTokens.toDouble();

    if (isBtw) {
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

      final session = _sessionController.currentSession;
      _store.update(sessionId, status: SessionStatus.interrupted);
      session.status = SessionStatus.interrupted;
    }

    _showToast('Response interrupted', mode: ToastMode.status);
    _refresh();
  }

  Future<Message?> findLastUserMessage() async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return null;
    final messages = await _messageStore.getMessages(sessionId);
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role == 'user') return messages[i];
    }
    return null;
  }

  Future<void> deleteMessagesFrom(int fromId) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    await _messageStore.deleteMessagesFrom(sessionId, fromId);
    _sessionController.clearBtwTurnsFor(sessionId);
    await _sessionController.loadMessages(sessionId);
    _refresh();
  }

  Future<void> maybeGenerateTldr(
    int sessionId,
    Message aiMsg, {
    bool force = false,
    TldrDetail detail = TldrDetail.defaultLevel,
    String? userQuestion,
  }) async {
    await _tldrHandler.maybeGenerateTldr(
      sessionId,
      aiMsg,
      force: force,
      detail: detail,
      userQuestion: userQuestion,
    );
  }

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

  bool _shouldDeferTitleToAfterResponse() {
    final session = _sessionController.currentSession;
    if (session.id == 0) return true;
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == null || auxKey == 'none') return true;
    return session.model == auxKey;
  }

  void _maybeKickOffTitleEarly(int sessionId, String userContent) {
    final title = _sessionController.currentSession.title;
    if (title != 'New Session' && title != 'New Chat') return;
    if (_shouldDeferTitleToAfterResponse()) return;
    _sessionController.generateTitle(sessionId, userContent: userContent);
  }
}
