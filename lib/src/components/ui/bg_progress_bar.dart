import 'package:nocterm/nocterm.dart';
import '../../theme/crux_theme.dart';

/// A progress bar that renders progress using background colors.
///
/// Unlike [ProgressBar] which uses fill characters (█/░) that conflict
/// with label text, this component uses the background color of each cell
/// to indicate progress. Label text is rendered on top with contrasting
/// foreground colors, so both the progress and the label are visible
/// simultaneously.
///
/// Example:
/// ```dart
/// BgProgressBar(
///   value: 0.48,
///   width: 20,
///   label: '125073 / 262144',
///   fillColor: CruxTheme.of(context).progressFill,
///   emptyColor: CruxTheme.of(context).progressEmpty,
/// )
/// ```
class BgProgressBar extends StatelessComponent {
  /// Progress value between 0.0 and 1.0.
  final double value;

  /// Width of the bar in character cells.
  final int width;

  /// Optional text label centered within the bar.
  final String? label;

  /// Background color for the filled portion.
  final Color? fillColor;

  /// Background color for the empty portion.
  final Color? emptyColor;

  /// Foreground color for label text on filled background.
  final Color? labelFillFg;

  /// Foreground color for label text on empty background.
  final Color? labelEmptyFg;

  const BgProgressBar({
    super.key,
    required this.value,
    required this.width,
    this.label,
    this.fillColor,
    this.emptyColor,
    this.labelFillFg,
    this.labelEmptyFg,
  });

  @override
  Component build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    final theme = CruxTheme.of(context);
    final resolvedFillColor = fillColor ?? theme.progressFill;
    final resolvedEmptyColor = emptyColor ?? theme.progressEmpty;
    final resolvedLabelFillFg = labelFillFg ?? theme.progressLabelFill;
    final resolvedLabelEmptyFg = labelEmptyFg ?? theme.progressLabelEmpty;

    // Split the (clamped × width) fill into whole cells plus a
    // fractional remainder. The remainder is rendered by lerping
    // the *leading-edge* cell's background between empty and fill
    // colors, so the bar shows continuous progress rather than
    // snapping to 5%-per-cell increments.
    final rawFill = clamped * width;
    final filledCount = rawFill.floor();
    final partial = rawFill - filledCount; // 0..1
    final boundaryIdx =
        (partial > 0.0 && filledCount < width) ? filledCount : -1;

    final labelText = label ?? '';
    final labelLen = labelText.length;

    // Center the label within the bar
    final labelStart = (width - labelLen) ~/ 2;

    final cells = <Component>[];
    for (int i = 0; i < width; i++) {
      final Color bg;
      if (i < filledCount) {
        bg = resolvedFillColor;
      } else if (i == boundaryIdx) {
        bg = Color.lerp(resolvedEmptyColor, resolvedFillColor, partial)!;
      } else {
        bg = resolvedEmptyColor;
      }

      // Check if this cell position holds a label character
      final labelIndex = i - labelStart;
      if (labelLen > 0 && labelIndex >= 0 && labelIndex < labelLen) {
        // For the boundary cell, the bg is a blend — pick whichever
        // label fg has better contrast against the dominant side.
        final Color fg;
        if (i < filledCount) {
          fg = resolvedLabelFillFg;
        } else if (i == boundaryIdx && partial >= 0.5) {
          fg = resolvedLabelFillFg;
        } else {
          fg = resolvedLabelEmptyFg;
        }
        cells.add(
          Text(
            labelText[labelIndex],
            style: TextStyle(color: fg, backgroundColor: bg),
          ),
        );
      } else {
        cells.add(Text(' ', style: TextStyle(backgroundColor: bg)));
      }
    }

    return Row(children: cells);
  }
}
