import 'dart:async';

import '../models/message.dart';
import '../models/provider_config.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../storage/session_store.dart';
import 'llm_client.dart';
import 'provider_service.dart';

class ChatResponse {
  final String content;
  final int promptTokens;
  final int completionTokens;
  final double cost;

  const ChatResponse({
    this.content = '',
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cost = 0.0,
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

  Future<void> sendMessage({
    required int sessionId,
    required String userContent,
    required Session session,
    required SessionRuntimeState runtime,
    required void Function(String delta) onDelta,
    required void Function() onChunk,
    required void Function(ChatResponse response) onComplete,
    required void Function(String error) onError,
  }) async {
    await _store.addMessage(
      sessionId,
      role: 'user',
      content: userContent,
    );

    await _store.update(sessionId, status: SessionStatus.running);
    session.status = SessionStatus.running;
    session.updatedAt = DateTime.now();

    runtime.isResponding = true;
    runtime.tokPerSec = 0.0;
    runtime.tokCount = 0.0;

    final compositeKey = session.model;
    final slashIndex = compositeKey.indexOf('/');
    final providerName = slashIndex > 0 ? compositeKey.substring(0, slashIndex) : '';
    final modelId = slashIndex > 0 ? compositeKey.substring(slashIndex + 1) : compositeKey;

    final provider = _providerService.providerByName(providerName);
    final apiKey = _providerService.getApiKey(providerName);

    if (provider == null || apiKey == null || apiKey.isEmpty) {
      await _store.update(sessionId, status: SessionStatus.needUserAction);
      session.status = SessionStatus.needUserAction;
      runtime.isResponding = false;
      onError('No API key for provider "$providerName". Use /provider to connect.');
      return;
    }

    final history = await _store.getMessages(sessionId);
    final apiMessages = _buildApiMessages(history);

    final buffer = StringBuffer();
    int promptTokens = 0;
    int completionTokens = 0;

    final stream = _llmClient.streamChat(
      endpointUrl: provider.endpointUrl,
      providerType: provider.type,
      apiKey: apiKey,
      modelId: modelId,
      messages: apiMessages,
    );

    bool firstToken = true;
    bool gotFinish = false;
    bool finalized = false;

    Future<void> finalize() async {
      if (finalized) return;
      finalized = true;
      final content = buffer.toString();
      final cost = _estimateCost(provider, modelId, promptTokens, completionTokens);

      await _store.addMessage(
        sessionId,
        role: 'ai',
        content: content,
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
        contextTokens: promptTokens + completionTokens,
      );

      session.status = SessionStatus.done;
      session.cost += cost;
      session.tokensIn += promptTokens;
      session.tokensOut += completionTokens;
      session.contextTokens = promptTokens + completionTokens;
      session.updatedAt = DateTime.now();

      runtime.isResponding = false;
      _activeStreams.remove(sessionId);

      onComplete(ChatResponse(
        content: content,
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        cost: cost,
      ));
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

        if (chunk.textDelta != null) {
          if (firstToken) {
            final elapsed = DateTime.now()
                .difference(runtime.responseStartTime!)
                .inMicroseconds / 1000.0;
            runtime.ttftMs = elapsed;
            runtime.ttftReceived = true;
            firstToken = false;
          }
          buffer.write(chunk.textDelta);
          onDelta(chunk.textDelta!);
          onChunk();
        }

        if (chunk.promptTokens != null) {
          promptTokens = chunk.promptTokens!;
        }
        if (chunk.completionTokens != null) {
          completionTokens = chunk.completionTokens!;
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
    int completionTokens,
  ) {
    final rates = <String, ({double input, double output})>{
      'deepseek-v4-flash': (input: 0.10 / 1_000_000, output: 0.40 / 1_000_000),
      'deepseek-v4-pro': (input: 2.0 / 1_000_000, output: 8.0 / 1_000_000),
      'gpt-4o': (input: 2.50 / 1_000_000, output: 10.0 / 1_000_000),
      'gpt-4.1': (input: 2.0 / 1_000_000, output: 8.0 / 1_000_000),
      'claude-3-5-sonnet': (input: 3.0 / 1_000_000, output: 15.0 / 1_000_000),
    };

    final rate = rates[modelId];
    if (rate == null) return 0.0;
    return (promptTokens * rate.input) + (completionTokens * rate.output);
  }

  void dispose() {
    for (final sub in _activeStreams.values) {
      sub.cancel();
    }
    _activeStreams.clear();
    _llmClient.dispose();
  }
}
