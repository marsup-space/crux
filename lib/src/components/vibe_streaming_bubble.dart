import 'dart:convert';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../models/session_runtime_state.dart';
import '../services/llm_provider.dart';
import '../services/shell_progress_registry.dart';
import '../theme/crux_theme.dart';
import '../i18n/strings.dart';
import '../utils/markdown_links.dart';
import '../utils/quick_reply_parser.dart';
import '../utils/token_estimate.dart';
import '../utils/tool_meta.dart';
import 'lsp_state_glyph.dart';
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
/// When [baseSegment] is non-null, its completed-round think/tools/files
/// data is merged with the current in-flight round. This keeps one open
/// response-bounded segment under a single set of boxes instead of rendering
/// the persisted tail and the live round as two visually separate segments.
/// The user line remains owned by [ChatHistory].
class VibeStreamingBubble extends StatefulComponent {
  final StreamingController streamingController;
  final int sessionId;
  final SessionRuntimeState? runtimeState;

  /// Persisted, still-open tail of the current response-bounded segment.
  /// Its [VibeSegment.prose] is always null at the call site.
  final VibeSegment? baseSegment;

  /// Quick-reply handler. The live bubble does NOT enable ask buttons
  /// while a turn is streaming (the active reply is still being
  /// emitted; clicking a stale quick reply would race the live
  /// content). The handler is accepted here so [ChatHistory] can
  /// pass one callback through to both the streaming and the persisted
  /// children, but it is wired to the prose [HighlightedMarkdownText]
  /// only when [enableQuickReplies] is true — and this bubble
  /// always passes `enableQuickReplies: false`.
  final void Function(QuickReply reply)? onQuickReplyTap;

  /// `ses://<id>` reference handler. The live bubble is happy to
  /// forward session links from the in-flight reply (the user can
  /// jump to a referenced session at any time).
  final void Function(int sessionId)? onSessionLinkTap;

  /// Markdown link (`[label](url)`) handler. The live bubble also
  /// forwards link clicks so the user can open referenced docs
  /// from the in-flight reply.
  final void Function(MarkdownLink link)? onLinkTap;

  /// Reasoning presets from the session's provider, used to map
  /// internal effort values to display labels (e.g. `normal` →
  /// `adaptive` for MiniMax). If null, the raw internal value is
  /// used.
  final List<ReasoningPreset> reasoningPresets;
  final Strings strings;

