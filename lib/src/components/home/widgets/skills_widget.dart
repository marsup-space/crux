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
/// The box renders *all* skills as a top-aligned column; scrolling is
/// handled by the box chrome (every box's content lives in a
/// scrollview — see `_BoxScrollArea`). The widget's own
/// [HomeWidget.boxScrollOffset] (written back by that scroll area) lets
/// [selectItemAt] translate a viewport-row hover into an absolute skill
/// index once the list is scrolled.
///
/// Activation calls [HomeContext.showSkill] with the skill — the chat
/// panel opens a read-only `Fullpane` on the SKILL.md content. Home
/// stays open underneath, so `esc` out of the pane lands back on the
/// dashboard.
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
  String titleFor(HomeContext ctx) => ctx.strings.t('home.title.skills');

  @override
  Set<int> get supportedSpans => const {1, 2};

  /// Content height; the list scrolls inside the box when there are
  /// more skills than rows. 6 rows balances "a real list" against not
  /// hogging the grid.
  @override
  int heightFor(int span) => 6;

  /// A content list — stays top-aligned (centering a scrollable list
  /// would fight the scrollview's height constraint).
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
    // `index` is already absolute — home's box-level hover adds the
    // box's own scroll offset (boxScrollOffset) before calling this.
    if (index < 0 || index >= itemCount) return false;
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
    final theme = CruxTheme.of(context);
    final all = skills();
    if (all.isEmpty) {
      return Text(
        ctx.strings.t('home.skills.empty'),
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }
    final selected = selectedIndex;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < all.length; i++)
          _SkillRow(
            skill: all[i],
            selected: focused && i == selected,
            theme: theme,
            onTap: () {
              _selectedIndex = i;
              final action = activateItem(ctx, i);
              if (action != null) action();
            },
          ),
      ],
    );
  }
}

/// One skill row: the name and its one-line description. Highlighted
/// when it's the box's selected item and the box is focused; its own
/// GestureDetector opens the skill's fullpane on click (per-row, not
/// whole-box). Mouse-hover selection is handled at the box level
/// (home's box MouseRegion computes the row from the cursor y, plus the
/// box's scroll offset), because a per-row MouseRegion nested under the
/// box region never receives hover in nocterm.
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
                softWrap: false,
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
