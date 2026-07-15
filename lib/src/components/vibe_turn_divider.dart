import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../utils/duration_format.dart';

/// Inline divider rendered above a user message in vibe mode,
/// marking the boundary between the previous agent turn and the
/// new user turn.
///
/// Mirrors the visual style of [CompactionDivider] (dashes
/// flanking a centered label that fills the available width),
/// but the label is a relative-time string like "5 minutes
/// ago" or "2 days and 3 hours 14 minutes ago" instead of
/// "Compaction". The intent is the same: a structural marker
/// that doesn't claim vertical real estate beyond a single row
/// and slots in between segments without a bulky separator
/// widget.
///
/// In production the divider is a static marker — the time
/// delta is informational, not interactive. There's no
/// onTap / fullpane hook (unlike Compaction, which has a
/// debug-mode click target that opens the raw compacted log).
class VibeTurnDivider extends StatelessComponent {
  /// How long ago the previous agent turn ended. The label is
  /// derived from this via [formatAgentTurnGap].
  final Duration sinceLastTurn;

  const VibeTurnDivider({
    required this.sinceLastTurn,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.toInt()
            : 0;
        final label = ' ${formatAgentTurnGap(sinceLastTurn)} ';
        final remaining = maxWidth - label.length;

        // Body: same edge-to-edge dash pattern as CompactionDivider
        // — SizedBox(forced-width) so the LayoutBuilder sees a real
        // maxWidth even when the divider sits inside a Row's
        // MainAxisSize.min column, then dashes+label+dashes.
        //
        // Use ASCII `-` (U+002D HYPHEN-MINUS) for the dash, not
        // `─` (U+2500 BOX DRAWINGS LIGHT HORIZONTAL). Both are
        // classified as East Asian Width "Narrow" in the Unicode
        // table and both return wcwidth=1 in nocterm's lookup,
        // so the LayoutBuilder math above treats them as equal.
        // However, many terminal fonts (especially those that
        // fall back to a CJK / wide glyph for U+2500) actually
        // render `─` as 2 cells — and nocterm's Text widget
        // does NOT post-render-correct against the terminal's
        // font, so the layout math would compute "this line is
        // 80 cells" while the terminal paints 136 cells and
        // wraps. ASCII `-` is rendered as exactly 1 cell by
        // every font the project supports, so the rendered
        // line width always matches the math.
        final line = SizedBox(
          width: double.infinity,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
            child: remaining > 0
                ? (() {
                    final leftPad = remaining ~/ 2;
                    final rightPad = remaining - leftPad;
                    return Text(
                      '-' * leftPad + label + '-' * rightPad,
                      style: TextStyle(color: theme.onSurfaceDim),
                    );
                  })()
                : Text(
                    label,
                    style: TextStyle(color: theme.onSurfaceDim),
                  ),
          ),
        );

        return line;
      },
    );
  }
}
