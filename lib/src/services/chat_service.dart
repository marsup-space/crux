import 'dart:async';

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
        providerName: providerName,
        providerType: provider.type,
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
      final title = buffer.toString().trim();
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
    final apiMessages = _buildApiMessages(history);
    final toolDefs = _toolExecutor.getApiToolDefinitions();
    final providerType = provider.type;

    final fullTextBuffer = StringBuffer();
    final fullReasoningBuffer = StringBuffer();
    int promptTokens = 0;
    int completionTokens = 0;
    int promptCacheHitTokens = 0;
    int promptCacheMissTokens = 0;
    int reasoningTokens = 0;

    var firstTokenEver = true;
    const maxRounds = 50;

    for (var round = 0; round < maxRounds; round++) {
      if (_cancelRequested.contains(sessionId)) {
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _activeSessions.remove(sessionId);
        _cancelRequested.remove(sessionId);
        return;
      }

      _llmClient.clearToolBlockState();

      final stream = _llmClient.streamChat(
        endpointUrl: provider.endpointUrl,
        providerName: providerName,
        providerType: providerType,
        apiKey: apiKey,
        modelId: modelId,
        messages: List<Map<String, dynamic>>.from(apiMessages),
        thinkingMode: runtime.thinkingMode,
        reasoningEffort: runtime.reasoningEffort,
        thinkingBudget: modelConfig?.thinkingBudget,
        tools: toolDefs.isNotEmpty ? toolDefs : null,
      );

      final chunks = <LlmChunk>[];
      final roundTextBuffer = StringBuffer();
      final roundReasoningBuffer = StringBuffer();

      try {
        await for (final chunk in stream) {
          if (chunk.error != null) {
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
              final elapsed =
                  DateTime.now()
                      .difference(runtime.responseStartTime!)
                      .inMicroseconds /
                  1000.0;
              runtime.ttftMs = elapsed;
              runtime.ttftReceived = true;
              firstTokenEver = false;
            }
            if (chunk.textDelta != null) {
              roundTextBuffer.write(chunk.textDelta);
              fullTextBuffer.write(chunk.textDelta);
              onDelta(chunk.textDelta!);
            }
            if (chunk.reasoningContent != null) {
              roundReasoningBuffer.write(chunk.reasoningContent);
              fullReasoningBuffer.write(chunk.reasoningContent);
              onReasoning(chunk.reasoningContent!);
            }
            onChunk();
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
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _activeSessions.remove(sessionId);
        onError(e.toString());
        return;
      }

      final finishReason = ToolExecutor.parseFinishReason(chunks);

      if (finishReason != 'tool_use') break;

      final toolCalls = ToolExecutor.parseToolUseFromChunks(chunks);
      if (toolCalls.isEmpty) break;

      apiMessages.add(
        _toolExecutor.formatAssistantToolCallsMessage(
          toolCalls,
          roundTextBuffer.toString(),
          providerType,
        ),
      );

      if (providerType == ProviderType.anthropic) {
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
        }
        apiMessages.add({'role': 'user', 'content': content});
      } else {
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
        }
      }
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
    );

    session.status = SessionStatus.done;
    session.cost += cost;
    session.tokensIn += promptTokens;
    session.tokensOut += completionTokens;
    session.contextTokens = promptTokens + completionTokens - reasoningTokens;
    session.updatedAt = DateTime.now();

    runtime.isResponding = false;
    _activeSessions.remove(sessionId);
    _cancelRequested.remove(sessionId);

    onComplete(
      ChatResponse(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        promptCacheHitTokens: promptCacheHitTokens,
        promptCacheMissTokens: promptCacheMissTokens,
      ),
    );
  }

  List<Map<String, dynamic>> _buildApiMessages(List<Message> history) {
    return history.map((m) {
      final role = m.role == 'ai' ? 'assistant' : m.role;
      return <String, dynamic>{'role': role, 'content': m.content};
    }).toList();
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
