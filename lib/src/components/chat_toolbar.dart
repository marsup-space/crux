// Unicode-width calculation lives in nocterm's `lib/src/`. The chat toolbar
// uses it to measure CJK/emoji display widths for the streaming indicator
// and branch-selector labels. Not re-exported by `package:nocterm/nocterm.dart`.
// ignore_for_file: implementation_imports

import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/utils/unicode_width.dart';
import 'package:nocterm_bloc/nocterm_bloc.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/chat_service.dart';
import '../services/llm_provider.dart';
import '../services/provider_service.dart';
import '../services/providers/coding_plan_provider.dart';
import '../services/providers/credit_balance_provider.dart';
import '../theme/crux_theme.dart';
import '../utils/frame_profiler.dart';
import '../utils/sampling.dart';
import 'coding_plan_usage_display.dart';
import 'credit_balance_display.dart';
import 'context_bar.dart';
import 'metrics_display.dart';
import 'session_controller.dart';
import 'session_cubit.dart';
import 'streaming_controller.dart';
import 'ui/button.dart';
import 'ui/glossy_model_button.dart';
import 'ui/layout_metrics.dart';

/// Toolbar icons — safe BMP symbols that render as 1 cell, monochrome, in
/// every Unicode-capable terminal. Previously these were Nerd Font PUA
/// codepoints (U+F0EB, U+F06E, U+F013), which produced tofu for users
/// without a Nerd Font and also caused a 1-cell-per-icon layout drift
/// because `UnicodeWidth.stringWidth()` returns 0 for PUA.
const _kIconReasoning = '\u{2736}'; // ✶ — six-pointed star
const _kIconImage = '\u{25A3}'; // ▣ — square with inner shape (image badge)
const _kIconAuxiliary = '\u{203A}'; // › — right chevron

/// The toolbar above the input box showing model name, thinking mode,
/// context bar, metrics (tok/s, TTFT), coding-plan usage, credit
/// balance, and auxiliary model button.
///
/// The coding-plan usage display is opt-in: it's only rendered when
/// [codingPlanProvider] is non-null. The chat panel passes the
/// `CodingPlanProvider` mixin instance of the active provider —
/// providers that include the mixin (currently just MiniMax) get
/// a quota cell.
///
/// The credit balance display is opt-in: it's only rendered when
/// [creditBalanceProvider] is non-null. Providers that include the
/// `CreditBalanceProvider` mixin (currently just DeepSeek) get a
/// balance cell.
class ChatToolbar extends StatefulComponent {
  final SessionController sessionController;
  final StreamingController streamingController;
  final ProviderService providerService;
  final bool providerServiceReady;

  /// The active provider's coding-plan mixin instance, or null
  /// if the active provider doesn't have a coding plan (or no
  /// API key is set). The chat panel resolves this on every
  /// build and passes it through; the toolbar just plumbs it
  /// to the widget and budgets layout when it's non-null.
  final CodingPlanProvider? codingPlanProvider;

  /// The active provider's credit-balance mixin instance, or
  /// null if the active provider doesn't have a credit balance
  /// (or no API key is set). The chat panel resolves this on
  /// every build and passes it through; the toolbar just
  /// plumbs it to the widget and budgets layout when it's
  /// non-null.
  final CreditBalanceProvider? creditBalanceProvider;

  /// Called when the user clicks the coding-plan usage display
  /// to force an immediate refresh via the provider's
  /// [CodingPlanProvider.refreshNow].
  final VoidCallback? onCodingPlanTap;

  /// Called when the user clicks the credit balance display
  /// to force an immediate refresh via the provider's
  /// [CreditBalanceProvider.refreshNow].
  final VoidCallback? onCreditBalanceTap;

  /// Called when the user clicks the temperature chip (the small
  /// `T:0.5` readout that appears next to the image modality
  /// badge when a temperature override is in effect). Wired by the
  /// chat panel to `stashAndSetCommand('/temperature ')` so the
  /// user lands in the input with a fresh `/temperature ` prefix
  /// ready to retype.
  final VoidCallback? onTemperaturePressed;

