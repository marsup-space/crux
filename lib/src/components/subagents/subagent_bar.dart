import 'package:nocterm/nocterm.dart';

import '../../i18n/strings.dart';
import '../../models/subagent.dart';
import '../../services/subagent/subagent_config_store.dart';
import '../../theme/crux_theme.dart';
import '../../utils/terminal_symbols.dart';
import '../ui/glossy_model_button.dart';
import '../ui/hoverable.dart';
import 'subagent_ui_models.dart';

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

  /// In-flight agent chips rendered inside the bar after the toggles
  /// (plan §UI: "Bar 内 chips = 当前 in-flight 的执行体"). Each shows
  /// the ✎/✦ role glyph + localized name; the tooltip carries
  /// domain / intention / model / status. Empty list → toggles only.
  final List<SubagentUiEntry> agents;

  /// Open the agent's detail view when a chip is pressed.
  final ValueChanged<SubagentUiEntry>? onAgentPressed;

  final Strings strings;

  const SubagentBar({
    super.key,
    required this.toggles,
    this.onToggleWorkers,
    this.onToggleExperts,
    this.agents = const [],
    this.onAgentPressed,
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

    // The switch state is color-only: on = success green, off = dim
    // (hover lifts toward foreground). No `on`/`off` suffix — the
    // colored word reads at the same glance and saves the columns.
    Component toggleCell(String label, bool value, VoidCallback? onTap) =>
        Hoverable(
          onTap: onTap,
          builder: (context, isHovered) {
            final color = value
                ? theme.success
                : (isHovered ? theme.foreground : theme.onSurfaceDim);
            return Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: value ? FontWeight.bold : null,
              ),
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
          // In-flight agent chips. The glyph prefixes the localized
          // constellation name; hovering shows the six-line tooltip
          // (domain / intention / model / status) via the shared
          // Hinted wrapper — same interaction as every other chip.
          for (final agent in component.agents) ...[
            Text('  ·  ', style: TextStyle(color: theme.outline)),
            Hinted(
              hint: _agentHint(agent),
              delay: Duration.zero,
              maxLines: 6,
              // In-flight (busy / queued) chips animate so the user sees
              // the state LIVE — a static glyph made a running Worker look
              // idle. Reuse the GlossyModelButton sweep already proven in
              // SubagentToolbarRow; its ticker is self-contained, so the
              // animation runs without needing the parent to rebuild.
              // A stable key keeps the animation state attached to this
              // agent while chips are inserted / removed / reordered.
              child: agent.status.isInFlight
                  ? GlossyModelButton(
                      key: ValueKey(agent.id),
                      label: _agentLabel(agent),
                      isAnimating: true,
                      compact: true,
                      onPressed: component.onAgentPressed == null
                          ? null
                          : () => component.onAgentPressed!(agent),
                    )
                  : Hoverable(
                      onTap: component.onAgentPressed == null
                          ? null
                          : () => component.onAgentPressed!(agent),
                      builder: (context, hovered) => Text(
                        _agentLabel(agent),
                        style: TextStyle(
                          color: hovered ? theme.foreground : theme.accent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  String _agentLabel(SubagentUiEntry agent) {
    final glyph = terminalSymbol(
      agent.role == SubagentRole.expert ? '✦' : '✎',
      agent.role == SubagentRole.expert ? '*' : '>',
    );
    final counter = _roundCounter(agent);
    return '$glyph ${agent.name}'
        '${counter == null ? '' : ' $counter'}';
  }

  /// Round counter suffix for an in-flight chip: `12/40` against a
  /// cap, bare `12` when unlimited, nothing when the entry carries no
  /// live round data (ready rows, legacy projections).
  String? _roundCounter(SubagentUiEntry agent) {
    final progress = agent.roundProgress;
    if (progress == null) return null;
    final limit = agent.roundLimit;
    return limit == null ? '$progress' : '$progress/$limit';
  }

  String _agentHint(SubagentUiEntry agent) {
    final s = component.strings;
    final status = switch (agent.status) {
      SubagentUiStatus.ready => s.t('subagent.tooltip.statusReady'),
      SubagentUiStatus.queued => s.t('subagent.tooltip.statusQueued'),
      SubagentUiStatus.busy => s.t('subagent.tooltip.statusBusy'),
    };
    return [
      s.t('subagent.tooltip.domain', {'domain': agent.domain}),
      if (agent.assignmentIntent != null && agent.assignmentIntent!.isNotEmpty)
        s.t('subagent.tooltip.intent', {'intent': agent.assignmentIntent!}),
      s.t('subagent.tooltip.model', {'model': agent.model}),
      status,
    ].join('\n');
  }
}