  const VibeStreamingBubble({
    required this.streamingController,
    required this.sessionId,
    this.runtimeState,
    this.baseSegment,
    this.onQuickReplyTap,
    this.onSessionLinkTap,
    this.onLinkTap,
    this.reasoningPresets = const [],
    this.strings = kEnglishStrings,
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

    // Active-generation time for the live think box. The bubble
    // rebuilds every 33 ms while streaming, so this stays in lockstep
    // with the live token row (which lerps as reasoning deltas land).
    //
    // Three clocks feed the row, chosen by the current phase of the
    // round:
    //
    // * Pre-first-delta (roundFirstTokenTime == null) — the round
    //   has started but no deltas have arrived yet. Fall back to
    //   [_waitingSeconds] (the "time waiting for the model" counter)
    //   so the think box still has a meaningful time row during the
    //   TTFT phase. The two clocks never run simultaneously, since
    //   _waitingSeconds freezes once the first delta arrives.
    //
    // * Reasoning phase active — the LLM is emitting reasoning
    //   deltas. Tick from the first reasoning delta so the row
    //   advances in lockstep with the live token row. Tracks
    //   [StreamingController.reasoningFirstAtFor] which is set on
    //   the first reasoning delta and cleared on round boundaries.
    //
    // * Reasoning phase ended — the model has moved on to tool
    //   calls, tool execution, or response prose. Freeze the time
    //   at `lastReasoningAt - reasoningFirstAt` so the row stops
    //   ticking while the rest of the round runs. Without this,
    //   the think time kept growing through the tool write and
    //   execution phases, which felt like the model was still
    //   thinking.
    //
    // `lastReasoningAt == null` means the round hasn't produced any
    // reasoning yet (e.g. it started with a tool call or the
    // response). In that case the live bubble has no think row,
    // so we return `null` to signal "no think time this round."
    final ctrl = component.streamingController;
    final reasoningFirstAt = ctrl.reasoningFirstAtFor(component.sessionId);
    final lastReasoningAt = ctrl.lastReasoningAtFor(component.sessionId);
    final isReasoningActive = ctrl.isReasoningPhaseActiveFor(
      component.sessionId,
    );
    final double? liveSeconds;
    if (rt?.roundFirstTokenTime == null) {
      liveSeconds = _waitingSeconds;
    } else if (reasoningFirstAt == null || lastReasoningAt == null) {
      liveSeconds = null;
    } else if (isReasoningActive) {
      liveSeconds =
          DateTime.now().difference(reasoningFirstAt).inMicroseconds /
          1000000.0;
    } else {
      liveSeconds =
          lastReasoningAt.difference(reasoningFirstAt).inMicroseconds /
          1000000.0;
    }

    final boxes = <Component>[];

    // One think box for the whole open segment: completed rounds come from
    // [baseSegment], while [_reasoning]/[liveSeconds] describe only the
    // current in-flight round. Rendering these sources independently was the
    // duplicate-box bug seen from the second model round onward.
    final baseThink = component.baseSegment?.think;
    final hasLiveThink = _reasoning.isNotEmpty || liveSeconds != null;
    final hasThink = baseThink != null || hasLiveThink;
    final thinkActive = isReasoningActive && _content.isEmpty;

    if (hasThink) {
      final rows = <String>[];
      final totalSeconds =
          (baseThink?.duration.inMicroseconds ?? 0) / 1000000.0 +
          (liveSeconds ?? 0.0);
      rows.add('${totalSeconds.toStringAsFixed(1)}s');

      final totalTokens =
          (baseThink?.tokens ?? 0) +
          (_reasoning.isEmpty ? 0 : estimateTokens(_reasoning));
      if (baseThink != null || _reasoning.isNotEmpty) {
        rows.add(formatTokens(totalTokens));
      }

      final effort = _displayEffort(rt?.reasoningEffort ?? baseThink?.effort);
      if (effort.isNotEmpty) {
        rows.add(effort);
      }
      boxes.add(
        VibeBox(
          title: component.strings.t('chat.vibe.think'),
          bodyRows: rows,
          active: thinkActive,
          mutedColor: theme.thinkPrefix,
          activeColor: theme.responsePrefix,
        ),
      );
    }

    // One tools box for the whole open segment. Seed it with completed calls
    // from the persisted tail, then fold in the current streaming/executing
    // calls. Map insertion order preserves the original first-seen ordering.
    final allToolNames = <String, int>{};
    final completedToolTokens = <String, int>{};
    // Per-name worst LSP outcome from the persisted tail's completed
    // calls (errors > failed > clean > none). In-flight streaming /
    // executing calls have no result yet, so they contribute no state
    // — the glyph appears once a call completes and its `lsp` meta
    // persists, matching the persisted VibeSegmentBubble behavior.
    final toolLspState = <String, LspState>{};
    for (final entry
        in component.baseSegment?.tools?.entries ?? const <ToolBoxEntry>[]) {
      allToolNames[entry.name] = entry.callCount;
      completedToolTokens[entry.name] = entry.totalTokens;
      toolLspState[entry.name] = entry.lspState;
    }
    for (final tc in _streamingToolCalls) {
      allToolNames[tc.name] = (allToolNames[tc.name] ?? 0) + 1;
    }
    for (final tc in _executingToolCalls) {
      allToolNames[tc.name] = (allToolNames[tc.name] ?? 0) + 1;
    }
    if (allToolNames.isNotEmpty) {
      // Render as rich-text spans so the LSP outcome glyph (`⎇`) can be
      // color-coded while the label keeps the box body color — same as
      // the persisted tools box in vibe_segment_bubble.dart.
      final rowSpans = allToolNames.entries.map((e) {
        final completedTokens = completedToolTokens[e.key];
        final label = completedTokens == null
            ? '${e.key} x${e.value}'
            : '${e.key} x${e.value}: ${formatTokens(completedTokens)}';
        // Name-aware fallback: only write/edit consult a language
        // server, so any other tool is disabled (no glyph) even when
        // it has no persisted entry yet. An in-flight write/edit with
        // no completed result falls back to gray (none) — a "pending /
        // not-applicable-yet" state that resolves once the call's `lsp`
        // meta persists.
        final isLspTool = e.key == 'write' || e.key == 'edit';
        final state =
            toolLspState[e.key] ??
            (isLspTool ? LspState.none : LspState.disabled);
        final glyph = lspStateGlyphSpan(state, theme);
        if (glyph == null) return TextSpan(text: label);
        return TextSpan(
          children: [
            TextSpan(text: label),
            glyph,
          ],
        );
      }).toList();
      boxes.add(
        VibeBox(
          title: component.strings.t('chat.vibe.tools'),
          bodyRowSpans: rowSpans,
          active:
              _streamingToolCalls.isNotEmpty || _executingToolCalls.isNotEmpty,
          mutedColor: theme.toolPrefix,
          activeColor: theme.accent,
        ),
      );
    }

    // Files follow the same ownership rule as think/tools: completed edits
    // live on the persisted open segment; current edit/write calls come from
    // the controller. Render both in one box and dedupe by **basename** —
    // not by the raw path string — because the LLM (and the
    // executing-side `_toolExecutionPreview`) can return the same file
    // under different path strings (absolute vs relative, project-relative
    // preview vs the raw LLM path, etc.). The displayed row is the
    // basename either way, so basename is the correct dedup key.
    // baseMods wins on overlap because it carries the +N -M diff; the
    // live row would be a strict downgrade of information.
    final baseMods = component.baseSegment?.mods;
    final liveFilePaths = _collectLiveFilePaths();
    final fileRows = <String>[];
    final seenBasenames = <String>{};
    if (baseMods != null) {
      for (final path in baseMods.paths) {
        final base = p.basename(path);
        final name = base.isEmpty ? path : base;
        if (name.isEmpty || !seenBasenames.add(name)) continue;
        fileRows.add('$name +${baseMods.linesAdded} -${baseMods.linesRemoved}');
      }
    }
    for (final path in liveFilePaths) {
      final base = p.basename(path);
      final name = base.isEmpty ? path : base;
      if (name.isEmpty || !seenBasenames.add(name)) continue;
      fileRows.add(name);
    }
    if (baseMods != null && baseMods.overflowCount > 0) {
      fileRows.add('+${baseMods.overflowCount} more files');
    }
    if (fileRows.isNotEmpty) {
      final filesActive = _executingToolCalls.any(
        (tc) => tc.name == 'edit' || tc.name == 'write',
      );
      boxes.add(
        VibeBox(
          title: component.strings.t('chat.vibe.files'),
          bodyRows: fileRows,
          active: filesActive,
          mutedColor: theme.success,
          activeColor: theme.warning,
        ),
      );
    }

    // ── Progress box (live long-running bash) ───────────────────
    // Joins the think/tools/files row as a fourth box so the whole
    // turn's state stays on one line of boxes. Each entry renders as
    // multiple short body rows (bar+percent / phase / rate·ETA /
    // elapsed) instead of one long packed line, plus the raw output
    // line as dim evidence. Entries only render once they've run ≥2s,
    // so a fast command that happened to mention "Downloading" never
    // flashes a box. A base-segment summary (a previous round's bash
    // whose box already closed) renders as a dim ✓/✗ row inside the
    // box, matching how think/tools/files merge persisted tails.
    final now = DateTime.now();
    final liveProgress = ShellProgressRegistry.instance
        .entriesFor(component.sessionId)
        .where((e) => now.difference(e.startedAt).inSeconds >= 2)
        .toList();
    final baseProgress = component.baseSegment?.progress;
    final progressRows = <Component>[];
    for (final entry in liveProgress) {
      final rowColor = entry.finished ? theme.onSurfaceVariant : theme.text;
      for (final row in _liveProgressRows(entry, now)) {
        progressRows.add(Text(row, style: TextStyle(color: rowColor)));
      }
      final raw = entry.progress.lastLine;
      if (raw.isNotEmpty) {
        final capped = raw.length <= 80 ? raw : raw.substring(0, 80);
        progressRows.add(
          Text(capped, style: TextStyle(color: theme.onSurfaceDim)),
        );
      }
    }
    if (baseProgress != null) {
      progressRows.add(
        Text(
          _renderBaseProgressLine(baseProgress),
          style: TextStyle(color: theme.onSurfaceVariant),
        ),
      );
    }
    if (progressRows.isNotEmpty) {
      boxes.add(
        VibeBox(
          title: component.strings.t('chat.vibe.progress'),
          bodyRowComponents: progressRows,
          active: liveProgress.any((e) => !e.finished),
          mutedColor: theme.warning,
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
                  child: HighlightedMarkdownText(
                    _content,
                    onSessionLinkTap: component.onSessionLinkTap,
                    onLinkTap: component.onLinkTap,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Collect file paths from any in-flight `edit` / `write` tool
  /// calls — both mid-JSON (in [_streamingToolCalls]) and
  /// already-executing (in [_executingToolCalls]). Order is
  /// preserved (streaming first, then executing). Returns the
  /// path as-is; the renderer trims to basename for the row.
  List<String> _collectLiveFilePaths() {
    final paths = <String>[];
    for (final tc in _streamingToolCalls) {
      if (tc.name == 'edit' || tc.name == 'write') {
        final path = _extractFilePathFromJson(tc.accumulatedInputJson);
        if (path != null && path.isNotEmpty) paths.add(path);
      }
    }
    for (final tc in _executingToolCalls) {
      if (tc.name == 'edit' || tc.name == 'write') {
        // `inputPreview` is the rendered preview from
        // `_toolExecutionPreview` in `chat_turn_orchestrator.dart`.
        // For `edit` / `write` the priority list starts with
        // `filePath`, so the preview is the path (possibly made
        // project-relative). We use it directly here — the path
        // is preserved verbatim in the underlying ToolCallData.
        final path = tc.inputPreview;
        if (path.isNotEmpty) paths.add(path);
      }
    }
    return paths;
  }

  /// Pull the `filePath` value out of an `edit` / `write`
  /// tool-call input. The input arrives as raw JSON, possibly
  /// partial (open string, missing closing braces, etc.) — the
  /// streaming layer doesn't wait for parseability to start
  /// surfacing chunks, and we want the box to appear the moment
  /// the path lands, not after the full JSON is parseable.
  ///
  /// Strategy: try `jsonDecode` first (handles any time the
  /// accumulated JSON happens to be complete); fall back to a
  /// regex that matches `"filePath":"..."` even in the middle of
  /// a partial payload.
  String? _extractFilePathFromJson(String json) {
    if (json.isEmpty) return null;
    // Try the full parse — works once the input is well-formed.
    try {
      final parsed = jsonDecode(json);
      if (parsed is Map<String, dynamic>) {
        final fp = parsed['filePath'];
        if (fp is String && fp.isNotEmpty) return fp;
      }
    } catch (_) {
      // Fall through to the regex below.
    }
    // Regex on partial JSON. `filePath` is the first key in the
    // arg shape for both `edit` and `write`, so it lands in the
    // first one or two chunks — usually visible before any of
    // `oldString` / `content` / `intent` arrive.
    final m = RegExp(r'"filePath"\s*:\s*"([^"]*)"').firstMatch(json);
    return m?.group(1);
  }

  /// Render one live progress entry as its body rows — one fact per
  /// line so the box stays narrow instead of packing the whole meter
  /// into a single long string:
  ///
  ///   `[########----------] 68%`
  ///   `Receiving objects`
  ///   `12.4MB/s · ETA 1m`
  ///   `3m 05s`
  ///
  /// The bar row is omitted when no percent was detected (phase-only
  /// box); the rate/ETA row and the elapsed row are omitted when
  /// their data is absent. The `✓` marker lands on the first row of
  /// a finished entry.
  List<String> _liveProgressRows(ShellProgressEntry entry, DateTime now) {
    final p = entry.progress;
    final rows = <String>[];
    final percent = p.percent;
    if (percent != null) {
      final filled = (percent / 100 * 20).round().clamp(0, 20);
      final bar =
          '[${List.filled(filled, '#').join()}${List.filled(20 - filled, '-').join()}] ${percent.round()}%';
      rows.add(entry.finished ? '✓ $bar' : bar);
    }
    final phase = p.phase;
    if (phase != null) {
      rows.add(percent == null && entry.finished ? '✓ $phase' : phase);
    }
    if (percent == null && p.phase == null) {
      rows.add(entry.finished ? '✓ done' : 'running');
    }
    final stats = <String>[];
    if (p.ratePerSec != null) stats.add(_formatRate(p.ratePerSec!));
    if (p.eta != null) stats.add('ETA ${p.eta}');
    if (stats.isNotEmpty) rows.add(stats.join(' · '));
    final elapsed = now.difference(entry.startedAt);
    if (elapsed.inSeconds > 0) rows.add(_formatElapsed(elapsed));
    return rows;
  }

  /// Render the persisted (base-segment) progress summary as a dim
  /// one-liner — the closed box of a previous round's bash.
  String _renderBaseProgressLine(ProgressBoxData p) {
    final phase = p.phase ?? 'bash';
    final ok = p.exitCode == 0;
    final details = <String>[];
    if (p.peakPercent != null) details.add('${p.peakPercent!.round()}%');
    if (p.bytes > 0) details.add(_formatBytes(p.bytes));
    if (p.durationSec > 0) {
      details.add(_formatElapsed(Duration(seconds: p.durationSec)));
    }
    if (ok) return '✓ $phase${details.isEmpty ? '' : ' · ${details.join(' · ')}'}';
    return '✗ $phase failed';
  }

  static String _formatRate(double bytesPerSec) {
    if (bytesPerSec >= 1024 * 1024) {
      return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)}MB/s';
    }
    if (bytesPerSec >= 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)}KB/s';
    }
    return '${bytesPerSec.round()}B/s';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  static String _formatElapsed(Duration d) {
    final totalSeconds = d.inSeconds;
    if (totalSeconds < 60) return '${totalSeconds}s';
    final m = d.inMinutes;
    final s = totalSeconds % 60;
    if (m < 60) return '${m}m ${s}s';
    return '${d.inHours}h ${m % 60}m';
  }
}
