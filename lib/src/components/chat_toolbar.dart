import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/utils/unicode_width.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/llm_provider.dart';
import '../services/provider_service.dart';
import '../theme/crux_theme.dart';
import '../utils/frame_profiler.dart';
import 'context_bar.dart';
import 'metrics_display.dart';
import 'session_controller.dart';
import 'streaming_controller.dart';
import 'ui/bg_progress_bar.dart';
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
/// context bar, metrics (tok/s, TTFT), and auxiliary model button.
class ChatToolbar extends StatefulComponent {
  final SessionController sessionController;
  final StreamingController streamingController;
  final ProviderService providerService;
  final bool providerServiceReady;
  final SessionRuntimeState? runtime;
  final int contextMaxTokens;
  final void Function() onModelPressed;
  final void Function() onCompactPressed;
  final void Function() onAuxiliaryPressed;
  final void Function(SessionRuntimeState) onCycleThinking;

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
    return ContextBar(
      sessionController: _sessionController,
      streamingController: _streamingController,
      contextMaxTokens: component.contextMaxTokens,
      onTap: component.onCompactPressed,
    );
  }

  Component _buildAuxiliaryModelButton(BuildContext context) {
    final sessionId = _sessionController.currentSessionId;
    final rt =
        sessionId != null ? _sessionController.runtime(sessionId) : null;
    final isAuxBusy = _sessionController.isGeneratingTitle ||
        (rt?.isGeneratingTldr ?? false);
    return GlossyModelButton(
      label: '$_kIconAuxiliary ${_sessionController.auxiliaryModelShortName}',
      isAnimating: isAuxBusy,
      onPressed: component.onAuxiliaryPressed,
    );
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
    final isResponding = rt?.isResponding ?? false;

    final modelButton = isResponding
        ? GlossyModelButton(
            label: modelLabel,
            isAnimating: true,
            onPressed: component.onModelPressed,
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
        final imageW = _modelSupportsImages(
                _sessionController.currentSession.model)
            ? UnicodeWidth.stringWidth(_kIconImage)
            : 0;
        final thinkingLabel = (rt != null &&
                _modelSupportsThinking(
                    _sessionController.currentSession.model))
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
        final auxLabel =
            '$_kIconAuxiliary ${_sessionController.auxiliaryModelShortName}';
        final auxW = UnicodeWidth.stringWidth(auxLabel) + btnPad;

        var remaining =
            constraints.maxWidth.toInt() - 2 - modelW - imageW;

        final showThinking =
            thinkingLabel != null && (remaining - thinkingW) >= 0;
        if (showThinking) remaining -= thinkingW;

        final showContext = (remaining - contextW) >= 0;
        if (showContext) remaining -= contextW;

        final showTokPerSec = (remaining - tokW) >= 0;
        if (showTokPerSec) remaining -= tokW;

        final showTtft = (remaining - ttftW) >= 0;
        if (showTtft) remaining -= ttftW;

        final showAux = (remaining - auxW) >= 0;

        // At this point, if showThinking is true, rt is guaranteed
        // non-null. Promote it to avoid null-check noise below.
        final nonNullRt = rt;

        return Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Row(
            children: [
              modelButton,
              if (_modelSupportsImages(
                  _sessionController.currentSession.model))
                Text(
                  _kIconImage,
                  style: TextStyle(
                    color: CruxTheme.of(context).onSurfaceVariant,
                  ),
                ),
              if (showThinking && nonNullRt != null)
                Button(
                  label: thinkingLabel,
                  onPressed: () => component.onCycleThinking(nonNullRt),
                  color: nonNullRt.thinkingMode == 'disabled'
                      ? CruxTheme.of(context).thinkingLabelDisabled
                      : CruxTheme.of(context).onSurfaceVariant,
                  hoverColor: CruxTheme.of(context).buttonTextHover,
                  bgColor: CruxTheme.of(context).buttonBackground,
                  hoverBgColor:
                      CruxTheme.of(context).buttonBackgroundHover,
                  padding:
                      EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                ),
              if (showContext) ...[
                _buildContextBar(context),
                Text(
                  '  ',
                  style:
                      TextStyle(color: CruxTheme.of(context).divider),
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
                MetricsDisplay(
                  sessionController: _sessionController,
                  streamingController: _streamingController,
                  currentSessionId: _sessionController.currentSessionId,
                ),
              Expanded(child: SizedBox()),
              if (showAux) _buildAuxiliaryModelButton(context),
            ],
          ),
        );
      },
    );
  }
}
