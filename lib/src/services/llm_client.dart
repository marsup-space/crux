import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/provider_config.dart';
import '../utils/proxy_aware_http.dart';
import '../utils/system_proxy.dart' show SystemProxyDetector;
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
  final String? reasoningSignatureDelta;
  final String? finishReason;
  final int? promptTokens;
  final int? completionTokens;
  final int? promptCacheHitTokens;
  final int? promptCacheMissTokens;
  final int? reasoningTokens;
  final String? error;
  final String? abortReason;
  final bool guardAbort;
  final ToolUseChunk? toolUse;

  const LlmChunk({
    this.textDelta,
    this.reasoningContent,
    this.reasoningSignatureDelta,
    this.finishReason,
    this.promptTokens,
    this.completionTokens,
    this.promptCacheHitTokens,
    this.promptCacheMissTokens,
    this.reasoningTokens,
    this.error,
    this.abortReason,
    this.guardAbort = false,
    this.toolUse,
  });
}

class LlmStreamCancelToken {
  HttpClientResponse? _response;
  bool _isCancelled = false;
  String? _reason;
  bool _guardAbort = false;

  bool get isCancelled => _isCancelled;
  String? get reason => _reason;
  bool get guardAbort => _guardAbort;

  void _attachResponse(HttpClientResponse response) {
    _response = response;
    if (_isCancelled) {
      unawaited(_destroyResponse(response));
    }
  }

  Future<void> cancelActiveStream({
    required String reason,
    bool guardAbort = false,
  }) async {
    _isCancelled = true;
    _reason = reason;
    _guardAbort = guardAbort;
    final response = _response;
    if (response != null) {
      await _destroyResponse(response);
    }
  }

  Future<void> _destroyResponse(HttpClientResponse response) async {
    try {
      final socket = await response.detachSocket();
      socket.destroy();
    } catch (_) {
      // The response may already be closed. Cancellation is best-effort.
    }
  }
}

LlmChunk? contentBlockDeltaToChunk(
  Map<String, dynamic> json,
  Map<int, ({String callId, String name})> toolBlocks,
) {
  final delta = json['delta'] as Map<String, dynamic>?;
  if (delta == null) return null;
  final deltaType = delta['type'] as String?;
  if (deltaType == 'thinking_delta') {
    return LlmChunk(reasoningContent: delta['thinking'] as String?);
  }
  if (deltaType == 'signature_delta') {
    return LlmChunk(reasoningSignatureDelta: delta['signature'] as String?);
  }
  if (deltaType == 'text_delta') {
    return LlmChunk(textDelta: delta['text'] as String?);
  }
  if (deltaType == 'input_json_delta') {
    final partialJson = delta['partial_json'] as String? ?? '';
    final index = json['index'] as int? ?? 0;
    final block = toolBlocks[index];
    return LlmChunk(
      toolUse: ToolUseChunk(
        index: index,
        callId: block?.callId ?? '',
        name: block?.name ?? '',
        inputDelta: partialJson,
      ),
    );
  }
  return null;
}

class LlmClient {
  final HttpClient _httpClient = HttpClient();

  /// `true` once this client has switched to using the system proxy
  /// for all subsequent requests. Flipped on the first connection
  /// failure; once flipped, stays flipped for the life of this
  /// `LlmClient` instance. The user can restart Crux to retry
  /// direct.
  bool _useSystemProxy = false;

  /// Configure [_httpClient] to use the system proxy for all
  /// subsequent requests. Called on the first connection failure
  /// in `streamChat`; once flipped, stays flipped for the life of
  /// this `LlmClient` instance. The user can restart Crux to retry
  /// direct.
  void _enableSystemProxyFallback() {
    if (_useSystemProxy) return;
    final proxy = SystemProxyDetector.detect();
    if (proxy == null || proxy.isEmpty) return;
    _useSystemProxy = true;
    _httpClient.findProxy = (uri) => proxy.findProxyFor(uri);
  }

  /// Whether system-proxy fallback is enabled for this LlmClient.
  /// Read by [streamChat] (and by the integration tests).
  bool get isUsingSystemProxy => _useSystemProxy;