  final SessionRuntimeState? runtime;
  final int contextMaxTokens;
  final void Function() onModelPressed;
  final void Function() onCompactPressed;
  final void Function() onAuxiliaryPressed;
  final void Function(SessionRuntimeState) onCycleThinking;

  /// Pre-projected compaction result for the current session.
  /// Forwarded to [ContextBar] so its hover label can show
  /// `preTokens → postTokens` (e.g. `123k → 56k`) instead of
  /// the bare `Compact` action label — the user sees the
  /// expected result of clicking the bar before committing.
  final ChatLogCompactionEstimate? compactEstimate;

  /// When true, the context bar's hover label always shows the
  /// projection (e.g. `143k → 145k`) instead of `143k · skip`,
  /// even when the savings are below the 5% threshold. Used by
  /// `/debug` so the user can see the projection itself and
  /// diagnose why the skip gate is firing. Wired from
  /// [CommandRegistry.debugEnabled] by the chat panel.
  final bool debugMode;

  const ChatToolbar({
    super.key,
    required this.sessionController,
    required this.streamingController,
    required this.providerService,
    required this.providerServiceReady,
    required this.runtime,
    required this.contextMaxTokens,
    required this.onModelPressed,
    required this.onCompactPressed,
    required this.onAuxiliaryPressed,
    required this.onCycleThinking,
    this.compactEstimate,
    this.codingPlanProvider,
    this.creditBalanceProvider,
    this.onCodingPlanTap,
    this.onCreditBalanceTap,
    this.onTemperaturePressed,
    this.debugMode = false,
  });

  @override
  State<ChatToolbar> createState() => _ChatToolbarState();
}

class _ChatToolbarState extends State<ChatToolbar> {
  // The `_metricsHovered` state used to live here so the
  // inline tok/s Text could swap to a cache-hit label on
  // hover. After the [MetricsDisplay] extraction, hover
  // state is owned by the metrics widget itself — keeping
  // a duplicate here would just be dead state.

  SessionController get _sessionController => component.sessionController;
  StreamingController get _streamingController => component.streamingController;
  ProviderService get _providerService => component.providerService;
  SessionRuntimeState? get _rt => component.runtime;

  bool _modelSupportsImages(String compositeKey) {
    if (!component.providerServiceReady) return false;
    return _providerService.imageModelKeys().contains(compositeKey);
  }

  bool _modelSupportsThinking(String compositeKey) {
    if (!component.providerServiceReady) return false;
    final mc = _providerService.modelByCompositeKey(compositeKey);
    return mc?.thinking == true || mc?.reasoningEffort != null;
  }

  List<ReasoningPreset> _currentReasoningPresets() {
    final modelKey = _sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : '';
    final llm = _providerService.llmProviderByName(providerName);
    if (llm == null) return const [];
    final modelId = slashIdx > 0 ? modelKey.substring(slashIdx + 1) : modelKey;
    final provider = _providerService.providerByName(providerName);
    final modelConfig = provider?.modelById(modelId);
    return llm.reasoningPresetsFor(
      modelId,
      providerLabels: provider?.reasoningLabels ?? const {},
      modelLabels: modelConfig?.reasoningLabels ?? const {},
    );
  }

  String _displayEffort(String effort) {
    final presets = _currentReasoningPresets();
    for (final p in presets) {
      if (p.internalValue == effort) return p.displayLabel;
    }
    return effort;
  }

  String _thinkingLabel(SessionRuntimeState rt) {
    final effort = rt.thinkingMode == 'disabled'
        ? 'off'
        : _displayEffort(rt.reasoningEffort ?? 'normal');
    return '$_kIconReasoning ${effort.padRight(4)}';
  }

  // The old _cacheHitLabel helper moved to [MetricsDisplay],
  // which owns the live tok/s readout and the cache-hit
  // hover label. Keeping a no-op shim here would just be
  // dead code; the helper was only used by the inline
  // metrics row that this refactor replaced.

