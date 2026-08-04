import 'package:nocterm/nocterm.dart';

import '../../../services/skills/skill.dart';
import '../../../theme/crux_theme.dart';
import '../home_widgets.dart';

/// The `skills` box — every skill the agent can see, tap one to read
/// its full body in a fullpane.
///
/// Data source: the discovered, deduped `SkillInfo` list
/// (`discoverSkills(cwd: projectPath)` — project skills first, then the
/// global roots), read live on each build so installing a skill and
/// re-entering home shows it immediately.
///
/// The box holds *all* skills in a scrollable list: unlike
/// `recent-sessions` (which truncates to `_maxRows`), a longer skill
/// list stays reachable — ↑↓ past the last visible row scrolls the
/// list (selectedIndex is absolute; the viewport follows the
/// selection), and the mouse wheel scrolls it directly.
///
/// Activation calls [HomeContext.showSkill] with the skill's location —
/// the chat panel opens a read-only `Fullpane` on the SKILL.md content.
/// Home stays open underneath, so `esc` out of the pane lands back on
/// the dashboard.
class SkillsHomeWidget extends HomeWidget {
  /// All discovered skills (project + global), in discovery order.
  /// Read on each build / item-interface call.
  final List<SkillInfo> Function() skills;

  SkillsHomeWidget({required this.skills});

  @override
  String get id => 'skills';

  @override
  String get title => 'Skills';

  @override
  Set<int> get supportedSpans => const {1, 2};

  /// Fixed content height; the list scrolls inside when there are more
  /// skills than rows. 6 rows balances "a real list" against not
  /// hogging the grid.
  @override
  int heightFor(int span) => 6;

  /// The list scrolls — centering it would break the scrollview's
  /// height constraint.
  @override
  bool get verticallyCenter => false;

  // ── Item selection ────────────────────────────────────────────────

  int _selectedIndex = 0;

  @override
  int get itemCount => skills().length;

  @override
  int get selectedIndex {
    final n = itemCount;
    if (n == 0) return 0;
    return _selectedIndex.clamp(0, n - 1);
  }

  @override
  void moveSelection(int delta) {
    final n = itemCount;
    if (n == 0) return;
    _selectedIndex = (selectedIndex + delta) % n;
    if (_selectedIndex < 0) _selectedIndex += n;
  }

  @override
  bool selectItemAt(int index) {
    // `index` is a *viewport* row (home's box-level hover maps the
    // cursor to a row inside the visible box). The list may be
    // scrolled, so translate through the viewport's scroll offset —
    // the view state registers it here on every build.
    final absolute = _viewportFirstRow + index;
    if (absolute < 0 || absolute >= itemCount) return false;
    _selectedIndex = absolute;
    return true;
  }

  @override
  void resetSelection() => _selectedIndex = 0;

  /// The absolute index of the list's first visible row, mirrored from
  /// the view state on each build so [selectItemAt] can translate the
  /// viewport-row hover math into an absolute item index.
  int _viewportFirstRow = 0;

  @override
  void Function()? activateItem(HomeContext ctx, int index) {
    final all = skills();
    if (index < 0 || index >= all.length) return null;
    final skill = all[index];
    final show = ctx.showSkill;
    if (show == null) return null;
    return () => show(skill);
  }

  @override
  void Function()? activate(HomeContext ctx) {
    final n = itemCount;
    if (n == 0) return null; // empty: passive box
    return activateItem(ctx, selectedIndex);
  }

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    final all = skills();
    if (all.isEmpty) {
      final theme = CruxTheme.of(context);
      return Text(
        'no skills found',
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }
    return _SkillsView(
      skills: all,
      focused: focused,
      selectedIndex: selectedIndex,
      onTapItem: (i) {
        _selectedIndex = i;
        final action = activateItem(ctx, i);
        if (action != null) action();
      },
      onViewportChanged: (firstRow) => _viewportFirstRow = firstRow,
    );
  }
}

/// The scrollable skill list. Stateful to own the ScrollController and
/// mirror its viewport back to the widget (for hover row translation).
class _SkillsView extends StatefulComponent {
  final List<SkillInfo> skills;
  final bool focused;
  final int selectedIndex;
  final void Function(int index) onTapItem;

  /// Called each build with the absolute index of the first visible
  /// row, so the owning widget can translate viewport-row hovers.
  final void Function(int firstRow) onViewportChanged;

  const _SkillsView({
    required this.skills,
    required this.focused,
    required this.selectedIndex,
    required this.onTapItem,
    required this.onViewportChanged,
  });

  @override
  State<_SkillsView> createState() => _SkillsViewState();
}

class _SkillsViewState extends State<_SkillsView> {
  final ScrollController _scrollController = ScrollController();

  /// The viewport height from the last build, used to keep the
  /// selection visible and to clamp the hover offset. Defaults to the
  /// widget's declared height (correct on the first build — the box
  /// allocates exactly that).
  double _viewportRows = 6;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Repaint the scrollbar thumb. setState is cheap here — the list
    // is a handful of rows.
    setState(() {});
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final all = component.skills;
    final selected = component.selectedIndex;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight.isFinite && constraints.maxHeight > 0) {
          _viewportRows = constraints.maxHeight;
        }
        final viewport = _viewportRows.floor().clamp(1, all.length);

        // Keep the selection inside the viewport: ↑↓ past the last
        // visible row scrolls the list so the highlight never leaves
        // the box.
        var first = _scrollController.offset.round();
        if (selected < first) first = selected;
        if (selected > first + viewport - 1) first = selected - viewport + 1;
        first = first.clamp(0, (all.length - viewport).clamp(0, all.length));
        if (_scrollController.offset.round() != first) {
          _scrollController.jumpTo(first.toDouble());
        }
        component.onViewportChanged(first);

        return Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          thumbColor: theme.onSurfaceDim.withOpacity(0.4),
          trackColor: theme.surfaceVariant.withOpacity(0.3),
          child: SingleChildScrollView(
            controller: _scrollController,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < all.length; i++)
                  _SkillRow(
                    skill: all[i],
                    selected: component.focused && i == selected,
                    theme: theme,
                    onTap: () => component.onTapItem(i),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One skill row: the name and its one-line description. Highlighted
/// when it's the box's selected item and the box is focused; its own
/// GestureDetector opens the skill's fullpane on click (per-row, not
/// whole-box). Mouse-hover selection is handled at the box level
/// (home's box MouseRegion computes the row from the cursor y, and the
/// widget translates it through the scroll offset), because a per-row
/// MouseRegion nested under the box region never receives hover in
/// nocterm.
class _SkillRow extends StatelessComponent {
  final SkillInfo skill;
  final bool selected;
  final CruxThemeData theme;
  final VoidCallback onTap;

  const _SkillRow({
    required this.skill,
    required this.selected,
    required this.theme,
    required this.onTap,
  });

  @override
  Component build(BuildContext context) {
    final nameColor = selected ? theme.selectedText : theme.accent;
    final descColor = selected ? theme.selectedText : theme.onSurfaceDim;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: selected ? theme.selection : null,
        child: Row(
          children: [
            Text(
              skill.name,
              style: TextStyle(
                color: nameColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            Expanded(
              child: Text(
                '  ${skill.description}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: descColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
