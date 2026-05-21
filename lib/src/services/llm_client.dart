import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/provider_config.dart';

class LlmChunk {
  final String? textDelta;
  final String? reasoningContent;
  final String? finishReason;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
  final int? promptCacheHitTokens;
  final int? promptCacheMissTokens;
  final int? reasoningTokens;
  final String? error;

  const LlmChunk({
    this.textDelta,
    this.reasoningContent,
    this.finishReason,
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.promptCacheHitTokens,
    this.promptCacheMissTokens,
    this.reasoningTokens,
    this.error,
  });
}

class LlmClient {
  final HttpClient _httpClient = HttpClient();

  Stream<LlmChunk> streamChat({
    required String endpointUrl,
    required ProviderType providerType,
    required String apiKey,
    required String modelId,
    required List<Map<String, String>> messages,
    String thinkingMode = 'enabled',
    String? reasoningEffort,
  }) {
    final controller = StreamController<LlmChunk>();

    () async {
      try {
        final uri = _buildUri(endpointUrl, providerType);
        final request = await _httpClient.postUrl(uri);

        request.headers
            .set('Content-Type', 'application/json; charset=utf-8');
        _setAuthHeaders(request, providerType, apiKey);

        final body = _buildRequestBody(modelId, messages, providerType);
        final bodyBytes = utf8.encode(body);
        request.headers.set('Content-Length', bodyBytes.length.toString());
        request.add(bodyBytes);

        final response = await request.close();

        if (response.statusCode != 200) {
          final errorBody = await response.transform(utf8.decoder).join();
          controller.add(LlmChunk(
            error: 'HTTP ${response.statusCode}: $errorBody',
          ));
          await controller.close();
          return;
        }

        String buffer = '';
        await for (final chunk in response.transform(utf8.decoder)) {
          buffer += chunk;
          final lines = buffer.split('\n');
          buffer = lines.removeLast();

          for (final line in lines) {
            final trimmed = line.trim();
            if (trimmed.isEmpty || !trimmed.startsWith('data: ')) continue;

            final data = trimmed.substring(6);
            if (data == '[DONE]') {
              controller.add(const LlmChunk(finishReason: 'stop'));
              await controller.close();
              return;
            }

            try {
              final json = jsonDecode(data) as Map<String, dynamic>;
              final error = json['error'];
              if (error != null) {
                final msg = error is Map
                    ? error['message'] ?? error.toString()
                    : error.toString();
                controller.add(LlmChunk(error: msg.toString()));
                await controller.close();
                return;
              }

              if (json.containsKey('choices')) {
                final choices = json['choices'] as List<dynamic>;
                if (choices.isNotEmpty) {
                  final choice = choices[0] as Map<String, dynamic>;
                  final delta = choice['delta'] as Map<String, dynamic>?;
                  final finishReason = choice['finish_reason'] as String?;

                  String? text;
                  String? reasoning;
                  if (delta != null) {
                    text = delta['content'] as String?;
                    reasoning = delta['reasoning_content'] as String?;
                  }

                  if (text != null || reasoning != null || finishReason != null) {
                    controller.add(LlmChunk(
                      textDelta: text,
                      reasoningContent: reasoning,
                      finishReason: finishReason,
                    ));
                  }
                }
              }

              if (json.containsKey('usage') && json['usage'] != null) {
                final usage = json['usage'] as Map<String, dynamic>;
                final completionDetails = usage['completion_tokens_details'] as Map<String, dynamic>?;
                controller.add(LlmChunk(
                  promptTokens: usage['prompt_tokens'] as int?,
                  completionTokens: usage['completion_tokens'] as int?,
                  totalTokens: usage['total_tokens'] as int?,
                  promptCacheHitTokens: usage['prompt_cache_hit_tokens'] as int?,
                  promptCacheMissTokens: usage['prompt_cache_miss_tokens'] as int?,
                  reasoningTokens: completionDetails?['reasoning_tokens'] as int?,
                ));
              }
            } catch (_) {
              continue;
            }
          }
        }

        controller.add(const LlmChunk(finishReason: 'done'));
        await controller.close();
      } catch (e) {
        controller.add(LlmChunk(error: e.toString()));
        await controller.close();
      }
    }();

    return controller.stream;
  }

  Uri _buildUri(String endpointUrl, ProviderType providerType) {
    var base = endpointUrl;
    if (providerType == ProviderType.openai && !base.endsWith('/v1')) {
      base = '$base/v1';
    }
    final uri = Uri.parse(base);
    if (providerType == ProviderType.anthropic) {
      return uri.resolve('messages');
    }
    return uri.resolve('chat/completions');
  }

  void _setAuthHeaders(
    HttpClientRequest request,
    ProviderType providerType,
    String apiKey,
  ) {
    if (providerType == ProviderType.openai) {
      request.headers.set('Authorization', 'Bearer $apiKey');
    } else if (providerType == ProviderType.anthropic) {
      request.headers.set('x-api-key', apiKey);
      request.headers.set('anthropic-version', '2023-06-01');
    }
  }

  String _buildRequestBody(
    String modelId,
    List<Map<String, String>> messages,
    ProviderType providerType, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
  }) {
    if (providerType == ProviderType.anthropic) {
      final systemMsg = messages.where((m) => m['role'] == 'system').toList();
      final chatMsgs = messages.where((m) => m['role'] != 'system').toList();
      final body = <String, dynamic>{
        'model': modelId,
        'messages': chatMsgs,
        'max_tokens': 8192,
        'stream': true,
      };
      if (systemMsg.isNotEmpty) {
        body['system'] = systemMsg.map((m) => m['content']).join('\n');
      }
      return jsonEncode(body);
    }

    return jsonEncode({
      'model': modelId,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      if (thinkingMode != 'disabled') 'thinking': {'type': thinkingMode},
      if (reasoningEffort != null) 'reasoning_effort': reasoningEffort,
    });
  }

  void dispose() {
    _httpClient.close();
  }
}
