import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../theme/crux_theme.dart';
import '../utils/markdown_links.dart';
import '../utils/quick_reply_parser.dart';
import 'ui/highlighted_markdown_text.dart';
import 'vibe_box.dart';
import 'vibe_box_data.dart';

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

  const VibeSegmentBubble({
    required this.segment,
    this.onQuickReplyTap,
    this.enableQuickReplies = false,
    this.onSessionLinkTap,
    this.onLinkTap,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final userText = segment.userMessage.content.replaceAll('\n', ' ').trim();

    final boxes = <Component>[];

    if (segment.think != null) {
      final think = segment.think!;
      final rows = <String>[];
      final secs = think.duration.inMilliseconds / 1000.0;
      rows.add('${secs.toStringAsFixed(1)}s');
      rows.add(formatTokens(think.tokens));
      if (think.effort != null) {
        rows.add(think.effort!);
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
      final rows = tools.entries.map((e) {
        return '${e.name} x${e.callCount}: ${formatTokens(e.totalTokens)}';
      }).toList();
      boxes.add(
        VibeBox(
          title: 'tools',
          bodyRows: rows,
          mutedColor: theme.toolPrefix,
          activeColor: theme.accent,
        ),
      );
    }

    if (segment.mods != null) {
      final mods = segment.mods!;
      // Show just the filename — the directory prefix is rarely
      // interesting at a glance and the box is narrow enough that
      // full paths would push the +N -M diff off the visible
      // region. The full path is still in [ModBoxData.paths] for
      // any future tooltip / filter / drill-down.
      final rows = mods.paths.map((path) {
        final name = p.basename(path);
        final added = mods.linesAdded;
        final removed = mods.linesRemoved;
        return '$name +$added -$removed';
      }).toList();
      if (mods.overflowCount > 0) {
        rows.add('+${mods.overflowCount} more files');
      }
      boxes.add(
        VibeBox(
          title: 'files',
          bodyRows: rows,
          mutedColor: theme.success,
          activeColor: theme.warning,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // User line — only on the first segment of a user turn.
        // Wrapped in the same `Padding(horizontal: 1)` + leading
        // space as the prose row below so the `you:` label and the
        // `crux:` label land on the same column (column 2 — 1 cell
        // of padding + 1 leading space inside the text). Without
        // this, the user line renders flush-left at column 0 while
        // the boxes (Padding(left: 2)) and crux line both start at
        // column 2, which makes the prefix labels look misaligned.
        if (segment.showUserMessage)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Text(
              ' you: $userText',
              style: TextStyle(color: theme.userPrefix),
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
