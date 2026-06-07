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
import 'llm_client.dart';
import 'provider_service.dart';
import 'tool_executor.dart';

class ChatResponse {
  final int promptTokens;
  final int completionTokens;
  final int promptCacheHitTokens;
  final int promptCacheMissTokens;

  const ChatResponse({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.promptCacheHitTokens = 0,
    this.promptCacheMissTokens = 0,
  });
}

class ChatService {
  final SessionStore _store;
  final ProviderService _providerService;
  final LlmClient _llmClient;
  final ToolExecutor _toolExecutor;
  final Set<int> _activeSessions = {};
  final Set<int> _cancelRequested = {};

  ChatService(
    this._store,
    this._providerService,
    this._llmClient,
    this._toolExecutor,
  );

  bool isStreaming(int sessionId) => _activeSessions.contains(sessionId);

  void cancelStream(int sessionId) {
    _cancelRequested.add(sessionId);
  }

  Future<String?> generateSessionTitle(int sessionId) async {
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == null || auxKey == 'none') {
      print(
        '[auxiliary] no auxiliary model configured, skipping title generation',
      );
      return null;
    }

    final slashIndex = auxKey.indexOf('/');
    final providerName = slashIndex > 0 ? auxKey.substring(0, slashIndex) : '';
    final modelId = slashIndex > 0 ? auxKey.substring(slashIndex + 1) : auxKey;

    final provider = _providerService.providerByName(providerName);
    final apiKey = _providerService.getApiKey(providerName);
    if (provider == null || apiKey == null || apiKey.isEmpty) return null;

    final messages = await _store.getMessages(sessionId);
    final userMessage = messages.firstWhere(
      (m) => m.role == 'user',
      orElse: () => messages.first,
    );
    if (userMessage.content.trim().isEmpty) return null;

    final client = LlmClient();
    try {
      final stream = client.streamChat(
        endpointUrl: provider.endpointUrl,
        config: provider,
        apiKey: apiKey,
        modelId: modelId,
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': titleSystemPrompt},
          <String, dynamic>{'role': 'user', 'content': userMessage.content},
        ],
        thinkingMode: 'disabled',
        reasoningEffort: null,
      );

