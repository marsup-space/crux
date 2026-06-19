import 'package:nocterm/nocterm.dart';

import '../models/session_runtime_state.dart';
import '../theme/crux_theme.dart';
import '../tools/registry.dart';
import '../tools/tool_def.dart';
import '../utils/frame_profiler.dart';
import '../utils/tool_metrics_animator.dart';
import 'streaming_controller.dart';
import 'ui/highlighted_markdown_text.dart';

/// Live streaming bubble shown at the bottom of the chat log
/// while the model is generating.
///
/// Previously a [StatelessComponent] that took the current
/// streaming content as a constructor argument — the chat
/// history rebuilt it on every chunk because it added the
/// bubble to its items list with new content each time,
/// which in turn forced a chat-panel rebuild for the cost
/// of an entire 606-message layout pass. This is the
/// streaming counterpart of the typing fix: the bubble
/// owns its own [State] and a ~30fps [TickerToken] that polls the
/// streaming controller for fresh content and calls
/// [State.setState] on itself. The chat history, the chat
/// panel, the toolbar — none of them get re-laid-out on a
/// streaming chunk anymore. Only this widget.
///
/// The widget still goes in the chat history's items list
/// (so it scrolls with the messages), but the framework
/// sees the same `StreamingBubble` instance across rebuilds
/// (because the chat history caches the items list when
/// messages don't change) and only the bubble's own subtree
/// is dirtied on each tick.
class StreamingBubble extends StatefulComponent {
  final StreamingController streamingController;
  final int sessionId;
  final SessionRuntimeState? runtimeState;

  /// In-progress tool calls, in declared order. Each entry is a
  /// snapshot of one call's id, name, and the (possibly-partial)
  /// input JSON the LLM has emitted so far. We render one row per
  /// call so the user sees parallel calls materialize as they
  /// stream, instead of having to wait for the round to end.
  ///
  /// These are initial snapshots from the chat history. The bubble
  /// also polls [streamingController] every frame so partial
  /// tool-use JSON, token estimates, and line deltas can animate
  /// without a chat-panel-wide rebuild.
  final List<StreamingToolCall> streamingToolCalls;

  /// Optional registry used to look up the [ToolDef] for each
  /// streaming call, so we can ask it for a richer streaming
  /// preview label (e.g. `Bash ls -la` instead of `Bash (~12 t)`).
  /// When null — or the tool isn't registered — we fall back to
  /// the default capitalized-name + token-budget label.
  final ToolRegistry? toolRegistry;

  const StreamingBubble({
    required this.streamingController,
    required this.sessionId,
    this.runtimeState,
    this.streamingToolCalls = const [],
    this.toolRegistry,
    super.key,
  });

  @override
  State<StreamingBubble> createState() => _StreamingBubbleState();
}

class _StreamingBubbleState extends State<StreamingBubble> {
  static const Duration _tickInterval = Duration(milliseconds: 16);
  // The lerp speed used to live here too; it now lives inside
  // [ToolMetricsAnimator] (default 12.0) so the post-call
  // collapsed row + the tool detail pane animate at the same
  // rate as the streaming bubble.

  /// Cached strings read from the streaming controller. The
  /// controller's `streamingContent` and `streamingReasoning`
  /// are `String`s we can't subscribe to, so we poll on a
  /// 60fps scheduler callback and call setState when the value
  /// changes. The callback is registered with [NoctermScheduler]
  /// so it runs inside Nocterm's frame pipeline.
  String _content = '';
  String _reasoning = '';
  List<StreamingToolCall> _toolCalls = const [];
  /// Per-callId animated metrics, driven manually from the
  /// 16ms scheduler below. The shared module also powers the
  /// collapsed post-call row + the tool detail pane header, so
  /// the per-frame math, the line-delta extraction, and the
  /// "· ~N t · +M lines" formatter all live in one place.
  final ToolMetricsAnimator _animator = ToolMetricsAnimator(
    tickerName: 'streamingBubble',
    driveManually: true,
  );
  SchedulerHandle? _schedulerHandle;

  @override
  void initState() {
    super.initState();
    _refreshFromController(_tickInterval);
    _syncSchedulerSubscription();
  }