  Component _buildContextBar(BuildContext context) {
    // Delegate to the dedicated [ContextBar] widget, which
    // owns its own 16ms lerp [Timer] and only rebuilds itself
    // (not the whole chat panel) when the displayed value
    // changes. Previously this method read
    // `rt.contextDisplayTokens` directly, which was the value
    // a streaming-controller timer updated every 16ms via a
    // chat-panel-wide `_refresh()`. That caused an 80ms full
    // relayout on every tick — the 12-FPS bottleneck the
    // profiler exposed via `byLayout`.
    //
    // While the session is running, manual compaction is
    // unsafe (it would tear down mid-flight tokens). Disable
    // the click here at the UX level so the bar doesn't
    // advertise an action it can't perform; the runtime guard
    // in `compactCurrentSession` is a backstop.
    final isSessionRunning =
        _sessionController.currentSession.status == SessionStatus.running;
    // When the projection says "skip" (post > pre), the click
    // is a no-op. We don't set `disabled: true` here because
    // that would hide the projection on hover (the bar falls
    // back to the idle `X / Y` label), which is the only way the
    // user finds out the click won't do anything. Instead, set
    // `onTap: null` so the gesture detector drops the click
    // while the hover label keeps showing `X · skip`.
    final isSkip = ContextBarState.isCompactCounterproductive(
      component.compactEstimate,
    );
    return ContextBar(
      sessionController: _sessionController,
      streamingController: _streamingController,
      contextMaxTokens: component.contextMaxTokens,
      compactEstimate: component.compactEstimate,
      // Even in `/debug` mode where the hover label reveals the
      // projection, we still gate the click on the 5% threshold.
      // Debug mode is for inspection, not override — the user
      // wants to see WHY the gate fired, not bypass it.
      onTap: isSkip ? null : component.onCompactPressed,
      disabled: isSessionRunning,
      debugMode: component.debugMode,
    );
  }

  Component _buildAuxiliaryModelButton(BuildContext context) {
    final sessionId = _sessionController.currentSessionId;
    final rt = sessionId != null ? _sessionController.runtime(sessionId) : null;
    final isAuxBusy =
        _sessionController.isGeneratingTitle || (rt?.isGeneratingTldr ?? false);
    // Subscribe to the auxiliary-model short-name through a
    // BlocSelector<SessionCubit, String> so this button only
    // rebuilds when that one field changes. Re-renders triggered
    // by anything else in the cubit state (session list, message
    // cache, pending images, …) are dropped at the selector
    // boundary, so the auxiliary section does not pay the cost of
    // a full chat-panel refresh just to keep its label up to date.
    //
    // The auxiliary model is only used for side tasks (session-title
    // generation, TLDR summaries) — never for the in-flight chat
    // response — so it's safe to swap while the main model is busy.
    // [AuxiliaryService._streamAuxiliaryCall] resolves the
    // provider/key/model id once at the start of each call, so a
    // mid-flight change takes effect on the *next* auxiliary call
    // without disturbing the one currently in flight. The main-model
    // button (above) is the one that needs to stay disabled while
    // the session is running.
    return BlocSelector<SessionCubit, SessionCubitState, String>(
      selector: (state) => state.auxiliaryModelShortName,
      builder: (context, auxShortName) => GlossyModelButton(
        label: '$_kIconAuxiliary $auxShortName',
        isAnimating: isAuxBusy,
        onPressed: component.onAuxiliaryPressed,
      ),
    );
  }

  /// Whether the active provider opted into the coding-plan
  /// mixin (and thus has a stream to subscribe to). The
  /// toolbar hides the quota cell when this is false so
  /// non-coding-plan providers (DeepSeek, Local, custom)
  /// don't get a stray "5h 100% / 1w 100%" tag in their
  /// toolbar.
  bool _hasCodingPlanProvider() => component.codingPlanProvider != null;

  /// Whether the active provider opted into the credit-balance
  /// mixin (and thus has a stream to subscribe to). The
  /// toolbar hides the balance cell when this is false so
  /// non-credit-balance providers (MiniMax, Local, custom)
  /// don't get a stray balance tag in their toolbar.
  bool _hasCreditBalanceProvider() => component.creditBalanceProvider != null;

