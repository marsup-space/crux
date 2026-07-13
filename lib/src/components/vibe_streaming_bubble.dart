import 'package:nocterm/nocterm.dart';

import '../models/session_runtime_state.dart';
import '../services/llm_provider.dart';
import '../theme/crux_theme.dart';
import '../utils/token_estimate.dart';
import 'streaming_controller.dart';
import 'ui/highlighted_markdown_text.dart';
import 'vibe_box.dart';
import 'vibe_box_data.dart';

/// Live streaming bubble for vibe mode. Replaces the verbose
/// [StreamingBubble] when `chatDisplayMode == vibe`.
///
/// Polls [StreamingController] at frame rate and renders live
/// think/tools boxes using the same [VibeBox] widget as persisted
/// segments. Shows:
///
/// - **think box**: elapsed time + estimated tokens + effort label.
///   Active (bright) while reasoning is streaming; deactivates when
///   the response body starts.
/// - **tools box**: tool names from streaming + executing tool calls.
///   Active while tools are executing.
/// - **prose**: live response text (via HighlightedMarkdownText)
///
/// Does NOT show the user message (already rendered by the pending
/// segment from [walkSegments]) or the files box (no tools have
/// completed in the current round yet).
class VibeStreamingBubble extends StatefulComponent {
  final StreamingController streamingController;
  final int sessionId;
  final SessionRuntimeState? runtimeState;

  /// Reasoning presets from the session's provider, used to map
  /// internal effort values to display labels (e.g. `normal` →
  /// `adaptive` for MiniMax). If null, the raw internal value is
  /// used.
  final List<ReasoningPreset> reasoningPresets;

  const VibeStreamingBubble({
    required this.streamingController,
    required this.sessionId,
    this.runtimeState,
    this.reasoningPresets = const [],
    super.key,
  });

  @override
  State<VibeStreamingBubble> createState() => _VibeStreamingBubbleState();
}

class _VibeStreamingBubbleState extends State<VibeStreamingBubble> {
  static const _tickInterval = Duration(milliseconds: 33);

  String _reasoning = '';
  String _content = '';
  List<StreamingToolCall> _streamingToolCalls = const [];
  List<ExecutingToolCall> _executingToolCalls = const [];
  double? _waitingSeconds;
  SchedulerHandle? _schedulerHandle;

  @override
  void initState() {
    super.initState();
    _refreshFromController();
    _syncScheduler();
  }

  @override
  void didUpdateComponent(VibeStreamingBubble old) {
    super.didUpdateComponent(old);
    if (old.sessionId != component.sessionId) {
      _refreshFromController();
      _syncScheduler();
    }
  }

  @override
  void dispose() {
    _schedulerHandle?.cancel();
    super.dispose();
  }

  void _syncScheduler() {
    _schedulerHandle ??= NoctermScheduler.instance.every(
      _tickInterval,
      (_) {
        if (!mounted) return;
        _refreshFromController();
      },
      owner: this,
      name: 'vibeStreamingBubble',
      delay: Duration.zero,
      priority: SchedulePriority.animation,
    );
  }

  void _refreshFromController() {
    final c = component.streamingController;
    final sid = component.sessionId;
    final newReasoning = c.streamingReasoningFor(sid);
    final newContent = c.streamingContentFor(sid);
    final newWaiting = c.waitingForModelSeconds(sid);
    final newStreaming = c.streamingToolCallsFor(sid);
    final newExecuting = c.executingToolCallsFor(sid);

    // Always setState — the elapsed time changes every tick even
    // when the reasoning text hasn't grown.
    setState(() {
      _reasoning = newReasoning;
      _content = newContent;
      _waitingSeconds = newWaiting;
      _streamingToolCalls = newStreaming;
      _executingToolCalls = newExecuting;
    });
  }

  /// Map an internal effort value to its display label using the
  /// provider's reasoning presets (e.g. `normal` → `adaptive` for
  /// MiniMax). Falls back to the raw internal value.
  String _displayEffort(String? internal) {
    if (internal == null) return '';
    for (final p in component.reasoningPresets) {
      if (p.internalValue == internal) return p.displayLabel;
    }
    return internal;
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final rt = component.runtimeState;

    // Active-generation time for the live think box, computed each
    // build from [SessionRuntimeState.roundFirstTokenTime]. The bubble
    // rebuilds every 33 ms while streaming, so this stays in lockstep
    // with the live token row (which lerps as reasoning deltas land).
    //
    // Before the first delta lands (roundFirstTokenTime == null),
    // fall back to [_waitingSeconds] — the "time waiting for the
    // model" counter — so the think box still has a meaningful time
    // row during the TTFT phase and the user sees a tick before any
    // tokens exist. The two clocks never run simultaneously, since
    // _waitingSeconds freezes once the first delta arrives.
    //
    // Previously this row used [_waitingSeconds] for the entire
    // thinking phase, which froze at the small TTFT value once
    // reasoning actually streamed — the time row visually stopped
    // moving while the token row kept growing, so the two never
    // ticked together.
    final liveSeconds = rt?.roundFirstTokenTime == null
        ? _waitingSeconds
        : DateTime.now()
            .difference(rt!.roundFirstTokenTime!)
            .inMicroseconds / 1000000.0;

    final boxes = <Component>[];

    // Think box: show whenever reasoning is streaming OR has streamed
    // in this round (even if the response body has started, the final
    // values are still relevant).
    final hasThink = _reasoning.isNotEmpty || liveSeconds != null;
    final thinkActive = _reasoning.isNotEmpty && _content.isEmpty;

    if (hasThink) {
      final rows = <String>[];
      if (liveSeconds != null) {
        rows.add('${liveSeconds.toStringAsFixed(1)}s');
      }
      if (_reasoning.isNotEmpty) {
        rows.add(formatTokens(estimateTokens(_reasoning)));
      }
      // Effort — known from the start, not just when reasoning arrives
      final effort = _displayEffort(rt?.reasoningEffort);
      if (effort.isNotEmpty) {
        rows.add(effort);
      }
      boxes.add(
        VibeBox(
          title: 'think',
          bodyRows: rows,
          active: thinkActive,
          mutedColor: theme.thinkPrefix,
          activeColor: theme.responsePrefix,
        ),
      );
    }

    // Tools box: from streaming + executing tool calls.
    final allToolNames = <String, int>{};
    for (final tc in _streamingToolCalls) {
      allToolNames[tc.name] = (allToolNames[tc.name] ?? 0) + 1;
    }
    for (final tc in _executingToolCalls) {
      allToolNames[tc.name] = (allToolNames[tc.name] ?? 0) + 1;
    }
    if (allToolNames.isNotEmpty) {
      final rows = allToolNames.entries.map((e) {
        return '${e.key} x${e.value}';
      }).toList();
      boxes.add(
        VibeBox(
          title: 'tools',
          bodyRows: rows,
          active: _executingToolCalls.isNotEmpty,
          mutedColor: theme.toolPrefix,
          activeColor: theme.accent,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (boxes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < boxes.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  boxes[i],
                ],
              ],
            ),
          ),
        // Live response text (if any has been emitted).
        if (_content.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ' Crux: ',
                  style: TextStyle(
                    color: theme.responsePrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: HighlightedMarkdownText(_content),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
