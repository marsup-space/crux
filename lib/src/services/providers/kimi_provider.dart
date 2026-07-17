import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/coding_plan_usage.dart';
import '../../models/provider_config.dart';
import '../../utils/proxy_aware_http.dart';
import '../kimi_usage_parser.dart';
import 'coding_plan_provider.dart';
import 'openai_compatible_provider.dart';

/// Provider for the [Kimi Code](https://www.kimi.com/code/) platform
/// (`api.kimi.com/coding/v1`).
///
/// ## Wire format
///
/// The Kimi API speaks OpenAI's Chat Completions shape (so we extend
/// [OpenAICompatibleProvider] and reuse the URL / stream / message
/// sanitization plumbing), but with three Kimi-specific quirks:
///
/// 1. **K3 model-ID remap.** K3 is exposed to users as two
///    composite Crux entries (`k3-1m` and `k3-256k`) so the user
///    can pick the context size their Kimi Code plan grants them
///    (Allegretto+ = up to 1M; Moderato = up to 256K). Kimi's API
///    only recognizes a single `model: "k3"` ID — the plan tier
///    decides the server-side context cap. We translate both
///    Crux-side IDs to `k3` on the wire.
///
/// 2. **K2.7 binary thinking.** The K2.7 Code family
///    (`kimi-for-coding` and `kimi-for-coding-highspeed`) is
///    documented as a binary `thinking.type: enabled/disabled` knob
///    (see [Kimi's model docs](https://www.kimi.com/code/docs/kimi-code/models)).
///    The upstream kosong SDK used by kimi-cli never sends
///    `reasoning_effort` for these models — it only flips
///    `thinking.type`. We drop any `reasoning_effort` field the
///    generic OpenAI-compatible builder would emit, so a future
///    tightening of the Kimi API can't 400 on us.
///
/// 3. **`temperature` is fixed at 1.0** for every Kimi Code model
///    (K3 and the K2.7 Code family). The Kimi API rejects any
///    other value with
///    `400 invalid temperature: only 1 is allowed for this model`.
///    Crux's default sampling is `temperature = 0.0` (deterministic
///    coding) and the `/temperature` slash command clamps to
///    `[0.0, 1.0]`, so without an override every Kimi request
///    would 400. We force `temperature: 1.0` and pair it with
///    Kimi's recommended `top_p: 0.95` on the wire so the model
///    sits in its expected operating regime regardless of what
///    the user configured. The TOML `temperature` field is
///    silently ignored for Kimi — we document this on the
///    provider config so users aren't surprised by the
///    /temperature command having no effect.
///
/// K3 (the flagship) *does* accept `reasoning_effort`, and the
/// Kimi docs specify a server-side mapping
/// (currently only `max` is honored; `low`/`high` are "coming
/// later"). The OpenAI-compatible builder already maps Crux's
/// `max` → wire `max`, so K3 passes through unchanged.
///
/// ## Usage polling
///
/// We mix in [CodingPlanProvider] so the toolbar can show the
/// user's remaining quota. The polling endpoint is
/// `{endpoint_url}/usages` (Bearer auth); the response parser
/// lives in `kimi_usage_parser.dart` so it can be unit-tested
/// directly against canned JSON payloads without standing up a
/// fake HTTP server.
String _trimTrailingSlash(String url) {
  if (url.length > 1 && url.endsWith('/')) {
    return url.substring(0, url.length - 1);
  }
  return url;
}

class KimiProvider extends OpenAICompatibleProvider with CodingPlanProvider {
  @override
  String get name => 'kimi';

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  @override
  double? get forcedTemperature => _kimiTemperature;

  // ─── Wire format overrides ─────────────────────────────────

  /// Crux-side model IDs that map to the upstream `k3` model.
  /// K3 is one upstream model; we expose it twice (1M and 256K
  /// context) so the user can match the variant to their plan's
  /// granted context window.
  static const Set<String> _k3CruxIds = {'k3-1m', 'k3-256k'};

  /// Upstream model IDs that are K2.7 (binary thinking, no
  /// `reasoning_effort` field on the wire).
  static bool _isK27(String upstreamId) =>
      upstreamId.startsWith('kimi-for-coding');

