import 'package:nocterm/nocterm.dart';

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
      final rows = mods.paths.map((path) {
        final added = mods.linesAdded;
        final removed = mods.linesRemoved;
        return '$path +$added -$removed';
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
        if (segment.showUserMessage)
          Text(
            'you: $userText',
            style: TextStyle(color: theme.userPrefix),
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
        // Prose line (null for pending segments during streaming).
        // Uses the same Row + Expanded pattern as MessageBubble so
        // the 'crux:' prefix sits inline with the first line of the
        // markdown content, not on a separate line.
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
                  child: HighlightedMarkdownText(segment.prose!.content),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
