// We import nocterm's internal `UnicodeWidth` (the same util its
// `Text` widget uses to compute display width) so the dash/label
// math here matches what the renderer actually paints to the
// terminal. Without this, `String.length` would under-count
// any wide unicode character (CJK ideographs, full-width
// punctuation, etc.) and the line would silently wrap.
// ignore_for_file: implementation_imports
import 'package:nocterm/src/utils/unicode_width.dart';
import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../i18n/strings.dart';
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
  final Strings strings;

  const VibeTurnDivider({
    required this.sinceLastTurn,
    this.strings = kEnglishStrings,
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
            final label =
                ' ${formatAgentTurnGap(sinceLastTurn, strings: strings)} ';
            // Use nocterm's display-width util so the math here
            // matches what the inner `Text` widget actually paints
            // to the terminal. Plain `label.length` would be off
            // for any wide unicode character (CJK ideograph, full-
            // width punctuation, etc.) — the `Text` widget would
            // still paint at its real width, the line would just
            // appear visually mis-cropped.
            final labelWidth = UnicodeWidth.stringWidth(label);
            // Use the same box-drawing horizontal glyph as borders and
            // markdown rules. A repeated ASCII hyphen is visibly dashed in
            // many terminal fonts even though the cells are adjacent.
            const rule = '─';
            final dashWidth = UnicodeWidth.stringWidth(rule);
            // Available cell count after the label is set aside.
            // `maxWidth` already reflects whatever Padding above
            // us consumed, so we don't subtract it again here.
            final remaining = maxWidth - labelWidth;
            if (remaining <= 0 || dashWidth == 0) {
              // Either the line is too narrow for the label alone,
              // or for some reason `-` is zero-width (shouldn't
              // happen on any sane terminal, but guard). Either
              // way, dropping the dashes is the right call: the
              // label still renders, just without the flanking
              // padding.
              return Text(label, style: TextStyle(color: theme.onSurfaceDim));
            }
            // Distribute the remaining cells as evenly as possible
            // on both sides of the label. `leftPad` is the smaller
            // side; if `remaining` is odd, the extra cell lands on
            // the right (matching [CompactionDivider]'s convention,
            // which keeps the right edge flush with what the
            // `TextOverflow` math would expect).
            final leftPad = remaining ~/ (2 * dashWidth);
            final rightPad = (remaining - leftPad * dashWidth) ~/ dashWidth;
            return Text(
              rule * leftPad + label + rule * rightPad,
              style: TextStyle(color: theme.onSurfaceDim),
            );
          },
        ),
      ),
    );
  }
}
