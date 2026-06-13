import 'dart:async';
import 'dart:convert';

import '../models/message.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../storage/session_store.dart';
import '../tools/tool_def.dart';
import '../utils/token_estimate.dart';
import 'auxiliary_prompts.dart';
import 'auxiliary_service.dart';
import 'install_slug.dart';
import 'llm_client.dart';
import 'provider_service.dart';
import 'tool_executor.dart';

class ChatResponse {
  final int promptTokens;
  final int completionTokens;
  final int promptCacheHitTokens;
  final int promptCacheMissTokens;

  /// If non-null, the user queued a message during streaming that
  /// should be sent as a new turn immediately after this response
  /// completes. The caller (ChatPanel) uses this to auto-kick off
  /// a new `_sendTurn` so the queued message reaches the LLM
  /// without the user having to re-submit.
  final String? queuedMessage;

  const ChatResponse({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.promptCacheHitTokens = 0,
    this.promptCacheMissTokens = 0,
    this.queuedMessage,
  });
}

class ChatService {
  final SessionStore _store;
  final ProviderService _providerService;
  final LlmClient _llmClient;
  final ToolExecutor _toolExecutor;
  final AuxiliaryService _auxiliaryService;
  final Set<int> _activeSessions = {};
  final Set<int> _cancelRequested = {};

  ChatService(
    this._store,
    this._providerService,
    this._llmClient,
    this._toolExecutor,
  ) : _auxiliaryService = AuxiliaryService(_providerService, _store);

  bool isStreaming(int sessionId) => _activeSessions.contains(sessionId);

  void cancelStream(int sessionId) {
    _cancelRequested.add(sessionId);
  }

  Future<String?> generateSessionTitle(
    int sessionId, {
    String? userContent,
  }) =>
      _auxiliaryService.generateTitle(sessionId, userContent: userContent);

  Future<String?> generateTldr(
    String responseContent, {
    TldrDetail detail = TldrDetail.defaultLevel,
  }) =>
      _auxiliaryService.generateTldr(responseContent, detail: detail);

