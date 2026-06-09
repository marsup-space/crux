import '../../models/provider_config.dart';
import '../llm_provider.dart';
import '../providers/anthropic_compatible_provider.dart';

/// Provider for the MiniMax Anthropic-compatible endpoint.
///
/// The MiniMax quirk vs. plain Anthropic-compatible endpoints is the
/// `thinking` shape: the `normal` (Crux preset) reasoning effort maps
/// to `{type: "adaptive"}` (no `budget_tokens`) — the model decides
/// how much to think on its own. For `high` and `max` efforts, the
/// standard `{type: "enabled", budget_tokens: ...}` shape is used so
/// the user has explicit budget control.
///
/// The `normal` preset is displayed as `adaptive` in the UI (see
/// [reasoningPresets]), because MiniMax's wire format uses adaptive
/// thinking for this effort level. All other providers show `normal`
/// as `normal`.
class MiniMaxProvider extends AnthropicCompatibleProvider {
  @override
  String get name => 'minimax';

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  @override
  List<ReasoningPreset> get reasoningPresets => const [
        ReasoningPreset(internalValue: 'off', displayLabel: 'off'),
        ReasoningPreset(internalValue: 'normal', displayLabel: 'adaptive'),
        ReasoningPreset(internalValue: 'high', displayLabel: 'high'),
        ReasoningPreset(internalValue: 'max', displayLabel: 'max'),
      ];

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
    final body = <String, dynamic>{
      'model': modelId,
      'messages': injectCacheBreakpoints(chatMsgs),
      'max_tokens': maxTokens ?? 16384,
      'stream': true,
    };
    if (systemMsg.isNotEmpty) {
      body['system'] = buildCachedSystemBlocks(systemMsg);
    }

    if (thinkingMode == 'disabled') {
      // Off: omit the `thinking` block entirely so the server treats the
      // request as a non-thinking call. Using `{type: 'disabled'}` is
      // also accepted by the API, but omission is what the AI SDK emits
      // (`expect(requestBody.thinking).toBeUndefined()` for `reasoning:
      // 'none'`). Match that.
    } else if (reasoningEffort == 'normal') {
      // MiniMax "normal" override: adaptive thinking — the model
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
      // depth control. Used for `high` and `max` (and any
      // future non-adaptive efforts).
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': thinkingBudget ?? 10000,
      };
      body['output_config'] = {
        'effort': super.mapEffort(reasoningEffort),
      };
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = buildCachedTools(tools);
    }
    return body;
  }
}