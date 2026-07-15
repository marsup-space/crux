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

    // Padding is OUTSIDE the LayoutBuilder so the builder sees
    // the post-padding maxWidth. The reverse ordering (builder
    // outside, padding inside) was the cause of a 2-cell wrap
    // visible at narrow panel widths: the math said "this line
    // is N cells" using the un-padded width, then the Text
    // widget inside Padding tried to fit N cells into N-2 and
    // wrapped the last 2 dashes onto a second line.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      child: SizedBox(
        width: double.infinity,
        child: LayoutBuilder(
          builder: (ctx, constraints) {
            final maxWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth.toInt()
                : 0;
            final label = ' ${formatAgentTurnGap(sinceLastTurn)} ';
            final remaining = maxWidth - label.length;

            // Same edge-to-edge dash pattern as [CompactionDivider].
            // Use ASCII `-` (U+002D) — many terminal fonts render
            // U+2500 LIGHT HORIZONTAL as 2 cells while nocterm's
            // wcwidth returns 1, leading to a "fit" that doesn't
            // fit. ASCII `-` is exactly 1 cell in every font.
            return remaining > 0
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
                  );
          },
        ),
      ),
    );
  }
}