  /// Run a single chat turn for [sessionId].
  ///
  /// [userContent] is the new user prompt for this turn. Pass `null`
  /// to skip the user-message persist and re-submit the existing
  /// history as-is — used by `/continue` when the conversation
  /// already ends on a role that the LLM API will accept as a
  /// trailing turn (a `tool` result, or a `user` message that's
  /// already a valid final turn). When `null`, no new user message
  /// is appended; the LLM is called with the wire-format history
  /// as it stands. When non-null, the user turn is persisted and
  /// the LLM is called with the new message appended.
  Future<void> sendMessage({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required void Function(String delta) onDelta,
    required void Function(String reasoning) onReasoning,
    required void Function() onChunk,
    required void Function(ChatResponse response) onComplete,
    required void Function(String error) onError,
    void Function(int toolResultTokens)? onToolRound,
    void Function(ToolUseChunk chunk)? onToolUse,
    String? Function()? onQueueDrain,
    void Function(AbortSignal)? onAbortSignal,
    String? userContent,
  }) async {
    if (userContent != null) {
      await _store.addMessage(sessionId, role: 'user', content: userContent);
    }

    await _store.update(sessionId, status: SessionStatus.running);
    session.status = SessionStatus.running;
    session.updatedAt = DateTime.now();

    runtime.isResponding = true;
    runtime.tokPerSec = 0.0;
    runtime.tokCount = 0.0;

    _activeSessions.add(sessionId);

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
    final modelConfig = provider?.modelById(modelId);

    if (provider == null || apiKey == null || apiKey.isEmpty) {
      await _store.update(sessionId, status: SessionStatus.needUserAction);
      session.status = SessionStatus.needUserAction;
      runtime.isResponding = false;
      _activeSessions.remove(sessionId);
      onError(
        'No API key for provider "$providerName". Use /provider to connect.',
      );
      return;
    }

    final history = await _store.getMessages(sessionId);
    final wireFamily = provider.wireFamily;
    final apiMessages = buildApiMessages(history, wireFamily);
    final toolDefs = _toolExecutor.getApiToolDefinitions();

    // Per-round text/reasoning accumulators, hoisted out of the agentic
    // loop so the post-loop persist (just below the `while (true)`)
    // can read the final round's content. Inside the loop, these are
    // cleared at the end of every tool round (both Anthropic and
    // OpenAI branches), so by the time we break out of the loop they
    // hold exactly the last round's text/reasoning — the "final
    // answer" content. This avoids the prior bug where an accumulating
    // buffer concatenated every round into the final `ai` row, which
    // caused earlier rounds' text to appear twice in the next request
    // (once in their own `tool_call` assistant message, once in the
    // concatenated `ai` message) — wasting tokens and invalidating
    // the server-side prompt-cache (KV) prefix on every turn.
    final roundTextBuffer = StringBuffer();
    final roundReasoningBuffer = StringBuffer();
    final roundReasoningSignatureBuffer = StringBuffer();
    int promptTokens = 0;
    int completionTokens = 0;
    int promptCacheHitTokens = 0;
    int promptCacheMissTokens = 0;
    int reasoningTokens = 0;

    // Per-round thinking metrics. Reset at the top of each loop
    // iteration so every tool_call message gets its own thinking
    // duration and token count rather than inheriting stale values
    // from a prior round.
    int roundReasoningTokens = 0;
    double roundThinkingDurationMs = 0;
    DateTime? roundFirstContentTime;
    DateTime? roundFirstDeltaTime;
    DateTime? roundFirstReasoningTime;
    DateTime? roundLastReasoningTime;
    DateTime? roundLastDeltaTime;

    var firstTokenEver = true;

    // Resolve the per-turn round-trip cap from provider/model TOML config.
    // Precedence: model-level max_rounds → provider default_max_rounds
    // → null (unbounded, the default). When set, the agentic loop bails
    // out after that many model→tool→model round-trips and surfaces a
    // soft "step limit reached" signal to the UI.
    final maxRounds = provider.effectiveMaxRoundsFor(modelConfig!);
    var stepCount = 0;
    var stepLimitReached = false;

    while (true) {
      if (maxRounds != null) {
        stepCount++;
        if (stepCount > maxRounds) {
          stepLimitReached = true;
          break;
        }
      }

      if (_cancelRequested.contains(sessionId)) {
        runtime.pauseStreamingTimer();
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _activeSessions.remove(sessionId);
        _cancelRequested.remove(sessionId);
        return;
      }

      runtime.startStreamingTimer();
      // Mark that the LLM is not currently streaming deltas — the first
      // delta of this round will flip this on, and the metrics timer
      // uses the flag to pause tok/s while we wait for the model to
      // start emitting and while tools run.
      runtime.roundStreaming = false;
      runtime.roundFirstTokenTime = null;

      // Reset per-round thinking metrics so every tool_call message
      // gets its own duration and token count.
      roundReasoningTokens = 0;
      roundReasoningSignatureBuffer.clear();
      roundThinkingDurationMs = 0;
      roundFirstContentTime = null;
      roundFirstDeltaTime = null;
      roundFirstReasoningTime = null;
      roundLastReasoningTime = null;
      roundLastDeltaTime = null;

      final stream = _llmClient.streamChat(
        endpointUrl: provider.endpointUrl,
        config: provider,
        apiKey: apiKey,
        modelId: modelId,
        messages: List<Map<String, dynamic>>.from(apiMessages),
        thinkingMode: runtime.thinkingMode,
        reasoningEffort: runtime.reasoningEffort,
        thinkingBudget: modelConfig?.thinkingBudget,
        maxTokens: modelConfig?.maxTokens,
        tools: toolDefs.isNotEmpty ? toolDefs : null,
        userId: '${InstallSlug.slug}-$sessionId',
      );

      final chunks = <LlmChunk>[];

      final useLerp = modelConfig?.streamLerp ?? false;
      String lerpPendingText = '';
      String lerpPendingReasoning = '';
      Timer? lerpTimer;
      var lerpStreamDone = false;
      Completer<void>? lerpDrainCompleter;

      try {
        void ensureLerpTimer() {
          if (lerpTimer != null) return;
          lerpTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
            // Stop emitting if the stream was cancelled.
            if (_cancelRequested.contains(sessionId)) {
              lerpTimer?.cancel();
              lerpTimer = null;
              if (lerpDrainCompleter != null &&
                  !lerpDrainCompleter!.isCompleted) {
                lerpDrainCompleter!.complete();
              }
              return;
            }

            final totalPending =
                lerpPendingText.length + lerpPendingReasoning.length;
            if (totalPending == 0) {
              if (lerpStreamDone &&
                  lerpDrainCompleter != null &&
                  !lerpDrainCompleter!.isCompleted) {
                lerpDrainCompleter!.complete();
              }
              return;
            }

            final alpha = lerpStreamDone ? 0.03 : 0.016;
            final minCount = lerpStreamDone ? 2 : 1;
            final count = (totalPending * alpha).ceil().clamp(
              minCount,
              totalPending,
            );

            var remaining = count;

            if (lerpPendingText.isNotEmpty) {
              final take = remaining.clamp(0, lerpPendingText.length);
              if (take > 0) {
                final emit = lerpPendingText.substring(0, take);
                lerpPendingText = lerpPendingText.substring(take);
                onDelta(emit);
                remaining -= take;
              }
            }

            if (remaining > 0 && lerpPendingReasoning.isNotEmpty) {
              final take = remaining.clamp(0, lerpPendingReasoning.length);
              if (take > 0) {
                final emit = lerpPendingReasoning.substring(0, take);
                lerpPendingReasoning = lerpPendingReasoning.substring(take);
                onReasoning(emit);
              }
            }

            onChunk();
          });
        }

        await for (final chunk in stream) {
          // Check if the caller requested a cancel. Without this,
          // the stream keeps consuming chunks until the LLM finishes
          // naturally, even after cancelStream() was called. Breaking
          // here lets the interrupt take effect on the very next chunk.
          if (_cancelRequested.contains(sessionId)) {
            lerpTimer?.cancel();
            break;
          }

          if (chunk.error != null) {
            lerpTimer?.cancel();
            runtime.pauseStreamingTimer();
            runtime.isResponding = false;
            await _store.update(sessionId, status: SessionStatus.idle);
            session.status = SessionStatus.idle;
            _activeSessions.remove(sessionId);
            onError(chunk.error!);
            return;
          }

          chunks.add(chunk);

          if (chunk.reasoningSignatureDelta != null) {
            roundReasoningSignatureBuffer.write(chunk.reasoningSignatureDelta);
          }

          // First delta of the current round (text, reasoning, or
          // tool_use): mark the start of active generation for this
          // round. The metrics timer uses roundFirstTokenTime to
          // compute the live tok/s denominator. The cumulative
          // completion-token counter also gets a small bump for
          // tool_use JSON fragments so the LLM's tool-call generation
          // is included in tok/s (text and reasoning are accounted
          // for via estimateTokens in the metrics timer).
          if (chunk.textDelta != null ||
              chunk.reasoningContent != null ||
              chunk.toolUse != null) {
            final now = DateTime.now();
            if (!runtime.roundStreaming) {
              runtime.roundFirstTokenTime = now;
              runtime.roundStreaming = true;
              roundFirstDeltaTime = now;
            }
            // Always track the last delta time so we can compute
            // reasoning duration from stream boundaries when the LLM
            // reports reasoningTokens but doesn't stream reasoning
            // content separately.
            roundLastDeltaTime = now;
            if (chunk.toolUse != null) {
              if (chunk.toolUse!.inputDelta.isNotEmpty) {
                runtime.cumulativeCompletionTokens += estimateTokens(
                  chunk.toolUse!.inputDelta,
                );
              }
              // Forward the raw delta to the chat panel so the live
              // streaming bubble can show a per-tool "ToolName (~Nt)"
              // row that materializes as the JSON arguments stream
              // in. The chat panel folds this into
              // [StreamingController] state and re-renders. We fire
              // on *every* tool_use delta — including the very first
              // one that may carry only the call id and name with no
              // input yet (OpenAI splits id/name into one delta and
              // arguments into a later one) — so the row appears the
              // moment the LLM starts streaming a tool call rather
              // than after the full JSON has been received and parsed.
              onToolUse?.call(chunk.toolUse!);
            }
            if (firstTokenEver &&
                (chunk.textDelta != null || chunk.reasoningContent != null)) {
              final now = DateTime.now();
              final elapsed =
                  now.difference(runtime.responseStartTime!).inMicroseconds /
                  1000.0;
              runtime.ttftMs = elapsed;
              runtime.ttftReceived = true;
              // Stash the wall-clock time of the first delta so the
              // tok/s display can measure generation rate from this
              // point on, excluding the TTFT wait. Without this, the
              // tok/s denominator is inflated by the time spent
              // waiting for the model to start emitting — significant
              // for thinking-mode providers (MiniMax, etc.) where
              // TTFT includes a long thinking preamble.
              runtime.firstTokenTime = now;
              firstTokenEver = false;
            }
            if (chunk.textDelta != null) {
              roundTextBuffer.write(chunk.textDelta);
              // Track when the first content (non-reasoning) delta
              // arrives in this round — used as the reasoning-end
              // boundary in the fallback duration calculation when
              // the LLM reports reasoningTokens but doesn't stream
              // reasoning content separately.
              roundFirstContentTime ??= now;
              if (useLerp) {
                lerpPendingText += chunk.textDelta!;
                ensureLerpTimer();
              } else {
                onDelta(chunk.textDelta!);
              }
            }
            if (chunk.reasoningContent != null) {
              roundReasoningBuffer.write(chunk.reasoningContent);
              // Track the first and last reasoning delta timestamps so
              // we can compute the actual reasoning stream duration.
              // This works even when the LLM doesn't report a
              // thinking_duration field — we measure wall-clock time
              // from first reasoning token to last reasoning token.
              roundFirstReasoningTime ??= now;
              roundLastReasoningTime = now;
              if (useLerp) {
                lerpPendingReasoning += chunk.reasoningContent!;
                ensureLerpTimer();
              } else {
                onReasoning(chunk.reasoningContent!);
              }
            }
            if ((!useLerp &&
                    (chunk.textDelta != null ||
                        chunk.reasoningContent != null)) ||
                chunk.toolUse != null) {
              // Repaint trigger for the chat panel. Text/reasoning
              // deltas are gated on `!useLerp` because the lerp
              // timer's 60fps tick is the repaint source in that
              // mode (see `ensureLerpTimer`). Tool-use deltas always
              // fire immediately so the in-progress tool call row
              // appears in the live bubble the moment the LLM
              // starts streaming one — the lerp timer is not
              // running at that point (no pending text).
              onChunk();
            }
          }

          if (chunk.promptTokens != null) {
            promptTokens = chunk.promptTokens!;
          }
          if (chunk.completionTokens != null) {
            completionTokens = chunk.completionTokens!;
          }
          if (chunk.promptCacheHitTokens != null) {
            promptCacheHitTokens = chunk.promptCacheHitTokens!;
          }
          if (chunk.promptCacheMissTokens != null) {
            promptCacheMissTokens = chunk.promptCacheMissTokens!;
          }
          if (chunk.reasoningTokens != null) {
            reasoningTokens = chunk.reasoningTokens!;
          }
        }
      } catch (e) {
        lerpTimer?.cancel();
        runtime.pauseStreamingTimer();
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _activeSessions.remove(sessionId);
        onError(e.toString());
        return;
      }