  @override
  void didUpdateComponent(StreamingBubble old) {
    super.didUpdateComponent(old);
    // If the user switched sessions, the new widget's
    // sessionId is different — re-read content and restart
    // the scheduler callback against the new id. (The chat history is
    // responsible for keeping the StreamingBubble instance
    // stable across rebuilds, but the runtime's `findSession`
    // lookup is keyed by sessionId, not instance.)
    if (old.sessionId != component.sessionId) {
      _refreshFromController(_tickInterval);
      _syncSchedulerSubscription();
      return;
    }
    // Session didn't change — just resync in case the
    // controller was repopulated between two ticks (e.g.
    // tool calls just finished and the new state arrived).
    _refreshFromController(_tickInterval);
    _syncSchedulerSubscription();
  }

  void _syncSchedulerSubscription() {
    final running = component.runtimeState?.isResponding ?? false;
    if (running && _schedulerHandle == null) {
      _schedulerHandle = NoctermScheduler.instance.every(
        _tickInterval,
        (tick) {
          if (!mounted) return;
          FrameProfiler.instance.markTimer('streamingBubble');
          _refreshFromController(tick.delta);
        },
        owner: this,
        name: 'streamingBubble',
        delay: Duration.zero,
        priority: SchedulePriority.animation,
      );
    } else if (!running && _schedulerHandle != null) {
      _schedulerHandle?.cancel();
      _schedulerHandle = null;
    }
  }

  void _refreshFromController(Duration elapsed) {
    final c = component.streamingController;
    final newContent = c.streamingContentFor(component.sessionId);
    final newReasoning = c.streamingReasoningFor(component.sessionId);
    final newToolCalls = c.streamingToolCallsFor(component.sessionId);
    final effectiveToolCalls = newToolCalls.isNotEmpty
        ? newToolCalls
        : component.streamingToolCalls;

    var changed = newContent != _content || newReasoning != _reasoning;
    changed = _syncToolMetrics(effectiveToolCalls, elapsed) || changed;

    if (!changed) return;
    setState(() {
      _content = newContent;
      _reasoning = newReasoning;
      _toolCalls = effectiveToolCalls;
    });
  }

  bool _syncToolMetrics(List<StreamingToolCall> toolCalls, Duration elapsed) {
    var changed = !_sameToolCalls(_toolCalls, toolCalls);
    final liveKeys = <String>{};

    for (var i = 0; i < toolCalls.length; i++) {
      final tc = toolCalls[i];
      final key = _toolMetricKey(tc, i);
      liveKeys.add(key);
      final target = toolMetricsLineDeltaFromPartialJson(
        toolName: tc.name,
        partialJson: tc.accumulatedInputJson,
      );
      if (_animator.setTarget(
        key,
        tokens: tc.estimatedInputTokens,
        addedLines: target.addedLines,
        removedLines: target.removedLines,
      )) {
        changed = true;
      }
    }

    // Drive the display one frame forward using the actual
    // tick delta from the scheduler. The shared animator
    // advances every tracked metric; we just need to know
    // whether any value moved so the build knows to dirty
    // itself.
    if (_animator.advance(elapsed)) changed = true;

    final staleKeys = _animator.metrics.keys
        .where((key) => !liveKeys.contains(key))
        .toList(growable: false);
    for (final key in staleKeys) {
      _animator.forget(key);
      changed = true;
    }

    return changed;
  }

