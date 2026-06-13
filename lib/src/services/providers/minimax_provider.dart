import '../../models/provider_config.dart';
import '../llm_provider.dart';
import '../providers/anthropic_compatible_provider.dart';

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
class MiniMaxProvider extends AnthropicCompatibleProvider {
  @override
  String get name => 'minimax';

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

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
        body['output_config'] = {
          'effort': super.mapEffort(reasoningEffort),
        };
      } else {
        // Budget-driven path: emit `thinking: {type: "enabled",
        // budget_tokens: ...}` plus `output_config.effort` for
        // depth control. Used for `low`, `high`, and `max` (and
        // any future non-adaptive efforts).
        body['thinking'] = {
          'type': 'enabled',
          'budget_tokens': thinkingBudget ?? 10000,
        };
        body['output_config'] = {
          'effort': super.mapEffort(reasoningEffort),
        };
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
        body['output_config'] = {
          'effort': super.mapEffort(reasoningEffort),
        };
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
