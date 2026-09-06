import 'package:nocterm/nocterm.dart';

import '../../theme/crux_theme.dart';
import '../../utils/terminal_symbols.dart';
import 'hoverable.dart';

/// A segmented toggle widget that displays mutually exclusive options
/// side-by-side in a bordered group.
///
/// When [focused], the group draws a bright cyan rounded border, and
/// the selection can be changed with arrow keys (handled by the parent
/// [Focusable]'s `onKeyEvent`).
///
/// Each option uses the shared [Hoverable] interaction wrapper and responds
/// to mouse hover with a highlight.
///
/// ```dart
/// OptionToggle(
///   options: const ['OpenAI Compatible', 'Anthropic Compatible'],
///   selectedIndex: 0,
///   onChanged: (i) => setState(() => _index = i),
///   focused: true,
/// )
/// ```
class OptionToggle extends StatefulComponent {
  /// Labels for each option in the toggle group.
  final List<String> options;

  /// Index of the currently selected option.
  final int selectedIndex;

  /// Called when the user clicks an option or the parent routes an
  /// arrow-key event to change the selection.
  final ValueChanged<int> onChanged;

  /// Whether the toggle group has keyboard focus, which controls
  /// the border highlight.
  final bool focused;

  /// Border color when [focused] is true.
  final Color? focusedBorderColor;

  /// Border color when [focused] is false.
  final Color? unfocusedBorderColor;

  /// Background color of the selected option.
  final Color? selectedBgColor;

  /// Background color of an unselected option.
  final Color? unselectedBgColor;

  /// Background color when hovering over an unselected option.
  final Color? hoverBgColor;

  /// Text color of the selected option.
  final Color? selectedTextColor;

  /// Text color of an unselected option.
  final Color? unselectedTextColor;

  /// Text color when hovering.
  final Color? hoverTextColor;

  /// Called when a mouse click should move the owning keyboard focus.
  final ValueChanged<int>? onFocusRequest;

  /// Group border color while the pointer is over any option.
  final Color? hoveredBorderColor;

  const OptionToggle({
    super.key,
    required this.options,
    required this.selectedIndex,
    required this.onChanged,
    required this.focused,
    this.focusedBorderColor,
    this.unfocusedBorderColor,
    this.selectedBgColor,
    this.unselectedBgColor,
    this.hoverBgColor,
    this.selectedTextColor,
    this.unselectedTextColor,
    this.hoverTextColor,
    this.onFocusRequest,
    this.hoveredBorderColor,
  });

  @override
  State<OptionToggle> createState() => _OptionToggleState();
}

class _OptionToggleState extends State<OptionToggle> {
  int? _hoveredIndex;

  @override
  Component build(BuildContext context) {
    final comp = component;
    final theme = CruxTheme.of(context);
    final selectedBgColor = comp.selectedBgColor ?? theme.wizardRowBgSelected;
    final unselectedBgColor = comp.unselectedBgColor ?? theme.buttonBackground;
    final hoverBgColor = comp.hoverBgColor ?? theme.surfaceVariant;
    final selectedTextColor = comp.selectedTextColor ?? theme.buttonTextFocused;
    final unselectedTextColor =
        comp.unselectedTextColor ?? theme.buttonTextDisabled;
    final hoverTextColor = comp.hoverTextColor ?? theme.foreground;
    final children = <Component>[];

    for (int i = 0; i < comp.options.length; i++) {
      final isSelected = i == comp.selectedIndex;
      children.add(
        Hoverable(
          onTap: () {
            comp.onFocusRequest?.call(i);
            comp.onChanged(i);
          },
          onHoverChanged: (hovered) => setState(() {
            if (hovered) {
              _hoveredIndex = i;
            } else if (_hoveredIndex == i) {
              _hoveredIndex = null;
            }
          }),
          builder: (context, isHovered) {
            final bgColor = isSelected
                ? selectedBgColor
                : isHovered
                ? hoverBgColor
                : unselectedBgColor;
            final textColor = isSelected
                ? selectedTextColor
                : isHovered
                ? hoverTextColor
                : unselectedTextColor;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
              decoration: BoxDecoration(color: bgColor),
              child: Text(
                isSelected
                    ? '${terminalSymbol('▶', '>')} ${comp.options[i]}'
                    : '  ${comp.options[i]}',
                style: TextStyle(
                  color: textColor,
                  fontWeight: isSelected ? FontWeight.bold : null,
                ),
              ),
            );
          },
        ),
      );

      if (i < comp.options.length - 1) {
        children.add(Text(' │ ', style: TextStyle(color: theme.outline)));
      }
    }

    final borderColor = comp.focused || _hoveredIndex != null
        ? (_hoveredIndex != null
              ? comp.hoveredBorderColor ?? theme.outlineBright
              : comp.focusedBorderColor ?? theme.buttonTextFocused)
        : comp.unfocusedBorderColor ?? theme.outline;

    return Container(
      decoration: BoxDecoration(
        color: unselectedBgColor,
        border: BoxBorder(
          top: BorderSide(color: borderColor, style: BoxBorderStyle.rounded),
          right: BorderSide(color: borderColor, style: BoxBorderStyle.rounded),
          bottom: BorderSide(color: borderColor, style: BoxBorderStyle.rounded),
          left: BorderSide(color: borderColor, style: BoxBorderStyle.rounded),
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}