  /// Kimi's recommended sampling defaults for the K2.7 Code / K3
  /// family. The platform's [model parameter reference](https://platform.kimi.ai/docs/api/models-overview)
  /// documents `temperature = 1.0` as fixed for every Kimi Code
  /// model and pairs it with `top_p = 0.95` (the API silently
  /// accepts any `[0, 1]` `top_p`, but the model is calibrated
  /// for the recommended pair — drifting off it is a quiet
  /// quality regression, not an error).
  static const double _kimiTemperature = 1.0;
  static const double _kimiTopP = 0.95;

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
    // Remap the Crux-side K3 IDs (`k3-1m` / `k3-256k`) to the
    // single upstream `k3` model. Everything else passes through
    // unchanged.
    final upstreamId = _k3CruxIds.contains(modelId) ? 'k3' : modelId;

    final body = super.buildRequestBody(
      upstreamId,
      messages,
      thinkingMode: thinkingMode,
      reasoningEffort: reasoningEffort,
      thinkingBudget: thinkingBudget,
      // Force `temperature = 1.0` for every Kimi model — the
      // API rejects any other value with
      // `400 invalid temperature: only 1 is allowed for this model`.
      // The `temperature` parameter the caller passed (model
      // config default or `/temperature` override) is silently
      // discarded. The TOML comment on each [[models]] entry
      // documents this so users aren't surprised.
      temperature: _kimiTemperature,
      // Pair with Kimi's recommended `top_p = 0.95`. The
      // executor's `topPForTemperature(temp)` helper would
      // otherwise derive `top_p = 0.85` (from temp=1) or
      // `top_p = 1.0` (from temp=0) — both outside the model's
      // calibrated range, so we override here too.
      topP: _kimiTopP,
      tools: tools,
      userId: userId,
    );

    // K2.7 is a binary Thinking:ON/OFF knob. The kimi-cli kosong
    // SDK never sends `reasoning_effort` for these models — strip
    // it from our generic OpenAI-compatible body so we match the
    // reference implementation's wire shape.
    if (_isK27(upstreamId)) {
      body.remove('reasoning_effort');
    }

    return body;
  }

  // ─── CodingPlanProvider implementation ────────────────────

  /// The API endpoint the mixin's [getCodingPlanUsage] calls.
  /// Resolved at polling-start time from the per-provider
  /// `endpoint_url` TOML field (which lives in [ProviderConfig],
  /// not on the provider class) so users can point at a
  /// self-hosted proxy or regional mirror without a rebuild.
  String? _codingPlanBaseUrl;

  /// The API key passed to [startCodingPlanPolling]. The mixin
  /// owns the timer / stream / cache, but the provider owns the
  /// key + URL (the chat panel pulls it from `ProviderService`
  /// and threads it through). We stash it on private fields
  /// here so [getCodingPlanUsage] can read them back during a
  /// tick.
  String? _currentCodingPlanApiKey;

  @override
  void startCodingPlanPolling({
    required String apiKey,
    Duration? interval,
    String? baseUrl,
  }) {
    _currentCodingPlanApiKey = apiKey;
    _codingPlanBaseUrl = baseUrl;
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
    _codingPlanBaseUrl = null;
  }

  @override
  Future<CodingPlanUsage> getCodingPlanUsage() async {
    final baseUrl = _codingPlanBaseUrl;
    final apiKey = _currentCodingPlanApiKey;
    if (baseUrl == null || baseUrl.isEmpty) {
      throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.notConfigured,
        'No base URL configured for Kimi coding-plan polling',
      );
    }
    if (apiKey == null || apiKey.isEmpty) {
      throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.noApiKey,
        'No API key available for Kimi coding-plan fetch',
      );
    }

    final url = '${_trimTrailingSlash(baseUrl)}/usages';

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
          request.headers
            ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
            ..set(HttpHeaders.acceptHeader, 'application/json');
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
          return parseKimiUsageResponse(body, providerName: name);
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

  /// Map a non-2xx HTTP status from `/usages` to a
  /// [CodingPlanUsageError]. The Kimi platform returns 401 for
  /// invalid API keys and 404 when the endpoint isn't enabled for
  /// the user's plan — the same shape kimi-cli's `/usage`
  /// command distinguishes, so we mirror those messages for a
  /// familiar error surface.
  CodingPlanUsageError _httpStatusToError(int status, String url) {
    switch (status) {
      case 401:
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
