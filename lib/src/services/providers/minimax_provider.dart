import '../../models/provider_config.dart';
import '../providers/anthropic_compatible_provider.dart';

/// Provider for the MiniMax Anthropic-compatible endpoint.
///
/// The MiniMax quirk vs. plain Anthropic-compatible endpoints is the
/// `thinking` shape: this API accepts `{type: "adaptive"}` (no
/// `budget_tokens`) instead of `{type: "enabled", budget_tokens: ...}`.
/// Adaptive is a model-side decision — the server chooses how much to
/// think — and `budget_tokens` is intentionally absent. The AI SDK unit
/// test `should send adaptive thinking without budget_tokens` is
/// explicit about this (`expect(requestBody.thinking.budget_tokens)
/// .toBeUndefined()`).
///
/// Reasoning depth is steered via the sibling
/// `output_config: {effort: <low|medium|high|max>}` field. Crux's
/// user-facing preset vocabulary is `off|normal|high|max`; the `normal`
/// rename to wire `medium` happens in the shared
/// [AnthropicCompatibleProvider.mapEffort] helper, which we reuse via
/// `super.mapEffort` rather than duplicating the switch.
///
/// If a future model under this provider does *not* support adaptive
/// thinking, callers can fall back to the budget-driven path by passing
/// a non-null `thinkingBudget` *and* a non-disabled `thinkingMode` — we
/// then emit `thinking: {type: "enabled", budget_tokens: ...}` instead.
/// The MiniMax model line currently advertises adaptive thinking, so
/// this branch is opt-in safety rather than the default.
class MiniMaxProvider extends AnthropicCompatibleProvider {
  @override
  String get name => 'minimax';

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

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
    } else if (thinkingBudget != null) {
      // Budget-driven path: model doesn't support adaptive, or caller
      // explicitly opted into the legacy `enabled` + `budget_tokens`
      // shape. The server may still cap the budget at `max_tokens - 1`.
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': thinkingBudget,
      };
    } else {
      // Default MiniMax path: adaptive thinking, no budget, effort
      // steered via `output_config.effort` below.
      body['thinking'] = {'type': 'adaptive'};
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
