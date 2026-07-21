import 'package:nocterm/nocterm.dart';
import '../../theme/crux_theme.dart';

/// A reusable button component with hover and click support.
///
/// Displays a label text that changes appearance when the mouse hovers
/// over it and responds to tap/click via [onPressed].
///
/// Example:
/// ```dart
/// Button(
///   label: 'Click me',
///   onPressed: () => print('Button pressed'),
/// )
/// ```
class Button extends StatefulComponent {
  /// The text displayed inside the button.
  final String label;

  /// Callback invoked when the button is tapped.
  final VoidCallback? onPressed;

  /// Text color in the normal (non-hovered) state.
  final Color? color;

  /// Text color when the button is hovered.
  final Color? hoverColor;

  /// Background color in the normal state.
  final Color? bgColor;

  /// Background color when hovered.
  final Color? hoverBgColor;

  /// Padding inside the button.
  final EdgeInsets padding;

  /// Text style applied to the label (color is overridden by hover state).
  final TextStyle? style;

  /// Whether the button is keyboard-focused.
  final bool focused;

  /// Text color when keyboard-focused.
  final Color? focusColor;

  /// Background color when keyboard-focused.
  final Color? focusBgColor;

  const Button({
    super.key,
    required this.label,
    this.onPressed,
    this.color,
    this.hoverColor,
    this.bgColor,
    this.hoverBgColor,
    this.focused = false,
    this.focusColor,
    this.focusBgColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 1),
    this.style,
  });

  @override
  State<Button> createState() => _ButtonState();
}

class _ButtonState extends State<Button> {
  bool _hovered = false;

  @override
  Component build(BuildContext context) {
    final btn = component;
    final theme = CruxTheme.of(context);
    final activeColor = _hovered
        ? btn.hoverColor ?? theme.buttonTextHover
        : btn.focused
        ? btn.focusColor ?? theme.buttonTextFocused
        : btn.color ?? theme.buttonText;
    final activeBgColor = _hovered
        ? btn.hoverBgColor ?? theme.buttonBackgroundHover
        : btn.focused
        ? btn.focusBgColor ?? theme.buttonBackgroundFocused
        : btn.bgColor ?? theme.buttonBackground;

    final effectiveStyle = TextStyle(
      color: activeColor,
      fontWeight: _hovered || btn.focused ? FontWeight.bold : null,
    ).merge(btn.style);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      opaque: false,
      child: GestureDetector(
        onTap: btn.onPressed,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(color: activeBgColor),
          padding: btn.padding,
          child: Text(btn.label, style: effectiveStyle),
        ),
      ),
    );
  }
}
