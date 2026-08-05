import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/credit_balance.dart';
import '../../models/provider_config.dart';
import '../../utils/proxy_aware_http.dart';
import '../llm_provider.dart';
import 'credit_balance_provider.dart';

/// DeepSeek provider, speaking the **Responses API** wire
/// (`WireFamily.responsesApi`) since deepseek-v4-flash (2026-07).
///
/// The older Chat Completions endpoint (`/v1/chat/completions`) still
/// exists, but DeepSeek is moving all model launches onto the Responses
/// API (`/responses`) — deepseek-v4-pro will pick it up in early
/// August 2026. Crux therefore routes **every** DeepSeek model through
/// the Responses API so the v4-pro switch is a no-op.
///
/// ## Wire shape (empirically verified 2026-07-31)
///
/// - Endpoint: `POST https://api.deepseek.com/responses` (no `/v1`).
/// - Request body: Responses API — `instructions` (the system prompt),
///   `input` (a list of input items or a plain string), `reasoning:
///   {effort}`, `max_output_tokens`, flat `tools: [{type,function,name,
///   description,parameters}]`, `stream: true`.
/// - SSE: semantic events (`response.output_text.delta`,
///   `response.reasoning_text.delta`,
///   `response.function_call_arguments.delta`, …), ending with
///   `response.completed` / `response.incomplete` / `response.failed`.
///   No `data: [DONE]`.
///
/// ## Message history IR
///
/// Crux's storage / executor / `buildApiMessages` all use the OpenAI
/// Chat Completions message shape (`{role, content}`,
/// `{role: 'assistant', tool_calls: [...]}`,
/// `{role: 'tool', tool_call_id, content}`). The executor picks that
/// shape for any non-Anthropic wire family — including
/// [WireFamily.responsesApi]. This provider's [buildRequestBody]
/// converts that OpenAI-IR list into Responses input items at the last
/// moment, so no change is needed in the executor or the wire-format
/// builder.
class DeepSeekProvider extends LlmProvider with CreditBalanceProvider {
  @override
  String get name => 'deepseek';

  @override
  WireFamily get wire => WireFamily.responsesApi;

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  /// Map Crux's internal reasoning effort values onto DeepSeek's
  /// wire values. Declared on this provider (not inherited from
  /// [OpenAICompatibleProvider], which [DeepSeekProvider] no longer
  /// extends) because the Responses API wire still takes the same
  /// `high`/`max` scale.
  String mapEffort(String? effort) {
    switch (effort) {
      case 'max':
        return 'max';
      case 'high':
        return 'high';
      default: // normal, low, or anything else → API maps to high
        return 'high';
    }
  }

