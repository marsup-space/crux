import '../models/provider_config.dart';
import '../storage/session_store.dart';
import 'auxiliary_prompts.dart';
import 'llm_client.dart';
import 'provider_service.dart';

/// Lightweight LLM calls that use the auxiliary model (title generation,
/// TLDR summarization). Runs on a single long-lived [LlmClient] instead
/// of creating and disposing one per call — avoids the overhead of a
/// fresh `HttpClient` per auxiliary request.
class AuxiliaryService {
  final ProviderService _providerService;
  final SessionStore _store;
  final LlmClient _client = LlmClient();

  AuxiliaryService(this._providerService, this._store);

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
  Future<String?> _streamAuxiliaryCall({
    required String systemPrompt,
    required String userMessage,
    required String logTag,
    int? maxLength,
  }) async {
    final aux = _resolve();
    if (aux == null) return null;

    try {
      final stream = _client.streamChat(
        endpointUrl: aux.provider.endpointUrl,
        config: aux.provider,
        apiKey: aux.apiKey,
        modelId: aux.modelId,
        messages: <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': systemPrompt},
          <String, dynamic>{'role': 'user', 'content': userMessage},
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
        print('[$logTag] stream error: $streamError');
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
      final messages = await _store.getMessages(sessionId);
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
    TldrDetail detail = TldrDetail.defaultLevel,
  }) async {
    final tldr = await _streamAuxiliaryCall(
      systemPrompt: tldrSystemPromptFor(detail),
      userMessage: responseContent,
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
