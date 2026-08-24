import 'dart:async';

import '../services/auxiliary_prompts.dart';
import '../services/install_slug.dart';
import '../services/llm_client.dart';
import '../services/llm_error.dart';
import '../services/provider_service.dart';
import '../services/wire_format.dart';
import '../storage/message_store.dart';
import '../utils/run_metrics.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import 'ui/toast.dart';

typedef ShowToastCallback = void Function(String message, {ToastMode mode});

/// Handles `/btw` (side-question) turns.
///
/// Extracted from `ChatTurnOrchestrator` so the BTW code path — which
/// doesn't go through `ChatService.sendMessage` and manages its own
/// LLM stream — lives in its own class.
class BtwTurnHandler {
  final SessionController sessionController;
  final StreamingController streamingController;
  final ProviderService providerService;
  final MessageStore messageStore;
  final ShowToastCallback showToast;
  final void Function() refresh;

  final Map<int, bool> _btwCancelFlags = {};

  BtwTurnHandler({
    required this.sessionController,
    required this.streamingController,
    required this.providerService,
    required this.messageStore,
    required this.showToast,
    required this.refresh,
  });

  Future<void> sendBtwTurn(String prompt) async {
    final sessionId = sessionController.currentSessionId;
    if (sessionId == null) return;
    final rt = sessionController.runtime(sessionId);
    if (rt.isResponding) return;

    final session = sessionController.currentSession;
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
    if (provider == null || apiKey == null || apiKey.isEmpty) {
      // A bare model id (no "provider/" prefix) parses out to an
      // empty providerName, which used to produce the useless
      // `No API key for provider ""` toast. Resolve the provider
      // that actually serves this model so the error names it and
      // gives the exact next step.
      var effectiveName = providerName;
      if (effectiveName.isEmpty) {
        for (final candidate in providerService.providers()) {
          if (candidate.modelById(modelId) != null) {
            effectiveName = candidate.name;
            break;
          }
        }
      }
      showToast(
        effectiveName.isNotEmpty
            ? 'No API key for provider "$effectiveName". '
                  'Use /provider $effectiveName to configure an API key, '
                  'then try again.'
            : 'No configured provider serves model "$modelId". '
                  'Use /provider to configure a provider and API key, '
                  'then try again.',
        mode: ToastMode.error,
      );
      return;
    }

    final history = await messageStore.getMessages(sessionId);
    final wireFamily = provider.wireFamily;
    final apiMessages = <Map<String, dynamic>>[
      ...buildApiMessages(
        history,
        wireFamily,
        systemPrompt: session.systemPrompt,
      ),
    ];
    final priorBtw = sessionController.btwTurnsFor(sessionId);
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

    streamingController.clearStreamingFor(sessionId);
    rt.isResponding = true;
    rt.btwMode = true;
    // Mirror the phase transition into ChatTurnCubit so chat_history
    // sees the btwStreaming render path immediately, not on the next
    // chat-panel _refresh().
    sessionController.mirrorTurnFlags(sessionId);
    rt.responseStartTime = DateTime.now();
    // Anchor the stall clock to the btw start, same as the main
    // turn path — otherwise a stale value from the previous real
    // turn would surface as a bogus "quiet Ns" readout.
    rt.lastChunkTime = rt.responseStartTime;
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
    streamingController.startMetricsTimer(sessionId);
    sessionController.appendPendingBtwTurn(sessionId, prompt);
    refresh();

    final llmClient = LlmClient();
    final buffer = StringBuffer();
    LlmError? streamError;

    int btwTokensIn = 0;
    int btwTokensOut = 0;
    int btwCacheHit = 0;
    int btwCacheMiss = 0;

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
        if (chunk.promptTokens != null) btwTokensIn = chunk.promptTokens!;
        if (chunk.completionTokens != null)
          btwTokensOut = chunk.completionTokens!;
        if (chunk.promptCacheHitTokens != null)
          btwCacheHit = chunk.promptCacheHitTokens!;
        if (chunk.promptCacheMissTokens != null)
          btwCacheMiss = chunk.promptCacheMissTokens!;
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
            if (sessionController.streamingCubit.state
                .streamingContentFor(sessionId)
                .isEmpty) {
              rt.contentStartTime = DateTime.now();
            }
            streamingController.appendStreamingContent(sessionId, deltaText);
            sessionController.updateLastBtwTurnAiText(
              sessionId,
              buffer.toString(),
            );
          }
          if (deltaReasoning != null) {
            streamingController.appendStreamingReasoning(
              sessionId,
              deltaReasoning,
            );
          }
          refresh();
        }
      }
    } catch (e) {
      streamError = classifyThrownError(e, providerName: provider.name);
    } finally {
      llmClient.dispose();
    }

    if (rt.interrupted && !rt.isResponding) {
      RunMetrics.instance.recordBtwUsage(
        tokensIn: btwTokensIn,
        tokensOut: btwTokensOut,
        cacheHit: btwCacheHit,
        cacheMiss: btwCacheMiss,
      );
      return;
    }

    if (rt.roundStreaming && rt.roundFirstTokenTime != null) {
      rt.cumulativeGenMs +=
          DateTime.now().difference(rt.roundFirstTokenTime!).inMicroseconds /
          1000.0;
    }
    rt.roundStreaming = false;
    rt.roundStartTime = null;
    rt.roundFirstTokenTime = null;
    rt.pauseStreamingTimer();
    streamingController.stopMetricsTimer(sessionId);
    rt.isResponding = false;
    rt.btwMode = false;
    // Mirror the btw-end flag reset into ChatTurnCubit so chat_history
    // can switch from btwStreaming render back to normal message render.
    sessionController.mirrorTurnFlags(sessionId);

    if (streamError != null) {
      streamingController.clearStreamingFor(sessionId);
      final turns = sessionController.btwTurnsFor(sessionId);
      if (turns.isNotEmpty && turns.last.aiText.isEmpty) {
        sessionController.clearBtwTurnsFor(sessionId);
        if (turns.length > 1) {
          for (var i = 0; i < turns.length - 1; i++) {
            sessionController.appendPendingBtwTurn(
              sessionId,
              turns[i].userText,
            );
            sessionController.updateLastBtwTurnAiText(
              sessionId,
              turns[i].aiText,
            );
          }
        }
      }
      showToast(streamError.toUserMessage(), mode: ToastMode.error);
      RunMetrics.instance.recordBtwUsage(
        tokensIn: btwTokensIn,
        tokensOut: btwTokensOut,
        cacheHit: btwCacheHit,
        cacheMiss: btwCacheMiss,
      );
      refresh();
      return;
    }

    final responseText = buffer.toString();
    streamingController.clearStreamingFor(sessionId);
    assert(responseText.isNotEmpty || streamError == null);

    final queued = sessionController.drainMessageQueue(sessionId);
    if (queued != null && queued.isNotEmpty) {
      sessionController.clearBtwTurnsFor(sessionId);
      refresh();
      RunMetrics.instance.recordBtwUsage(
        tokensIn: btwTokensIn,
        tokensOut: btwTokensOut,
        cacheHit: btwCacheHit,
        cacheMiss: btwCacheMiss,
      );
      // Hand the captured usage to the run aggregator before kicking off the next turn.
      // The queued turn will be handled by the orchestrator's sendTurn.
      return;
    }

    RunMetrics.instance.recordBtwUsage(
      tokensIn: btwTokensIn,
      tokensOut: btwTokensOut,
      cacheHit: btwCacheHit,
      cacheMiss: btwCacheMiss,
    );
    refresh();
  }

  void cancelBtwTurn(int sessionId) {
    _btwCancelFlags[sessionId] = true;
  }
}