  bool _sameToolCalls(List<StreamingToolCall> a, List<StreamingToolCall> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final left = a[i];
      final right = b[i];
      if (left.callId != right.callId ||
          left.name != right.name ||
          left.accumulatedInputJson != right.accumulatedInputJson ||
          left.abortInfo?.reason != right.abortInfo?.reason ||
          left.abortInfo?.abortedInputChars !=
              right.abortInfo?.abortedInputChars) {
        return false;
      }
    }
    return true;
  }

  String _toolMetricKey(StreamingToolCall tc, int index) {
    if (tc.callId.isNotEmpty) return tc.callId;
    return '$index:${tc.name}';
  }

  @override
  void dispose() {
    _schedulerHandle?.cancel();
    _schedulerHandle = null;
    _animator.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final hasReasoning = _reasoning.isNotEmpty;

    final children = <Component>[];

    if (hasReasoning) {
      children.add(
        Tint(
          color: CruxTheme.of(context).thinkingExpandedText.withOpacity(0.5),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ' Think: ',
                  style: TextStyle(
                    color: CruxTheme.of(context).thinkPrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: HighlightedMarkdownText(
                    _reasoning,
                    styleSheet: HighlightMarkdownStyleSheet.thinking(
                      CruxTheme.of(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    children.add(
      Container(
        padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ' Crux: ',
              style: TextStyle(
                color: CruxTheme.of(context).responsePrefix,
                fontWeight: FontWeight.bold,
              ),
            ),
            Expanded(
              child: _content.isEmpty
                  ? Text(
                      '...',
                      style: TextStyle(color: CruxTheme.of(context).foreground),
                    )
                  : HighlightedMarkdownText(_content),
            ),
          ],
        ),
      ),
    );

    if (_toolCalls.isNotEmpty) {
      children.add(
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < _toolCalls.length; i++)
                _buildStreamingToolCallRow(_toolCalls[i], i, context),
            ],
          ),
        ),
      );
    }

    return Column(children: children);
  }

  /// Render a single in-flight tool call as a `ToolName: <label>`
  /// row, matching the look of [MessageBubble._buildCollapsedToolCall]
  /// but with no result yet. The label comes from
  /// [ToolDef.streamingLabel] when we can resolve the tool, or
  /// the default `Name (~Nt t)` format otherwise. For
  /// [IntentionalTool]s, the intent is shown instead of the
  /// default streaming label when it can be extracted from the
  /// partial JSON.
  Component _buildStreamingToolCallRow(
    StreamingToolCall tc,
    int index,
    BuildContext context,
  ) {
    final tool = component.toolRegistry?.lookup(tc.name);
    // The shared animator's `format` reads the same per-callId
    // state we used to cache in a local `metrics` var; we don't
    // need a local handle here.

    // For intentional tools, try to extract the intent from the
    // partial JSON and display it as the label.
    String? intentLabel;
    if (tool is IntentionalTool) {
      intentLabel = _tryExtractIntent(tc.accumulatedInputJson);
    }

    final previewLabel =
        intentLabel ??
        tool?.streamingLabel(
          accumulatedInputJson: tc.accumulatedInputJson,
          estimatedInputTokens: tc.estimatedInputTokens,
        ) ??
        '${_capitalize(tc.name)} (~${tc.estimatedInputTokens} t)';
    final label = stripToolTokenSuffix(previewLabel);
    final metricLabel = tc.abortInfo == null
        ? _animator.format(_toolMetricKey(tc, index))
        : _formatAbortedMetrics(tc.abortInfo!);
    final valueColor = tc.abortInfo != null
        ? CruxTheme.of(context).warning
        : intentLabel != null
        ? CruxTheme.of(context).foreground
        : CruxTheme.of(context).onSurfaceDim;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          ' ${_capitalize(tc.name)}: ',
          style: TextStyle(
            color: CruxTheme.of(context).toolPrefix,
            fontWeight: FontWeight.bold,
          ),
        ),
        Expanded(
          child: Text(
            label.isEmpty ? metricLabel : '$label$metricLabel',
            style: TextStyle(
              color: valueColor,
              fontStyle: intentLabel != null ? FontStyle.italic : null,
            ),
          ),
        ),
      ],
    );
  }

  String _formatAbortedMetrics(StreamingToolAbortInfo abortInfo) {
    return ' · aborted at ${abortInfo.abortedInputChars} chars';
  }

  /// Attempt to extract the `intent` value from a possibly-partial
  /// JSON string. The LLM streams input JSON incrementally, so we
  /// can't use `jsonDecode`. Instead, we do a simple regex search
  /// for `"intent":"..."` or `"intent": "..."`.
  String? _tryExtractIntent(String partialJson) {
    final match = RegExp(
      r'"intent"\s*:\s*"((?:[^"\\]|\\.)*)"',
    ).firstMatch(partialJson);
    if (match == null) return null;
    final raw = match.group(1);
    if (raw == null || raw.isEmpty) return null;
    // Unescape simple JSON string escapes.
    return raw
        .replaceAll(r'\\', '\\')
        .replaceAll(r'\"', '"')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\t', '\t');
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }
}
