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
/// Because adaptive thinking is an M3-only feature, the UI only
/// shows the `adaptive` label (renamed from `normal`) when the
/// current model is M3. M2.x models show `normal` as `normal` —
/// the same as every other provider.
class MiniMaxProvider extends AnthropicCompatibleProvider {
  @override
  String get name => 'minimax';

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  @override
  List<ReasoningPreset> reasoningPresetsFor(String modelId) {
    if (_isM3(modelId)) {
      // M3: rename `normal` to `adaptive` so the user can see the
      // connection between the preset and M3's adaptive-thinking
      // wire format.
      return const [
        ReasoningPreset(internalValue: 'off', displayLabel: 'off'),
        ReasoningPreset(internalValue: 'low', displayLabel: 'low'),
        ReasoningPreset(internalValue: 'normal', displayLabel: 'adaptive'),
        ReasoningPreset(internalValue: 'high', displayLabel: 'high'),
        ReasoningPreset(internalValue: 'max', displayLabel: 'max'),
      ];
    }
    // M2.x and any other MiniMax model: show `normal` as `normal`,
    // matching every other provider. M2.x doesn't support
    // adaptive thinking, so the rename would be misleading.
    return const [
      ReasoningPreset(internalValue: 'off', displayLabel: 'off'),
      ReasoningPreset(internalValue: 'low', displayLabel: 'low'),
      ReasoningPreset(internalValue: 'normal', displayLabel: 'normal'),
      ReasoningPreset(internalValue: 'high', displayLabel: 'high'),
      ReasoningPreset(internalValue: 'max', displayLabel: 'max'),
    ];
  }

  /// Returns `true` for MiniMax-M3 models that support adaptive
  /// thinking. M2.x models have thinking always on and do not
  /// support the `adaptive` type.
  static bool _isM3(String modelId) {
    final lower = modelId.toLowerCase();
    // Match "minimax-m3" exactly — M2.7, M2.5, M2.1, M2 are NOT M3.
    // Model IDs come in forms like "MiniMax-M3", "minimax-m3", etc.
    return lower == 'minimax-m3';
  }

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
}
