import 'package:nocterm/nocterm.dart';

import '../models/session_runtime_state.dart';
import '../theme/crux_theme.dart';
import '../tools/registry.dart';
import '../tools/tool_def.dart';
import '../utils/ticker_registry.dart';
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
  /// These are *snapshots* — passed in once by the chat history
  /// and re-rendered each tick. The bubble doesn't poll the
  /// controller for tool calls because they only change on round
  /// boundaries, which the chat history already reacts to.
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
  static const Duration _tickInterval = Duration(milliseconds: 33);

  /// Cached strings read from the streaming controller. The
  /// controller's `streamingContent` and `streamingReasoning`
  /// are `String`s we can't subscribe to, so we poll on a
  /// ~30fps ticker and call setState when the value changes.
  /// 33ms is fast enough to look smooth during streaming
  /// (~30fps) and slow enough that the ticker itself is
  /// negligible cost. Shares the global [TickerRegistry] so
  /// the bubble's tick is delivered by the same wakeup that
  /// drives every other periodic widget in the app.
  String _content = '';
  String _reasoning = '';
  TickerToken? _ticker;

  @override
  void initState() {
    super.initState();
    _refreshFromController();
    _startTimerIfNeeded();
  }

  @override
  void didUpdateComponent(StreamingBubble old) {
    super.didUpdateComponent(old);
    // If the user switched sessions, the new widget's
    // sessionId is different — re-read content and restart
    // the timer against the new id. (The chat history is
    // responsible for keeping the StreamingBubble instance
    // stable across rebuilds, but the runtime's `findSession`
    // lookup is keyed by sessionId, not instance.)
    if (old.sessionId != component.sessionId) {
      _refreshFromController();
      _startTimerIfNeeded();
      return;
    }
    // Session didn't change — just resync in case the
    // controller was repopulated between two ticks (e.g.
    // tool calls just finished and the new state arrived).
    _refreshFromController();
    _startTimerIfNeeded();
  }

  void _startTimerIfNeeded() {
    final running = component.runtimeState?.isResponding ?? false;
    if (running && _ticker == null) {
      _ticker = TickerRegistry.instance.subscribe(
        name: 'streamingBubble',
        interval: _tickInterval,
        onTick: () {
          if (!mounted) return;
          _refreshFromController();
        },
      );
    } else if (!running && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _refreshFromController() {
    final c = component.streamingController;
    final newContent = c.streamingContentFor(component.sessionId);
    final newReasoning = c.streamingReasoningFor(component.sessionId);
    if (newContent == _content && newReasoning == _reasoning) return;
    setState(() {
      _content = newContent;
      _reasoning = newReasoning;
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _ticker = null;
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

    if (component.streamingToolCalls.isNotEmpty) {
      children.add(
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: component.streamingToolCalls
                .map((tc) => _buildStreamingToolCallRow(tc, context))
                .toList(),
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
    BuildContext context,
  ) {
    final tool = component.toolRegistry?.lookup(tc.name);

    // For intentional tools, try to extract the intent from the
    // partial JSON and display it as the label.
    String? intentLabel;
    if (tool is IntentionalTool) {
      intentLabel = _tryExtractIntent(tc.accumulatedInputJson);
    }

    final label = intentLabel ?? tool?.streamingLabel(
          accumulatedInputJson: tc.accumulatedInputJson,
          estimatedInputTokens: tc.estimatedInputTokens,
        ) ??
        '${_capitalize(tc.name)} (~${tc.estimatedInputTokens} t)';

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
            label,
            style: TextStyle(
              color: intentLabel != null
                  ? CruxTheme.of(context).foreground
                  : CruxTheme.of(context).onSurfaceDim,
              fontStyle: intentLabel != null ? FontStyle.italic : null,
            ),
          ),
        ),
      ],
    );
  }

  /// Attempt to extract the `intent` value from a possibly-partial
  /// JSON string. The LLM streams input JSON incrementally, so we
  /// can't use `jsonDecode`. Instead, we do a simple regex search
  /// for `"intent":"..."` or `"intent": "..."`.
  String? _tryExtractIntent(String partialJson) {
    final match = RegExp(r'"intent"\s*:\s*"((?:[^"\\]|\\.)*)"')
        .firstMatch(partialJson);
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
