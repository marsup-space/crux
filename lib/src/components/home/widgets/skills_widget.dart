import 'package:nocterm/nocterm.dart';

import '../../../services/a2ui/surface_builder.dart';
import '../../../services/skills/skill.dart';
import '../home_surface.dart';
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
    final all = skills();
    if (all.isEmpty) {
      return homeSurface(
        declaration: SurfaceBuilder(
          surfaceId: 'home.skills.empty',
        ).text('root', ctx.strings.t('home.skills.empty')).build(),
        strings: ctx.strings,
      );
    }
    final selected = selectedIndex;
    final surface = SurfaceBuilder(surfaceId: 'home.skills')
      ..column('root', [for (var i = 0; i < all.length; i++) 'item$i']);
    for (var i = 0; i < all.length; i++) {
      final skill = all[i];
      surface.listItem(
        'item$i',
        title: skill.name,
        detail: skill.description.replaceAll('\n', ' '),
        selected: focused && i == selected,
        inline: true,
        action: 'open_skill',
        actionContext: {'index': i},
      );
    }
    return homeSurface(
      declaration: surface.build(),
      strings: ctx.strings,
      onAction: (event) {
        if (event.name != 'open_skill') return;
        final index = event.context['index'];
        if (index is! int || index < 0 || index >= all.length) return;
        _selectedIndex = index;
        activateItem(ctx, index)?.call();
      },
    );
  }
}
