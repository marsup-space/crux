import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';

/// A single bordered metadata box for vibe mode.
///
/// Renders a rounded-border region with the [title] embedded in the top
/// border (via [BorderTitle]) and [bodyRows] inside the body. The border
/// characters are `╭ ╮ ╰ ╯ ─ │` (nocterm's `BoxBorderStyle.rounded`).
///
/// When [active] is `true`, the border uses [activeColor] with a subtle
/// background tint of the same hue (alpha 0.1). When `false`, the border
/// uses [mutedColor] with no background tint. Border characters stay
/// identical in both states — color + tint carry the signal.
///
/// Colors are picked by the caller from the existing `CruxTheme` palette:
///   think box → `thinkPrefix` (muted) / `responsePrefix` (active)
///   tools box → `toolPrefix` (muted) / `accent` (active)
///   files box → `success` (muted) / `warning` (active)
///
/// No new color slots are added to `CruxThemeData`.
class VibeBox extends StatelessComponent {
  /// The title text embedded in the top border.
  final String title;

  /// The body rows rendered inside the box, one per line.
  final List<String> bodyRows;

  /// Whether this box is "active" (streaming). Active boxes use the
  /// bright color + background tint; inactive boxes use the muted color.
  final bool active;

  /// Border/text color in the muted (inactive) state.
  final Color mutedColor;

  /// Border/text color in the active state. Also drives the background
  /// tint at `withOpacity(0.1)`.
  final Color activeColor;

  /// Text color for the body rows. Defaults to the theme's `text` color.
  final Color? bodyColor;

  const VibeBox({
    required this.title,
    required this.bodyRows,
    this.active = false,
    required this.mutedColor,
    required this.activeColor,
    this.bodyColor,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final borderColor = active ? activeColor : mutedColor;
    final bgColor = active ? activeColor.withOpacity(0.1) : null;
    final effectiveBodyColor = bodyColor ?? theme.text;

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        border: BoxBorder.all(
          color: borderColor,
          style: BoxBorderStyle.rounded,
        ),
        title: BorderTitle(
          text: title,
          alignment: TitleAlignment.left,
          style: TextStyle(color: borderColor, fontWeight: FontWeight.bold),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: bodyRows
            .map((row) => Text(row, style: TextStyle(color: effectiveBodyColor)))
            .toList(),
      ),
    );
  }
}
