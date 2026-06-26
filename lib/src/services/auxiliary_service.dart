import '../models/provider_config.dart';
import '../storage/message_store.dart';
import 'auxiliary_prompts.dart';
import 'llm_client.dart';
import 'llm_error.dart';
import 'provider_service.dart';

/// Lightweight LLM calls that use the auxiliary model (title generation,
/// TLDR summarization). Runs on a single long-lived [LlmClient] instead
/// of creating and disposing one per call — avoids the overhead of a
/// fresh `HttpClient` per auxiliary request.
class AuxiliaryService {
  final ProviderService _providerService;
  final MessageStore _messageStore;
  final LlmClient _client = LlmClient();

  AuxiliaryService(this._providerService, this._messageStore);

  /// Resolve the auxiliary model's provider, api key, and model id.
  /// Returns null if no auxiliary model is configured or if the
  /// provider/key is missing.
  _AuxModel? _resolve() {
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == null || auxKey == 'none') return null;

    final slashIndex = auxKey.indexOf('/');
    final providerName =
        slashIndex > 0 ? auxKey.substring(0, slashIndex) : '';
    final modelId =
        slashIndex > 0 ? auxKey.substring(slashIndex + 1) : auxKey;

    final provider = _providerService.providerByName(providerName);
    final apiKey = _providerService.getApiKey(providerName);
    if (provider == null || apiKey == null || apiKey.isEmpty) return null;

    return _AuxModel(
      provider: provider,
      apiKey: apiKey,
      modelId: modelId,
    );
  }

  /// Stream a single-shot auxiliary call (no tools, no thinking).
  /// Collects the full text response and returns it, or null on
  /// error / empty / too long.
  ///
  /// By default builds a two-message `[system, user]` exchange
  /// from [systemPrompt] + [userMessage]. When [messages] is
  /// provided it is used verbatim instead — callers that need a
  /// richer conversation shape (e.g. TLDR, which passes the
  /// user question + assistant response as a Q→A pair) pass
  /// the full list and we skip the default builder. In that
  /// mode [systemPrompt] is unused.
  Future<String?> _streamAuxiliaryCall({
    required String systemPrompt,
    String? userMessage,
    List<Map<String, dynamic>>? messages,
    required String logTag,
    int? maxLength,
  }) async {
    final aux = _resolve();
    if (aux == null) return null;

    final effectiveMessages = messages ??
        <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': systemPrompt},
          if (userMessage != null && userMessage.isNotEmpty)
            <String, dynamic>{'role': 'user', 'content': userMessage},
        ];

    try {
      final stream = _client.streamChat(
        endpointUrl: aux.provider.endpointUrl,
        config: aux.provider,
        apiKey: aux.apiKey,
        modelId: aux.modelId,
        messages: effectiveMessages,
        thinkingMode: 'disabled',
        reasoningEffort: null,
      );

      final buffer = StringBuffer();
      LlmError? streamError;
      await for (final chunk in stream) {
        if (chunk.error != null) {
          streamError = chunk.error;
          break;
        }
        if (chunk.textDelta != null) buffer.write(chunk.textDelta);
      }
      if (streamError != null) {
        // Auxiliary calls are background work (title generation, TLDR)
        // — we don't surface errors as a persistent bubble, only log
        // the structured error so debugging has the kind/code/context.
        print('[$logTag] ${streamError.kind.name}'
            '${streamError.vendorCode != null ? "(${streamError.vendorCode})" : ""}'
            ': ${streamError.toUserMessage()}');
        return null;
      }
      final result = buffer.toString().trim();
      if (result.isEmpty) return null;
      if (maxLength != null && result.length > maxLength) return null;
      return result;
    } catch (e) {
      print('[$logTag] generation failed: $e');
      return null;
    }
  }

  Future<String?> generateTitle(
    int sessionId, {
    String? userContent,
  }) async {
    // Use the provided userContent directly when available (e.g. when
    // generating the title early, before the message has been persisted).
    // Otherwise fall back to reading from the store.
    String userText;
    if (userContent != null && userContent.trim().isNotEmpty) {
      userText = userContent;
    } else {
      final messages = await _messageStore.getMessages(sessionId);
      final userMessage = messages.firstWhere(
        (m) => m.role == 'user',
        orElse: () => messages.first,
      );
      if (userMessage.content.trim().isEmpty) return null;
      userText = userMessage.content;
    }

    final title = await _streamAuxiliaryCall(
      systemPrompt: titleSystemPrompt,
      userMessage: userText,
      logTag: 'auxiliary',
      maxLength: 80,
    );
    if (title == null) return null;
    // Collapse newlines into spaces for single-line display.
    final collapsed = title.replaceAll(RegExp(r'[\r\n]+'), ' ');
    print('[auxiliary] generated title: $collapsed');
    return collapsed;
  }

  Future<String?> generateTldr(
    String responseContent, {
    String? userQuestion,
    TldrDetail detail = TldrDetail.defaultLevel,
  }) async {
    // Build a tiny Q→A exchange so the auxiliary model has the
    // user's question in its context window. This lets it (a)
    // prioritize the parts of the long response that actually
    // answer what was asked and (b) anchor the language of the
    // summary to the user's question (see the system prompt).
    // Falls back to the historical single-user-message layout
    // when no question is supplied (e.g. summarising a synthetic
    // AI bubble).
    final messages = <Map<String, dynamic>>[
      <String, dynamic>{
        'role': 'system',
        'content': tldrSystemPromptFor(detail),
      },
      if (userQuestion != null && userQuestion.trim().isNotEmpty)
        <String, dynamic>{'role': 'user', 'content': userQuestion},
      <String, dynamic>{'role': 'assistant', 'content': responseContent},
    ];
    final tldr = await _streamAuxiliaryCall(
      systemPrompt: tldrSystemPromptFor(detail),
      messages: messages,
      logTag: 'tldr',
    );
    if (tldr == null) return null;
    print('[tldr] generated: ${tldr.length} chars');
    return tldr;
  }

  void dispose() {
    _client.dispose();
  }
}

class _AuxModel {
  final ProviderConfig provider;
  final String apiKey;
  final String modelId;
  const _AuxModel({
    required this.provider,
    required this.apiKey,
    required this.modelId,
  });
}