      // If the stream was cancelled mid-chunk, exit the agentic loop
      // immediately — don't process partial chunks, execute tools, or
      // call onComplete. The caller (_interruptResponse in ChatPanel)
      // has already handled cleanup.
      if (_cancelRequested.contains(sessionId)) {
        runtime.pauseStreamingTimer();
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _activeSessions.remove(sessionId);
        _cancelRequested.remove(sessionId);
        return;
      }

      lerpStreamDone = true;

      // Round stream finished. Fold this round's wall-clock generation
      // time into the per-turn cumulative total and clear the
      // round-streaming flag so the metrics timer pauses while tools
      // execute and while we wait for the next LLM response. Done
      // BEFORE the lerp drain so the denominator reflects only the
      // LLM's actual generation time, not the visual lerp animation
      // (up to 10s of post-stream UI smoothing).
      if (runtime.roundStreaming && runtime.roundFirstTokenTime != null) {
        final roundMs =
            DateTime.now()
                .difference(runtime.roundFirstTokenTime!)
                .inMicroseconds /
            1000.0;
        runtime.cumulativeGenMs += roundMs;
      }

      // Compute per-round thinking duration from the wall-clock time
      // between the first and last reasoning tokens in the stream.
      // This works even when the LLM doesn't report a duration field —
      // we measure it directly from when reasoning deltas arrive.
      //
      // Three cases:
      // 1. Reasoning content was streamed: use first→last reasoning
      //    delta timestamps for an accurate measurement.
      // 2. No reasoning content streamed, but reasoningTokens > 0:
      //    the LLM did think but didn't stream the reasoning (e.g.
      //    some OpenAI-compatible providers). Fall back to the
      //    wall-clock time from the first delta to either the first
      //    content delta or the last delta of the round.
      // 3. No reasoning at all: duration stays 0.
      if (roundFirstReasoningTime != null && roundLastReasoningTime != null) {
        // Case 1: we saw reasoning content in the stream.
        roundThinkingDurationMs =
            roundLastReasoningTime
                .difference(roundFirstReasoningTime)
                .inMicroseconds /
            1000.0;
      } else if (reasoningTokens > 0 && roundFirstDeltaTime != null) {
        // Case 2: the LLM reports reasoning tokens but didn't stream
        // reasoning content. Use stream boundaries as an approximation:
        // from the first delta of any kind to either the first content
        // delta (if there is one) or the last delta of the round.
        final reasoningEnd =
            roundFirstContentTime ?? roundLastDeltaTime ?? DateTime.now();
        roundThinkingDurationMs =
            reasoningEnd.difference(roundFirstDeltaTime).inMicroseconds /
            1000.0;
      }
      // Capture per-round reasoning tokens before the final round
      // overwrites the cumulative value.
      roundReasoningTokens = reasoningTokens;

