import 'package:nocterm/nocterm.dart';
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../services/auxiliary_prompts.dart';
import '../services/chat_service.dart';
import '../services/install_slug.dart';
import '../services/llm_client.dart';
import '../services/provider_service.dart';
import '../storage/message_store.dart';
import '../storage/session_store.dart';
import '../tools/registry.dart';
import '../tools/shell_base.dart';
import '../tools/tool_def.dart';
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

  ChatTurnOrchestrator({
    required SessionStore store,
    required ChatService chatService,
    required ProviderService providerService,
    required SessionController sessionController,
    required StreamingController streamingController,
    required ToolRegistry toolRegistry,
    required ShowToastCallback showToast,
    required void Function() refresh,
  }) : _store = store,
       _messageStore = store.messageStore,
       _chatService = chatService,
       _providerService = providerService,
       _sessionController = sessionController,
       _streamingController = streamingController,
       _toolRegistry = toolRegistry,
       _showToast = showToast,
       _refresh = refresh;

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
  }) async {
    final sessionId = _sessionController.currentSessionId;
    if (sessionId == null) return;
    final rt = _sessionController.runtime(sessionId);
    if (rt.isResponding) return;

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
            final streamingTokens = estimateTokens(
              _streamingController.streamingContentFor(sessionId) +
                  _streamingController.streamingReasoningFor(sessionId),
            );
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
          onToolRound: (int toolResultTokens) {
            if (_interruptedSessions.contains(sessionId)) return;
            final streamingTokens = estimateTokens(
              _streamingController.streamingContentFor(sessionId) +
                  _streamingController.streamingReasoningFor(sessionId),
            );
            rt.accumulatedToolTokens += streamingTokens + toolResultTokens;
            _streamingController.clearStreamingFor(sessionId);
            rt.contextTargetTokens =
                rt.turnBaseTokens + rt.accumulatedToolTokens;
            rt.contextDisplayTokens = rt.contextTargetTokens.toDouble();
            _sessionController.loadMessages(sessionId).then((_) => _refresh());
          },
          onToolUse: (ToolUseChunk chunk) {
            if (_interruptedSessions.contains(sessionId)) return;
            _streamingController.updateStreamingToolCall(sessionId, chunk);
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
            final total = response.promptTokens;
            final miss = response.promptCacheMissTokens;
            final nonCached = total - hit;
            if (total > 0 && hit > 0 && nonCached > 0) {
              rt.cacheHitPct = ((hit / total) * 100).round();
            } else if (total > 0 && miss > 0 && hit == 0) {
              rt.cacheHitPct = 0;
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
              maybeGenerateTldr(sessionId, lastAiMsg);
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
            _showToast(error, mode: ToastMode.error);
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
    final history = await _messageStore.getMessages(sessionId);
    final wireFamily = provider.wireFamily;
    final apiMessages = <Map<String, dynamic>>[
      ...ChatService.buildApiMessages(history, wireFamily),
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
    String? streamError;
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
      streamError = e.toString();
    } finally {
      llmClient.dispose();
    }

    // If the user interrupted this btw turn, interruptResponse already
    // handled all cleanup. Skip the normal post-stream cleanup.
    if (rt.interrupted && !rt.isResponding) {
      return;
    }

    if (rt.roundStreaming && rt.roundStartTime != null) {
      rt.cumulativeGenMs +=
          DateTime.now().difference(rt.roundStartTime!).inMicroseconds / 1000.0;
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
      _showToast(streamError, mode: ToastMode.error);
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
      await sendTurn(text: queued);
      return;
    }

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
  Future<void> maybeGenerateTldr(
    int sessionId,
    Message aiMsg, {
    bool force = false,
    TldrDetail detail = TldrDetail.defaultLevel,
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