  /// The model's TOML-configured `temperature` default (i.e. what
  /// the user gets when no override is in effect). `null` when the
  /// model can't be resolved — the chip's hover hint then omits the
  /// "default" line rather than printing a number we can't verify.
  double? _modelDefaultTemperature() {
    if (!component.providerServiceReady) return null;
    final modelKey = _sessionController.currentSession.model;
    if (modelKey.isEmpty) return null;
    return _providerService.modelByCompositeKey(modelKey)?.temperature;
  }

  /// Build the `T:0.5` chip that surfaces the active temperature
  /// override beside the image modality badge. Returns `null`
  /// when the chip should be hidden — specifically:
  ///
  ///   - No runtime is attached (transient state during session
  ///     switch).
  ///   - No override is in effect, OR
  ///   - The override equals the model's TOML default (showing
  ///     the chip would be visually misleading — the effective
  ///     temperature is the model default either way).
  ///
  /// The chip is visually identical to the thinking label so it
  /// reads as another "this session is configured with X" affordance.
  /// Clicking it dumps `/temperature ` into the chat input so the
  /// user can immediately retype a new value. The click is disabled
  /// while the session is running — typing in the input while the
  /// agent is streaming would race with the active chat service.
  Component? _buildTemperatureChip(
    BuildContext context,
    bool isSessionRunning,
  ) {
    final rt = _rt;
    final override = rt?.temperatureOverride;

    // If the active provider pins a fixed temperature (Kimi
    // Code: `1.0` for every model, with the API 400ing on any
    // other value), render a non-interactive "T:1 (fixed)" chip
    // regardless of the override. The override's wire value
    // would be silently overridden by the provider, so showing
    // the user's value here would be misleading.
    final fixedTemp = _providerForcedTemperature();
    if (fixedTemp != null) {
      final label = 'T:${formatSamplingValue(fixedTemp)} (fixed)';
      final hint =
          'Temperature: ${formatSamplingValue(fixedTemp)} '
          '(fixed by the provider — /temperature has no effect)';
      return Hinted(
        hint: hint,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: kContentHorizontalPadding,
            vertical: 0,
          ),
          child: Text(
            label,
            style: TextStyle(color: CruxTheme.of(context).onSurfaceVariant),
          ),
        ),
      );
    }

    if (rt == null || override == null) return null;

    final modelDefault = _modelDefaultTemperature();
    // If the user typed the model's default temperature as an
    // override, the chip would say "T:0" while the actual sampling
    // config is already the model's default — visually misleading.
    // Suppress in that case. Compare with a small epsilon for
    // float drift (the runtime value comes from `double.tryParse`
    // of the user input, the model default from TOML — same
    // semantic value but possibly different bit-level doubles).
    if (modelDefault != null && (override - modelDefault).abs() < 1e-9) {
      return null;
    }

    final topP = topPForTemperature(override);
    final label = 'T:${formatSamplingValue(override)}';

    // Hover hint surfaces the three pieces of context the user
    // actually needs: the current setting (echoed in the chip
    // label), the derived `top_p` the model will see, and the
    // model default so they know what they're overriding from.
    // The click affordance is repeated in the hint so users
    // who've never seen the chip before know it's interactive.
    final buffer = StringBuffer()
      ..writeln('Temperature: ${formatSamplingValue(override)}')
      ..writeln('top_p = ${formatSamplingValue(topP)}');
    if (modelDefault != null) {
      buffer.writeln('Model default: ${formatSamplingValue(modelDefault)}');
    } else {
      buffer.writeln('Model default: (unknown)');
    }
    buffer.writeln('(click to change)');
    final hint = buffer.toString();

    return Hinted(
      hint: hint.trimRight(),
      child: Button(
        label: label,
        onPressed: isSessionRunning ? null : component.onTemperaturePressed,
        // Theme: match the thinking-label color so the chip reads
        // as "another knob you've tuned" — but a different hue so
        // the user can tell at a glance that it's not the
        // thinking level. Pick something distinct from the disabled
        // thinking color to avoid collisions on the off state.
        color: CruxTheme.of(context).onSurfaceVariant,
        hoverColor: CruxTheme.of(context).buttonTextHover,
        bgColor: CruxTheme.of(context).buttonBackground,
        hoverBgColor: CruxTheme.of(context).buttonBackgroundHover,
        padding: EdgeInsets.symmetric(
          horizontal: kContentHorizontalPadding,
          vertical: 0,
        ),
      ),
    );
  }

  /// The provider-pinned temperature for the active model, or
  /// `null` if the provider passes the caller's value through
  /// unchanged. Reads from
  /// [LlmProvider.forcedTemperature] on the resolved
  /// [LlmProvider] for the current session's model.
  double? _providerForcedTemperature() {
    if (!component.providerServiceReady) return null;
    final modelKey = _sessionController.currentSession.model;
    if (modelKey.isEmpty) return null;
    final slashIdx = modelKey.indexOf('/');
    if (slashIdx <= 0) return null;
    final providerName = modelKey.substring(0, slashIdx);
    final llm = _providerService.llmProviderByName(providerName);
    return llm?.forcedTemperature;
  }

  @override
  Component build(BuildContext context) {
    return FrameProfiler.instance.timed(
      'chatToolbar.build',
      () => _buildInner(context),
    );
  }

  Component _buildInner(BuildContext context) {
    final modelLabel = _sessionController.currentSession.model.isEmpty
        ? 'select model'
        : _sessionController.currentSession.model;
    final rt = _rt;
    final isSessionRunning =
        _sessionController.currentSession.status == SessionStatus.running;

    final modelButton = isSessionRunning
        ? GlossyModelButton(
            label: modelLabel,
            isAnimating: true,
            onPressed: null, // Not clickable during streaming
          )
        : Button(
            label: modelLabel,
            onPressed: component.onModelPressed,
            color: CruxTheme.of(context).onSurfaceVariant,
            hoverColor: CruxTheme.of(context).buttonTextHover,
            bgColor: CruxTheme.of(context).buttonBackground,
            hoverBgColor: CruxTheme.of(context).buttonBackgroundHover,
            padding: EdgeInsets.symmetric(
              horizontal: kContentHorizontalPadding,
              vertical: 0,
            ),
          );

    // Pre-compute the temperature chip label and width budget
    // BEFORE LayoutBuilder so the budget check knows to either
    // reserve room or skip it. The visibility rule mirrors the
    // chip builder's: hide when no override, or when the override
    // equals the model default (visually misleading to show
    // "T:0" when the effective temperature IS already the model
    // default of 0).
    //
    // When the provider pins a fixed temperature (Kimi Code
    // forces `1.0` for every model), the label reflects the
    // pinned value, not the caller's override. The override is
    // silently discarded on the wire, so showing its value
    // would be misleading — and the chip's own "T:1 (fixed)"
    // label is what the user actually needs to see.
    final fixedTemp = _providerForcedTemperature();
    final tempOverride = rt?.temperatureOverride;
    final tempModelDefault = _modelDefaultTemperature();
    final tempSuppressesChip =
        tempOverride != null &&
        tempModelDefault != null &&
        (tempOverride - tempModelDefault).abs() < 1e-9;
    final tempLabel = fixedTemp != null
        ? 'T:${formatSamplingValue(fixedTemp)} (fixed)'
        : (tempOverride != null && !tempSuppressesChip)
        ? 'T:${formatSamplingValue(tempOverride)}'
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        const btnPad = kToolbarButtonPadding;
        const spacer = kToolbarChipGap;
        const smallSpacer = kToolbarTightGap;

        final modelW = UnicodeWidth.stringWidth(modelLabel) + btnPad;
        final imageW =
            _modelSupportsImages(_sessionController.currentSession.model)
            ? UnicodeWidth.stringWidth(_kIconImage)
            : 0;
        // Temperature chip width is computed here (inside the
        // LayoutBuilder where `btnPad` is in scope) so the budget
        // check below can decide whether to reserve room for it
        // or skip it. The `tempLabel` itself is computed outside
        // the builder — the model-default suppression check needs
        // the runtime + provider data, none of which depends on
        // layout constraints.
        final tempW = tempLabel != null
            ? UnicodeWidth.stringWidth(tempLabel) + btnPad
            : 0;
        final thinkingLabel =
            (rt != null &&
                _modelSupportsThinking(_sessionController.currentSession.model))
            ? _thinkingLabel(rt)
            : null;
        final thinkingW = thinkingLabel != null
            ? UnicodeWidth.stringWidth(thinkingLabel) + btnPad
            : 0;
        final contextW = 20 + spacer;
        // The metrics area is now a dedicated widget
        // ([MetricsDisplay]) that owns its own state. For
        // layout-width budgeting we still need a width
        // estimate, so use the worst-case (longest) form of
        // the strings it might display — over-estimating
        // here just means the area gets reserved when it
        // could be hidden, which is harmless.
        final tokW = '999.9 tok/s'.length + spacer;
        final ttftW = '999.99s'.length + smallSpacer;
        // Coding-plan usage readout width budget. The widget
        // shows itself (zero-width) when the active provider
        // opted into the CodingPlanProvider mixin. Reserve
        // worst-case room so a provider switch doesn't make
        // the toolbar relayout mid-keystroke. Worst case is
        // the hover-countdown shape: "  5h 4h 32m / 1w 6d 4h"
        // — 27 characters.
        final showCodingPlan = _hasCodingPlanProvider();
        final codingPlanW = showCodingPlan ? 27 + spacer : 0;
        // Credit balance readout width budget. Worst case is
        // the hover-breakdown shape:
        // "  ¥110.00 (¥100.00)" — 22 characters.
        final showCreditBalance = _hasCreditBalanceProvider();
        final creditBalanceW = showCreditBalance ? 22 + spacer : 0;
        final auxLabel =
            '$_kIconAuxiliary ${_sessionController.auxiliaryModelShortName}';
        final auxW = UnicodeWidth.stringWidth(auxLabel) + btnPad;

        var remaining =
            constraints.maxWidth.toInt() - kToolbarRowInset - modelW - imageW;

        final showTemp = tempLabel != null && (remaining - tempW) >= 0;
        if (showTemp) remaining -= tempW;

        final showThinking =
            thinkingLabel != null && (remaining - thinkingW) >= 0;
        if (showThinking) remaining -= thinkingW;

        final showContext = (remaining - contextW) >= 0;
        if (showContext) remaining -= contextW;

        final showTokPerSec = (remaining - tokW) >= 0;
        if (showTokPerSec) remaining -= tokW;

        final showTtft = (remaining - ttftW) >= 0;
        if (showTtft) remaining -= ttftW;

        final showCodingPlanUsage =
            showCodingPlan && (remaining - codingPlanW) >= 0;
        if (showCodingPlanUsage) remaining -= codingPlanW;

        final showCreditBalanceUsage =
            showCreditBalance && (remaining - creditBalanceW) >= 0;
        if (showCreditBalanceUsage) remaining -= creditBalanceW;

        final showAux = (remaining - auxW) >= 0;

        // At this point, if showThinking is true, rt is guaranteed
        // non-null. Promote it to avoid null-check noise below.
        final nonNullRt = rt;

        // Build the temperature chip only if the width budget
        // allows it. The builder is self-suppressing: when the
        // override equals the model default it returns null even
        // when called — `showTemp` only checks the first two
        // conditions, so a late suppression inside the builder
        // nulls out the children-list entry below without leaking
        // the no-longer-needed width budget.
        final temperatureChip = showTemp
            ? _buildTemperatureChip(context, isSessionRunning)
            : null;

        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: kContentHorizontalPadding,
            vertical: 0,
          ),
          child: Row(
            children: [
              // The model picker button. Hinted with the current
              // model so the user can tell at a glance which model
              // the next click will switch to. The default
              // 500 ms delay is what we want for toolbar buttons.
              Hinted(
                hint: isSessionRunning
                    ? 'Current model: $modelLabel\n(model cannot be changed while the agent is responding)'
                    : 'Current model: $modelLabel\n(click to change)',
                child: modelButton,
              ),
              if (_modelSupportsImages(_sessionController.currentSession.model))
                Hinted(
                  hint: 'This model accepts image inputs',
                  child: Text(
                    _kIconImage,
                    style: TextStyle(
                      color: CruxTheme.of(context).onSurfaceVariant,
                    ),
                  ),
                ),
              // Tiny `T:0.5` chip beside the image modality badge;
              // surfaces the active per-session temperature override.
              // Click puts `/temperature ` in the input so the user
              // can retype a new value. See `_buildTemperatureChip`
              // for the visibility rules.
              ?temperatureChip,
              if (showThinking && nonNullRt != null)
                Hinted(
                  hint:
                      'Thinking mode: '
                      '${_displayEffort(nonNullRt.reasoningEffort ?? 'normal')}\n'
                      '(click to cycle through effort levels)',
                  child: Button(
                    label: thinkingLabel,
                    onPressed: () => component.onCycleThinking(nonNullRt),
                    color: nonNullRt.thinkingMode == 'disabled'
                        ? CruxTheme.of(context).thinkingLabelDisabled
                        : CruxTheme.of(context).onSurfaceVariant,
                    hoverColor: CruxTheme.of(context).buttonTextHover,
                    bgColor: CruxTheme.of(context).buttonBackground,
                    hoverBgColor: CruxTheme.of(context).buttonBackgroundHover,
                    padding: EdgeInsets.symmetric(
                      horizontal: kContentHorizontalPadding,
                      vertical: 0,
                    ),
                  ),
                ),
              if (showContext) ...[
                Text(
                  '  ',
                  style: TextStyle(color: CruxTheme.of(context).divider),
                ),
                // No [Hinted] wrapper here — the context bar
                // owns its own hover hint via [HintStateMixin]
                // (see [ContextBarState.hintContent]). The
                // loaded-skills list is what should surface on
                // hover, not a generic "click to compact"
                // affordance; the click hint is already
                // conveyed by the in-bar label swap from `X / Y`
                // to `Compact` (see [ContextBarState._formatLabel]).
                _buildContextBar(context),
              ],
              if (showTokPerSec || showTtft)
                // Delegate the live tok/s + TTFT readout to
                // [MetricsDisplay], which owns its own 50ms
                // Timer and only rebuilds itself. The
                // chat panel does NOT get setState on every
                // tick anymore — that's the 2.4× speedup
                // landed earlier. Hover state (cache-hit %)
                // is also handled locally in the widget.
                Hinted(
                  hint:
                      'Generation throughput (tokens/sec) and '
                      'time to first token',
                  child: MetricsDisplay(
                    sessionController: _sessionController,
                    streamingController: _streamingController,
                    currentSessionId: _sessionController.currentSessionId,
                  ),
                ),
              if (showCodingPlanUsage && component.codingPlanProvider != null)
                // Coding-plan (Token Plan) usage readout.
                Hinted(
                  hint:
                      'Coding-plan usage\n'
                      '5h: short-window remaining\n'
                      '1w: weekly remaining\n'
                      'Click to refresh',
                  child: CodingPlanUsageDisplay(
                    stream: component.codingPlanProvider!.codingPlanUsageStream,
                    initialUsage:
                        component.codingPlanProvider!.latestCodingPlanUsage,
                    onTap: component.onCodingPlanTap,
                  ),
                ),
              if (showCreditBalanceUsage &&
                  component.creditBalanceProvider != null)
                // Credit balance readout. Hover for granted /
                // topped-up breakdown.
                Hinted(
                  hint:
                      'Credit balance\n'
                      'Hover for granted / topped-up breakdown\n'
                      'Click to refresh',
                  child: CreditBalanceDisplay(
                    stream:
                        component.creditBalanceProvider!.creditBalanceStream,
                    initialBalance:
                        component.creditBalanceProvider!.latestCreditBalance,
                    onTap: component.onCreditBalanceTap,
                  ),
                ),
              Expanded(child: SizedBox()),
              if (showAux)
                Hinted(
                  hint: isSessionRunning
                      ? 'Auxiliary model: '
                            '${_sessionController.auxiliaryModelShortName}\n'
                            '(cannot be changed while the agent is responding)'
                      : 'Auxiliary model: '
                            '${_sessionController.auxiliaryModelShortName}\n'
                            '(used for /tldr summaries and title generation)',
                  child: _buildAuxiliaryModelButton(context),
                ),
            ],
          ),
        );
      },
    );
  }
}
