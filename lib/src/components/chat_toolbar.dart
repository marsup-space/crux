// Unicode-width calculation lives in nocterm's `lib/src/`. The chat toolbar
// uses it to measure CJK/emoji display widths for the streaming indicator
// and branch-selector labels. Not re-exported by `package:nocterm/nocterm.dart`.
// ignore_for_file: implementation_imports

import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/utils/unicode_width.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/chat_service.dart';
import '../services/llm_provider.dart';
import '../services/provider_service.dart';
import '../services/providers/coding_plan_provider.dart';
import '../services/providers/credit_balance_provider.dart';
import '../theme/crux_theme.dart';
import '../utils/frame_profiler.dart';
import 'coding_plan_usage_display.dart';
import 'credit_balance_display.dart';
import 'context_bar.dart';
import 'metrics_display.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import 'ui/button.dart';
import 'ui/glossy_model_button.dart';

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
        component.compactEstimate);
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
    // The auxiliary model is only used for side tasks (session-title
    // generation, TLDR summaries) — never for the in-flight chat
    // response — so it's safe to swap while the main model is busy.
    // [AuxiliaryService._streamAuxiliaryCall] resolves the
    // provider/key/model id once at the start of each call, so a
    // mid-flight change takes effect on the *next* auxiliary call
    // without disturbing the one currently in flight. The main-model
    // button (above) is the one that needs to stay disabled while
    // the session is running.
    return GlossyModelButton(
      label: '$_kIconAuxiliary ${_sessionController.auxiliaryModelShortName}',
      isAnimating: isAuxBusy,
      onPressed: component.onAuxiliaryPressed,
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
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        const btnPad = 2;
        const spacer = 2;
        const smallSpacer = 1;

        final modelW = UnicodeWidth.stringWidth(modelLabel) + btnPad;
        final imageW =
            _modelSupportsImages(_sessionController.currentSession.model)
            ? UnicodeWidth.stringWidth(_kIconImage)
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

        var remaining = constraints.maxWidth.toInt() - 2 - modelW - imageW;

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

        return Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
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
                    padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                  ),
                ),
              if (showContext) ...[
                Text(
                  '  ',
                  style: TextStyle(color: CruxTheme.of(context).divider),
                ),
                Hinted(
                  hint: isSessionRunning
                      ? 'Context window usage.\n'
                            'Compaction unavailable while the agent '
                            'is responding.'
                      : 'Context window usage.\n'
                            'Click to compact the session history.',
                  child: _buildContextBar(context),
                ),
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
