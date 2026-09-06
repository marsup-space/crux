import 'package:nocterm/nocterm.dart';

typedef HoverableBuilder = Component Function(
  BuildContext context,
  bool hovered,
);

/// Shared mouse-interaction primitive for Crux controls.
///
/// It owns hover state and optional tap handling so controls do not each
/// reimplement MouseRegion/GestureDetector coordination. Visuals stay with the
/// caller through [builder], which keeps this usable for buttons, rows, tabs,
/// cards, and decorated input shells.
class Hoverable extends StatefulComponent {
  final HoverableBuilder builder;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onHoverChanged;
  final bool enabled;
  final bool opaque;
  final HitTestBehavior behavior;

  const Hoverable({
    super.key,
    required this.builder,
    this.onTap,
    this.onHoverChanged,
    this.enabled = true,
    this.opaque = false,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hovered = false;

  void _setHovered(bool value) {
    final next = value && component.enabled;
    if (_hovered == next) return;
    setState(() => _hovered = next);
    component.onHoverChanged?.call(next);
  }

  @override
  Component build(BuildContext context) {
    final child = component.builder(context, _hovered && component.enabled);
    final interactive = component.onTap == null
        ? child
        : GestureDetector(
            onTap: component.enabled ? component.onTap : null,
            behavior: component.behavior,
            child: child,
          );
    return MouseRegion(
      opaque: component.opaque,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: interactive,
    );
  }
}
