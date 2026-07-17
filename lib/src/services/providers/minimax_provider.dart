import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/coding_plan_usage.dart';
import '../../models/provider_config.dart';
import '../../utils/proxy_aware_http.dart';
import '../coding_plan_usage_parser.dart';
import 'anthropic_compatible_provider.dart';
import 'coding_plan_provider.dart';

/// Provider for the MiniMax Anthropic-compatible endpoint.
///
/// MiniMax models split into two families with different thinking
/// behaviour:
///
/// - **MiniMax-M3**: thinking is off by default; set
///   `{type: "adaptive"}` to enable it (the model decides how much
///   to think). The `normal` (Crux preset) reasoning effort maps
///   to this adaptive shape — no `budget_tokens`. For `high` and
///   `max` efforts, the standard `{type: "enabled",
///   budget_tokens: …}` shape is used so the user has explicit
///   budget control. `{type: "disabled"}` keeps thinking off.
///
/// - **MiniMax-M2.x** (M2, M2.1, M2.5, M2.7 and their `-highspeed`
///   variants): thinking is always on and cannot be turned off.
///   Even `{type: "disabled"}` is ignored — the API still returns
///   thinking content. The `normal` effort uses the standard
///   `{type: "enabled", budget_tokens: …}` shape; there is no
///   adaptive mode for M2.x.
///
/// Display labels are configured via TOML, not hardcoded:
/// M3's `normal` → `adaptive` rename lives in `minimax.toml` under
/// the M3 model's `[models.reasoning_labels]` sub-table. M2.x models
/// have no such override, so `normal` displays as `normal`.
///
/// The provider also includes [CodingPlanProvider] so the
/// toolbar can display a live "Token Plan" usage readout while
/// any MiniMax model is active. The quota is queried via
/// `https://www.minimaxi.com/v1/token_plan/remains` using the
/// same API key as the chat endpoint.
class MiniMaxProvider extends AnthropicCompatibleProvider
    with CodingPlanProvider {
  @override
  String get name => 'minimax';

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  // ─── CodingPlanProvider implementation ──────────────────────

  /// The MiniMax coding-plan (Token Plan) "remains" endpoint.
  /// Same Bearer-token auth as the chat endpoint.
  @override
  Future<CodingPlanUsage> getCodingPlanUsage() async {
    // The mixin has the API key (it was passed to
    // `startCodingPlanPolling`); we read it back through the
    // mixin's stream-side. But the mixin doesn't expose the
    // key — it just stores it. Workaround: re-resolve via
    // [ProviderService]. For a single-provider TUI this is
    // the simplest path. See note on `currentCodingPlanApiKey`
    // below.
    final key = _currentCodingPlanApiKey;
    if (key == null) {
      throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.noApiKey,
        'No API key available for MiniMax coding-plan fetch',
      );
    }

    // The translation from raw `SocketException` / `TimeoutException`
    // to `CodingPlanUsageError` happens *outside* the wrapper so that
    // `withProxyRetry` can see the original connection error and
    // decide whether to retry through the system proxy. Translating
    // inside the attempt would hide the error class and the wrapper
    // would never trigger.
    return withProxyRetry<CodingPlanUsage>(
      enabled: isSystemProxyFallbackGloballyEnabled(),
      attempt: (proxy) async {
        final client = HttpClient();
        if (proxy != null) client.findProxy = proxy.findProxyFor;
        try {
          final request = await client
              .getUrl(Uri.parse(_codingPlanApiUrl))
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
            throw CodingPlanUsageError(
              CodingPlanUsageErrorKind.network,
              'HTTP ${response.statusCode} from $_codingPlanApiUrl',
            );
          }
          final body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 10));
          return parseCodingPlanUsageResponse(
            body,
            providerName: name,
            preferredModelName: 'general',
          );
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
      throw CodingPlanUsageError(
        CodingPlanUsageErrorKind.network,
        'Coding-plan usage fetch failed: $e',
      );
    });
  }

  /// The API endpoint the mixin's [getCodingPlanUsage] calls.
  /// Kept private to the provider so callers go through
  /// [startCodingPlanPolling] rather than hitting the URL
  /// directly.
  static const String _codingPlanApiUrl =
      'https://www.minimaxi.com/v1/token_plan/remains';

  /// The API key passed to [startCodingPlanPolling]. The
  /// mixin owns the timer / stream / cache, but the
  /// provider owns the key (the chat panel pulls it from
  /// `ProviderService` and threads it through). We stash it
  /// on a private field here so [getCodingPlanUsage] can
  /// read it back during a tick.
  String? _currentCodingPlanApiKey;

  @override
  void startCodingPlanPolling({
    required String apiKey,
    Duration? interval,
    String? baseUrl,
  }) {
    _currentCodingPlanApiKey = apiKey;
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
  }

  /// No class-level label overrides — all customization is done via
  /// TOML `[reasoning_labels]` (provider or model level). The base
  /// class defaults (off/low/normal/high/max) are used as-is.

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
    final systemMsg = messages.where((m) => m['role'] == 'system').toList();
    final chatMsgs = messages.where((m) => m['role'] != 'system').toList();
    final isM3 = _isM3(modelId);
    final body = <String, dynamic>{
      'model': modelId,
      'messages': injectCacheBreakpoints(chatMsgs),
      'max_tokens': maxTokens ?? 16384,
      'stream': true,
      'temperature': temperature,
      // Nucleus-sampling ceiling — derived from `temperature` by
      // `chat_turn_executor.topPForTemperature`. MiniMax's
      // Anthropic-compatible wire accepts [0.0, 1.0].
      'top_p': topP,
    };
    if (systemMsg.isNotEmpty) {
      body['system'] = buildCachedSystemBlocks(systemMsg);
    }

    if (isM3) {
      // ── M3: thinking is off by default; adaptive/controlled by
      // the user's preset choice. ──
      if (thinkingMode == 'disabled') {
        // Off: omit the `thinking` block entirely so the server
        // treats the request as a non-thinking call. Using
        // `{type: 'disabled'}` is also accepted by the API, but
        // omission is what the AI SDK emits
        // (`expect(requestBody.thinking).toBeUndefined()` for
        // `reasoning: 'none'`). Match that.
      } else if (reasoningEffort == 'normal') {
        // M3 "normal" override: adaptive thinking — the model
        // decides how much to think, no budget_tokens. The AI SDK
        // unit test `should send adaptive thinking without
        // budget_tokens` is explicit about this
        // (`expect(requestBody.thinking.budget_tokens).toBeUndefined()`).
        body['thinking'] = {'type': 'adaptive'};
        body['output_config'] = {'effort': super.mapEffort(reasoningEffort)};
      } else {
        // Budget-driven path: emit `thinking: {type: "enabled",
        // budget_tokens: ...}` plus `output_config.effort` for
        // depth control. Used for `low`, `high`, and `max` (and
        // any future non-adaptive efforts).
        body['thinking'] = {
          'type': 'enabled',
          'budget_tokens': thinkingBudget ?? 10000,
        };
        body['output_config'] = {'effort': super.mapEffort(reasoningEffort)};
      }
    } else {
      // ── M2.x: thinking is always on, cannot be disabled. The
      // API ignores `thinking.type = "disabled"` and still
      // returns thinking content. Emit the standard enabled
      // shape regardless of the user's thinking-mode toggle,
      // but honour reasoning effort for budget control. ──
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': thinkingBudget ?? 10000,
      };
      if (reasoningEffort != null) {
        body['output_config'] = {'effort': super.mapEffort(reasoningEffort)};
      }
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = buildCachedTools(tools);
    }
    return body;
  }

  /// Returns `true` for MiniMax-M3 models that support adaptive
  /// thinking. M2.x models have thinking always on and do not
  /// support the `adaptive` type.
  ///
  /// Note: this is used only for wire-format decisions in
  /// [buildRequestBody], not for display labels (those are
  /// configured via TOML `reasoning_labels`).
  static bool _isM3(String modelId) {
    final lower = modelId.toLowerCase();
    return lower == 'minimax-m3';
  }
}