      final buffer = StringBuffer();
      String? streamError;
      await for (final chunk in stream) {
        if (chunk.error != null) {
          streamError = chunk.error;
          break;
        }
        if (chunk.textDelta != null) buffer.write(chunk.textDelta);
      }
      if (streamError != null) {
        print('[auxiliary] stream error: $streamError');
        return null;
      }
      final title = buffer.toString().trim().replaceAll(RegExp(r'[\r\n]+'), ' ');
      if (title.isEmpty || title.length > 80) return null;
      print('[auxiliary] generated title: $title');
      return title;
    } catch (e) {
      print('[auxiliary] title generation failed: $e');
      return null;
    } finally {
      client.dispose();
    }
  }

  Future<String?> generateTldr(
    String responseContent, {
    TldrDetail detail = TldrDetail.defaultLevel,
  }) async {
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == null || auxKey == 'none') return null;

    final slashIndex = auxKey.indexOf('/');
    final providerName = slashIndex > 0 ? auxKey.substring(0, slashIndex) : '';
    final modelId = slashIndex > 0 ? auxKey.substring(slashIndex + 1) : auxKey;

    final provider = _providerService.providerByName(providerName);
    final apiKey = _providerService.getApiKey(providerName);
    if (provider == null || apiKey == null || apiKey.isEmpty) return null;

    final client = LlmClient();
    try {
      final stream = client.streamChat(
        endpointUrl: provider.endpointUrl,
        config: provider,
        apiKey: apiKey,
        modelId: modelId,
        messages: <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'system',
            'content': tldrSystemPromptFor(detail),
          },
          <String, dynamic>{'role': 'user', 'content': responseContent},
        ],
        thinkingMode: 'disabled',
        reasoningEffort: null,
      );

      final buffer = StringBuffer();
      String? streamError;
      await for (final chunk in stream) {
        if (chunk.error != null) {
          streamError = chunk.error;
          break;
        }
        if (chunk.textDelta != null) buffer.write(chunk.textDelta);
      }
      if (streamError != null) {
        print('[tldr] stream error: $streamError');
        return null;
      }
      final tldr = buffer.toString().trim();
      if (tldr.isEmpty) return null;
      print('[tldr] generated: ${tldr.length} chars');
      return tldr;
    } catch (e) {
      print('[tldr] generation failed: $e');
      return null;
    } finally {
      client.dispose();
    }
  }

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
    final apiMessages = _buildApiMessages(history, wireFamily);
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
    int promptTokens = 0;
    int completionTokens = 0;
    int promptCacheHitTokens = 0;
    int promptCacheMissTokens = 0;
    int reasoningTokens = 0;

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
        userId: 'crux-session-$sessionId',
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
            final totalPending = lerpPendingText.length + lerpPendingReasoning.length;
            if (totalPending == 0) {
              if (lerpStreamDone && lerpDrainCompleter != null && !lerpDrainCompleter!.isCompleted) {
                lerpDrainCompleter!.complete();
              }
              return;
            }

            final alpha = lerpStreamDone ? 0.03 : 0.016;
            final minCount = lerpStreamDone ? 2 : 1;
            final count = (totalPending * alpha).ceil().clamp(minCount, totalPending);

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
            if (!runtime.roundStreaming) {
              final now = DateTime.now();
              runtime.roundFirstTokenTime = now;
              runtime.roundStreaming = true;
            }
            if (chunk.toolUse != null && chunk.toolUse!.inputDelta.isNotEmpty) {
              runtime.cumulativeCompletionTokens += estimateTokens(
                chunk.toolUse!.inputDelta,
              );
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
              if (useLerp) {
                lerpPendingText += chunk.textDelta!;
                ensureLerpTimer();
              } else {
                onDelta(chunk.textDelta!);
              }
            }
            if (chunk.reasoningContent != null) {
              roundReasoningBuffer.write(chunk.reasoningContent);
              if (useLerp) {
                lerpPendingReasoning += chunk.reasoningContent!;
                ensureLerpTimer();
              } else {
                onReasoning(chunk.reasoningContent!);
              }
            }
            if (!useLerp && (chunk.textDelta != null || chunk.reasoningContent != null)) {
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

      lerpStreamDone = true;

      // Round stream finished. Fold this round's wall-clock generation
      // time into the per-turn cumulative total and clear the
      // round-streaming flag so the metrics timer pauses while tools
      // execute and while we wait for the next LLM response. Done
      // BEFORE the lerp drain so the denominator reflects only the
      // LLM's actual generation time, not the visual lerp animation
      // (up to 10s of post-stream UI smoothing).
      if (runtime.roundStreaming &&
          runtime.roundFirstTokenTime != null) {
        final roundMs = DateTime.now()
                .difference(runtime.roundFirstTokenTime!)
                .inMicroseconds /
            1000.0;
        runtime.cumulativeGenMs += roundMs;
      }
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

      final toolCalls = ToolExecutor.parseToolUseFromChunks(chunks);
      if (toolCalls.isEmpty) break;

      final roundText = roundTextBuffer.toString();
      final roundReasoning = roundReasoningBuffer.toString();

      final toolCallData = toolCalls
          .map(
            (call) => ToolCallData(
              callId: call.callId,
              name: call.name,
              input: call.input,
            ),
          )
          .toList();

      await _store.addMessage(
        sessionId,
        role: 'tool_call',
        content: roundText,
        reasoningContent: roundReasoning,
        toolCalls: toolCallData,
      );

      if (wireFamily == WireFamily.anthropicCompatible) {
        final assistantMsg = _toolExecutor.formatAssistantToolCallsMessage(
          toolCalls,
          roundText,
          wireFamily,
        );
        apiMessages.add(assistantMsg);

        final content = <Map<String, dynamic>>[];
        var roundResultTokens = 0;
        for (final call in toolCalls) {
          final ctx = ToolContext(
            sessionId: sessionId,
            messageId: -1,
            abort: AbortSignal(),
            workingDirectory: session.projectPath,
          );
          final result = await _toolExecutor.executeTool(call, ctx);
          content.add({
            'type': 'tool_result',
            'tool_use_id': call.callId,
            'content': result.output,
          });
          roundResultTokens += estimateToolRoundTripTokens(
            toolName: call.name,
            args: call.input,
            resultOutput: result.output,
            excludeArgsFromEstimate: largePayloadTools.contains(call.name)
                ? largePayloadExcludedArgs[call.name]
                : null,
          );
          await _store.addMessage(
            sessionId,
            role: 'tool',
            content: result.output,
            toolCallId: call.callId,
          );
        }
        apiMessages.add({'role': 'user', 'content': content});
        roundTextBuffer.clear();
        roundReasoningBuffer.clear();
        onToolRound?.call(roundResultTokens);
      } else {
        final assistantMsg = _toolExecutor.formatAssistantToolCallsMessage(
          toolCalls,
          roundText,
          wireFamily,
        );
        apiMessages.add(assistantMsg);

        var roundResultTokens = 0;
        for (final call in toolCalls) {
          final ctx = ToolContext(
            sessionId: sessionId,
            messageId: -1,
            abort: AbortSignal(),
            workingDirectory: session.projectPath,
          );
          final result = await _toolExecutor.executeTool(call, ctx);
          apiMessages.add({
            'role': 'tool',
            'tool_call_id': call.callId,
            'content': result.output,
          });
          roundResultTokens += estimateToolRoundTripTokens(
            toolName: call.name,
            args: call.input,
            resultOutput: result.output,
            excludeArgsFromEstimate: largePayloadTools.contains(call.name)
                ? largePayloadExcludedArgs[call.name]
                : null,
          );
          await _store.addMessage(
            sessionId,
            role: 'tool',
            content: result.output,
            toolCallId: call.callId,
          );
        }
        roundTextBuffer.clear();
        roundReasoningBuffer.clear();
        onToolRound?.call(roundResultTokens);
      }
    }

    final content = roundTextBuffer.toString();
    final reasoningContent = roundReasoningBuffer.toString();
    final cost = _estimateCost(
      provider,
      modelId,
      promptTokens,
      completionTokens,
      promptCacheHitTokens: promptCacheHitTokens,
    );

    final thinkingMs = reasoningContent.isNotEmpty
        ? runtime.thinkingDurationMs.round()
        : 0;

    await _store.addMessage(
      sessionId,
      role: 'ai',
      content: content,
      reasoningContent: reasoningContent,
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
      promptCacheHitTokens:
          session.promptCacheHitTokens + promptCacheHitTokens,
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

    onComplete(
      ChatResponse(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        promptCacheHitTokens: promptCacheHitTokens,
        promptCacheMissTokens: promptCacheMissTokens,
      ),
    );
  }

  List<Map<String, dynamic>> _buildApiMessages(
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
          result.add({
            'role': 'assistant',
            'content': m.content.isEmpty ? null : m.content,
          });
        case 'tool_call':
          if (wireFamily == WireFamily.anthropicCompatible) {
            final content = <Map<String, dynamic>>[];
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

  void dispose() {
    _cancelRequested.clear();
    _activeSessions.clear();
    _llmClient.dispose();
  }
}
