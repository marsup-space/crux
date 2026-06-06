import 'dart:async';
import 'dart:convert';

import '../models/message.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../storage/session_store.dart';
import '../tools/tool_def.dart';
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

  /// Maximum number of model→tool→model round-trips allowed in a single
  /// user turn. Prevents an agentic loop from running unbounded if the
  /// model keeps calling tools without producing a final answer. 50 is
  /// generous enough for genuine multi-step tasks (build, refactor, debug)
  /// while still bounding worst-case cost and latency.
  static const int _maxStepsPerTurn = 50;

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

  Future<void> sendMessage({
    required int sessionId,
    required String userContent,
    required Session session,
    required SessionRuntimeState runtime,
    required void Function(String delta) onDelta,
    required void Function(String reasoning) onReasoning,
    required void Function() onChunk,
    required void Function(ChatResponse response) onComplete,
    required void Function(String error) onError,
    void Function()? onToolRound,
  }) async {
    await _store.addMessage(sessionId, role: 'user', content: userContent);

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

    final fullTextBuffer = StringBuffer();
    final fullReasoningBuffer = StringBuffer();
    int promptTokens = 0;
    int completionTokens = 0;
    int promptCacheHitTokens = 0;
    int promptCacheMissTokens = 0;
    int reasoningTokens = 0;

    var firstTokenEver = true;
    var stepCount = 0;
    var stepLimitReached = false;

    while (true) {
      stepCount++;
      if (stepCount > _maxStepsPerTurn) {
        stepLimitReached = true;
        break;
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

      _llmClient.clearToolBlockState();

      runtime.startStreamingTimer();

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
      );

      final chunks = <LlmChunk>[];
      final roundTextBuffer = StringBuffer();
      final roundReasoningBuffer = StringBuffer();

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
                fullTextBuffer.write(emit);
                onDelta(emit);
                remaining -= take;
              }
            }

            if (remaining > 0 && lerpPendingReasoning.isNotEmpty) {
              final take = remaining.clamp(0, lerpPendingReasoning.length);
              if (take > 0) {
                final emit = lerpPendingReasoning.substring(0, take);
                lerpPendingReasoning = lerpPendingReasoning.substring(take);
                fullReasoningBuffer.write(emit);
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

          if (chunk.textDelta != null || chunk.reasoningContent != null) {
            if (firstTokenEver) {
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
                fullTextBuffer.write(chunk.textDelta);
                onDelta(chunk.textDelta!);
              }
            }
            if (chunk.reasoningContent != null) {
              roundReasoningBuffer.write(chunk.reasoningContent);
              if (useLerp) {
                lerpPendingReasoning += chunk.reasoningContent!;
                ensureLerpTimer();
              } else {
                fullReasoningBuffer.write(chunk.reasoningContent);
                onReasoning(chunk.reasoningContent!);
              }
            }
            if (!useLerp) {
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
          await _store.addMessage(
            sessionId,
            role: 'tool',
            content: result.output,
            toolCallId: call.callId,
          );
        }
        apiMessages.add({'role': 'user', 'content': content});
      } else {
        final assistantMsg = _toolExecutor.formatAssistantToolCallsMessage(
          toolCalls,
          roundText,
          wireFamily,
        );
        apiMessages.add(assistantMsg);

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
          await _store.addMessage(
            sessionId,
            role: 'tool',
            content: result.output,
            toolCallId: call.callId,
          );
        }
      }

      roundTextBuffer.clear();
      roundReasoningBuffer.clear();
      onToolRound?.call();
    }

    final content = fullTextBuffer.toString();
    final reasoningContent = fullReasoningBuffer.toString();
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
      // stopped because of the per-turn step cap. The session is left
      // in `done` state with whatever text + tool history was generated
      // up to this point, so the user can read it and send another
      // message to continue. This is not an error — it's a safety brake.
      onError(
        'Step limit reached ($_maxStepsPerTurn tool rounds). '
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
