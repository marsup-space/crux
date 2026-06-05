import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/provider_config.dart';
import 'llm_provider.dart';

class ToolUseChunk {
  final int index;
  final String callId;
  final String name;
  final String inputDelta;

  const ToolUseChunk({
    this.index = 0,
    required this.callId,
    required this.name,
    this.inputDelta = '',
  });
}

class LlmChunk {
  final String? textDelta;
  final String? reasoningContent;
  final String? finishReason;
  final int? promptTokens;
  final int? completionTokens;
  final int? promptCacheHitTokens;
  final int? promptCacheMissTokens;
  final int? reasoningTokens;
  final String? error;
  final ToolUseChunk? toolUse;

  const LlmChunk({
    this.textDelta,
    this.reasoningContent,
    this.finishReason,
    this.promptTokens,
    this.completionTokens,
    this.promptCacheHitTokens,
    this.promptCacheMissTokens,
    this.reasoningTokens,
    this.error,
    this.toolUse,
  });
}

class LlmClient {
  final HttpClient _httpClient = HttpClient();
  final Map<int, ({String callId, String name})> _anthropicToolBlocks = {};

  void clearToolBlockState() => _anthropicToolBlocks.clear();

  Stream<LlmChunk> streamChat({
    required String endpointUrl,
    required String providerName,
    required ProviderType providerType,
    required String apiKey,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    List<Map<String, dynamic>>? tools,
  }) {
    final controller = StreamController<LlmChunk>();

    () async {
      try {
        final provider = providerFor(providerName, providerType);
        final uri = _buildUri(endpointUrl, providerType);
        final request = await _httpClient.postUrl(uri);

        request.headers.set('Content-Type', 'application/json; charset=utf-8');
        _setAuthHeaders(request, providerType, apiKey);

        final bodyMap = provider.buildRequestBody(
          modelId,
          messages,
          thinkingMode: thinkingMode,
          reasoningEffort: reasoningEffort,
          thinkingBudget: thinkingBudget,
          tools: tools,
        );
        final body = jsonEncode(bodyMap);
        final bodyBytes = utf8.encode(body);
        request.headers.set('Content-Length', bodyBytes.length.toString());
        request.add(bodyBytes);

        final response = await request.close();

        if (response.statusCode != 200) {
          final errorBody = await response.transform(utf8.decoder).join();
          controller.add(
            LlmChunk(error: 'HTTP ${response.statusCode}: $errorBody'),
          );
          await controller.close();
          return;
        }

        if (providerType == ProviderType.anthropic) {
          await _handleAnthropicStream(response, controller);
        } else {
          await _handleOpenAiStream(response, controller);
        }
      } catch (e) {
        if (!controller.isClosed) {
          controller.add(LlmChunk(error: e.toString()));
          await controller.close();
        }
      }
    }();

    return controller.stream;
  }