  Stream<LlmChunk> streamChat({
    required String endpointUrl,
    required ProviderConfig config,
    required String apiKey,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    double temperature = 0,
    List<Map<String, dynamic>>? tools,
    String? userId,
    LlmStreamCancelToken? cancelToken,
  }) {
    final controller = StreamController<LlmChunk>();
    final resolved = resolveProvider(config.type);
    final wireFamily = resolved.wire;
    final authStyle = resolved.authStyle;
    final anthropicToolBlocks = <int, ({String callId, String name})>{};

    () async {
      try {
        final provider = resolved.provider;
        final uri = _buildUri(endpointUrl, wireFamily);

        // The full request is wrapped in withProxyRetry. The wrapper
        // tries the request direct first; if any step from
        // `postUrl` through `request.close()` throws a connection
        // error (SocketException / HandshakeException / Timeout /
        // HttpException), it retries once through the system proxy.
        // We can't wrap just `postUrl` because Dart's HttpClient
        // establishes the connection lazily — a refused port often
        // doesn't surface as an error until the request is actually
        // sent (i.e. at `request.close()`).
        final response = await withProxyRetry<HttpClientResponse>(
          enabled: isSystemProxyFallbackGloballyEnabled(),
          attempt: (proxy) async {
            // First call: proxy == null → no findProxy set, direct.
            // Retry call:  proxy != null → flip the HttpClient to
            // route through the system proxy and remember it for the
            // rest of this LlmClient's life.
            if (proxy != null && !_useSystemProxy) {
              _enableSystemProxyFallback();
            }

            final request = await _httpClient.postUrl(uri);
            request.headers
                .set('Content-Type', 'application/json; charset=utf-8');
            _setAuthHeaders(request, authStyle, apiKey);

            // Provider-specific wire-format sanitization (default no-op).
            // DeepSeek uses this to backfill `reasoning_content: ''` on
            // assistant messages that were produced by a different
            // provider and would otherwise trip DeepSeek's 400 "reasoning
            // context must be passed back" check. Runs per-request (not
            // per-turn) so it also catches `tool_call` assistant messages
            // that ChatService adds inside the agentic loop on rounds
            // 2+. The no-op default returns the same list reference, so
            // providers that don't need it pay zero allocation cost.
            final sanitizedMessages = provider.sanitizeMessages(messages);

            final bodyMap = provider.buildRequestBody(
              modelId,
              sanitizedMessages,
              thinkingMode: thinkingMode,
              reasoningEffort: reasoningEffort,
              thinkingBudget: thinkingBudget,
              maxTokens: maxTokens,
              temperature: temperature,
              tools: tools,
              userId: userId,
            );
            final body = jsonEncode(bodyMap);
            final bodyBytes = utf8.encode(body);
            request.headers.set('Content-Length', bodyBytes.length.toString());
            request.add(bodyBytes);
            return request.close();
          },
        );
        cancelToken?._attachResponse(response);

        if (response.statusCode != 200) {
          final errorBody = await response.transform(utf8.decoder).join();
          controller.add(
            LlmChunk(error: 'HTTP ${response.statusCode}: $errorBody'),
          );
          await controller.close();
          return;
        }

        if (wireFamily == WireFamily.anthropicCompatible) {
          await _handleAnthropicStream(
            response,
            controller,
            anthropicToolBlocks,
            cancelToken,
          );
        } else {
          await _handleOpenAiStream(response, controller, cancelToken);
        }
      } catch (e) {
        if (!controller.isClosed) {
          if (cancelToken?.isCancelled ?? false) {
            controller.add(
              LlmChunk(
                abortReason: cancelToken?.reason ?? 'cancelled',
                guardAbort: cancelToken?.guardAbort ?? false,
              ),
            );
          } else {
            controller.add(LlmChunk(error: e.toString()));
          }
          await controller.close();
        }
      }
    }();

    return controller.stream;
  }

