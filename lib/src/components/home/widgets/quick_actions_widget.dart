import 'package:nocterm/nocterm.dart';

import '../../../theme/crux_theme.dart';
import '../home_widgets.dart';

/// One quick action the box offers.
class QuickAction {
  /// Short label rendered in the box (e.g. `/new`).
  final String label;

  /// One-line description of what it does.
  final String hint;

  /// The slash-command text to run, or — when [seed] is true — to place
  /// in the chat input without executing.
  final String command;

  /// When true, the command is *seeded* into the chat input (not run),
  /// so the user completes it there. Seed-only actions are allowed even
  /// mid-stream because they don't execute anything session-mutating.
  final bool seed;

  const QuickAction(
    this.label,
    this.hint,
    this.command, {
    this.seed = false,
  });
}

/// The `quick-actions` box — the primary things to do next.
///
/// Actions are plain tappable rows (keyboard-first, not hover-reveal).
/// Session-mutating actions (`/new`, `/chat`, continue) route through
/// [HomeContext.runCommand], whose mid-stream guard refuses while a
/// response is in flight; the box surfaces that refusal via home's
/// notice. Seed-only actions (`/project `) bypass the guard — they just
/// prefill the input.
class QuickActionsHomeWidget extends HomeWidget {
  /// Seed text into the chat input without executing (the panel's
  /// `_switchProject`-style stash). Used for seed-only actions.
  final void Function(String text) seedInput;

  /// The actions, in display order.
  final List<QuickAction> actions;

  QuickActionsHomeWidget({
    required this.seedInput,
    List<QuickAction>? actions,
  }) : actions = actions ?? _defaultActions;

  static const _defaultActions = [
    QuickAction('/new', 'start a fresh session', '/new'),
    QuickAction('/chat', 'open a Chat-mode session', '/chat'),
    QuickAction('continue', 'resume the last session', 'continue'),
    QuickAction('/project', 'switch project…', '/project ', seed: true),
  ];

  @override
  String get id => 'quick-actions';

  @override
  String get title => 'Quick actions';

  @override
  Set<int> get supportedSpans => const {1, 2};

  @override
  int heightFor(int span) => actions.length;

  @override
  void Function()? activate(HomeContext ctx) {
    // Primary action: the first action (/new), which is session-mutating
    // and therefore guarded by runCommand. Home stays open on refusal so
    // the footer notice explains why nothing happened.
    return () => _run(ctx, actions.first);
  }

  void _run(HomeContext ctx, QuickAction action) {
    if (action.seed) {
      seedInput(action.command);
      ctx.close();
      return;
    }
    if (ctx.runCommand(action.command)) {
      ctx.close();
    }
  }

  @override
  Component build(BuildContext context, HomeContext ctx, int span) {
    final theme = CruxTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final action in actions)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _run(ctx, action),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  action.label,
                  style: TextStyle(
                    color: theme.accent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '  ${action.hint}',
                  style: TextStyle(color: theme.onSurfaceDim),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
