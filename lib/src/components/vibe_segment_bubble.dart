import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../models/message.dart';
import '../services/llm_provider.dart';
import '../theme/crux_theme.dart';
import '../utils/markdown_links.dart';
import '../utils/quick_reply_parser.dart';
import '../utils/strip_skill_bodies.dart';
import 'ui/highlighted_markdown_text.dart';
import 'lsp_state_glyph.dart';
import 'vibe_box.dart';
import 'vibe_box_data.dart';
import 'vibe_file_row.dart';

/// Renders one [VibeSegment]: user line + three aggregated metadata
/// boxes (think, tools, files) + prose line.
///
/// The prose row is rendered through [HighlightedMarkdownText] and
/// receives the same three clickable-token callbacks the verbose
/// `MessageBubble` uses:
///
/// * [onQuickReplyTap] — fired when the user clicks an
///   `ask://label{answer}` (or shorthand `ask://label`) button.
///   Gated to the most-recently-persisted AI segment so older turns'
///   asks don't fire; see [enableQuickReplies] for the exact rule.
/// * [onSessionLinkTap] — fired when the user clicks a
///   `ses://<id>` reference in the prose. Always forwarded (every
///   persisted turn is fair game for session switching).
/// * [onLinkTap] — fired when the user clicks a markdown link of
///   the form `[label](url)`. Always forwarded for the same reason.
///
/// Boxes are omitted when their data is null — no empty bordered
/// region renders. The three boxes are laid out in a [Row] side-by-side;
/// if the joined width exceeds the panel, the caller's [LayoutBuilder]
/// constraints will cause overflow, which the user can scroll to see.
/// (The design doc's horizontal↔vertical flip is future work; v1
/// uses horizontal only.)
class VibeSegmentBubble extends StatelessComponent {
  final VibeSegment segment;

  /// Forwarded to the prose [HighlightedMarkdownText] so any
  /// `ask://label{answer}` token in the segment's prose becomes a
  /// clickable button. Mirrors the same callback on the verbose
  /// `MessageBubble` so the chat panel can use one handler for both
  /// display modes.
  final void Function(QuickReply reply)? onQuickReplyTap;

  /// True when this segment is the most-recently-persisted AI segment
  /// in the open response. The chat history computes this and passes
  /// it down so quick replies are only clickable on the active reply
  /// (older turns' asks are stale and would mislead the user). The
  /// verbose path uses `i == latestAiIndex` for the same purpose;
  /// vibe's walker fans an agent turn into multiple segments, so
  /// the gating happens at the segment level instead of at the
  /// message index.
  ///
  /// The bubble also forces the value to `false` for prose rows
  /// whose `Message.role` is `tool_call` — those are mid-round
  /// remarks, not full replies, and never carry actionable asks.
  final bool enableQuickReplies;

  /// Forwarded for every persisted segment, regardless of whether
  /// it is the "latest closed AI" — switching to a referenced
  /// session is always safe, even for an older turn. When null,
  /// `ses://<id>` references render as plain prose.
  final void Function(int sessionId)? onSessionLinkTap;

  /// Forwarded for every persisted segment, regardless of gating —
  /// a markdown link to docs or an external resource is still
  /// useful to open from older turns. When null, `[label](url)`
  /// links render as plain prose.
  final void Function(MarkdownLink link)? onLinkTap;

  /// Fired when the user activates `open` on a file row. Receives the
  /// file's display path; the chat panel reveals it in the system file
  /// manager. When null, the row's `open` action is omitted.
  final void Function(String path)? onOpenFile;

  /// Fired when the user activates `diff` on a file row. Receives the
  /// file's index within the segment's files list plus the segment's
  /// [ModBoxData] and mutating tool calls, so the chat panel can open
  /// the diff fullpane focused on that file. When null, the row's `diff`
  /// action is omitted.
  final void Function(int fileIndex, ModBoxData mods, List<ToolCallData> calls)?
  onDiffFiles;