  /// Build the DeepSeek Responses API request body.
  ///
  /// [messages] arrive in OpenAI Chat Completions shape (the
  /// executor-internal IR). We translate them into Responses
  /// API `input` items:
  ///
  ///   - `{role: 'system', content}` — pulled out and sent as the
  ///     top-level `instructions` field (the Responses API's system
  ///     prompt slot). If there are multiple system messages they
  ///     are concatenated; the Responses API only accepts a single
  ///     `instructions` string.
  ///   - `{role: 'user'|'assistant', content}` — emitted as a
  ///     `{role, content}` input item. We drop a `null` content
  ///     rather than passing it through (the Responses API expects a
  ///     string for a `message` item).
  ///   - `{role: 'assistant', tool_calls: [...]}` — translated to a
  ///     sequence of `{type: 'function_call', call_id, name,
  ///     arguments}` items, placed *after* any sibling text content
  ///     for that assistant turn.
  ///   - `{role: 'tool', tool_call_id, content}` — translated to a
  ///     `{type: 'function_call_output', call_id, output}` item.
  ///
  /// The body also carries `reasoning: {effort}` (DeepSeek reflects
  /// the documented `high`/`max` scale), `max_output_tokens`, the
  /// flat-shape `tools` array, and `stream: true`.
  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    double temperature = 0,
    double topP = 1.0,
    List<Map<String, dynamic>>? tools,
    String? userId,
  }) {
    final instructions = StringBuffer();
    final input = <Map<String, dynamic>>[];

    for (final m in messages) {
      final role = m['role'] as String?;
      if (role == 'system' || role == 'developer') {
        final content = m['content'];
        if (content is String && content.isNotEmpty) {
          if (instructions.isNotEmpty) instructions.write('\n\n');
          instructions.write(content);
        }
        continue;
      }
      if (role == 'tool') {
        // OpenAI-IR tool result → Responses function_call_output.
        final callId = m['tool_call_id'] as String?;
        final output = m['content'];
        if (callId != null && callId.isNotEmpty) {
          input.add({
            'type': 'function_call_output',
            'call_id': callId,
            'output': output is String ? output : jsonEncode(output),
          });
        }
        continue;
      }
      if (role == 'assistant') {
        // Reasoning pass-back: DeepSeek's thinking mode requires the
        // assistant's chain-of-thought to be returned on subsequent
        // requests whenever a prior turn performed a tool call —
        // otherwise the API 400s with "The `reasoning_text` in the
        // thinking mode must be passed back to the API." In the
        // Responses API, reasoning is a dedicated input item
        // (`{type: 'reasoning', content: '<plain text>'}`) that the
        // server merges into the adjacent assistant message. Emit it
        // *before* the message item, mirroring the output-item order.
        final reasoning = m['reasoning_content'];
        if (reasoning is String && reasoning.isNotEmpty) {
          input.add({'type': 'reasoning', 'content': reasoning});
        }
        // Assistant text → a message item.
        final content = m['content'];
        if (content is String && content.isNotEmpty) {
          input.add({'role': 'assistant', 'content': content});
        }
        // Assistant tool_calls → function_call items (JSON-string args).
        final toolCalls = m['tool_calls'] as List?;
        if (toolCalls != null) {
          for (final tc in toolCalls) {
            if (tc is! Map) continue;
            final fn = tc['function'] as Map?;
            final callId = tc['id'] as String?;
            final fnName = fn?['name'] as String?;
            if (callId == null || fnName == null) continue;
            final args = fn?['arguments'];
            input.add({
              'type': 'function_call',
              'call_id': callId,
              'name': fnName,
              'arguments': args is String ? args : jsonEncode(args ?? const {}),
            });
          }
        }
        continue;
      }
      // user (and anything we didn't pattern-match) — pass content
      // through as a message item, mirroring how the wire-format
      // builder handles plain user turns.
      final content = m['content'];
      if (content is String) {
        input.add({'role': role ?? 'user', 'content': content});
      } else if (content is List) {
        // Multi-modal OpenAI content blocks. The DeepSeek Responses
        // API only accepts `input_text` / `output_text` parts for
        // messages (no images). Reduce to the text parts joined.
        final text = content
            .whereType<Map>()
            .where((b) => b['type'] == 'text' || b['type'] == 'input_text')
            .map((b) => b['text'] as String? ?? '')
            .join();
        if (text.isNotEmpty) {
          input.add({'role': role ?? 'user', 'content': text});
        }
      }
    }

    final body = <String, dynamic>{
      'model': modelId,
      'input': input,
      'stream': true,
      'temperature': temperature,
      'top_p': topP,
    };

    if (instructions.isNotEmpty) {
      body['instructions'] = instructions.toString();
    }

    if (thinkingMode == 'enabled') {
      // `reasoning.effort` is the only reasoning knob DeepSeek's
      // Responses API honors (no `summary`). Force `high` as the
      // floor — `low`/`normal` are SDK aliases that resolve to high,
      // and emitting them verbatim just mirrors that.
      body['reasoning'] = {'effort': mapEffort(reasoningEffort ?? 'high')};
    }

    if (maxTokens != null) {
      body['max_output_tokens'] = maxTokens;
    }

    if (tools != null && tools.isNotEmpty) {
      // Responses API tools use the FLAT shape
      // `{type:'function', name, description, parameters}` — not the
      // Chat Completions nested `{type:'function', function:{...}}`.
      body['tools'] = tools
          .map(
            (t) => {
              'type': 'function',
              'name': t['name'],
              'description': t['description'],
              'parameters': t['parameters'],
            },
          )
          .toList();
    }

    if (userId != null && userId.isNotEmpty) {
      body['user'] = userId;
    }

    return body;
  }

  /// Sanitize the OpenAI-IR message list before it's converted to
  /// Responses input items in [buildRequestBody].
  ///
  /// Two repairs run, in order:
  ///
  ///   1. **Tool-call pairing** (the Responses-API analogue of
  ///      [OpenAICompatibleProvider.sanitizeMessages]): enforces the
  ///      tool_call ↔ tool result pairing invariant (function_call →
  ///      function_call_output in Responses terms) so a
  ///      half-persisted multi-tool round doesn't surface as a 400.
  ///
  ///   2. **`reasoning_content` backfill**: every `assistant` message
  ///      that lacks the field gets `reasoning_content: ''`. DeepSeek's
  ///      thinking mode requires the field to be present on assistant
  ///      messages when the request is in thinking mode and a previous
  ///      turn involved a tool call — history produced by a different
  ///      provider (e.g. MiniMax's Anthropic wire, which serializes
  ///      thinking as a `thinking` content block, not this field) or
  ///      by an older build of this provider can be missing it, and
  ///      the API rejects such requests with a 400 ("reasoning context
  ///      must be passed back"). Empty strings satisfy the check for
  ///      turns that didn't perform a tool call; turns that did carry
  ///      real reasoning are preserved verbatim.
  ///
  /// Runs per-request (not per-turn), so it also catches the
  /// `tool_call` assistant messages the agentic loop adds on rounds
  /// 2+ — the exact spot DeepSeek's check is strictest about.
  ///
  /// Returns the original list reference when neither step changes
  /// anything, so the well-formed-history fast path is free.
  @override
  List<Map<String, dynamic>> sanitizeMessages(
    List<Map<String, dynamic>> messages,
  ) {
    final paired = _enforceToolCallPairing(messages);
    return _backfillReasoningContent(paired);
  }

  /// Backfill `reasoning_content: ''` on every `assistant` message
  /// that lacks the field (missing key or explicit `null`).
  ///
  /// See the [sanitizeMessages] doc for why DeepSeek requires this.
  /// `tool` / `user` / `system` messages pass through untouched.
  static List<Map<String, dynamic>> _backfillReasoningContent(
    List<Map<String, dynamic>> messages,
  ) {
    var modified = false;
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m['role'] == 'assistant' && m['reasoning_content'] == null) {
        out.add({...m, 'reasoning_content': ''});
        modified = true;
      } else {
        out.add(m);
      }
    }
    return modified ? out : messages;
  }

  static List<Map<String, dynamic>> _enforceToolCallPairing(
    List<Map<String, dynamic>> messages,
  ) {
    final orphanCallIds = <String>{};
    var hasMalformedToolMessage = false;
    Set<String>? pending;

    for (final m in messages) {
      final role = m['role'];
      if (role == 'assistant') {
        final toolCalls = m['tool_calls'] as List?;
        if (toolCalls != null && toolCalls.isNotEmpty) {
          pending?.forEach(orphanCallIds.add);
          pending = <String>{
            for (final tc in toolCalls)
              if (tc is Map && tc['id'] is String) tc['id'] as String,
          };
        } else {
          pending?.forEach(orphanCallIds.add);
          pending = null;
        }
      } else if (role == 'tool') {
        final callId = m['tool_call_id'] as String?;
        if (callId == null) {
          hasMalformedToolMessage = true;
          continue;
        }
        if (pending == null || !pending.remove(callId)) {
          orphanCallIds.add(callId);
        }
      } else {
        pending?.forEach(orphanCallIds.add);
        pending = null;
      }
    }
    pending?.forEach(orphanCallIds.add);

    if (orphanCallIds.isEmpty && !hasMalformedToolMessage) return messages;

    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'];
      if (role == 'assistant') {
        final toolCalls = m['tool_calls'] as List?;
        if (toolCalls != null && toolCalls.isNotEmpty) {
          final kept = <Map<String, dynamic>>[
            for (final tc in toolCalls.cast<Map<String, dynamic>>())
              if (tc['id'] is String && !orphanCallIds.contains(tc['id'])) tc,
          ];
          if (kept.length != toolCalls.length) {
            final patched = <String, dynamic>{...m};
            if (kept.isEmpty) {
              patched.remove('tool_calls');
            } else {
              patched['tool_calls'] = kept;
            }
            out.add(patched);
            continue;
          }
        }
        out.add(m);
      } else if (role == 'tool') {
        final callId = m['tool_call_id'] as String?;
        if (callId == null) continue;
        if (orphanCallIds.contains(callId)) continue;
        out.add(m);
      } else {
        out.add(m);
      }
    }
    return out;
  }

  // ─── CreditBalanceProvider implementation ───────────────────

  /// The DeepSeek balance endpoint.
  /// [API docs](https://api-docs.deepseek.com/api/get-user-balance)
  static const String _balanceApiUrl = 'https://api.deepseek.com/user/balance';

  /// The API key passed to [startCreditBalancePolling]. The
  /// mixin owns the timer / stream / cache, but the
  /// provider owns the key (the chat panel pulls it from
  /// `ProviderService` and threads it through). We stash it
  /// on a private field here so [getCreditBalance] can
  /// read it back during a tick.
  String? _currentCreditBalanceApiKey;

  @override
  void startCreditBalancePolling({required String apiKey, Duration? interval}) {
    _currentCreditBalanceApiKey = apiKey;
    super.startCreditBalancePolling(apiKey: apiKey, interval: interval);
  }

  @override
  void stopCreditBalancePolling() {
    super.stopCreditBalancePolling();
    _currentCreditBalanceApiKey = null;
  }

  @override
  Future<CreditBalance> getCreditBalance() async {
    final key = _currentCreditBalanceApiKey;
    if (key == null) {
      throw const CreditBalanceError(
        CreditBalanceErrorKind.noApiKey,
        'No API key available for DeepSeek balance fetch',
      );
    }

    // The translation from raw `SocketException` / `TimeoutException`
    // to `CreditBalanceError` happens *outside* the wrapper so that
    // `withProxyRetry` can see the original connection error and
    // decide whether to retry through the system proxy. Translating
    // inside the attempt would hide the error class and the wrapper
    // would never trigger.
    return withProxyRetry<CreditBalance>(
      enabled: isSystemProxyFallbackGloballyEnabled(),
      attempt: (proxy) async {
        final client = HttpClient();
        if (proxy != null) client.findProxy = proxy.findProxyFor;
        try {
          final request = await client
              .getUrl(Uri.parse(_balanceApiUrl))
              .timeout(const Duration(seconds: 10));
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
          request.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/json',
          );
          final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
          if (response.statusCode != 200) {
            throw CreditBalanceError(
              CreditBalanceErrorKind.network,
              'HTTP ${response.statusCode} from $_balanceApiUrl',
            );
          }
          final body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 10));
          return _parseBalanceResponse(body);
        } finally {
          client.close(force: true);
        }
      },
    ).catchError((Object e) {
      if (e is CreditBalanceError) throw e;
      if (e is SocketException) {
        throw CreditBalanceError(
          CreditBalanceErrorKind.network,
          'Network error: ${e.message}',
        );
      }
      if (e is TimeoutException) {
        throw const CreditBalanceError(
          CreditBalanceErrorKind.network,
          'Request timed out',
        );
      }
      // Anything else (e.g. FormatException from a parse failure) —
      // surface as a network error so the UI doesn't show a stack
      // trace. The original behaviour was a silent empty CreditBalance.
      throw CreditBalanceError(
        CreditBalanceErrorKind.network,
        'Balance fetch failed: $e',
      );
    });
  }

  /// Parse the JSON body of the `/user/balance` response into a
  /// [CreditBalance].
  ///
  /// Expected shape:
  /// ```json
  /// {
  ///   "is_available": true,
  ///   "balance_infos": [
  ///     {
  ///       "currency": "CNY",
  ///       "total_balance": "110.00",
  ///       "granted_balance": "10.00",
  ///       "topped_up_balance": "100.00"
  ///     }
  ///   ]
  /// }
  /// ```
  CreditBalance _parseBalanceResponse(String body) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (e) {
      throw CreditBalanceError(
        CreditBalanceErrorKind.parse,
        'Invalid JSON: ${e.message}',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const CreditBalanceError(
        CreditBalanceErrorKind.parse,
        'Response root is not a JSON object',
      );
    }

    final isAvailable = decoded['is_available'];
    if (isAvailable is! bool) {
      throw const CreditBalanceError(
        CreditBalanceErrorKind.parse,
        'Missing or invalid is_available field',
      );
    }

    final infosRaw = decoded['balance_infos'];
    if (infosRaw is! List || infosRaw.isEmpty) {
      throw const CreditBalanceError(
        CreditBalanceErrorKind.parse,
        'Missing or empty balance_infos array',
      );
    }

    final infos = <BalanceInfo>[];
    for (final entry in infosRaw) {
      if (entry is! Map<String, dynamic>) continue;
      final currency = entry['currency'];
      final total = entry['total_balance'];
      final granted = entry['granted_balance'];
      final toppedUp = entry['topped_up_balance'];
      if (currency is! String ||
          total is! String ||
          granted is! String ||
          toppedUp is! String) {
        throw const CreditBalanceError(
          CreditBalanceErrorKind.parse,
          'Malformed balance_infos entry',
        );
      }
      infos.add(
        BalanceInfo(
          currency: currency,
          totalBalance: total,
          grantedBalance: granted,
          toppedUpBalance: toppedUp,
        ),
      );
    }

    return CreditBalance(
      providerName: name,
      isAvailable: isAvailable,
      balanceInfos: infos,
      fetchedAt: DateTime.now(),
    );
  }
}