  Future<void> _handleOpenAiStream(
    HttpClientResponse response,
    StreamController<LlmChunk> controller,
    LlmStreamCancelToken? cancelToken,
  ) async {
    String buffer = '';
    await for (final chunk in response) {
      if (cancelToken?.isCancelled ?? false) {
        controller.add(
          LlmChunk(
            abortReason: cancelToken?.reason ?? 'cancelled',
            guardAbort: cancelToken?.guardAbort ?? false,
          ),
        );
        await controller.close();
        return;
      }
      buffer += utf8.decode(chunk, allowMalformed: true);
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
            controller.add(openAiUsageToChunk(usage));
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
    Map<int, ({String callId, String name})> toolBlocks,
    LlmStreamCancelToken? cancelToken,
  ) async {
    String buffer = '';
    String? eventType;

    // Accumulated usage, populated incrementally as SSE events arrive.
    // Usage arrives incrementally. Standard Anthropic responses usually put
    // input/cache counts in message_start and output_tokens in message_delta.
    // MiniMax may revise all of them in message_delta, including changing
    // input_tokens from 0 to the final uncached count. The accumulator accepts
    // those revisions while retaining an earlier positive cache count when a
    // compatible endpoint emits a placeholder zero at the end.
    final usageAccumulator = AnthropicUsageAccumulator();

    await for (final chunk in response) {
      if (cancelToken?.isCancelled ?? false) {
        controller.add(
          LlmChunk(
            abortReason: cancelToken?.reason ?? 'cancelled',
            guardAbort: cancelToken?.guardAbort ?? false,
          ),
        );
        await controller.close();
        return;
      }
      buffer += utf8.decode(chunk, allowMalformed: true);
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
              toolBlocks[index] = (
                callId: contentBlock['id'] as String? ?? '',
                name: contentBlock['name'] as String? ?? '',
              );
            }
          }

          if (eventType == 'message_start') {
            final message = json['message'] as Map<String, dynamic>?;
            if (message != null) {
              final usage = message['usage'] as Map<String, dynamic>?;
              if (usage != null) {
                usageAccumulator.apply(usage);
              }
            }
          }

          if (eventType == 'content_block_delta') {
            final chunk = contentBlockDeltaToChunk(json, toolBlocks);
            if (chunk != null) controller.add(chunk);
          }

          if (eventType == 'message_delta') {
            final delta = json['delta'] as Map<String, dynamic>?;
            final usage = json['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              usageAccumulator.apply(usage, isFinal: true);
            }
            // Emit a single final usage chunk with all accumulated
            // totals. This is the AI SDK's pattern: usage is buffered
            // during the stream and only released on the terminal
            // message_delta, so downstream consumers can't see partial
            // / zeroed values.
            controller.add(
              usageAccumulator.toChunk(
                finishReason: delta?['stop_reason'] as String?,
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

  Uri _buildUri(String endpointUrl, WireFamily wireFamily) {
    var base = endpointUrl;
    if (wireFamily == WireFamily.openaiCompatible &&
        !_endsWithVersionSegment(base)) {
      base = '$base/v1';
    }
    var uri = Uri.parse(base);
    if (wireFamily == WireFamily.anthropicCompatible) {
      final path = uri.path.endsWith('/')
          ? '${uri.path}messages'
          : '${uri.path}/messages';
      return uri.replace(path: path);
    }
    // For OpenAI-compatible endpoints, append `/chat/completions` to
    // the existing path (don't use `uri.resolve`, which would replace
    // the last path segment — e.g. `.../v1` would become `.../`).
    final path = uri.path.endsWith('/')
        ? '${uri.path}chat/completions'
        : '${uri.path}/chat/completions';
    return uri.replace(path: path);
  }

  /// `true` if [url] ends in `/v1` or `/v1/`. Used by
  /// [_buildUri] to decide whether the OpenAI-compatible endpoint
  /// already declares its version segment (in which case we don't
  /// want to add another `/v1`, or we'd get `.../v1/v1/chat/completions`).
  bool _endsWithVersionSegment(String url) {
    final stripped = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    return stripped.endsWith('/v1');
  }

  void _setAuthHeaders(
    HttpClientRequest request,
    AuthStyle authStyle,
    String apiKey,
  ) {
    if (authStyle == AuthStyle.bearer) {
      request.headers.set('Authorization', 'Bearer $apiKey');
    } else if (authStyle == AuthStyle.anthropicApiKey) {
      request.headers.set('x-api-key', apiKey);
      request.headers.set('anthropic-version', '2023-06-01');
    }
  }

  void dispose() {
    _httpClient.close();
  }
}

LlmChunk openAiUsageToChunk(Map<String, dynamic> usage) {
  final promptTokens = usage['prompt_tokens'] as int?;
  final completionDetails =
      usage['completion_tokens_details'] as Map<String, dynamic>?;
  final promptDetails = usage['prompt_tokens_details'] as Map<String, dynamic>?;
  final cacheHitTokens =
      usage['prompt_cache_hit_tokens'] as int? ??
      promptDetails?['cached_tokens'] as int?;
  final explicitMiss = usage['prompt_cache_miss_tokens'] as int?;
  final cacheMissTokens =
      explicitMiss ??
      (promptTokens != null
          ? (promptTokens - (cacheHitTokens ?? 0)).clamp(0, promptTokens)
          : null);

  return LlmChunk(
    promptTokens: promptTokens,
    completionTokens: usage['completion_tokens'] as int?,
    promptCacheHitTokens: cacheHitTokens,
    promptCacheMissTokens: cacheMissTokens,
    reasoningTokens: completionDetails?['reasoning_tokens'] as int?,
  );
}

class AnthropicUsageAccumulator {
  int inputTokens = 0;
  int outputTokens = 0;
  int cacheReadInputTokens = 0;
  int cacheCreationInputTokens = 0;

  void apply(Map<String, dynamic> usage, {bool isFinal = false}) {
    final input = usage['input_tokens'] as int?;
    if (input != null) inputTokens = input;

    final output = usage['output_tokens'] as int?;
    if (output != null) outputTokens = output;

    final cacheRead = usage['cache_read_input_tokens'] as int?;
    if (cacheRead != null &&
        (!isFinal || cacheRead > 0 || cacheReadInputTokens == 0)) {
      cacheReadInputTokens = cacheRead;
    }

    final cacheCreation = usage['cache_creation_input_tokens'] as int?;
    if (cacheCreation != null &&
        (!isFinal || cacheCreation > 0 || cacheCreationInputTokens == 0)) {
      cacheCreationInputTokens = cacheCreation;
    }
  }

  LlmChunk toChunk({String? finishReason}) {
    final cacheMissTokens = inputTokens + cacheCreationInputTokens;
    return LlmChunk(
      finishReason: finishReason,
      promptTokens: cacheMissTokens + cacheReadInputTokens,
      promptCacheHitTokens: cacheReadInputTokens,
      promptCacheMissTokens: cacheMissTokens,
      completionTokens: outputTokens,
    );
  }
}