  /// Reasoning presets from the session's provider, used to map
  /// the persisted [ThinkBoxData.effort] internal value to its
  /// display label (e.g. `normal` → `adaptive` for MiniMax).
  /// Mirrors the same parameter on [VibeStreamingBubble] and
  /// `MessageBubble` so the live and consolidated bubbles agree
  /// on how the same effort renders. When null/empty, the raw
  /// internal value is used (identity mapping).
  final List<ReasoningPreset> reasoningPresets;

  const VibeSegmentBubble({
    required this.segment,
    this.onQuickReplyTap,
    this.enableQuickReplies = false,
    this.onSessionLinkTap,
    this.onLinkTap,
    this.onOpenFile,
    this.onDiffFiles,
    this.reasoningPresets = const [],
    super.key,
  });

  

  /// Map a persisted effort internal value to its display label
  /// using the provider's reasoning presets. Returns the raw
  /// value when there's no preset entry — same fallback as the
  /// streaming bubble and `MessageBubble` so all three renderers
  /// agree on what the user sees.
  String _displayEffort(String internal) {
    for (final p in reasoningPresets) {
      if (p.internalValue == internal) return p.displayLabel;
    }
    return internal;
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  static String _fmtDuration(int secs) {
    if (secs < 60) return '${secs}s';
    final m = secs ~/ 60;
    final s = secs % 60;
    if (m < 60) return '${m}m ${s}s';
    return '${m ~/ 60}h ${m % 60}m';
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);

    final boxes = <Component>[];

    if (segment.think != null) {
      final think = segment.think!;
      final rows = <String>[];
      final secs = think.duration.inMilliseconds / 1000.0;
      rows.add('${secs.toStringAsFixed(1)}s');
      rows.add(formatTokens(think.tokens));
      if (think.effort != null) {
        // Apply the provider's internal→display mapping (e.g.
        // `normal` → `adaptive` for MiniMax). Without this the
        // consolidated segment bubble shows the raw internal
        // value while the streaming bubble next to it shows the
        // mapped label — the same effort rendering two ways in
        // the same view. `ThinkBoxData.effort` is documented as
        // "stored as a raw string because many models override
        // the display value", so the mapping belongs here, not
        // at the walker.
        rows.add(_displayEffort(think.effort!));
      }
      boxes.add(
        VibeBox(
          title: 'think',
          bodyRows: rows,
          mutedColor: theme.thinkPrefix,
          activeColor: theme.responsePrefix,
        ),
      );
    }

    if (segment.tools != null) {
      final tools = segment.tools!;
      // Build each row as spans so the LSP outcome glyph (`⎇`) can be
      // color-coded (green/red/yellow) while the rest of the row keeps
      // the box's default text color. Entries with LspState.none get no
      // glyph and render as a plain single-span row.
      final rowSpans = tools.entries.map((e) {
        final label =
            '${e.name} x${e.callCount}: ${formatTokens(e.totalTokens)}';
        final glyph = lspStateGlyphSpan(e.lspState, theme);
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
          title: 'tools',
          bodyRowSpans: rowSpans,
          mutedColor: theme.toolPrefix,
          activeColor: theme.accent,
        ),
      );
    }

    if (segment.mods != null) {
      final mods = segment.mods!;
      // One interactive multibutton row per file. Hovering a row swaps
      // it for `open` / `diff` actions (see [VibeFileRow]); the resting
      // row shows the basename plus its own per-file `+N -M` counts from
      // [ModBoxData.files] (falling back to the segment sums for legacy
      // segments that predate per-file entries).
      final rows = <Component>[];
      for (var i = 0; i < mods.paths.length; i++) {
        final path = mods.paths[i];
        final name = p.basename(path);
        final entry = i < mods.files.length ? mods.files[i] : null;
        final added = entry?.linesAdded ?? mods.linesAdded;
        final removed = entry?.linesRemoved ?? mods.linesRemoved;
        rows.add(
          VibeFileRow(
            key: ValueKey('vibe-file-$i-$path'),
            name: name.isEmpty ? path : name,
            linesAdded: added,
            linesRemoved: removed,
            onOpen: onOpenFile == null ? null : () => onOpenFile!(path),
            onDiff: onDiffFiles == null
                ? null
                : () => onDiffFiles!(i, mods, segment.modCalls),
          ),
        );
      }
      if (mods.overflowCount > 0) {
        rows.add(
          Text(
            '+${mods.overflowCount} more files',
            style: TextStyle(color: theme.onSurfaceDim),
          ),
        );
      }
      boxes.add(
        VibeBox(
          title: 'files',
          bodyRowComponents: rows,
          mutedColor: theme.success,
          activeColor: theme.warning,
        ),
      );
    }

    // Persisted progress box: the compact echo of a long-running bash
    // call that reported progress signals. Green ✓ on success, warning
    // ✗ on failure — same palette convention as the other boxes (muted
    // color carries the state; the box is never "active" once persisted).
    if (segment.progress != null) {
      final p = segment.progress!;
      final ok = p.exitCode == 0;
      final phase = p.phase ?? 'bash';
      final details = <String>[];
      if (p.peakPercent != null) details.add('${p.peakPercent!.round()}%');
      if (p.bytes > 0) details.add(_fmtBytes(p.bytes));
      if (p.durationSec > 0) details.add(_fmtDuration(p.durationSec));
      final row = ok
          ? '✓ $phase${details.isEmpty ? '' : ' · ${details.join(' · ')}'}'
          : '✗ $phase failed'
                '${p.peakPercent != null ? ' at ${p.peakPercent!.round()}%' : ''}';
      boxes.add(
        VibeBox(
          title: 'progress',
          bodyRows: [row],
          mutedColor: ok ? theme.success : theme.warning,
          activeColor: theme.accent,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // User line — only on the first segment of a user turn.
        // Mirrors the verbose `MessageBubble` layout:
        //   `Padding(horizontal: 1) → Row(Text(' You: '), Expanded(Text(userText)))`
        // so the user prose starts at the same column as the
        // agent prose below (column 8 — 1 cell of padding + the
        // 7-char `' You: '` prefix). Earlier this used a single
        // flat `Text(' you: $userText')` whose 6-char `' you: '`
        // prefix put the text at column 7, off by one from the
        // crux row. The `Expanded` also gives the user text a
        // real width budget so terminal-driven soft-wrap aligns
        // continuation lines at the same column as the first
        // line — without it, a long message wrapped flush-left
        // under the bubble's column 1, breaking the visual
        // anchor the prefix establishes. Explicit user newlines
        // keep their natural indentation inside `Expanded`.
        if (segment.showUserMessage)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ' You: ',
                  style: TextStyle(
                    color: theme.userPrefix,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  // Strip the `Skill: <name>\n<body>` blocks appended
                  // for the LLM — the chat log shows only what the
                  // user actually typed (mirrors the verbose
                  // `MessageBubble`).
                  child: Text(
                    stripSkillBodies(segment.userMessage.content).trim(),
                  ),
                ),
              ],
            ),
          ),
        // Boxes (only render if at least one box exists)
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
        // Prose line. Single closing message — its `content` is
        // rendered under the `crux:` prefix. Either `role: 'ai'`
        // (the agent's prose reply) or `role: 'tool_call'` with
        // non-empty content (a mid-round remark that itself
        // closed a prose boundary). Null on a pending or
        // boxes-only segment.
        if (segment.prose != null && segment.prose!.content.trim().isNotEmpty)
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
                  // Forward every markdown clickable token the way
                  // the verbose `MessageBubble` does. Quick-reply
                  // is gated to the latest closed AI segment so
                  // older turns' `ask://` labels don't go stale; the
                  // session link and markdown link callbacks are
                  // always live because a `ses://<id>` or
                  // `[label](url)` reference in an older turn is
                  // still actionable. When any callback is null,
                  // [HighlightedMarkdownText] short-circuits the
                  // matching token type — zero per-build cost, so
                  // the verbose path's `null` callback trick is
                  // preserved for legacy callers.
                  child: HighlightedMarkdownText(
                    segment.prose!.content,
                    onQuickReplyTap:
                        enableQuickReplies && segment.prose!.role == 'ai'
                        ? onQuickReplyTap
                        : null,
                    onSessionLinkTap: onSessionLinkTap,
                    onLinkTap: onLinkTap,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
