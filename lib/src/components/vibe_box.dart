import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../utils/text_width.dart';

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

  /// Rich-text body rows. When non-null this takes precedence over
  /// [bodyRows] and each row renders as a [RichText] span tree, so a
  /// row can mix colors (e.g. the tools box's color-coded LSP outcome
  /// glyph). Spans that don't set their own color should rely on the
  /// default — pass [bodyColor] down by giving uncolored spans no
  /// explicit style and letting the box wrap them (see build).
  final List<TextSpan>? bodyRowSpans;

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

  /// Interactive body rows. When non-null this takes precedence over both
  /// [bodyRows] and [bodyRowSpans]; each entry renders as its own
  /// component, so a row can host hover / tap affordances (the files
  /// box's per-row open·diff swap). Rows are laid out exactly like the
  /// plain text rows — one per line, left-aligned.
  final List<Component>? bodyRowComponents;

  const VibeBox({
    required this.title,
    this.bodyRows = const [],
    this.bodyRowSpans,
    this.bodyRowComponents,
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

    // Rich rows take precedence: wrap each span tree in a RichText. A
    // top-level span with no explicit color inherits the box body color
    // via the wrapping style; spans that set their own color (the LSP
    // glyph) keep it because TextSpan children override the inherited
    // style per-span. Plain rows fall back to simple Text widgets.
    //
    // The list is created with an explicit `<Component>` type argument
    // (not `.toList()` on the mapped iterable) so its reified element
    // type is Component. `.map(...).toList()` would reify to the mapped
    // type (Text / RichText), and the later `add(Padding(...))` — a
    // different component subclass — would then throw
    // "type 'Padding' is not a subtype of type 'Text'" at runtime.
    final bodyChildren = <Component>[];
    final rowComponents = bodyRowComponents;
    final spans = bodyRowSpans;
    if (rowComponents != null) {
      // Interactive rows (the files box): each entry is already a full
      // component — render as-is.
      bodyChildren.addAll(rowComponents);
    } else if (spans != null) {
      for (final span in spans) {
        bodyChildren.add(
          RichText(
            text: TextSpan(
              style: TextStyle(color: effectiveBodyColor),
              children: [span],
            ),
          ),
        );
      }
    } else {
      for (final row in bodyRows) {
        bodyChildren.add(
          Text(row, style: TextStyle(color: effectiveBodyColor)),
        );
      }
    }

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
      // Guarantee enough width for the border title. Title painting
      // (decorated_box.dart) needs ` W ≥ title + 6 ` for an untruncated
      // `␣title␣`: two corners + one horizontal col before the title +
      // `␣title␣` (title+2) + at least one horizontal col after. A
      // content-like box ("0.3s" / "max", ~4 cols) otherwise shrink-wraps
      // to ~9 columns and the top border degrades the title to `th…`.
      // minWidth degrades safely via BoxConstraints.enforce when the row
      // truly runs out of space.
      constraints: BoxConstraints(
        minWidth: (stringWidth(title) + 6).toDouble(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: bodyChildren,
      ),
    );
  }
}
