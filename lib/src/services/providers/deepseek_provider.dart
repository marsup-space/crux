import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/credit_balance.dart';
import '../../utils/proxy_aware_http.dart';
import '../providers/openai_compatible_provider.dart';
import 'credit_balance_provider.dart';

class DeepSeekProvider extends OpenAICompatibleProvider
    with CreditBalanceProvider {
  @override
  String get name => 'deepseek';

  @override
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

  /// Compose two sanitizers for the DeepSeek wire format:
  ///
  ///   1. **Inherited from [OpenAICompatibleProvider.sanitizeMessages]**
  ///      — enforces the OpenAI tool_call ↔ tool message pairing
  ///      invariant. Repairs orphan `tool_calls` (e.g. from a
  ///      mid-round interruption or a wire-family switch from
  ///      MiniMax's Anthropic shape) so the request doesn't get
  ///      rejected with the 400 "an assistant message with tool_call
  ///      must be followed by tool messages responding to each
  ///      tool_call_id" error.
  ///   2. **DeepSeek-specific** — backfill `reasoning_content: ''`
  ///      on every `assistant` message that lacks the field. When a
  ///      session switches the active model from a non-DeepSeek
  ///      provider to DeepSeek, the prior `assistant` messages in
  ///      the wire-format history were serialized without a
  ///      `reasoning_content` field — Crux's OpenAI-compatible wire
  ///      emitters don't emit one, and the Anthropic emitter uses a
  ///      different shape (`thinking` content block). DeepSeek's
  ///      API requires every prior `assistant` message to include
  ///      a `reasoning_content` field when the request is in
  ///      thinking mode and a previous turn involved a tool call:
  ///      "If your code does not correctly pass back
  ///      `reasoning_content`, the API will return a 400 error."
  ///      ([source](https://api-docs.deepseek.com/guides/thinking_mode))
  ///      Per the same docs, the field is ignored for turns that
  ///      didn't perform a tool call, so always backfilling is
  ///      safe.
  ///
  /// The backfill runs after the pairing repair so that messages
  /// touched by step 1 (e.g. an assistant message that had its
  /// `tool_calls` array emptied) still get a `reasoning_content`
  /// key, matching what a DeepSeek-produced assistant message
  /// would have looked like.
  ///
  /// Returns the original list reference when neither step changes
  /// anything, so the common case (DeepSeek-produced history) is
  /// free.
  @override
  List<Map<String, dynamic>> sanitizeMessages(
    List<Map<String, dynamic>> messages,
  ) {
    final paired = super.sanitizeMessages(messages);
    return _backfillReasoningContent(paired);
  }

  List<Map<String, dynamic>> _backfillReasoningContent(
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
