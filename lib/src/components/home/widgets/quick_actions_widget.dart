import 'package:nocterm/nocterm.dart';

import '../../../i18n/strings.dart';
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

  // Hints are catalog keys (`home.qa.*`), resolved at render via the
  // active locale's `Strings`. A raw English hint injected by tests (or a
  // caller-supplied action) passes through `Strings.t` unchanged, while
  // the defaults localize.
  static const _defaultActions = [
    QuickAction('/new', 'home.qa.freshSession', '/new'),
    QuickAction('/chat', 'home.qa.chatSession', '/chat'),
    QuickAction('continue', 'home.qa.resume', 'continue'),
    QuickAction('/project', 'home.qa.switchProject', '/project ', seed: true),
  ];

  @override
  String get id => 'quick-actions';

  @override
  String get title => 'Quick actions';

  @override
  String titleFor(HomeContext ctx) => ctx.strings.t('home.title.quickActions');

  @override
  Set<int> get supportedSpans => const {1, 2};

  @override
  int heightFor(int span) => actions.length;

  // ── Item selection ────────────────────────────────────────────────

  int _selectedIndex = 0;

  @override
  int get itemCount => actions.length;

  @override
  int get selectedIndex => _selectedIndex;

  @override
  void moveSelection(int delta) {
    _selectedIndex =
        (_selectedIndex + delta) % actions.length;
    if (_selectedIndex < 0) _selectedIndex += actions.length;
  }

  @override
  bool selectItemAt(int index) {
    if (index < 0 || index >= actions.length) return false;
    // No-op when the highlight is already here: home's onHover fires
    // on every mouse-motion event, so returning true unconditionally
    // made sweeping the cursor along one row trigger a full-screen
    // rebuild per event (hover lag).
    if (_selectedIndex == index) return false;
    _selectedIndex = index;
    return true;
  }

  @override
  void resetSelection() => _selectedIndex = 0;

  @override
  void Function()? activateItem(HomeContext ctx, int index) {
    if (index < 0 || index >= actions.length) return null;
    final action = actions[index];
    return () => _run(ctx, action);
  }

  @override
  void Function()? activate(HomeContext ctx) =>
      activateItem(ctx, _selectedIndex);

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
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    final theme = CruxTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < actions.length; i++)
          _ActionRow(
            action: actions[i],
            selected: focused && i == _selectedIndex,
            theme: theme,
            strings: ctx.strings,
            onTap: () {
              _selectedIndex = i;
              _run(ctx, actions[i]);
            },
          ),
      ],
    );
  }
}

/// One quick-action row: the command label and a dim hint. Highlighted
/// (selection background) when it's the box's selected item and the box
/// is focused. The row's own GestureDetector fires the action on click
/// (per-item, not whole-box). Mouse-hover selection is handled at the
/// box level (home's box MouseRegion computes the row from the cursor
/// y), because a per-row MouseRegion nested under the box region never
/// receives hover in nocterm.
class _ActionRow extends StatelessComponent {
  final QuickAction action;
  final bool selected;
  final CruxThemeData theme;
  final Strings strings;
  final VoidCallback onTap;

  const _ActionRow({
    required this.action,
    required this.selected,
    required this.theme,
    required this.strings,
    required this.onTap,
  });

  @override
  Component build(BuildContext context) {
    final labelColor = selected ? theme.selectedText : theme.accent;
    final hintColor = selected ? theme.selectedText : theme.onSurfaceDim;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: selected ? theme.selection : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                action.label,
                style: TextStyle(
                  color: labelColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '  ${strings.t(action.hint)}',
                style: TextStyle(color: hintColor),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
    );
  }
}