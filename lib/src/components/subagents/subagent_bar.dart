import 'package:nocterm/nocterm.dart';

import '../../i18n/strings.dart';
import '../../services/subagent/subagent_config_store.dart';
import '../../theme/crux_theme.dart';
import '../ui/hoverable.dart';

/// The subagent bar — a single row rendered **above** the chat toolbar
/// whenever either subagent-mode switch is on.
///
/// Layout: `workers [on|off]  ·  experts [on|off]` — two independent
/// clickable toggles. Clicking one flips the corresponding switch via
/// [onToggleWorkers] / [onToggleExperts] (wired to
/// `SubagentController.setToggle`); the bar itself is stateless — it
/// re-renders from the controller's ChangeNotifier.
///
/// When both switches are off the chat panel does not mount this bar
/// at all, so the toolbar layout is untouched in the default state.
class SubagentBar extends StatefulComponent {
  /// The live toggle state to render. Typically
  /// `SubagentController.toggles`, but any [SubagentRuntimeToggles]
  /// works �� tests pass a const value.
  final SubagentRuntimeToggles toggles;

  /// Flip the workers switch. Null disables interaction (render-only).
  final VoidCallback? onToggleWorkers;

  /// Flip the experts switch. Null disables interaction (render-only).
  final VoidCallback? onToggleExperts;

  final Strings strings;

  const SubagentBar({
    super.key,
    required this.toggles,
    this.onToggleWorkers,
    this.onToggleExperts,
    this.strings = kEnglishStrings,
  });

  @override
  State<SubagentBar> createState() => _SubagentBarState();
}

class _SubagentBarState extends State<SubagentBar> {
  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final strings = component.strings;

    Component toggleCell(
      String label,
      bool value,
      VoidCallback? onTap,
    ) => Hoverable(
      onTap: onTap,
      builder: (context, isHovered) {
        final color = value
            ? theme.success
            : (isHovered ? theme.foreground : theme.onSurfaceDim);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(color: theme.onSurfaceDim)),
            const SizedBox(width: 1),
            Text(
              value ? 'on' : 'off',
              style: TextStyle(
                color: color,
                fontWeight: value ? FontWeight.bold : null,
              ),
            ),
          ],
        );
      },
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          toggleCell(
            strings.t('subagent.bar.workers'),
            component.toggles.workersOn,
            component.onToggleWorkers,
          ),
          Text('  ·  ', style: TextStyle(color: theme.outline)),
          toggleCell(
            strings.t('subagent.bar.experts'),
            component.toggles.expertsOn,
            component.onToggleExperts,
          ),
        ],
      ),
    );
  }
}
