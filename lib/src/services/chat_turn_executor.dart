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
import '../tools/tool_def.dart';
import '../utils/frame_profiler.dart';
import '../utils/partial_json_field_extractor.dart';
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

    final provider = providerService.providerByName(providerName);
    final apiKey = providerService.getApiKey(providerName);
    final modelConfig = provider?.modelById(modelId);

    if (provider == null || apiKey == null || apiKey.isEmpty) {
      await store.update(sessionId, status: SessionStatus.needUserAction);
      session.status = SessionStatus.needUserAction;
      runtime.isResponding = false;
      leaseManager.markSessionInactive(sessionId);
      onError(
        LlmError(
          kind: LlmErrorKind.auth,
          vendor: LlmVendorX.fromProviderName(providerName),
          message: 'No API key for provider "$providerName". '
              'Use /provider to connect.',
          providerName: providerName,
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
          final backoff = ChatTurnExecutor.debugBackoffOverride?.call(attempt) ??
              Duration(
                milliseconds:
                    (1000 * (1 << (attempt - 1))).clamp(1000, 30000),
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
                    lerpPendingReasoning =
                        lerpPendingReasoning.substring(take);
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
              roundReasoningSignatureBuffer
                  .write(chunk.reasoningSignatureDelta);
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
                      reason: guardAbort.guard.reason ?? 'guard',
                      abortedInputTokensEstimate:
                          guardAbort.abortedInputTokensEstimate,
                    ),
                  );
                  await streamCancelToken.cancelActiveStream(
                    reason: guardAbort.guard.reason ?? 'guard',
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
        final stubCall = ToolCall(
          callId: guardAbort.callId,
          name: guardAbort.name,
          input: {
            '_aborted_by_guard': guardAbort.guard.reason ?? 'guard',
            'filePath': guardAbort.filePath,
          },
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
      if (toolCalls.isEmpty) break;

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
          message: 'Step limit reached ($maxRounds tool rounds). '
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
    return (callId: callId, output: '${result.output}$payload', meta: meta ?? '');
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
    final reason = pending.guard.reason ?? 'guard';
    return ToolResult(
      title: 'Tool call aborted by guard',
      output:
          '${pending.guard.header}\n\n'
          '${pending.guard.content}\n\n'
          '$earlyAbortSystemNoteMarker\n'
          'Crux stopped this ${pending.name} tool call while its arguments '
          'were still streaming. The tool was not executed. Reason: $reason. '
          'Aborted after ~${pending.abortedInputTokensEstimate} generated '
          'tool-argument tokens. '
          'Use the current file content above to retry with a valid tool call.',
      metadata: {
        'guardTriggered': true,
        'guardAbortedMidStream': true,
        'guardReason': reason,
        'tokensBeforeAbortEstimate': pending.abortedInputTokensEstimate,
      },
    );
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
  final String filePath;
  final GuardResult guard;
  final int abortedInputTokensEstimate;

  const _PendingStreamingGuardAbort({
    required this.index,
    required this.callId,
    required this.name,
    required this.filePath,
    required this.guard,
    required this.abortedInputTokensEstimate,
  });
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
      abortedInputTokensEstimate: estimateTokens(acc.input.toString()),
    );
  }
}