      runtime.roundStreaming = false;
      runtime.roundFirstTokenTime = null;

      if (lerpTimer != null) {
        if (lerpPendingText.isEmpty && lerpPendingReasoning.isEmpty) {
          lerpTimer!.cancel();
          lerpTimer = null;
        } else {
          lerpDrainCompleter = Completer<void>();
          await lerpDrainCompleter!.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () {},
          );
          lerpTimer?.cancel();
          lerpTimer = null;
        }
      }

      runtime.pauseStreamingTimer();

      final finishReason = ToolExecutor.parseFinishReason(chunks);

      if (finishReason != 'tool_use') break;

      // Check for cancel before executing tools — the user may have
      // interrupted after the LLM finished streaming but before tools
      // started executing.
      if (_cancelRequested.contains(sessionId)) {
        runtime.pauseStreamingTimer();
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _activeSessions.remove(sessionId);
        _cancelRequested.remove(sessionId);
        return;
      }

      final toolCalls = ToolExecutor.parseToolUseFromChunks(chunks);
      if (toolCalls.isEmpty) break;

      final roundText = roundTextBuffer.toString();
      final roundReasoning = roundReasoningBuffer.toString();
      final roundReasoningSignature = roundReasoningSignatureBuffer.toString();

      // ── Execute EVERY tool BEFORE compressing any of them ──
      //
      // We must know whether the read-before-write guard fired on
      // any LargePayloadTool call *before* deciding which args to
      // offload.  When the guard fires the LLM needs the original
      // args to re-evaluate its edit/write against the actual file
      // content — compressing them to stand-ins would force an
      // extra `recall` round-trip on the very next turn.
      //
      // The wire-format assistant message uses the original
      // toolCalls (line 694 / 747), so the LLM receives the full
      // args in the *current* turn regardless of compression.
      // Compression only affects what the *next* turn sees when
      // the history is rebuilt from the DB.

      // Execute tools + record guard triggers.
      final guardTriggers = <String>{};
      final assistantMsg = _toolExecutor.formatAssistantToolCallsMessage(
        toolCalls,
        roundText,
        wireFamily,
        reasoningContent: roundReasoning,
        reasoningSignature: roundReasoningSignature,
      );
      apiMessages.add(assistantMsg);
      final callResults = <String, ToolResult>{};
      var roundResultTokens = 0;
      {
        final isAnthropic = wireFamily == WireFamily.anthropicCompatible;
        final content = isAnthropic ? <Map<String, dynamic>>[] : null;
        for (final call in toolCalls) {
          // Check for cancel between tool executions — the user may have
          // interrupted while tools are running.
          if (_cancelRequested.contains(sessionId)) {
            runtime.pauseStreamingTimer();
            runtime.isResponding = false;
            await _store.update(sessionId, status: SessionStatus.idle);
            session.status = SessionStatus.idle;
            _activeSessions.remove(sessionId);
            _cancelRequested.remove(sessionId);
            return;
          }

          final abortSignal = AbortSignal(sessionId: sessionId);
          onAbortSignal?.call(abortSignal);
          final ctx = ToolContext(
            sessionId: sessionId,
            messageId: -1,
            abort: abortSignal,
            callId: call.callId,
            workingDirectory: session.projectPath,
          );
          final result = await _toolExecutor.executeTool(call, ctx);
          callResults[call.callId] = result;
          if (result.metadata['guardTriggered'] == true) {
            guardTriggers.add(call.callId);
          }
          if (isAnthropic) {
            content!.add({
              'type': 'tool_result',
              'tool_use_id': call.callId,
              'content': result.output,
            });
          } else {
            apiMessages.add({
              'role': 'tool',
              'tool_call_id': call.callId,
              'content': result.output,
            });
          }
          roundResultTokens += estimateToolRoundTripTokens(
            toolName: call.name,
            args: call.input,
            resultOutput: result.output,
            excludeArgsFromEstimate: offloadableArgsFor(
              _toolExecutor.lookupTool(call.name),
            ),
          );
        }
        if (isAnthropic) {
          apiMessages.add({'role': 'user', 'content': content});
        }
      }

      // ── Compress (skip calls where the guard fired) ──
      final compressedToolCalls = <ToolCall>[];
      var preCompressTokens = 0;
      for (final call in toolCalls) {
        final tool = _toolExecutor.lookupTool(call.name);
        if (tool is LargePayloadTool && guardTriggers.contains(call.callId)) {
          // Guard fired — keep the original args so the LLM can
          // re-evaluate its edit/write without an extra recall.
          compressedToolCalls.add(call);
          continue;
        }
        if (tool is LargePayloadTool) {
          // Include the OFFLOADABLE args in the pre-number. The
          // strikethrough is meant to show what compression SAVES —
          // if we exclude oldString/newString from the estimate,
          // both numbers look the same and the user sees zero
          // benefit. The post number (from collapsedSummary) also
          // includes the args (which are now stand-ins), so the
          // comparison is honest: big strikethrough = big saving.
          preCompressTokens += estimateToolRoundTripTokens(
            toolName: call.name,
            args: call.input,
            resultOutput: '',
          );
        }
        compressedToolCalls.add(
          await _toolExecutor.compressCallForPersistence(call, sessionId),
        );
      }

      final toolCallData = compressedToolCalls
          .map(
            (call) => ToolCallData(
              callId: call.callId,
              name: call.name,
              input: call.input,
            ),
          )
          .toList();

      // ── Persist (tool_call + tool_results in one transaction) ──
      // The two writes used to be sequential `_store.addMessage`
      // calls; closing the terminal between them left the
      // `tool_call` row stranded without its results, and every
      // subsequent replay would be rejected by strict providers
      // (e.g. MiniMax "tool call result does not follow tool
      // call"). [addToolRound] wraps both writes in a SQLite
      // transaction so the persist step is all-or-nothing.
      await _store.addToolRound(
        sessionId,
        roundText: roundText,
        reasoningContent: roundReasoning,
        reasoningSignature: roundReasoningSignature,
        reasoningTokens: roundReasoningTokens,
        thinkingDurationMs:
            (roundReasoning.isNotEmpty || roundReasoningTokens > 0)
            ? roundThinkingDurationMs.round()
            : 0,
        reasoningEffort: runtime.thinkingMode == 'disabled'
            ? null
            : runtime.reasoningEffort ?? 'normal',
        toolCalls: toolCallData,
        preCompressTokens: preCompressTokens > 0 ? preCompressTokens : null,
        results: [
          for (final call in toolCalls)
            (callId: call.callId, output: callResults[call.callId]!.output),
        ],
      );

      roundTextBuffer.clear();
      roundReasoningBuffer.clear();
      onToolRound?.call(roundResultTokens);

      // After the tool round completes, check if the user queued
      // any messages while the agent was streaming. If so, inject
      // the drained content as a user message into both the API
      // message list and the store so the next LLM round sees it.
      final queuedContent = onQueueDrain?.call();
      if (queuedContent != null) {
        await _store.addMessage(
          sessionId,
          role: 'user',
          content: queuedContent,
        );
        apiMessages.add({'role': 'user', 'content': queuedContent});
      }
    }

    final content = roundTextBuffer.toString();
    final reasoningContent = roundReasoningBuffer.toString();
    final reasoningSignature = roundReasoningSignatureBuffer.toString();
    final cost = _estimateCost(
      provider,
      modelId,
      promptTokens,
      completionTokens,
      promptCacheHitTokens: promptCacheHitTokens,
    );

    final thinkingMs = (reasoningContent.isNotEmpty || reasoningTokens > 0)
        ? roundThinkingDurationMs.round()
        : 0;

    await _store.addMessage(
      sessionId,
      role: 'ai',
      content: content,
      reasoningContent: reasoningContent,
      reasoningSignature: reasoningSignature,
      reasoningTokens: reasoningTokens,
      thinkingDurationMs: thinkingMs,
      reasoningEffort: runtime.thinkingMode == 'disabled'
          ? null
          : runtime.reasoningEffort ?? 'normal',
      model: compositeKey,
      cost: cost,
      tokensIn: promptTokens,
      tokensOut: completionTokens,
    );

    await _store.update(
      sessionId,
      status: SessionStatus.done,
      cost: session.cost + cost,
      tokensIn: session.tokensIn + promptTokens,
      tokensOut: session.tokensOut + completionTokens,
      contextTokens: promptTokens + completionTokens - reasoningTokens,
      ttftMs: session.ttftMs > 0 ? session.ttftMs : runtime.ttftMs,
      tokPerSec: runtime.tokPerSec,
      promptCacheHitTokens: session.promptCacheHitTokens + promptCacheHitTokens,
    );

    session.status = SessionStatus.done;
    session.cost += cost;
    session.tokensIn += promptTokens;
    session.tokensOut += completionTokens;
    session.contextTokens = promptTokens + completionTokens - reasoningTokens;
    if (session.ttftMs <= 0 && runtime.ttftMs > 0) {
      session.ttftMs = runtime.ttftMs;
    }
    session.tokPerSec = runtime.tokPerSec;
    session.promptCacheHitTokens += promptCacheHitTokens;
    session.updatedAt = DateTime.now();

    runtime.isResponding = false;
    _activeSessions.remove(sessionId);
    _cancelRequested.remove(sessionId);

    if (stepLimitReached) {
      // Soft signal to the user (toast in the UI) that the agent loop
      // stopped because of the per-turn step cap (configured in the
      // provider's TOML: `default_max_rounds` or per-model `max_rounds`).
      // The session is left in `done` state with whatever text + tool
      // history was generated up to this point, so the user can read
      // it and send another message to continue. This is not an error
      // — it's a safety brake configured by the provider.
      onError(
        'Step limit reached ($maxRounds tool rounds). '
        'Send another message to continue.',
      );
    }

    // After the final response, drain any remaining queued messages.
    // The caller's onComplete handler can use this to start a new
    // turn if the queue had messages.
    final finalQueuedContent = onQueueDrain?.call();

    onComplete(
      ChatResponse(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        promptCacheHitTokens: promptCacheHitTokens,
        promptCacheMissTokens: promptCacheMissTokens,
        queuedMessage: finalQueuedContent,
      ),
    );
  }

  static List<Map<String, dynamic>> buildApiMessages(
    List<Message> history,
    WireFamily wireFamily,
  ) {
    final result = <Map<String, dynamic>>[];

    for (final m in history) {
      switch (m.role) {
        case 'user':
          result.add({'role': 'user', 'content': m.content});
        case 'system':
          result.add({'role': 'system', 'content': m.content});
        case 'ai':
          if (wireFamily == WireFamily.anthropicCompatible &&
              m.reasoningContent.isNotEmpty &&
              m.reasoningSignature.isNotEmpty) {
            result.add({
              'role': 'assistant',
              'content': [
                {
                  'type': 'thinking',
                  'thinking': m.reasoningContent,
                  'signature': m.reasoningSignature,
                },
                if (m.content.isNotEmpty) {'type': 'text', 'text': m.content},
              ],
            });
          } else {
            result.add({
              'role': 'assistant',
              'content': m.content.isEmpty ? null : m.content,
            });
          }
        case 'tool_call':
          if (wireFamily == WireFamily.anthropicCompatible) {
            final content = <Map<String, dynamic>>[];
            if (m.reasoningContent.isNotEmpty &&
                m.reasoningSignature.isNotEmpty) {
              content.add({
                'type': 'thinking',
                'thinking': m.reasoningContent,
                'signature': m.reasoningSignature,
              });
            }
            if (m.content.isNotEmpty) {
              content.add({'type': 'text', 'text': m.content});
            }
            for (final call in m.toolCalls) {
              content.add({
                'type': 'tool_use',
                'id': call.callId,
                'name': call.name,
                'input': call.input,
              });
            }
            result.add({'role': 'assistant', 'content': content});
          } else {
            final toolCalls = m.toolCalls
                .map(
                  (call) => {
                    'id': call.callId,
                    'type': 'function',
                    'function': {
                      'name': call.name,
                      'arguments': jsonEncode(call.input),
                    },
                  },
                )
                .toList();
            result.add({
              'role': 'assistant',
              'content': m.content.isNotEmpty ? m.content : null,
              'tool_calls': toolCalls,
            });
          }
        case 'tool':
          if (wireFamily == WireFamily.anthropicCompatible) {
            final last = result.isNotEmpty ? result.last : null;
            final toolResult = {
              'type': 'tool_result',
              'tool_use_id': m.toolCallId,
              'content': m.content,
            };
            if (last != null &&
                last['role'] == 'user' &&
                last['content'] is List) {
              (last['content'] as List<dynamic>).add(toolResult);
            } else {
              result.add({
                'role': 'user',
                'content': [toolResult],
              });
            }
          } else {
            result.add({
              'role': 'tool',
              'tool_call_id': m.toolCallId,
              'content': m.content,
            });
          }
      }
    }

    return result;
  }

  double _estimateCost(
    ProviderConfig provider,
    String modelId,
    int promptTokens,
    int completionTokens, {
    int promptCacheHitTokens = 0,
  }) {
    final rates = <String, ({double input, double cacheHit, double output})>{
      'deepseek-v4-flash': (
        input: 0.10 / 1_000_000,
        cacheHit: 0.01 / 1_000_000,
        output: 0.40 / 1_000_000,
      ),
      'deepseek-v4-pro': (
        input: 2.0 / 1_000_000,
        cacheHit: 0.20 / 1_000_000,
        output: 8.0 / 1_000_000,
      ),
      'gpt-4o': (
        input: 2.50 / 1_000_000,
        cacheHit: 1.25 / 1_000_000,
        output: 10.0 / 1_000_000,
      ),
      'gpt-4.1': (
        input: 2.0 / 1_000_000,
        cacheHit: 0.50 / 1_000_000,
        output: 8.0 / 1_000_000,
      ),
      'claude-3-5-sonnet': (
        input: 3.0 / 1_000_000,
        cacheHit: 0.30 / 1_000_000,
        output: 15.0 / 1_000_000,
      ),
    };

    final rate = rates[modelId];
    if (rate == null) return 0.0;
    final cacheMissTokens = promptTokens - promptCacheHitTokens;
    return (cacheMissTokens * rate.input) +
        (promptCacheHitTokens * rate.cacheHit) +
        (completionTokens * rate.output);
  }

  /// Argument keys whose values should be excluded from the
  /// per-round token-count estimate for the given tool [name], or
  /// `null` if the tool is unknown or has no offloadable args.
  /// Exposed so the session controller (which computes the base
  /// context from persisted messages) can ask the chat service —
  /// which owns the tool registry — without taking on a direct
  /// registry dependency.
  Set<String>? offloadableArgsForTool(String name) {
    return offloadableArgsFor(_toolExecutor.lookupTool(name));
  }

  void dispose() {
    _cancelRequested.clear();
    _activeSessions.clear();
    _llmClient.dispose();
    _auxiliaryService.dispose();
  }
}
