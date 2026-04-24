import 'package:nocterm/nocterm.dart';

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
///   fillColor: Color.fromRGB(120, 80, 200),
///   emptyColor: Color.fromRGB(30, 25, 50),
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
  final Color fillColor;

  /// Background color for the empty portion.
  final Color emptyColor;

  /// Foreground color for label text on filled background.
  final Color labelFillFg;

  /// Foreground color for label text on empty background.
  final Color labelEmptyFg;

  const BgProgressBar({
    super.key,
    required this.value,
    required this.width,
    this.label,
    this.fillColor = const Color.fromRGB(120, 80, 200),
    this.emptyColor = const Color.fromRGB(30, 25, 50),
    this.labelFillFg = const Color.fromRGB(25, 20, 45),
    this.labelEmptyFg = const Color.fromRGB(200, 180, 255),
  });

  @override
  Component build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    final filledCount = (clamped * width).floor();
    final labelText = label ?? '';
    final labelLen = labelText.length;

    // Center the label within the bar
    final labelStart = (width - labelLen) ~/ 2;

    final cells = <Component>[];
    for (int i = 0; i < width; i++) {
      final isFilled = i < filledCount;
      final bg = isFilled ? fillColor : emptyColor;

      // Check if this cell position holds a label character
      final labelIndex = i - labelStart;
      if (labelLen > 0 && labelIndex >= 0 && labelIndex < labelLen) {
        final fg = isFilled ? labelFillFg : labelEmptyFg;
        cells.add(
          Text(
            labelText[labelIndex],
            style: TextStyle(color: fg, backgroundColor: bg),
          ),
        );
      } else {
        cells.add(
          Text(' ', style: TextStyle(backgroundColor: bg)),
        );
      }
    }

    return Row(children: cells);
  }
}
