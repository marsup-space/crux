import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/coding_plan_usage.dart';
import '../../models/provider_config.dart';
import '../../utils/proxy_aware_http.dart';
import '../zhipu_usage_parser.dart';
import 'coding_plan_provider.dart';
import 'openai_compatible_provider.dart';

/// Provider for the [Zhipu GLM Coding Plan](https://bigmodel.cn/glm-coding)
/// platform (`open.bigmodel.cn/api/coding/paas/v4`).
///
/// ## Wire format
///
/// The GLM Coding Plan endpoint speaks OpenAI's Chat Completions
/// shape (so we extend [OpenAICompatibleProvider] and reuse the
/// URL / stream / message sanitization plumbing), with two
/// Zhipu-specific quirks handled by [buildRequestBody]:
///
/// 1. **`max_tokens`, not `max_completion_tokens`.** The Zhipu
///    docs only show the legacy OpenAI field name in their cURL
///    examples (see
///    [glm-5.3](https://docs.bigmodel.cn/cn/guide/models/text/glm-5.3)
///    and the switch guide
///    [glm-5.3-flash](https://docs.bigmodel.cn/cn/coding-plan/latest-model)).
///    The generic `OpenAICompatibleProvider` body uses the
///    newer `max_completion_tokens`; we rename the field so
///    a future Zhipu tightening of the spec can't 400 on us.
///
/// 2. **Model IDs are lowercase and dot-separated** (`glm-5.3`,
///    `glm-5.3-flash`). The model-overview
///    pages use the marketing names "GLM-5.3" etc., but every
///    authoritative wire-format reference (cURL, Python, Java
///    SDK examples) uses lowercase. Crux passes the TOML `id`
///    field through verbatim, so the `zhipu.toml` is the source
///    of truth for the canonical ID.
///
/// The other Zhipu-specific quirks (thinking-mode shape,
/// `reasoning_effort: "max"`, Bearer auth) already match what
/// the generic OpenAI-compatible builder emits, so we don't
/// override them.
///
/// ## Usage polling
///
/// We mix in [CodingPlanProvider] so the toolbar can show the
/// user's remaining 5-hour and weekly quota. The polling
/// endpoint is
/// `https://open.bigmodel.cn/api/monitor/usage/quota/limit` —
///
/// * The path is *under the same origin* as the chat base URL
///   (`open.bigmodel.cn`) but at a different path (`/api/...`),
///   so we can't just append `/usages` to `endpoint_url` the
///   way Kimi does. We re-derive the URL on every tick by
///   stripping the path from the chat base URL and using the
///   well-known quota path. The chat endpoint URL is the
///   source of truth, so a self-hosted proxy or regional
///   mirror automatically works without code changes.
/// * Auth is `Authorization: <raw key>` (no `Bearer` prefix) —
///   the documented shape from the cc-switch extractor
///   (https://github.com/farion1231/cc-switch/discussions/1038)
///   and the pi-glm-usage package. We send `Accept-Language:
///   en-US,en` so the response carries the English field
///   spellings the parser expects.
///
/// The response parser lives in `zhipu_usage_parser.dart` so
/// it can be unit-tested against canned JSON payloads
/// without standing up a fake HTTP server.
class ZhipuProvider extends OpenAICompatibleProvider with CodingPlanProvider {
  @override
  String get name => 'zhipu';

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  // ─── Wire format overrides ─────────────────────────────────

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
    // Build the standard OpenAI-compatible body, then swap
    // `max_completion_tokens` → `max_tokens` to match the
    // documented Zhipu field name. Every other key is what
    // the Zhipu cURL / SDK examples emit.
    final body = super.buildRequestBody(
      modelId,
      messages,
      thinkingMode: thinkingMode,
      reasoningEffort: reasoningEffort,
      thinkingBudget: thinkingBudget,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      tools: tools,
      userId: userId,
    );
    final maxCompletion = body.remove('max_completion_tokens');
    if (maxCompletion != null) {
      body['max_tokens'] = maxCompletion;
    }
    return body;
  }

  // ─── CodingPlanProvider implementation ────────────────────

  /// The path the mixin's [getCodingPlanUsage] calls. Built
  /// from the per-provider `endpoint_url` TOML field (which
  /// lives in [ProviderConfig], not on the provider class) so
  /// users can point at a self-hosted proxy or regional
  /// mirror without a rebuild. Resolved on each tick by
  /// stripping the path off the chat base URL and replacing
  /// it with the well-known quota path.
  static const String _quotaPath = '/api/monitor/usage/quota/limit';

  /// The chat endpoint URL passed to
  /// [startCodingPlanPolling]. The mixin owns the timer /
  /// stream / cache, but the provider owns the URL + key (the
  /// chat panel pulls them from `ProviderService` and threads
  /// them through). We stash them on private fields here so
  /// [getCodingPlanUsage] can read them back during a tick.
  String? _quotaBaseUrl;

  /// The API key passed to [startCodingPlanPolling]. See
  /// [_quotaBaseUrl] for the lifecycle rationale.
  String? _currentCodingPlanApiKey;

  @override
  void startCodingPlanPolling({
    required String apiKey,
    Duration? interval,
    String? baseUrl,
  }) {
    _currentCodingPlanApiKey = apiKey;
    _quotaBaseUrl = baseUrl;
    super.startCodingPlanPolling(
      apiKey: apiKey,
      interval: interval,
      baseUrl: baseUrl,
    );
  }

  @override
  void stopCodingPlanPolling() {
    super.stopCodingPlanPolling();
    _currentCodingPlanApiKey = null;
    _quotaBaseUrl = null;
  }

  @override
  Future<CodingPlanUsage> getCodingPlanUsage() async {
    final baseUrl = _quotaBaseUrl;
    final apiKey = _currentCodingPlanApiKey;
    if (baseUrl == null || baseUrl.isEmpty) {
      throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.notConfigured,
        'No base URL configured for Zhipu coding-plan polling',
      );
    }
    if (apiKey == null || apiKey.isEmpty) {
      throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.noApiKey,
        'No API key available for Zhipu coding-plan fetch',
      );
    }

    final url = _quotaUrlFor(baseUrl);

    // Translation from raw `SocketException` / `TimeoutException`
    // to `CodingPlanUsageError` happens *outside* the
    // `withProxyRetry` wrapper so the wrapper can see the
    // original connection error and decide whether to retry
    // through the system proxy. Translating inside the attempt
    // would hide the error class and the wrapper would never
    // trigger.
    return withProxyRetry<CodingPlanUsage>(
      enabled: isSystemProxyFallbackGloballyEnabled(),
      attempt: (proxy) async {
        final client = HttpClient();
        if (proxy != null) client.findProxy = proxy.findProxyFor;
        try {
          final request = await client
              .getUrl(Uri.parse(url))
              .timeout(const Duration(seconds: 10));
          // Zhipu's quota endpoint uses a raw `Authorization:
          // <key>` header (no `Bearer ` prefix) — the documented
          // shape from the cc-switch extractor and the
          // pi-glm-usage reference implementation. We also send
          // `Accept-Language: en-US,en` so the server returns
          // the English `level` field spellings the parser
          // expects ("lite" / "pro" / "max").
          request.headers
            ..set(HttpHeaders.authorizationHeader, apiKey)
            ..set(HttpHeaders.acceptHeader, 'application/json')
            ..set('Accept-Language', 'en-US,en');
          final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
          if (response.statusCode != 200) {
            throw _httpStatusToError(response.statusCode, url);
          }
          final body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 10));
          return parseZhipuUsageResponse(body, providerName: name);
        } finally {
          client.close(force: true);
        }
      },
    ).catchError((Object e) {
      if (e is CodingPlanUsageError) throw e;
      if (e is SocketException) {
        throw CodingPlanUsageError(
          CodingPlanUsageErrorKind.network,
          'Network error: ${e.message}',
        );
      }
      if (e is TimeoutException) {
        throw const CodingPlanUsageError(
          CodingPlanUsageErrorKind.network,
          'Request timed out',
        );
      }
      // Anything else (FormatException from a parse failure, an
      // unexpected exception type) — surface as a network error
      // so the UI doesn't show a raw stack trace.
      throw CodingPlanUsageError(
        CodingPlanUsageErrorKind.network,
        'Coding-plan usage fetch failed: $e',
      );
    });
  }

  /// Build the quota endpoint URL from a chat base URL by
  /// stripping the path and replacing it with the well-known
  /// quota path. Keeps self-hosted proxies and regional
  /// mirrors working: only the origin (scheme + host + port)
  /// is reused, the path is hardcoded to the documented
  /// Zhipu quota endpoint.
  static String _quotaUrlFor(String chatBaseUrl) {
    final uri = Uri.parse(chatBaseUrl);
    return uri.replace(path: _quotaPath).toString();
  }

  /// Map a non-2xx HTTP status from `/api/monitor/usage/quota/limit`
  /// to a [CodingPlanUsageError]. Zhipu returns 401 for invalid
  /// API keys and 403/404 for endpoints that aren't enabled on
  /// the user's plan — the same shape the pi-glm-usage reference
  /// distinguishes, so we mirror those messages for a familiar
  /// error surface.
  CodingPlanUsageError _httpStatusToError(int status, String url) {
    switch (status) {
      case 401:
      case 403:
        return const CodingPlanUsageError(
          CodingPlanUsageErrorKind.network,
          'Authorization failed. Please check your API key.',
        );
      case 404:
        return const CodingPlanUsageError(
          CodingPlanUsageErrorKind.notConfigured,
          'Usage endpoint not available for this plan.',
        );
      default:
        return CodingPlanUsageError(
          CodingPlanUsageErrorKind.network,
          'HTTP $status from $url',
        );
    }
  }
}
