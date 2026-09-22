import '../../models/provider_config.dart';
import 'openai_compatible_provider.dart';

/// Provider for the [Xiaomi MiMo](https://mimo.mi.com/docs) API.
///
/// MiMo exposes an OpenAI Chat Completions-compatible endpoint at
/// `https://api.xiaomimimo.com/v1/chat/completions`. This provider
/// extends [OpenAICompatibleProvider] for URL, Bearer auth, and SSE
/// parsing, and layers MiMo-specific request-body quirks on top.
///
/// ## Wire-format quirks
///
/// 1. **No `reasoning_effort` knob.** MiMo only understands the
///    binary `thinking.type: enabled/disabled` field. Passing
///    `reasoning_effort` (an OpenAI o-series concept) is ignored by
///    the upstream, so we strip it from the generic
///    OpenAI-compatible body.
///
/// 2. **Temperature / top_p are forced in thinking mode.** MiMo's
///    `mimo-v2.6` and `mimo-v2.6-pro` models ignore any custom
///    `temperature` or `top_p` while thinking is enabled and silently
///    use their recommended defaults (`1.0` and `0.95`). To keep the
///    toolbar honest about what the server will actually use, we
///    pin those values on the wire whenever thinking is on.
///
///    - Thinking enabled → `temperature: 1.0`, `top_p: 0.95`.
///    - Thinking disabled → caller's `temperature`/`top_p` are
///      honored (MiMo supports `temperature` in `[0.0, 1.5]` and
///      `top_p` in `(0.0, 1.0]` in non-thinking mode).
///
/// 3. **`reasoning_content` pass-back.** MiMo requires the assistant's
///    `reasoning_content` to be returned on subsequent turns when
///    thinking is enabled and the history contains tool calls. Crux's
///    OpenAI-IR already preserves `reasoning_content` on assistant
///    messages, and the inherited
///    [OpenAICompatibleProvider.sanitizeMessages] handles tool-call
///    pairing; no extra MiMo-specific sanitizer is needed.
///
/// 4. **Auth header.** MiMo accepts either `Authorization: Bearer`
///    or `api-key: $KEY`. We use the Bearer style already used by
///    the OpenAI-compatible family.
///
/// ## No credit-balance endpoint
///
/// MiMo's inference API exposes **no** key-authenticated balance
/// endpoint. Verified against the official docs sitemap (the API
/// section only documents chat / responses / list-models / audio
/// endpoints) and empirically: `/v1/user/balance`, `/v1/balance`,
/// `/v1/credits`, and the OpenAI billing-style
/// `/v1/dashboard/billing/*` paths all 404 on `api.xiaomimimo.com`,
/// while the known endpoints (`/v1/chat/completions`) respond with
/// the documented 401 error shape — the probes are valid, the
/// balance surface simply does not exist.
///
/// Balance is visible only in the web console at
/// `https://platform.xiaomimimo.com/#/console/balance`. This
/// provider therefore does NOT mix in [CreditBalanceProvider] —
/// unlike DeepSeek (`/user/balance`) there is nothing a Crux-side
/// API-key call can fetch. If MiMo ships a documented
/// key-authenticated balance API later, mix in the mixin and
/// implement `getCreditBalance` following the DeepSeek provider.
///
/// ## Model configuration
///
/// See `providers/mimo.toml` for the bundled model list. MiMo
/// publishes the `mimo-v2.6` series (`mimo-v2.6-pro`,
/// `mimo-v2.6-flash`, `mimo-v2.6-pro-ultraspeed`). All three are
/// advertised as natively multimodal (text/image/video/audio input),
/// so vision input is enabled in the TOML for every entry. The
/// deprecated `mimo-v2.5` series was removed from the TOML — per
/// https://mimo.mi.com/docs/welcome, `mimo-v2.5-pro` and
/// `mimo-v2.5` stop being served on 2026-10-21 10:00 (GMT+8).
class MimoProvider extends OpenAICompatibleProvider {
  @override
  String get name => 'mimo';

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  /// MiMo's thinking-enabled models ignore any caller-provided
  /// temperature and use `1.0` on the server. Expose that as a
  /// fixed chip in the toolbar so the UI doesn't imply the user can
  /// change it while thinking is on (Crux's default mode for MiMo).
  @override
  double? get forcedTemperature => _mimoThinkingTemperature;

  /// MiMo-recommended sampling values while thinking is enabled.
  static const double _mimoThinkingTemperature = 1.0;
  static const double _mimoThinkingTopP = 0.95;

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

    // MiMo does not support OpenAI's `reasoning_effort`; it only
    // understands the binary `thinking.type` field emitted by the
    // base class. Remove the spurious key so the wire shape matches
    // the documented request examples.
    body.remove('reasoning_effort');

    if (thinkingMode != 'disabled') {
      // When thinking is enabled, MiMo ignores any user-provided
      // temperature/top_p and silently applies its recommended
      // defaults. Pin those values explicitly so the request body
      // matches what the server will actually use.
      body['temperature'] = _mimoThinkingTemperature;
      body['top_p'] = _mimoThinkingTopP;
    }

    return body;
  }
}
