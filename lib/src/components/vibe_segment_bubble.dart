import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../theme/crux_theme.dart';
import 'ui/highlighted_markdown_text.dart';
import 'vibe_box.dart';
import 'vibe_box_data.dart';

/// Renders one [VibeSegment]: user line + three aggregated metadata
/// boxes (think, tools, files) + prose line.
///
/// In v1 this widget handles completed (persisted) segments only.
/// Live streaming segments are rendered by the existing
/// [StreamingBubble] in verbose mode; the vibe-mode live rendering
/// (polling StreamingController at frame rate) is future work.
///
/// Boxes are omitted when their data is null — no empty bordered
/// region renders. The three boxes are laid out in a [Row] side-by-side;
/// if the joined width exceeds the panel, the caller's [LayoutBuilder]
/// constraints will cause overflow, which the user can scroll to see.
/// (The design doc's horizontal↔vertical flip is future work; v1
/// uses horizontal only.)
class VibeSegmentBubble extends StatelessComponent {
  final VibeSegment segment;

  const VibeSegmentBubble({
    required this.segment,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final userText = segment.userMessage.content
        .replaceAll('\n', ' ')
        .trim();

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
        // Prose line. Per the per-turn model, [segment.prose] is
        // the concatenated prose string for the turn — every
        // `ai` row's content and every non-empty `tool_call`
        // row's content joined with `\n\n`. Renders under the
        // `crux:` prefix. Null on a pending or boxes-only
        // segment.
        if (segment.prose != null && segment.prose!.trim().isNotEmpty)
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
                  child: HighlightedMarkdownText(segment.prose!),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
