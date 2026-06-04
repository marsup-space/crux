import 'dart:async';

import '../models/message.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../storage/session_store.dart';
import 'auxiliary_prompts.dart';
import 'llm_client.dart';
import 'provider_service.dart';

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
  final Map<int, StreamSubscription<LlmChunk>> _activeStreams = {};

  ChatService(this._store, this._providerService, this._llmClient);

  bool isStreaming(int sessionId) => _activeStreams.containsKey(sessionId);

  void cancelStream(int sessionId) {
    _activeStreams[sessionId]?.cancel();
    _activeStreams.remove(sessionId);
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
        messages: [
          {'role': 'system', 'content': titleSystemPrompt},
          {'role': 'user', 'content': userMessage.content},
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
      onError(
        'No API key for provider "$providerName". Use /provider to connect.',
      );
      return;
    }

    final history = await _store.getMessages(sessionId);
    final apiMessages = _buildApiMessages(history);

    final buffer = StringBuffer();
    final reasoningBuffer = StringBuffer();
    int promptTokens = 0;
    int completionTokens = 0;
    int promptCacheHitTokens = 0;
    int promptCacheMissTokens = 0;
    int reasoningTokens = 0;

    final stream = _llmClient.streamChat(
      endpointUrl: provider.endpointUrl,
      providerName: providerName,
      providerType: provider.type,
      apiKey: apiKey,
      modelId: modelId,
      messages: apiMessages,
      thinkingMode: runtime.thinkingMode,
      reasoningEffort: runtime.reasoningEffort,
      thinkingBudget: modelConfig?.thinkingBudget,
    );

    bool firstToken = true;
    bool gotFinish = false;
    bool finalized = false;

    Future<void> finalize() async {
      if (finalized) return;
      finalized = true;
      final content = buffer.toString();
      final cost = _estimateCost(
        provider,
        modelId,
        promptTokens,
        completionTokens,
        promptCacheHitTokens: promptCacheHitTokens,
      );

      final thinkingMs = reasoningBuffer.isNotEmpty
          ? runtime.thinkingDurationMs.round()
          : 0;

      await _store.addMessage(
        sessionId,
        role: 'ai',
        content: content,
        reasoningContent: reasoningBuffer.toString(),
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
      _activeStreams.remove(sessionId);

      onComplete(
        ChatResponse(
          promptTokens: promptTokens,
          completionTokens: completionTokens,
          promptCacheHitTokens: promptCacheHitTokens,
          promptCacheMissTokens: promptCacheMissTokens,
        ),
      );
    }

    final sub = stream.listen(
      (chunk) async {
        if (chunk.error != null) {
          runtime.isResponding = false;
          await _store.update(sessionId, status: SessionStatus.idle);
          session.status = SessionStatus.idle;
          onError(chunk.error!);
          return;
        }

        if (chunk.textDelta != null || chunk.reasoningContent != null) {
          if (firstToken) {
            final elapsed =
                DateTime.now()
                    .difference(runtime.responseStartTime!)
                    .inMicroseconds /
                1000.0;
            runtime.ttftMs = elapsed;
            runtime.ttftReceived = true;
            firstToken = false;
          }
          if (chunk.textDelta != null) {
            buffer.write(chunk.textDelta);
            onDelta(chunk.textDelta!);
          }
          if (chunk.reasoningContent != null) {
            reasoningBuffer.write(chunk.reasoningContent);
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

        if (chunk.finishReason != null) {
          gotFinish = true;
        }

        if (gotFinish && promptTokens > 0 && !finalized) {
          await finalize();
        }
      },
      onDone: () async {
        if (gotFinish) {
          await finalize();
        }
        _activeStreams.remove(sessionId);
      },
      onError: (e) async {
        runtime.isResponding = false;
        await _store.update(sessionId, status: SessionStatus.idle);
        session.status = SessionStatus.idle;
        _activeStreams.remove(sessionId);
        onError(e.toString());
      },
      cancelOnError: true,
    );

    _activeStreams[sessionId] = sub;
  }

  List<Map<String, String>> _buildApiMessages(List<Message> history) {
    return history.map((m) {
      final role = m.role == 'ai' ? 'assistant' : m.role;
      return {'role': role, 'content': m.content};
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
    for (final sub in _activeStreams.values) {
      sub.cancel();
    }
    _activeStreams.clear();
    _llmClient.dispose();
  }
}
