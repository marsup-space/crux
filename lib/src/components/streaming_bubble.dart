import 'package:nocterm/nocterm.dart';

import '../models/session_runtime_state.dart';
import '../theme/crux_theme.dart';
import '../tools/registry.dart';
import '../tools/tool_def.dart';
import '../utils/frame_profiler.dart';
import '../utils/tool_metrics_animator.dart';
import 'streaming_controller.dart';
import 'ui/highlighted_markdown_text.dart';
import '../utils/reasoning_block_splitter.dart';

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
  /// Polling interval for the streaming bubble. Schedules a
  /// `setState` whenever the controller's content has changed.
  /// We keep the interval at 16 ms (one frame at 60 fps) so the
  /// bubble can react to fresh chunks at frame rate, but the
  /// scheduler passes us the actual `tick.delta` (which may be
  /// larger on a slow frame) and we forward that to the animator
  /// so its lerp math is delta-driven rather than fixed-step.
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

  /// Paragraph-split view of [_reasoning], computed lazily
  /// in [_buildInner] and memoised via [_reasoningBlocksFor].
  /// See [_splitReasoningBlocks] for the split strategy.
  List<String> _reasoningBlocks = const [];

  /// The reasoning string that [_reasoningBlocks] was computed
  /// for. We only re-split when [_reasoning] actually changes,
  /// so static (frozen) blocks keep the exact same `String`
  /// instance across rebuilds — and Flutter's element diffing
  /// reuses their layout elements without re-running
  /// [RichText] layout for them.
  String? _reasoningBlocksFor;

  double? _waitingForModelSeconds;
  double? _executingToolsSeconds;
  List<ExecutingToolCall> _executingToolCalls = const [];
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
    _refreshFromController(Duration.zero);
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
      _refreshFromController(Duration.zero);
      _syncSchedulerSubscription();
      return;
    }
    // Session didn't change — just resync in case the
    // controller was repopulated between two ticks (e.g.
    // tool calls just finished and the new state arrived).
    _refreshFromController(Duration.zero);
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
          // Forward the wall-clock delta so the animator (and
          // anything else that reads `elapsed`) is delta-time,
          // not fixed-step. On a slow frame the lerp moves
          // further; on a fast frame less.
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
    final newWaitingForModelSeconds = c.waitingForModelSeconds(
      component.sessionId,
    );
    final newExecutingToolsSeconds = c.executingToolsSeconds(
      component.sessionId,
    );
    final newExecutingToolCalls = c.executingToolCallsFor(component.sessionId);
    final newToolCalls = c.streamingToolCallsFor(component.sessionId);
    final effectiveToolCalls = newToolCalls.isNotEmpty
        ? newToolCalls
        : component.streamingToolCalls;

    var changed =
        newContent != _content ||
        newReasoning != _reasoning ||
        newWaitingForModelSeconds != _waitingForModelSeconds ||
        newExecutingToolsSeconds != _executingToolsSeconds ||
        !_sameExecutingToolCalls(_executingToolCalls, newExecutingToolCalls);
    changed = _syncToolMetrics(effectiveToolCalls, elapsed) || changed;

    if (!changed) return;
    setState(() {
      _content = newContent;
      _reasoning = newReasoning;
      _waitingForModelSeconds = newWaitingForModelSeconds;
      _executingToolsSeconds = newExecutingToolsSeconds;
      _executingToolCalls = newExecutingToolCalls;
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
          left.abortInfo?.abortedInputTokensEstimate !=
              right.abortInfo?.abortedInputTokensEstimate) {
        return false;
      }
    }
    return true;
  }

  /// Split [text] into blocks at paragraph boundaries so each
  /// block stays under [cap] characters. Only the last block
  /// is the *active* one (still receiving streamed tokens) —
  /// earlier blocks are frozen snapshots of the reasoning
  /// emitted earlier, rendered as their own
  /// [HighlightedMarkdownText] widgets so Flutter's element
  /// diffing reuses their layout across rebuilds.
  ///
  /// The win: per-frame layout cost is bounded by the size
  /// of the active block, not the size of the whole reasoning
  /// preamble. A long reasoning trace (10 kB, 20 kB, 50 kB)
  /// degrades into one slow layout pass per emitted block —
  /// each block is at most [_renderedReasoningCap] chars —
  /// rather than one slow pass per frame for the full text.
  /// See `docs/perf-roadmap.md` Phase 1 for the profile
  /// data this targets.
  ///
  /// The actual split logic lives in
  /// [splitReasoningIntoBlocks] in
  /// `utils/reasoning_block_splitter.dart` — that's a pure
  /// function with a unit test suite. We just wrap it here so
  /// the build path is one line.
  List<String> _splitReasoningBlocks(String text, int cap) {
    return splitReasoningIntoBlocks(text, cap);
  }

  bool _sameExecutingToolCalls(
    List<ExecutingToolCall> a,
    List<ExecutingToolCall> b,
  ) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final left = a[i];
      final right = b[i];
      if (left.callId != right.callId ||
          left.name != right.name ||
          left.inputPreview != right.inputPreview) {
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

  /// Per-block cap on the streaming reasoning text. Reasoning
  /// is split at `\n\n` paragraph boundaries into blocks of at
  /// most this many characters each (see [_splitReasoningBlocks]).
  /// Only the *last* block is the active one growing under
  /// live tokens; earlier blocks are static snapshots. Flutter
  /// element diffing reuses the static blocks across rebuilds,
  /// so per-frame layout cost is bounded by the active block's
  /// size rather than the full reasoning preamble.
  ///
  /// Why we cap per-block: [RichText] layout in nocterm is
  /// O(N) in the rendered text length (every grapheme gets a
  /// width measurement + the span tree is walked). For very
  /// long reasoning preambles (15 kB+), the layout phase alone
  /// takes 8-20 ms per frame, dropping the chat panel from
  /// 60 fps to 25-40 fps. A 4 kB per-block cap keeps the
  /// active block's layout cost at ~3-4 ms, well under the
  /// 16 ms frame budget, and pays the static-block layout
  /// cost only once when each block is first promoted from
  /// active to frozen.
  ///
  /// The split is a render-time optimisation, not a data loss:
  /// the full reasoning is still in [StreamingController] and
  /// ends up in the saved [MessageBubble] for the round once
  /// the turn ends. The streaming bubble's job is to show
  /// *live* reasoning, and a 4 kB tail per block is plenty to
  /// read while the LLM is thinking.
  static const int _renderedReasoningCap = 4096;

  @override
  Component build(BuildContext context) {
    return FrameProfiler.instance.timed(
      'streamingBubble.build',
      () => _buildInner(context),
    );
  }

  Component _buildInner(BuildContext context) {
    final hasReasoning = _reasoning.isNotEmpty;
    final waitingSeconds = _waitingForModelSeconds;
    final executingSeconds = _executingToolsSeconds;

    final children = <Component>[];

    if (hasReasoning) {
      // Recompute the paragraph-split blocks only when the
      // reasoning text actually changed. We reuse the cached
      // list otherwise so Flutter can dedupe static blocks via
      // widget equality (same `String` → same `Widget` →
      // reused `Element` → no relayout).
      if (_reasoningBlocksFor != _reasoning) {
        _reasoningBlocks = _splitReasoningBlocks(
          _reasoning,
          _renderedReasoningCap,
        );
        _reasoningBlocksFor = _reasoning;
      }

      children.add(
        Tint(
          color: CruxTheme.of(context).thinkingExpandedText.withOpacity(0.5),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // First line: ' Think: ' left-rail label +
                // the first block inline, matching the legacy
                // single-block Row layout exactly. The block
                // grows in place; we only split into a new
                // row when a block would exceed the per-block
                // cap.
                //
                // Guarded by isNotEmpty: when the bubble first
                // mounts, _reasoningBlocks is still empty and
                // indexing [0] would throw a RangeError that
                // surfaces as a build error for the whole
                // streaming bubble.
                if (_reasoningBlocks.isNotEmpty)
                  Row(
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
                          _reasoningBlocks[0],
                          useIsolate: true,
                          styleSheet: HighlightMarkdownStyleSheet.thinking(
                            CruxTheme.of(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                // Subsequent (static) blocks: full-width rows
                // indented by the width of ' Think: ' so the
                // markdown text aligns where it did before
                // the multi-block refactor. SizedBox forces
                // the row's height to 1 cell between blocks
                // so frozen blocks don't visually touch the
                // active one above them.
                for (var i = 1; i < _reasoningBlocks.length; i++) ...[
                  const SizedBox(height: 1),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Width of ' Think: ' in monospace cells.
                      // Matches the original left-rail label
                      // so the markdown text aligns where it
                      // did before the multi-block refactor.
                      const SizedBox(width: 8),
                      Expanded(
                        child: HighlightedMarkdownText(
                          _reasoningBlocks[i],
                          useIsolate: true,
                          styleSheet: HighlightMarkdownStyleSheet.thinking(
                            CruxTheme.of(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
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
              child: _content.isEmpty && waitingSeconds != null
                  ? Text(
                      '(waiting for ${_formatSeconds(waitingSeconds)})',
                      style: TextStyle(
                        color: CruxTheme.of(context).onSurfaceDim,
                      ),
                    )
                  : _content.isEmpty && executingSeconds != null
                  ? Text(
                      '(executing tools for ${_formatSeconds(executingSeconds)})',
                      style: TextStyle(
                        color: CruxTheme.of(context).onSurfaceDim,
                      ),
                    )
                  : _content.isEmpty
                  ? Text(
                      '...',
                      style: TextStyle(color: CruxTheme.of(context).foreground),
                    )
                  : HighlightedMarkdownText(
                      // No render-cap here: streamed content
                      // is the user-facing reply (final text,
                      // code, tables) and we don't want to
                      // hide anything from it. The reasoning
                      // block above is the one that can run
                      // into thousands of tokens during long
                      // thinking, so it's the one that needs
                      // the cost cap. Parse still runs on the
                      // isolate to keep the main thread free.
                      _content,
                      useIsolate: true,
                    ),
            ),
          ],
        ),
      ),
    );

    if (_executingToolCalls.isNotEmpty) {
      children.add(
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final call in _executingToolCalls)
                _buildExecutingToolCallRow(
                  call,
                  executingSeconds ?? 0,
                  context,
                ),
            ],
          ),
        ),
      );
    }

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
    return ' · aborted after ~${abortInfo.abortedInputTokensEstimate} t';
  }

  Component _buildExecutingToolCallRow(
    ExecutingToolCall call,
    double elapsedSeconds,
    BuildContext context,
  ) {
    final preview = call.inputPreview.isEmpty ? '' : '${call.inputPreview} ';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          ' ${_capitalize(call.name)}: ',
          style: TextStyle(
            color: CruxTheme.of(context).toolPrefix,
            fontWeight: FontWeight.bold,
          ),
        ),
        Expanded(
          child: Text(
            '${preview}executing for ${_formatSeconds(elapsedSeconds)}',
            style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
          ),
        ),
      ],
    );
  }

  String _formatSeconds(double seconds) {
    if (seconds < 60) return '${seconds.toStringAsFixed(2)}s';
    final minutes = seconds ~/ 60;
    final rest = seconds - minutes * 60;
    return '${minutes}m ${rest.toStringAsFixed(2)}s';
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
