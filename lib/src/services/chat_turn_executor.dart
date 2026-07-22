import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';

import '../components/tool_guard_bubble.dart';
import '../lsp/diagnostic.dart';
import '../lsp/protocol.dart';
import '../models/chat_types.dart';
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../storage/session_store.dart';
import '../tools/shell_guard.dart';
import '../tools/shell_risk.dart';
import '../tools/tool_def.dart';
import '../utils/frame_profiler.dart';
import '../utils/partial_json_field_extractor.dart';
import '../utils/sampling.dart';
import '../utils/token_estimate.dart';
import 'auxiliary_service.dart';
import 'install_slug.dart';
import 'llm_client.dart';
import 'llm_error.dart';
import 'prompts/praise_prompts.dart';
import 'prompts/semantic_search_hint.dart';
import 'prompts/system_prompt.dart';
import 'provider_service.dart';
import 'session_lease_manager.dart';
import 'tool_executor.dart';
import 'wire_format.dart';

const String earlyAbortSystemNoteMarker =
    '[Crux system note — tool-call early abort]';

/// Maximum number of automatic retries for retriable LLM errors
/// (rateLimit, overloaded, serverError, timeout, network). The initial
/// attempt counts as try 0, so the total number of attempts is
/// [kMaxLlmRetries] + 1.
const int kMaxLlmRetries = 5;

/// Returns a short, user-facing label describing the error that triggered
/// a retry attempt. Used in the status toast shown between attempts.
String errorLabelForRetry(Object? thrownError, LlmError? streamError) {
  if (streamError != null) {
    switch (streamError.kind) {
      case LlmErrorKind.rateLimit:
        return 'rate limited';
      case LlmErrorKind.overloaded:
        return 'upstream overloaded';
      case LlmErrorKind.serverError:
        return 'server error';
      case LlmErrorKind.timeout:
        return 'timed out';
      case LlmErrorKind.network:
        return 'network error';
      default:
        return 'error';
    }
  }
  if (thrownError != null) {
    if (thrownError is TimeoutException) return 'timed out';
    if (thrownError is SocketException) return 'network error';
    if (thrownError is HandshakeException) return 'TLS error';
    if (thrownError is HttpException) return 'HTTP error';
    return 'error';
  }
  return 'error';
}

/// Runs a single chat turn: streams the LLM response, executes tool
/// calls in parallel, injects hints, and persists the round.
///
/// Extracted from `chat_service.dart` so the agentic loop — the most
/// complex and most-changed part of the chat subsystem — lives in its
/// own file, independent of compaction, wire format, and session
/// management.
class ChatTurnExecutor {
  /// Test hook: when set, this function replaces the production exponential
  /// backoff (`1s, 2s, 4s, 8s, 16s`, capped at 30s) so unit tests can drive
  /// the retry loop without waiting up to 31 seconds. Set to
  /// `(int) => Duration.zero` to skip the wait entirely.
  ///
  /// Always reset to `null` in `tearDown` so a leaked override doesn't
  /// affect other tests in the same process.
  static Duration Function(int attempt)? debugBackoffOverride;

  final SessionStore store;
  final ProviderService providerService;
  final LlmClient llmClient;
  final ToolExecutor toolExecutor;
  final AuxiliaryService auxiliaryService;
  final SessionLeaseManager leaseManager;

  ChatTurnExecutor(
    this.store,
    this.providerService,
    this.llmClient,
    this.toolExecutor,
    this.leaseManager,
  ) : auxiliaryService = AuxiliaryService(providerService, store.messageStore);

  /// Run a single chat turn for [sessionId].
  Future<void> sendMessage({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required void Function(String delta) onDelta,
    required void Function(String reasoning) onReasoning,
    required void Function() onChunk,
    required FutureOr<void> Function(ChatResponse response) onComplete,
    required void Function(LlmError error) onError,
    void Function(String status)? onStatus,
    FutureOr<void> Function(int toolResultTokens)? onToolRound,
    void Function(ToolUseChunk chunk)? onToolUse,
    void Function(List<ToolCallData> toolCalls)? onToolExecutionStart,
    void Function(StreamingGuardAbortEvent event)? onStreamingGuardAbort,
    String? Function()? onQueueDrain,
    void Function(AbortSignal)? onAbortSignal,
    String? userContent,
    List<ImageAttachment> images = const [],
  }) async {
    try {
      await _sendMessageUnsafe(
        sessionId: sessionId,
        session: session,
        runtime: runtime,
        onDelta: onDelta,
        onReasoning: onReasoning,
        onChunk: onChunk,
        onComplete: onComplete,
        onError: onError,
        onStatus: onStatus,
        onToolRound: onToolRound,
        onToolUse: onToolUse,
        onToolExecutionStart: onToolExecutionStart,
        onStreamingGuardAbort: onStreamingGuardAbort,
        onQueueDrain: onQueueDrain,
        onAbortSignal: onAbortSignal,
        userContent: userContent,
        images: images,
      );
    } on SessionLeaseClaimException catch (e) {
      runtime.pauseStreamingTimer();
      runtime.isResponding = false;
      runtime.roundStreaming = false;
      runtime.roundStartTime = null;
      runtime.roundFirstTokenTime = null;
      leaseManager.markSessionInactive(sessionId);
      onError(
        LlmError(
          kind: LlmErrorKind.unknown,
          vendor: LlmVendor.unknown,
          message: e.toString(),
          cause: e,
        ),
      );
    } catch (e) {
      await _recoverFromUnexpectedTurnExit(
        sessionId: sessionId,
        session: session,
        runtime: runtime,
      );
      onError(
        LlmError(
          kind: LlmErrorKind.unknown,
          vendor: LlmVendor.unknown,
          message: 'Unhandled chat service error: $e',
          cause: e,
        ),
      );
    }
  }

