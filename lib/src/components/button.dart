import 'package:nocterm/nocterm.dart';

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
  final Color color;

  /// Text color when the button is hovered.
  final Color hoverColor;

  /// Background color in the normal state.
  final Color bgColor;

  /// Background color when hovered.
  final Color hoverBgColor;

  /// Border color in the normal state.
  final Color borderColor;

  /// Border color when hovered.
  final Color hoverBorderColor;

  /// Padding inside the button.
  final EdgeInsets padding;

  /// Text style applied to the label (color is overridden by hover state).
  final TextStyle? style;

  const Button({
    super.key,
    required this.label,
    this.onPressed,
    this.color = Colors.gray,
    this.hoverColor = Colors.brightCyan,
    this.bgColor = const Color.fromRGB(25, 20, 45),
    this.hoverBgColor = const Color.fromRGB(40, 30, 80),
    this.borderColor = const Color.fromRGB(50, 50, 70),
    this.hoverBorderColor = const Color.fromRGB(100, 80, 160),
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
    final activeColor = _hovered ? btn.hoverColor : btn.color;
    final activeBgColor = _hovered ? btn.hoverBgColor : btn.bgColor;
    final activeBorderColor =
        _hovered ? btn.hoverBorderColor : btn.borderColor;

    final effectiveStyle = TextStyle(
      color: activeColor,
      fontWeight: _hovered ? FontWeight.bold : null,
    ).merge(btn.style);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      opaque: false,
      child: GestureDetector(
        onTap: btn.onPressed,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: activeBgColor,
            border: BoxBorder(
              top: BorderSide(color: activeBorderColor),
              bottom: BorderSide(color: activeBorderColor),
              left: BorderSide(color: activeBorderColor),
              right: BorderSide(color: activeBorderColor),
            ),
          ),
          padding: btn.padding,
          child: Text(btn.label, style: effectiveStyle),
        ),
      ),
    );
  }
}