  Future<void> _handleOpenAiStream(
    HttpClientResponse response,
    StreamController<LlmChunk> controller,
  ) async {
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

              if (delta != null) {
                final text = delta['content'] as String?;
                final reasoning = delta['reasoning_content'] as String?;

                if (text != null || reasoning != null) {
                  controller.add(
                    LlmChunk(textDelta: text, reasoningContent: reasoning),
                  );
                }

                final toolCalls = delta['tool_calls'] as List<dynamic>?;
                if (toolCalls != null) {
                  for (final tc in toolCalls) {
                    final tcMap = tc as Map<String, dynamic>;
                    final tcIndex = tcMap['index'] as int? ?? 0;
                    final tcId = tcMap['id'] as String? ?? '';
                    final tcFunction =
                        tcMap['function'] as Map<String, dynamic>?;
                    final tcName = tcFunction?['name'] as String? ?? '';
                    final tcArgs = tcFunction?['arguments'] as String? ?? '';
                    controller.add(
                      LlmChunk(
                        toolUse: ToolUseChunk(
                          index: tcIndex,
                          callId: tcId,
                          name: tcName,
                          inputDelta: tcArgs,
                        ),
                      ),
                    );
                  }
                }
              }

              if (finishReason != null) {
                controller.add(LlmChunk(finishReason: finishReason));
              }
            }
          }

          if (json.containsKey('usage') && json['usage'] != null) {
            final usage = json['usage'] as Map<String, dynamic>;
            final completionDetails =
                usage['completion_tokens_details'] as Map<String, dynamic>?;
            controller.add(
              LlmChunk(
                promptTokens: usage['prompt_tokens'] as int?,
                completionTokens: usage['completion_tokens'] as int?,
                promptCacheHitTokens: usage['prompt_cache_hit_tokens'] as int?,
                promptCacheMissTokens:
                    usage['prompt_cache_miss_tokens'] as int?,
                reasoningTokens: completionDetails?['reasoning_tokens'] as int?,
              ),
            );
          }
        } catch (_) {
          continue;
        }
      }
    }

    controller.add(const LlmChunk(finishReason: 'done'));
    await controller.close();
  }

  Future<void> _handleAnthropicStream(
    HttpClientResponse response,
    StreamController<LlmChunk> controller,
  ) async {
    String buffer = '';
    String? eventType;

    await for (final chunk in response.transform(utf8.decoder)) {
      buffer += chunk;
      final lines = buffer.split('\n');
      buffer = lines.removeLast();

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          eventType = null;
          continue;
        }
        if (trimmed.startsWith('event: ')) {
          eventType = trimmed.substring(7);
          continue;
        }
        if (!trimmed.startsWith('data: ')) continue;

        final data = trimmed.substring(6);

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;

          if (eventType == 'ping') continue;

          if (eventType == 'error') {
            final errMsg = json['error']?['message'] ?? json.toString();
            controller.add(LlmChunk(error: errMsg.toString()));
            await controller.close();
            return;
          }

          if (eventType == 'content_block_start') {
            final contentBlock = json['content_block'] as Map<String, dynamic>?;
            if (contentBlock != null && contentBlock['type'] == 'tool_use') {
              final index = json['index'] as int? ?? 0;
              _anthropicToolBlocks[index] = (
                callId: contentBlock['id'] as String? ?? '',
                name: contentBlock['name'] as String? ?? '',
              );
            }
          }

          if (eventType == 'message_start') {
            final message = json['message'] as Map<String, dynamic>?;
            if (message != null) {
              final usage = message['usage'] as Map<String, dynamic>?;
              controller.add(
                LlmChunk(promptTokens: usage?['input_tokens'] as int?),
              );
            }
          }

          if (eventType == 'content_block_delta') {
            final delta = json['delta'] as Map<String, dynamic>?;
            if (delta != null) {
              final deltaType = delta['type'] as String?;
              if (deltaType == 'thinking_delta') {
                controller.add(
                  LlmChunk(reasoningContent: delta['thinking'] as String?),
                );
              } else if (deltaType == 'text_delta') {
                controller.add(LlmChunk(textDelta: delta['text'] as String?));
              } else if (deltaType == 'input_json_delta') {
                final partialJson = delta['partial_json'] as String? ?? '';
                final index = json['index'] as int? ?? 0;
                final block = _anthropicToolBlocks[index];
                controller.add(
                  LlmChunk(
                    toolUse: ToolUseChunk(
                      callId: block?.callId ?? '',
                      name: block?.name ?? '',
                      inputDelta: partialJson,
                    ),
                  ),
                );
              }
            }
          }

          if (eventType == 'message_delta') {
            final delta = json['delta'] as Map<String, dynamic>?;
            final usage = json['usage'] as Map<String, dynamic>?;
            controller.add(
              LlmChunk(
                finishReason: delta?['stop_reason'] as String?,
                completionTokens: usage?['output_tokens'] as int?,
                promptCacheHitTokens: usage?['cache_read_input_tokens'] as int?,
                promptCacheMissTokens:
                    usage?['cache_creation_input_tokens'] as int?,
              ),
            );
          }
        } catch (_) {
          continue;
        }
      }
    }

    controller.add(const LlmChunk(finishReason: 'done'));
    await controller.close();
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

  void dispose() {
    _httpClient.close();
  }
}