  Future<void> _recoverFromUnexpectedTurnExit({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
  }) async {
    runtime.pauseStreamingTimer();
    runtime.isResponding = false;
    runtime.roundStreaming = false;
    runtime.roundStartTime = null;
    runtime.roundFirstTokenTime = null;
    leaseManager.markSessionInactive(sessionId);
    leaseManager.clearCancelRequest(sessionId);

    if (session.status == SessionStatus.running) {
      session.status = SessionStatus.idle;
      session.updatedAt = DateTime.now();
      try {
        final updated = await store.update(
          sessionId,
          status: SessionStatus.idle,
        );
        session.status = updated.status;
        session.updatedAt = updated.updatedAt;
      } catch (_) {}
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // Agentic loop
  // ══════════════════════════════════════════════════════════════════

  Future<void> _sendMessageUnsafe({
    required int sessionId,
    required Session session,
    required SessionRuntimeState runtime,
    required void Function(String delta) onDelta,
    required void Function(String reasoning) onReasoning,
    required void Function() onChunk,
    required FutureOr<void> Function(ChatResponse response) onComplete,
    required void Function(LlmError error) onError,
    void Function(String status)? onStatus,
    FutureOr<void> Function(int toolResultTokens)? onToolRound,
    void Function(ToolUseChunk chunk)? onToolUse,
    void Function(List<ToolCallData> toolCalls)? onToolExecutionStart,
    void Function(StreamingGuardAbortEvent event)? onStreamingGuardAbort,
    String? Function()? onQueueDrain,
    void Function(AbortSignal)? onAbortSignal,
    String? userContent,
    List<ImageAttachment> images = const [],
  }) async {
    await store.messageStore.clearStreamErrorsFor(sessionId);

    final updatedSession = await store.update(
      sessionId,
      status: SessionStatus.running,
    );
    session.status = updatedSession.status;
    session.runningOwnerId = updatedSession.runningOwnerId;
    session.runningHeartbeatAt = updatedSession.runningHeartbeatAt;
    session.updatedAt = updatedSession.updatedAt;

    if (userContent != null) {
      await store.messageStore.addMessage(
        sessionId,
        role: 'user',
        content: userContent,
        images: images,
      );
    }

    runtime.isResponding = true;
    runtime.tokPerSec = 0.0;
    runtime.tokCount = 0.0;

    leaseManager.markSessionActive(
      sessionId,
      heartbeat: store.heartbeatRunningSession,
    );

    final compositeKey = session.model;
    final slashIndex = compositeKey.indexOf('/');
    final providerName = slashIndex > 0
        ? compositeKey.substring(0, slashIndex)
        : '';
    final modelId = slashIndex > 0
        ? compositeKey.substring(slashIndex + 1)
        : compositeKey;

    // Cache the resolved LlmProvider for the orphan-tool auto-repair
    // hook (`providerService.llmProviderByName` is just a config
    // lookup but resolving it once avoids per-attempt overhead). The
    // hook itself only acts when `supportsOrphanToolRepair == true`,
    // so OpenAI-compatible providers (the default) pay nothing.
    final llmProvider = providerService.llmProviderByName(providerName);

    final provider = providerService.providerByName(providerName);
    final apiKey = providerService.getApiKey(providerName);
    final modelConfig = provider?.modelById(modelId);

    if (provider == null || apiKey == null || apiKey.isEmpty) {
      await store.update(sessionId, status: SessionStatus.needUserAction);
      session.status = SessionStatus.needUserAction;
      runtime.isResponding = false;
      leaseManager.markSessionInactive(sessionId);
      // A bare model id (composite key without the "provider/" prefix)
      // parses out to an empty [providerName], which used to produce
      // the useless `No API key for provider ""` message. Resolve the
      // provider that actually serves this model so the error names it
      // and tells the user the exact next step.
      final effectiveProviderName = providerName.isNotEmpty
          ? providerName
          : (_providerServingModel(modelId)?.name ?? '');
      final String authMessage;
      if (effectiveProviderName.isNotEmpty) {
        authMessage =
            'No API key for provider "$effectiveProviderName". '
            'Use /provider $effectiveProviderName to configure an API '
            'key, then try again.';
      } else {
        authMessage =
            'No configured provider serves model "$modelId" '
            '(session model "$compositeKey" has no provider prefix). '
            'Use /provider to configure a provider and API key, then '
            'try again.';
      }
      onError(
        LlmError(
          kind: LlmErrorKind.auth,
          vendor: LlmVendorX.fromProviderName(effectiveProviderName),
          message: authMessage,
          providerName: effectiveProviderName,
        ),
      );
      return;
    }

    String? systemPrompt = session.systemPrompt;
    if (systemPrompt == null || systemPrompt.isEmpty) {
      if (modelConfig == null) {
        systemPrompt = null;
      } else {
        systemPrompt = buildSystemPrompt(
          provider: provider,
          model: modelConfig,
          cwd: session.projectPath,
          worktree: session.projectPath,
          sessionStarted: session.createdAt,
        );
        session.systemPrompt = systemPrompt;
        await store.update(sessionId, systemPrompt: systemPrompt);
      }
    }

    final history = await store.messageStore.getMessages(sessionId);
    final wireFamily = provider.wireFamily;
    final apiMessages = buildApiMessages(
      history,
      wireFamily,
      systemPrompt: systemPrompt,
    );
    final toolDefs = toolExecutor.getApiToolDefinitions();

    final roundTextBuffer = StringBuffer();
    final roundReasoningBuffer = StringBuffer();
    final roundReasoningSignatureBuffer = StringBuffer();

    // -- Repetition (doom loop) detection --------------------------------
    // Tracks sentence hashes across rounds. When the same sequence of
    // `cycleLen` sentences repeats `threshold` times consecutively,
    // we flag a doom loop and cancel the stream.
    final repSentences = <int>[];
    final repBuffer = StringBuffer();
    const repCycleLen = 9;
    const repThreshold = 3;
    int repMatchStreak = 0;
    bool repDetected = false;

    int findSentenceEnd(String s) {
      for (int i = 0; i < s.length; i++) {
        final c = s.codeUnitAt(i);
        // . ! ? 。
        if (c == 46 || c == 33 || c == 63 || c == 12290) {
          // Must be followed by whitespace or end of string
          if (i + 1 >= s.length || s.codeUnitAt(i + 1) <= 32) {
            return i + 1;
          }
        }
      }
      return -1;
    }

    bool listEquals(List<int> a, List<int> b) {
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    void checkRepetition(String text) {
      repBuffer.write(text);
      // Extract complete sentences (ending with . ! ? 。)
      while (true) {
        final s = repBuffer.toString();
        final endIdx = findSentenceEnd(s);
        if (endIdx < 0) break;
        final sent = s.substring(0, endIdx).trim();
        repBuffer.clear();
        if (endIdx < s.length) {
          repBuffer.write(s.substring(endIdx));
        }
        if (sent.length <= 5) continue;
        repSentences.add(sent.hashCode);
        if (repSentences.length >= repCycleLen * 2) {
          final len = repSentences.length;
          final recent = repSentences.sublist(len - repCycleLen);
          final previous = repSentences.sublist(
            len - repCycleLen * 2,
            len - repCycleLen,
          );
          if (listEquals(recent, previous)) {
            repMatchStreak++;
            if (repMatchStreak >= repThreshold) {
              repDetected = true;
            }
          } else {
            repMatchStreak = 0;
          }
        }
      }
    }

    int promptTokens = 0;
    int completionTokens = 0;
    int promptCacheHitTokens = 0;
    int promptCacheMissTokens = 0;
    int reasoningTokens = 0;

    int roundReasoningTokens = 0;
    double roundThinkingDurationMs = 0;
    DateTime? roundFirstContentTime;
    DateTime? roundFirstDeltaTime;
    DateTime? roundFirstReasoningTime;
    DateTime? roundLastReasoningTime;
    DateTime? roundLastDeltaTime;

    var firstTokenEver = true;

    void stopActiveRound({bool accumulate = false}) {
      if (accumulate &&
          runtime.roundStreaming &&
          runtime.roundFirstTokenTime != null) {
        runtime.cumulativeGenMs +=
            DateTime.now()
                .difference(runtime.roundFirstTokenTime!)
                .inMicroseconds /
            1000.0;
      }
      runtime.roundStreaming = false;
      runtime.roundStartTime = null;
      runtime.roundFirstTokenTime = null;
    }

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

      if (leaseManager.isCancelRequested(sessionId)) {
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        leaseManager.markSessionInactive(sessionId);
        leaseManager.clearCancelRequest(sessionId);
        return;
      }

      LlmError? streamError;
      Object? thrownError;

      // Track whether this round already triggered the orphan-tool
      // auto-repair, so a second 2013 after the repair surfaces
      // normally (the user gets the existing ▶ retry button) instead
      // of looping us into another repair. Resets at the top of
      // each round so a multi-round turn can repair fresh rounds if
      // a totally-different round also breaks.
      var orphanToolRepairAttempted = false;

      // One-shot sentinel for the orphan-repair branch: when set at
      // the bottom of the previous iteration, the next iteration
      // starts at attempt 0 (the `attempt = -1` trick skips the
      // backoff block) AND clears the residual error state so the
      // bottom-of-loop success check on the rebuilt request behaves
      // correctly. The standard `streamError = null; thrownError =
      // null;` reset inside `if (attempt > 0)` doesn't fire at
      // attempt = 0, so this sentinel is the only path that
      // re-clears on the post-repair iteration.
      var orphanToolRepairJustFired = false;

      // Declared outside the retry loop so they remain in scope for
      // the post-stream processing that follows.
      final chunks = <LlmChunk>[];
      _PendingStreamingGuardAbort? pendingGuardAbort;
      SchedulerHandle? lerpTimer;
      String lerpPendingText = '';
      String lerpPendingReasoning = '';
      var lerpStreamDone = false;
      Completer<void>? lerpDrainCompleter;
      final useLerp = modelConfig.streamLerp;

      for (var attempt = 0; attempt <= kMaxLlmRetries; attempt++) {
        if (attempt > 0) {
          // Production backoff: 1s, 2s, 4s, 8s, 16s (capped at 30s).
          // Tests can set `debugBackoffOverride` to skip the wait entirely.
          final backoff =
              ChatTurnExecutor.debugBackoffOverride?.call(attempt) ??
              Duration(
                milliseconds: (1000 * (1 << (attempt - 1))).clamp(1000, 30000),
              );
          onStatus?.call(
            'Retrying ($attempt/$kMaxLlmRetries) after '
            '${errorLabelForRetry(thrownError, streamError)} — '
            'waiting ${backoff.inMilliseconds}ms...',
          );
          await Future.delayed(backoff);
          if (leaseManager.isCancelRequested(sessionId)) {
            runtime.pauseStreamingTimer();
            stopActiveRound();
            runtime.isResponding = false;
            await store.update(sessionId, status: SessionStatus.idle);
            session.status = SessionStatus.idle;
            leaseManager.markSessionInactive(sessionId);
            leaseManager.clearCancelRequest(sessionId);
            return;
          }
          streamError = null;
          thrownError = null;
        }
        // On the orphan-tool auto-repair path the previous
        // iteration landed here on `attempt = -1` (so post-step
        // would put us back at 0 with no backoff). The standard
        // attempt-N clear above didn't run — re-run it now so the
        // bottom-of-loop success check (`streamError == null &&
        // thrownError == null`) recognises a clean attempt as
        // clean. Only fires when the previous iteration was the
        // orphan-tool repair branch, since the regular retriable
        // path lands at attempt > 0 and clears via the block
        // above.
        if (orphanToolRepairJustFired) {
          orphanToolRepairJustFired = false;
          streamError = null;
          thrownError = null;
        }

        runtime.startStreamingTimer();
        runtime.roundStartTime = DateTime.now();
        runtime.roundStreaming = true;
        runtime.roundFirstTokenTime = null;

        roundReasoningTokens = 0;
        roundReasoningSignatureBuffer.clear();
        roundThinkingDurationMs = 0;
        roundFirstContentTime = null;
        roundFirstDeltaTime = null;
        roundFirstReasoningTime = null;
        roundLastReasoningTime = null;
        roundLastDeltaTime = null;

        final streamCancelToken = LlmStreamCancelToken();
        final streamingGuard = _StreamingGuardAccumulator();

        final stream = llmClient.streamChat(
          endpointUrl: provider.endpointUrl,
          config: provider,
          apiKey: apiKey,
          modelId: modelId,
          messages: List<Map<String, dynamic>>.from(apiMessages),
          thinkingMode: runtime.thinkingMode,
          reasoningEffort: runtime.reasoningEffort,
          thinkingBudget: modelConfig.thinkingBudget,
          maxTokens: modelConfig.maxTokens,
          // Per-session `/temperature` override wins over the
          // model's TOML default. Null means "no override" — the
          // pre-existing behavior, preserved exactly so existing
          // installs without the override column don't change.
          temperature: runtime.temperatureOverride ?? modelConfig.temperature,
          // Nucleus ceiling is derived from the effective temperature
          // via `topPForTemperature` so the two sampling knobs move
          // together (a higher temperature gets a narrower nucleus —
          // see the helper's doc for the rationale and limits).
          topP: topPForTemperature(
            runtime.temperatureOverride ?? modelConfig.temperature,
          ),
          tools: toolDefs.isNotEmpty ? toolDefs : null,
          userId: '${InstallSlug.slug}-$sessionId',
          cancelToken: streamCancelToken,
        );

        chunks.clear();
        pendingGuardAbort = null;
        lerpTimer?.cancel();
        lerpTimer = null;
        lerpPendingText = '';
        lerpPendingReasoning = '';
        lerpStreamDone = false;
        lerpDrainCompleter = null;

        const double lerpBaselineMs = 16.0;
        double lerpAccumulatedBudgetMs = 0.0;

        try {
          void ensureLerpTimer() {
            if (lerpTimer != null) return;
            lerpTimer = NoctermScheduler.instance.every(
              const Duration(milliseconds: 16),
              (tick) {
                FrameProfiler.instance.markTimer('lerp');
                if (leaseManager.isCancelRequested(sessionId)) {
                  lerpTimer?.cancel();
                  lerpTimer = null;
                  if (lerpDrainCompleter != null &&
                      !lerpDrainCompleter.isCompleted) {
                    lerpDrainCompleter.complete();
                  }
                  return;
                }

                final totalPending =
                    lerpPendingText.length + lerpPendingReasoning.length;
                if (totalPending == 0) {
                  if (lerpStreamDone &&
                      lerpDrainCompleter != null &&
                      !lerpDrainCompleter.isCompleted) {
                    lerpDrainCompleter.complete();
                  }
                  return;
                }

                final deltaMs = tick.delta == Duration.zero
                    ? lerpBaselineMs
                    : tick.delta.inMicroseconds / 1000.0;
                if (deltaMs > lerpBaselineMs) {
                  lerpAccumulatedBudgetMs += deltaMs - lerpBaselineMs;
                }
                final extraFromBudget =
                    (lerpAccumulatedBudgetMs / lerpBaselineMs).floor();
                lerpAccumulatedBudgetMs -= extraFromBudget * lerpBaselineMs;

                final alpha = lerpStreamDone ? 0.03 : 0.016;
                final baselineMin = lerpStreamDone ? 2 : 1;
                final floodCount = (totalPending * alpha).ceil();

                final minCount = baselineMin + extraFromBudget;
                final count = (minCount > floodCount ? minCount : floodCount)
                    .clamp(1, totalPending);

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
              },
              name: 'streamLerp',
              owner: this,
              priority: SchedulePriority.animation,
            );
          }

          await for (final chunk in stream) {
            if (leaseManager.isCancelRequested(sessionId)) {
              lerpTimer?.cancel();
              break;
            }

            if (chunk.error != null) {
              lerpTimer?.cancel();
              if (chunk.error!.isRetriable && attempt < kMaxLlmRetries) {
                streamError = chunk.error!;
                break;
              }

              // ── Orphan tool history auto-repair + retry ─────────
              //
              // Only on Anthropic-compatible providers
              // (`supportsOrphanToolRepair == true`); OpenAI /
              // DeepSeek have their own per-request sanitizer
              // handling a different orphan-tool case, and they
              // don't reach this hook. Only fires once per round
              // (the `!orphanToolRepairAttempted` guard) so a
              // second 2013 after the repair falls through to
              // the existing non-retriable path — the user gets
              // the standard ▶ retry button, no loop.
              //
              // Sets `streamError` so the bottom-of-loop success
              // check (`streamError == null && thrownError ==
              // null`) does NOT fire immediately after the
              // `break` — we want another iteration of the for
              // (the rebuild) before the check is allowed to
              // exit the loop. The next iteration lands at
              // attempt 0 via `attempt = -1`, so the standard
              // `if (attempt > 0)` clear doesn't run; the
              // `orphanToolRepairJustFired` sentinel clears
              // them at iter start instead, so a successful
              // rebuilt request does exit the loop normally.
              if (chunk.error!.isOrphanToolUseError &&
                  llmProvider?.supportsOrphanToolRepair == true &&
                  !orphanToolRepairAttempted) {
                onStatus?.call(
                  'Detected orphan tool rows from a previous round — '
                  'repairing and retrying…',
                );
                await store.messageStore.repairOrphanToolRows(sessionId);
                orphanToolRepairAttempted = true;
                orphanToolRepairJustFired = true;
                streamError = chunk.error!;
                // Reset `attempt` to -1 so the post-increment at
                // the end of this iteration lands on `attempt = 0`
                // — no backoff, just an immediate retry of the
                // rebuilt request. The repair was the side-effect;
                // the rebuild itself goes out clean (the
                // per-request sanitizer in LlmClient still runs
                // and acts as defense-in-depth).
                attempt = -1;
                break;
              }
              runtime.pauseStreamingTimer();
              stopActiveRound();
              runtime.isResponding = false;
              await store.update(sessionId, status: SessionStatus.idle);
              session.status = SessionStatus.idle;
              leaseManager.markSessionInactive(sessionId);
              onError(chunk.error!);
              return;
            }

            if (chunk.guardAbort) {
              lerpTimer?.cancel();
              pendingGuardAbort ??= streamingGuard.pendingAbort;
              break;
            }

            chunks.add(chunk);

            if (chunk.reasoningSignatureDelta != null) {
              roundReasoningSignatureBuffer.write(
                chunk.reasoningSignatureDelta,
              );
            }

            if (chunk.textDelta != null ||
                chunk.reasoningContent != null ||
                chunk.toolUse != null) {
              final now = DateTime.now();
              if (runtime.roundFirstTokenTime == null) {
                runtime.roundFirstTokenTime = now;
                roundFirstDeltaTime = now;
              }
              roundLastDeltaTime = now;
              if (chunk.toolUse != null) {
                final toolUse = chunk.toolUse!;
                if (toolUse.inputDelta.isNotEmpty) {
                  runtime.cumulativeCompletionTokens += estimateTokens(
                    toolUse.inputDelta,
                  );
                }
                onToolUse?.call(toolUse);
                final guardAbort = await streamingGuard.accumulateAndCheck(
                  toolUse,
                  toolExecutor: toolExecutor,
                  workingDirectory: session.projectPath,
                );
                if (guardAbort != null) {
                  pendingGuardAbort = guardAbort;
                  onStreamingGuardAbort?.call(
                    StreamingGuardAbortEvent(
                      index: guardAbort.index,
                      callId: guardAbort.callId,
                      name: guardAbort.name,
                      filePath: guardAbort.filePath,
                      // `_PendingStreamingGuardAbort.reason` is the
                      // canonical source of truth for every abort
                      // kind (`read-before-write`,
                      // `oldString-no-match`, `unknown-tool`); the
                      // event surface and the LlmClient cancel
                      // reason both consume it.
                      reason: guardAbort.reason,
                      abortedInputTokensEstimate:
                          guardAbort.abortedInputTokensEstimate,
                    ),
                  );
                  await streamCancelToken.cancelActiveStream(
                    reason: guardAbort.reason,
                    guardAbort: true,
                  );
                  lerpTimer?.cancel();
                  break;
                }
              }
              if (firstTokenEver &&
                  (chunk.textDelta != null || chunk.reasoningContent != null)) {
                final now = DateTime.now();
                final elapsed =
                    now.difference(runtime.responseStartTime!).inMicroseconds /
                    1000.0;
                runtime.ttftMs = elapsed;
                runtime.ttftReceived = true;
                runtime.firstTokenTime = now;
                firstTokenEver = false;
              }
              if (chunk.textDelta != null) {
                roundTextBuffer.write(chunk.textDelta);
                checkRepetition(chunk.textDelta!);
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
                checkRepetition(chunk.reasoningContent!);
                roundFirstReasoningTime ??= now;
                roundLastReasoningTime = now;
                if (useLerp) {
                  lerpPendingReasoning += chunk.reasoningContent!;
                  ensureLerpTimer();
                } else {
                  onReasoning(chunk.reasoningContent!);
                }
              }
              if (repDetected) {
                lerpTimer?.cancel();
                await streamCancelToken.cancelActiveStream(
                  reason: 'doom_loop',
                  guardAbort: false,
                );
                // Break out of the stream loop. After lerpStreamDone,
                // we'll save the partial message and nudge the LLM.
                break;
              }
              if ((!useLerp &&
                      (chunk.textDelta != null ||
                          chunk.reasoningContent != null)) ||
                  chunk.toolUse != null) {
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

          // Don't `break` the outer for here — a retriable chunk.error
          // or thrown error must let the backoff block at the top of
          // the for-loop run again. The `if (streamError == null &&
          // thrownError == null) break;` below exits the loop only on
          // a clean completion of the attempt.
          lerpStreamDone = true;
        } catch (e) {
          lerpTimer?.cancel();
          final error = classifyThrownError(e, providerName: providerName);
          if (error.isRetriable && attempt < kMaxLlmRetries) {
            thrownError = e;
          } else {
            runtime.pauseStreamingTimer();
            stopActiveRound();
            runtime.isResponding = false;
            await store.update(sessionId, status: SessionStatus.idle);
            session.status = SessionStatus.idle;
            leaseManager.markSessionInactive(sessionId);
            onError(error);
            return;
          }
        }

        if (streamError == null && thrownError == null) {
          break;
        }
      }

      if (streamError != null) {
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        leaseManager.markSessionInactive(sessionId);
        onError(streamError);
        return;
      }

      if (thrownError != null) {
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        leaseManager.markSessionInactive(sessionId);
        onError(classifyThrownError(thrownError, providerName: providerName));
        return;
      }

      if (leaseManager.isCancelRequested(sessionId)) {
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        leaseManager.markSessionInactive(sessionId);
        leaseManager.clearCancelRequest(sessionId);
        return;
      }

      lerpStreamDone = true;

      final roundTextReasoningTokens = estimateTokens(
        roundTextBuffer.toString() + roundReasoningBuffer.toString(),
      );
      if (roundTextReasoningTokens > 0) {
        runtime.cumulativeCompletionTokens += roundTextReasoningTokens;
      }
      stopActiveRound(accumulate: true);

      if (roundFirstReasoningTime != null && roundLastReasoningTime != null) {
        roundThinkingDurationMs =
            roundLastReasoningTime
                .difference(roundFirstReasoningTime)
                .inMicroseconds /
            1000.0;
      } else if (reasoningTokens > 0 && roundFirstDeltaTime != null) {
        final reasoningEnd =
            roundFirstContentTime ?? roundLastDeltaTime ?? DateTime.now();
        roundThinkingDurationMs =
            reasoningEnd.difference(roundFirstDeltaTime).inMicroseconds /
            1000.0;
      }
      roundReasoningTokens = reasoningTokens;

      if (lerpTimer != null) {
        if (lerpPendingText.isEmpty && lerpPendingReasoning.isEmpty) {
          lerpTimer?.cancel();
          lerpTimer = null;
        } else {
          lerpDrainCompleter = Completer<void>();
          await lerpDrainCompleter.future.timeout(
            const Duration(seconds: 10),
            onTimeout: () {},
          );
          lerpTimer?.cancel();
          lerpTimer = null;
        }
      }

      runtime.pauseStreamingTimer();

      final precomputedCallResults = <String, ToolResult>{};
      final List<ToolCall> toolCalls;
      final guardAbort = pendingGuardAbort;
      if (guardAbort != null) {
        toolCalls = _completeToolCallsBeforeIndex(chunks, guardAbort.index);
        // The stub input shape persists "what would have been
        // here" so future replays can distinguish an aborted file
        // guard from an aborted unknown-tool. File guards carry
        // `filePath`; unknown-tool guards carry the bad name and
        // the names of the tools the LLM *could* have used. The
        // `_aborted_*` markers are inert to the model — they're
        // here for humans/compaction, not in the LLM-visible
        // wire (the synthetic ToolResult carries the message).
        final stubInput = guardAbort.isUnknownTool
            ? <String, dynamic>{
                '_aborted_by_unknown_tool': true,
                'requestedName': guardAbort.name,
                'availableTools': guardAbort.availableTools,
              }
            : <String, dynamic>{
                '_aborted_by_guard': guardAbort.reason,
                'filePath': guardAbort.filePath,
              };
        final stubCall = ToolCall(
          callId: guardAbort.callId,
          name: guardAbort.name,
          input: stubInput,
        );
        toolCalls.add(stubCall);
        precomputedCallResults[stubCall.callId] = _buildGuardAbortedToolResult(
          guardAbort,
        );
      } else {
        final finishReason = ToolExecutor.parseFinishReason(chunks);

        if (finishReason != 'tool_use') break;

        if (leaseManager.isCancelRequested(sessionId)) {
          runtime.pauseStreamingTimer();
          stopActiveRound();
          runtime.isResponding = false;
          await store.update(sessionId, status: SessionStatus.idle);
          session.status = SessionStatus.idle;
          leaseManager.markSessionInactive(sessionId);
          leaseManager.clearCancelRequest(sessionId);
          return;
        }

        toolCalls = ToolExecutor.parseToolUseFromChunks(chunks);
      }
      if (toolCalls.isEmpty) {
        // No tool calls. If doom loop was detected, save the partial
        // message, nudge the LLM, and let it retry. Otherwise exit.
        if (repDetected) {
          // Persist the partial AI message so the user sees what was
          // generated before the loop was caught.
          final partialContent = roundTextBuffer.toString();
          final partialReasoning = roundReasoningBuffer.toString();
          final partialSig = roundReasoningSignatureBuffer.toString();
          if (partialContent.isNotEmpty || partialReasoning.isNotEmpty) {
            await store.messageStore.addMessage(
              sessionId,
              role: 'ai',
              content: partialContent,
              reasoningContent: partialReasoning,
              reasoningSignature: partialSig,
              model: compositeKey,
              tokensIn: promptTokens,
              tokensOut: completionTokens,
            );
          }
          // Nudge the LLM to break out of the loop.
          const nudge =
              '[Crux system note — doom loop detected] '
              'Your response became repetitive — you were repeating the '
              'same sentences over and over. Stop this approach entirely. '
              'Take a different tactic, summarize what you know so far, '
              'or ask the user for clarification if you are stuck.';
          await store.messageStore.addMessage(
            sessionId,
            role: 'user',
            content: nudge,
          );
          apiMessages.add({'role': 'user', 'content': nudge});
          // Reset detection state and continue the agentic loop.
          repSentences.clear();
          repBuffer.clear();
          repMatchStreak = 0;
          repDetected = false;
          roundTextBuffer.clear();
          roundReasoningBuffer.clear();
          roundReasoningSignatureBuffer.clear();
          // Do not count this as a tool round — no onToolRound callback.
          continue;
        }
        break;
      }

      final roundText = roundTextBuffer.toString();
      final roundReasoning = roundReasoningBuffer.toString();
      final roundReasoningSignature = roundReasoningSignatureBuffer.toString();

      final llm = providerService.llmProviderByName(providerName);
      final hintEnabled = llm == null
          ? true
          : llm.effectiveHintParallelCallsFor(
              modelOverride: modelConfig.hintParallelCalls,
              providerOverride: provider.hintParallelCalls,
            );
      final hintSingleThreshold = llm == null
          ? 10
          : llm.effectiveHintParallelCallsSingleThresholdFor(
              modelOverride: modelConfig.hintParallelCallsSingleThreshold,
              providerOverride: provider.hintParallelCallsSingleThreshold,
            );

      final assistantMsg = toolExecutor.formatAssistantToolCallsMessage(
        toolCalls,
        roundText,
        wireFamily,
        reasoningContent: roundReasoning,
        reasoningSignature: roundReasoningSignature,
      );
      apiMessages.add(assistantMsg);
      final executingToolCalls = [
        for (final call in toolCalls)
          if (!precomputedCallResults.containsKey(call.callId))
            ToolCallData(
              callId: call.callId,
              name: call.name,
              input: call.input,
            ),
      ];
      if (executingToolCalls.isNotEmpty) {
        onToolExecutionStart?.call(executingToolCalls);
      }
      final callResults = <String, ToolResult>{...precomputedCallResults};
      var roundResultTokens = 0;
      var successfulCalls = 0;
      try {
        final isAnthropic = wireFamily == WireFamily.anthropicCompatible;
        final content = isAnthropic ? <Map<String, dynamic>>[] : null;
        final abortSignalsByCallId = <String, AbortSignal>{};
        for (final call in toolCalls) {
          final abortSignal = AbortSignal(sessionId: sessionId);
          abortSignalsByCallId[call.callId] = abortSignal;
          onAbortSignal?.call(abortSignal);
        }

        final toolResultEntries = await Future.wait([
          for (final call in toolCalls)
            if (!precomputedCallResults.containsKey(call.callId))
              () async {
                final abortSignal = abortSignalsByCallId[call.callId]!;
                if (leaseManager.isCancelRequested(sessionId)) {
                  abortSignal.abort();
                  return MapEntry(
                    call.callId,
                    ToolResult.error('Tool aborted'),
                  );
                }
                final ctx = ToolContext(
                  sessionId: sessionId,
                  messageId: -1,
                  abort: abortSignal,
                  callId: call.callId,
                  workingDirectory: session.projectPath,
                  sessionRuntime: runtime,
                  shellRiskEvaluator: (
                    command, {
                    required intent,
                    required isWindows,
                    required abort,
                  }) async {
                    // `null` from the assessment means the user
                    // aborted mid-evaluation. It maps to `unavailable`
                    // here only because the ToolContext evaluator
                    // contract has no abort verdict — the actual stop
                    // is shell_base's post-evaluation abort gate,
                    // which re-checks ctx.abort before executing.
                    final verdict = await _assessShellRiskWithAbort(
                      command: command,
                      intent: intent,
                      abort: abort,
                    );
                    return verdict ??
                        const ShellRiskVerdict(
                          ShellRiskVerdictKind.unavailable,
                        );
                  },
                  // Progress-monitor evaluator: when an auxiliary
                  // model is configured this makes the shell tools
                  // drop the static timeout and instead watch the
                  // running process, killing it only on a STUCK
                  // verdict. The monitor loop in shell_base builds
                  // the full continuing conversation and passes it
                  // here; the service is transport-only.
                  shellMonitorEvaluator: (messages, {required abort}) {
                    return auxiliaryService.assessShellProgress(
                      messages: messages,
                    );
                  },
                );
                final result = await toolExecutor.executeTool(call, ctx);
                if (_shouldAbortParallelToolSiblings(result)) {
                  for (final sibling in abortSignalsByCallId.entries) {
                    if (sibling.key != call.callId) sibling.value.abort();
                  }
                }
                return MapEntry(call.callId, result);
              }(),
        ]);

        if (leaseManager.isCancelRequested(sessionId)) {
          for (final signal in abortSignalsByCallId.values) {
            signal.abort();
          }
          runtime.pauseStreamingTimer();
          stopActiveRound();
          runtime.isResponding = false;
          await store.update(sessionId, status: SessionStatus.idle);
          session.status = SessionStatus.idle;
          leaseManager.markSessionInactive(sessionId);
          leaseManager.clearCancelRequest(sessionId);
          return;
        }

        for (final entry in toolResultEntries) {
          callResults[entry.key] = entry.value;
        }

        // ── semantic_search preference hint ──────────────────────
        if (!runtime.hasShownsemanticSearchHint ||
            nextSemanticSearchHintThreshold(
                  runtime.contextTargetTokens,
                  runtime.semanticSearchHintLastThreshold,
                ) !=
                null) {
          const hintTriggerTools = <String>{'grep', 'glob'};
          for (final call in toolCalls) {
            if (call.parseError != null) continue;
            final lower = call.name.toLowerCase();
            if (!hintTriggerTools.contains(lower)) continue;
            final result = callResults[call.callId];
            if (result == null) continue;
            if (result.title == 'Error') continue;
            if (result.metadata['guardTriggered'] == true) continue;

            callResults[call.callId] = ToolResult(
              title: result.title,
              output: result.output + renderSemanticSearchHintEmbedded(),
              truncated: result.truncated,
              outputPath: result.outputPath,
              metadata: result.metadata,
            );
            if (!runtime.hasShownsemanticSearchHint) {
              runtime.hasShownsemanticSearchHint = true;
            } else {
              final threshold = nextSemanticSearchHintThreshold(
                runtime.contextTargetTokens,
                runtime.semanticSearchHintLastThreshold,
              );
              if (threshold != null) {
                runtime.semanticSearchHintLastThreshold = threshold;
              }
            }
            break;
          }
        }

        for (final call in toolCalls) {
          final result = callResults[call.callId]!;
          // Same-turn LSP feedback: write/edit collect diagnostics but
          // historically only persistence attached them (the
          // `<crux-lsp>` payload in [_buildToolResultForPersist]), so
          // the model saw the errors its own edit introduced one turn
          // late. Attach a compact, budget-capped error block to the
          // result sent to the API right now. `callResults` itself is
          // left untouched so persistence keeps its original behavior.
          final apiOutput = _outputWithSameTurnLspDiagnostics(
            call,
            result,
            session.projectPath,
          );
          if (isAnthropic) {
            content!.add({
              'type': 'tool_result',
              'tool_use_id': call.callId,
              'content': apiOutput,
            });
          } else {
            apiMessages.add({
              'role': 'tool',
              'tool_call_id': call.callId,
              'content': apiOutput,
            });
          }
          roundResultTokens += estimateToolRoundTripTokens(
            toolName: call.name,
            args: call.input,
            resultOutput: apiOutput,
          );
          if (call.parseError == null &&
              result.title != 'Error' &&
              result.metadata['guardTriggered'] != true) {
            successfulCalls++;
          }
        }

        // ── Shell-tool fallback guard: streak maintenance ────────
        const properToolsForShellGuardReset = <String>{
          'semantic_search',
          'find_similar_code',
          'webfetch',
          'websearch',
          'read',
          'write',
          'edit',
          'grep',
          'glob',
        };
        var hadProperToolSuccess = false;
        for (final call in toolCalls) {
          if (call.parseError != null) continue;
          final lower = call.name.toLowerCase();
          if (!properToolsForShellGuardReset.contains(lower)) continue;
          final result = callResults[call.callId];
          if (result == null) continue;
          if (result.title == 'Error') continue;
          if (result.metadata['guardTriggered'] == true) continue;
          hadProperToolSuccess = true;
          break;
        }
        if (hadProperToolSuccess) {
          runtime.consecutiveShellViolations = 0;
        }

        // ── In-context hint injection ────────────────────────────
        if (successfulCalls == 1) {
          runtime.consecutiveSingleToolCallRounds += 1;
        } else {
          runtime.consecutiveSingleToolCallRounds = 0;
        }

        if (isAnthropic) {
          apiMessages.add({'role': 'user', 'content': content});
        }
        if (guardAbort == null && hintEnabled && successfulCalls >= 2) {
          injectParallelToolCallHintIntoLastTool(
            apiMessages,
            isAnthropic: isAnthropic,
            count: successfulCalls,
          );
        } else if (guardAbort == null &&
            hintEnabled &&
            successfulCalls == 1 &&
            runtime.consecutiveSingleToolCallRounds > 0 &&
            runtime.consecutiveSingleToolCallRounds % hintSingleThreshold ==
                0) {
          final count = runtime.consecutiveSingleToolCallRounds;
          if (singleCallHintSeverityFor(
                count,
                threshold: hintSingleThreshold,
              ) ==
              SingleCallHintSeverity.urgent) {
            injectParallelSingleCallHintAsUserMessage(
              apiMessages,
              isAnthropic: isAnthropic,
              consecutiveCount: count,
              threshold: hintSingleThreshold,
            );
          } else {
            injectParallelSingleCallHintIntoLastTool(
              apiMessages,
              isAnthropic: isAnthropic,
              consecutiveCount: count,
              threshold: hintSingleThreshold,
            );
          }
        }
      } catch (e) {
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        leaseManager.markSessionInactive(sessionId);
        onError(
          LlmError(
            kind: LlmErrorKind.unknown,
            vendor: LlmVendorX.fromProviderName(providerName),
            message: 'Tool execution error: $e',
            cause: e,
            providerName: providerName,
          ),
        );
        return;
      }

      final toolCallData = toolCalls
          .map(
            (call) => ToolCallData(
              callId: call.callId,
              name: call.name,
              input: call.input,
            ),
          )
          .toList();

      // ── Persist (tool_call + tool_results in one transaction) ──
      try {
        await store.messageStore.addToolRound(
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
          results: [
            for (final call in toolCalls)
              _buildToolResultForPersist(
                call.callId,
                callResults[call.callId]!,
              ),
          ],
        );
        for (final call in toolCalls) {
          final result = callResults[call.callId];
          if (result == null) continue;
          final lsp = result.metadata['lsp'];
          if (lsp is! List || lsp.isEmpty) continue;
          final errors = errorDiagnostics(lsp.cast<LspDiagnostic>());
          if (errors.isEmpty) continue;
          final relPath = relativeFilePathFromCall(call, session.projectPath);
          await store.messageStore.addMessage(
            sessionId,
            role: 'lsp_diagnostics',
            content: relPath,
            parallelCount: errors.length,
          );
        }

        for (final call in toolCalls) {
          final result = callResults[call.callId];
          if (result == null) continue;
          final kind = _guardKindFromResult(result);
          if (kind == null) continue;
          final relPath = relativeFilePathFromCall(call, session.projectPath);
          await store.messageStore.addMessage(
            sessionId,
            role: 'tool_guard',
            content: relPath,
            parallelCount: kind.index,
          );
        }

        if (guardAbort == null && hintEnabled && successfulCalls >= 2) {
          await store.messageStore.addMessage(
            sessionId,
            role: 'parallel_praise',
            content: renderParallelPraiseBubbleLabel(successfulCalls),
            parallelCount: successfulCalls,
          );
        }
        if (guardAbort == null &&
            hintEnabled &&
            successfulCalls == 1 &&
            runtime.consecutiveSingleToolCallRounds > 0 &&
            runtime.consecutiveSingleToolCallRounds % hintSingleThreshold ==
                0) {
          await store.messageStore.addMessage(
            sessionId,
            role: 'single_call_reminder',
            content: renderSingleCallReminderBubbleLabel(
              runtime.consecutiveSingleToolCallRounds,
              threshold: hintSingleThreshold,
            ),
            parallelCount: runtime.consecutiveSingleToolCallRounds,
          );
        }

        if (guardAbort == null && hintEnabled) {
          for (final call in toolCalls) {
            final result = callResults[call.callId];
            if (result == null) continue;
            if (result.metadata['shellGuard'] != true) continue;
            final kindName = result.metadata['shellGuardKind'] as String?;
            final severityName =
                result.metadata['shellGuardSeverity'] as String?;
            final streakAfter =
                result.metadata['shellGuardStreakAfter'] as int?;
            if (kindName == null ||
                severityName == null ||
                streakAfter == null) {
              continue;
            }
            final kind = ShellGuardKind.values.firstWhere(
              (k) => k.name == kindName,
              orElse: () => ShellGuardKind.none,
            );
            final severity = ShellGuardSeverity.values.firstWhere(
              (s) => s.name == severityName,
              orElse: () => ShellGuardSeverity.none,
            );
            if (kind == ShellGuardKind.none ||
                severity == ShellGuardSeverity.none) {
              continue;
            }
            final verdict = ShellGuardVerdict(
              kind: kind,
              severity: severity,
              what: '',
              toolName: _shellGuardToolNameForKind(kind),
              example: '',
              command: '',
              streakAfter: streakAfter,
            );
            await store.messageStore.addMessage(
              sessionId,
              role: 'shell_guard',
              content: renderShellGuardBubbleLabel(verdict),
              parallelCount: streakAfter,
            );
          }
        }
      } catch (e) {
        runtime.pauseStreamingTimer();
        stopActiveRound();
        runtime.isResponding = false;
        await store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        leaseManager.markSessionInactive(sessionId);
        onError(
          LlmError(
            kind: LlmErrorKind.unknown,
            vendor: LlmVendorX.fromProviderName(providerName),
            message: 'Persistence error: $e',
            cause: e,
            providerName: providerName,
          ),
        );
        return;
      }

      roundTextBuffer.clear();
      roundReasoningBuffer.clear();
      // Reset repetition detection at round boundary — sentences
      // from prior rounds must not count against the next round.
      repSentences.clear();
      repBuffer.clear();
      repMatchStreak = 0;
      repDetected = false;
      await onToolRound?.call(roundResultTokens);

      final queuedContent = onQueueDrain?.call();
      if (queuedContent != null) {
        await store.messageStore.addMessage(
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

    final thinkingMs = (reasoningContent.isNotEmpty || reasoningTokens > 0)
        ? roundThinkingDurationMs.round()
        : 0;

    await store.messageStore.addMessage(
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
      tokensIn: promptTokens,
      tokensOut: completionTokens,
    );

    await store.update(
      sessionId,
      status: SessionStatus.done,
      tokensIn: session.tokensIn + promptTokens,
      tokensOut: session.tokensOut + completionTokens,
      contextTokens: promptTokens > 0
          ? promptTokens + completionTokens - reasoningTokens
          : session.contextTokens,
      ttftMs: session.ttftMs > 0 ? session.ttftMs : runtime.ttftMs,
      tokPerSec: runtime.tokPerSec,
      promptCacheHitTokens: session.promptCacheHitTokens + promptCacheHitTokens,
    );

    session.status = SessionStatus.done;
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
    leaseManager.markSessionInactive(sessionId);
    leaseManager.clearCancelRequest(sessionId);

    if (stepLimitReached) {
      onError(
        LlmError(
          kind: LlmErrorKind.unknown,
          vendor: LlmVendorX.fromProviderName(providerName),
          message:
              'Step limit reached ($maxRounds tool rounds). '
              'Send another message to continue.',
          providerName: providerName,
        ),
      );
    }

    final finalQueuedContent = onQueueDrain?.call();

    await onComplete(
      ChatResponse(
        promptTokens,
        completionTokens,
        promptCacheHitTokens,
        promptCacheMissTokens,
        finalQueuedContent,
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  // Tool/guard helpers
  // ══════════════════════════════════════════════════════════════════

  /// Find the configured provider that serves [modelId] (first match
  /// in load order). Used to make the no-API-key error actionable when
  /// the session's composite model key is a bare model id with no
  /// "provider/" prefix (e.g. sessions created before composite keys
  /// became mandatory): `providerName` then parses out as `''` and the
  /// error would otherwise read `No API key for provider ""`.
  ProviderConfig? _providerServingModel(String modelId) {
    for (final candidate in providerService.providers()) {
      if (candidate.modelById(modelId) != null) return candidate;
    }
    return null;
  }

  /// Append a compact, error-only LSP diagnostics block to the tool
  /// result sent back to the API on the SAME turn a write/edit ran.
  ///
  /// The full diagnostic list still reaches the model on later turns
  /// via the persisted `<crux-lsp>` payload (see
  /// [_buildToolResultForPersist]); this block closes the same-turn
  /// feedback loop so the model can self-correct immediately, at a
  /// deliberately small token budget ([kSameTurnMaxDiagnostics]
  /// entries, [kSameTurnMaxMessageChars] chars per message). Returns
  /// [result]'s output unchanged when there is nothing error-level
  /// to report (or no LSP metadata at all).
  static String _outputWithSameTurnLspDiagnostics(
    ToolCall call,
    ToolResult result,
    String projectPath,
  ) {
    final lsp = result.metadata['lsp'];
    if (lsp is! List || lsp.isEmpty) return result.output;
    final block = reportDiagnosticsSameTurn(
      relativeFilePathFromCall(call, projectPath),
      lsp.cast<LspDiagnostic>(),
    );
    if (block.isEmpty) return result.output;
    return '${result.output}\n\n$block';
  }

  ({String callId, String output, String meta}) _buildToolResultForPersist(
    String callId,
    ToolResult result,
  ) {
    String? meta;
    final routing = result.metadata['routing'];
    if (routing is String && routing.isNotEmpty) {
      meta = '{"routing":${_jsonString(routing)}}';
    }

    final lsp = result.metadata['lsp'];
    if (lsp is! List || lsp.isEmpty) {
      return (callId: callId, output: result.output, meta: meta ?? '');
    }
    final payload = buildLspPayload(lsp.cast());
    if (payload.isEmpty) {
      return (callId: callId, output: result.output, meta: meta ?? '');
    }
    return (
      callId: callId,
      output: '${result.output}$payload',
      meta: meta ?? '',
    );
  }

  static String _jsonString(String s) {
    return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
  }

  static String _shellGuardToolNameForKind(ShellGuardKind kind) {
    switch (kind) {
      case ShellGuardKind.read:
        return 'read';
      case ShellGuardKind.glob:
        return 'glob';
      case ShellGuardKind.grep:
        return 'grep';
      case ShellGuardKind.semanticSearch:
        return 'semantic_search';
      case ShellGuardKind.none:
        return '';
    }
  }

  static ToolGuardKind? _guardKindFromResult(ToolResult result) {
    final meta = result.metadata;
    if (meta['guardAbortedMidStream'] == true) {
      return ToolGuardKind.streamingAbort;
    }
    if (meta['autoRead'] == true) {
      return ToolGuardKind.autoRead;
    }
    if (meta['guardTriggered'] == true) {
      switch (meta['guardKind']) {
        case 'size_mismatch':
          return ToolGuardKind.sizeMismatch;
        case 'read_before_write':
        default:
          return ToolGuardKind.readBeforeWrite;
      }
    }
    return null;
  }

  static bool _shouldAbortParallelToolSiblings(ToolResult result) {
    return result.title == 'Error' || result.metadata['guardTriggered'] == true;
  }

  /// Layer-2 shell risk evaluation, wired to the auxiliary service
  /// and injected into every tool-call [ToolContext] as
  /// `shellRiskEvaluator`.
  ///
  /// Abort handling uses a poll-race: [AbortSignal] is synchronous
  /// (no listener API), so a short periodic timer watches it and
  /// resolves to `null` if the user interrupts while the aux model
  /// is still thinking. `null` is the interrupt signal — kept
  /// distinct from [ShellRiskVerdictKind.unavailable] so "the user
  /// aborted" is never confused with "the assessment failed" (the
  /// latter is shell_base's fail-open case). The injection point
  /// maps `null` back to `unavailable` only to satisfy the
  /// [ToolContext.shellRiskEvaluator] contract; the command is
  /// actually stopped by shell_base's abort gate, which re-checks
  /// `ctx.abort` after the evaluator returns and before `_run`.
  /// The abandoned assessment finishes in the background — harmless,
  /// it holds no per-call resources beyond the HTTP stream it
  /// already owns, and its result is simply discarded.
  Future<ShellRiskVerdict?> _assessShellRiskWithAbort({
    required String command,
    required String intent,
    required AbortSignal abort,
  }) async {
    final assessment = auxiliaryService.assessShellCommand(
      command: command,
      intent: intent,
    );
    final abortCompleter = Completer<ShellRiskVerdict?>();
    final abortTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (abort.isAborted && !abortCompleter.isCompleted) {
        abortCompleter.complete(null);
      }
    });
    try {
      return await Future.any([assessment, abortCompleter.future]);
    } finally {
      abortTimer.cancel();
    }
  }

  static List<ToolCall> _completeToolCallsBeforeIndex(
    List<LlmChunk> chunks,
    int index,
  ) {
    final priorChunks = [
      for (final chunk in chunks)
        if (chunk.toolUse == null || chunk.toolUse!.index < index) chunk,
    ];
    return ToolExecutor.parseToolUseFromChunks(
      priorChunks,
    ).where((call) => call.parseError == null).toList();
  }

  static ToolResult _buildGuardAbortedToolResult(
    _PendingStreamingGuardAbort pending,
  ) {
    // Two paths share this builder: the existing file-edit/write
    // guards (read-before-write, oldString-no-match) and the new
    // unknown-tool abort (`ask`, stale registration, etc.). The
    // body differs but the *system-note marker* and the
    // `guardAbortedMidStream` metadata flag are identical so the
    // existing display banners and the compaction filters pick
    // both paths up the same way.
    final reason = pending.reason;
    final String title;
    final String body;
    final Map<String, dynamic> metadata;
    if (pending.isUnknownTool) {
      title = 'Tool call aborted: unknown tool';
      final toolList = pending.availableTools.isEmpty
          ? '<no tools registered>'
          : pending.availableTools.join(', ');
      body =
          '[UNKNOWN TOOL] Crux stopped this \'${pending.name}\' tool call '
          'while its arguments were still streaming — no tool named '
          '"${pending.name}" is registered in this Crux session.\n\n'
          'Available tools: $toolList\n\n'
          '$earlyAbortSystemNoteMarker\n'
          'Crux stopped this ${pending.name} tool call while its arguments '
          'were still streaming. The tool was not executed. '
          'Reason: $reason. '
          'Aborted after ~${pending.abortedInputTokensEstimate} generated '
          'tool-argument tokens. '
          'Call one of the tools listed in "Available tools" above '
          'instead of "${pending.name}".';
      metadata = {
        'guardTriggered': true,
        'guardAbortedMidStream': true,
        'guardReason': reason,
        'guardUnknownTool': true,
        'requestedToolName': pending.name,
        'availableTools': pending.availableTools,
        'tokensBeforeAbortEstimate': pending.abortedInputTokensEstimate,
      };
    } else {
      final guard = pending.guard!;
      title = 'Tool call aborted by guard';
      body =
          '${guard.header}\n\n'
          '${guard.content}\n\n'
          '$earlyAbortSystemNoteMarker\n'
          'Crux stopped this ${pending.name} tool call while its arguments '
          'were still streaming. The tool was not executed. '
          'Reason: $reason. '
          'Aborted after ~${pending.abortedInputTokensEstimate} generated '
          'tool-argument tokens. '
          'Use the current file content above to retry with a valid tool call.';
      metadata = {
        'guardTriggered': true,
        'guardAbortedMidStream': true,
        'guardReason': reason,
        'tokensBeforeAbortEstimate': pending.abortedInputTokensEstimate,
      };
    }
    return ToolResult(title: title, output: body, metadata: metadata);
  }

  /// Dispose of the executor and its LLM client.
  void dispose() {
    llmClient.dispose();
    auxiliaryService.dispose();
  }
}

// ════════════════════════════════════════════════════════════════════
// Streaming guard accumulator (inner class)
// ════════════════════════════════════════════════════════════════════

class _PendingStreamingGuardAbort {
  final int index;
  final String callId;
  final String name;

  /// Path the LLM was targeting. Only meaningful for the
  /// `read-before-write` and `oldString-no-match` guards; empty for
  /// the `unknown-tool` abort.
  final String filePath;

  /// File-guard result. Non-null for `read-before-write` and
  /// `oldString-no-match` aborts; null for the `unknown-tool` abort.
  final GuardResult? guard;

  /// Names of tools currently registered in the session, in
  /// registry order. Non-empty only for the `unknown-tool` abort —
  /// surfaced in the synthetic ToolResult so the LLM can pick a
  /// real tool on its retry.
  final List<String> availableTools;

  /// One of `read-before-write`, `oldString-no-match`,
  /// `unknown-tool`. Persisted to `metadata.guardReason` and used
  /// by the display layer to pick the right label / banner.
  final String reason;

  final int abortedInputTokensEstimate;

  const _PendingStreamingGuardAbort({
    required this.index,
    required this.callId,
    required this.name,
    required this.filePath,
    required this.guard,
    required this.availableTools,
    required this.reason,
    required this.abortedInputTokensEstimate,
  });

  /// True when the abort was triggered because the LLM emitted a
  /// tool name that isn't registered (e.g. `ask`). False for the
  /// existing file-edit/write guards.
  bool get isUnknownTool => guard == null;
}

class _StreamingToolAccum {
  String? callId;
  String? name;
  final input = StringBuffer();
  String? filePath;
  String? oldString;
  bool checkedWriteGuard = false;
  bool checkedEditGuard = false;
}

class _StreamingGuardAccumulator {
  final Map<int, _StreamingToolAccum> _byIndex = {};
  int _maxSeenIndex = -1;
  _PendingStreamingGuardAbort? pendingAbort;

  Future<_PendingStreamingGuardAbort?> accumulateAndCheck(
    ToolUseChunk chunk, {
    required ToolExecutor toolExecutor,
    required String workingDirectory,
  }) async {
    final acc = _byIndex.putIfAbsent(chunk.index, _StreamingToolAccum.new);
    if (chunk.callId.isNotEmpty) acc.callId = chunk.callId;
    if (chunk.name.isNotEmpty) acc.name = chunk.name;
    acc.input.write(chunk.inputDelta);
    if (chunk.index > _maxSeenIndex) _maxSeenIndex = chunk.index;

    final toolName = acc.name;

    // Unknown-tool abort: the LLM emitted a tool name the registry
    // doesn't know (e.g. `ask`, `question`, or any tool that was
    // registered earlier in the session but unregistered via
    // `/web-provider` mid-stream). We detect this on the very
    // first chunk that names the tool — the abort fires BEFORE
    // any arguments stream, so we save the full cost of the
    // arguments the LLM was about to generate for a tool that
    // can never run. Mirror the parallel-tool guard behaviour
    // (only the latest-index tool stream triggers abort) so
    // earlier siblings still get persisted normally.
    if (toolName != null &&
        toolExecutor.lookupTool(toolName) == null &&
        chunk.index == _maxSeenIndex) {
      return pendingAbort = _PendingStreamingGuardAbort(
        index: chunk.index,
        callId: acc.callId ?? '',
        name: toolName,
        filePath: '',
        guard: null,
        availableTools: toolExecutor.allToolNames(),
        reason: 'unknown-tool',
        abortedInputTokensEstimate: estimateTokens(acc.input.toString()),
      );
    }

    // Existing file-edit/write guard path. Tools other than write/edit
    // (and not in our `unknown` branch above) have no streaming-time
    // guard from partial JSON, so they pass through uneventfully.
    if (toolName != 'write' && toolName != 'edit') return null;
    if (chunk.index != _maxSeenIndex) return null;

    final partial = acc.input.toString();
    acc.filePath ??= PartialJsonFieldExtractor.extractStringField(
      partial,
      'filePath',
    );
    final filePath = acc.filePath;
    if (filePath == null || filePath.isEmpty) return null;

    if (toolName == 'write') {
      if (acc.checkedWriteGuard) return null;
      acc.checkedWriteGuard = true;
      final guard = await toolExecutor.checkWriteGuard(
        filePath: filePath,
        workingDirectory: workingDirectory,
      );
      if (guard == null) return null;
      return pendingAbort = _PendingStreamingGuardAbort(
        index: chunk.index,
        callId: acc.callId ?? '',
        name: toolName!,
        filePath: filePath,
        guard: guard,
        availableTools: const [],
        reason: guard.reason ?? 'guard',
        abortedInputTokensEstimate: estimateTokens(acc.input.toString()),
      );
    }

    acc.oldString ??= PartialJsonFieldExtractor.extractStringField(
      partial,
      'oldString',
    );
    final oldString = acc.oldString;
    if (oldString == null || oldString.isEmpty) return null;
    if (acc.checkedEditGuard) return null;
    acc.checkedEditGuard = true;
    final guard = await toolExecutor.checkEditGuard(
      filePath: filePath,
      oldString: oldString,
      workingDirectory: workingDirectory,
    );
    if (guard == null) return null;
    return pendingAbort = _PendingStreamingGuardAbort(
      index: chunk.index,
      callId: acc.callId ?? '',
      name: toolName!,
      filePath: filePath,
      guard: guard,
      availableTools: const [],
      reason: guard.reason ?? 'guard',
      abortedInputTokensEstimate: estimateTokens(acc.input.toString()),
    );
  }
}
