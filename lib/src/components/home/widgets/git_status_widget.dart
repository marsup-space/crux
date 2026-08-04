import 'package:nocterm/nocterm.dart';

import '../../../services/git_status_service.dart';
import '../../../theme/crux_theme.dart';
import '../home_widgets.dart';

/// The `git-status` box — branch, ahead/behind, and working-tree churn.
///
/// Data source: [GitStatusService], a `ChangeNotifier` that pushes
/// snapshots. This widget subscribes in `initState` and rebuilds on
/// notify — the same pattern the side-panel `GitStatusWidget` uses. The
/// snapshot is replaced atomically before notify, so `build` always
/// reads a consistent [GitStatus].
///
/// The action forces a refresh (`service.refresh()`).
class GitStatusHomeWidget extends HomeWidget {
  final GitStatusService service;

  GitStatusHomeWidget(this.service);

  @override
  String get id => 'git-status';

  @override
  String get title => 'Git';

  @override
  Set<int> get supportedSpans => const {1};

  @override
  int heightFor(int span) => 4;

  @override
  void Function()? activate(HomeContext ctx) {
    return () => service.refresh();
  }

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    return _GitStatusHomeView(service: service);
  }
}

/// Stateful view so the widget rebuilds when the service notifies.
class _GitStatusHomeView extends StatefulComponent {
  final GitStatusService service;

  const _GitStatusHomeView({required this.service});

  @override
  State<_GitStatusHomeView> createState() => _GitStatusHomeViewState();
}

class _GitStatusHomeViewState extends State<_GitStatusHomeView> {
  @override
  void initState() {
    super.initState();
    component.service.addListener(_onChanged);
  }

  @override
  void didUpdateComponent(_GitStatusHomeView old) {
    super.didUpdateComponent(old);
    if (!identical(old.service, component.service)) {
      old.service.removeListener(_onChanged);
      component.service.addListener(_onChanged);
    }
  }

  @override
  void deactivate() {
    // The `mounted` check in [_onChanged] is not enough: in nocterm
    // `mounted` is true while the element is merely *deactivated*
    // (mid tree-swap, e.g. the home→chat full-screen swap), but
    // `setState` asserts the element is *active*. Unsubscribing here
    // guarantees no notification can reach this State while it's
    // deactivated, so the assert can't trip on a late isolate event.
    component.service.removeListener(_onChanged);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    component.service.addListener(_onChanged);
  }

  @override
  void dispose() {
    component.service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final status = component.service.current;

    if (!status.isRepo) {
      return Text(
        'not a git repo',
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    final rows = <Component>[
      // Branch line: ⎇ main ↑3 ↓2 (only non-zero sync markers shown).
      _buildBranchRow(theme, status),
    ];

    if (status.addedLines > 0 || status.deletedLines > 0) {
      rows.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '+${status.addedLines}',
              style: TextStyle(
                color: theme.successColor,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text('  ', style: TextStyle(color: theme.onSurfaceDim)),
            Text(
              '−${status.deletedLines}',
              style: TextStyle(
                color: theme.errorColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    final counts = _buildCountsRow(theme, status);
    if (counts != null) {
      rows.add(counts);
    } else if (status.addedLines == 0 && status.deletedLines == 0) {
      // Clean tree: a single muted ✓ so the box isn't blank.
      rows.add(Text('✓ clean', style: TextStyle(color: theme.onSurfaceDim)));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  Component _buildBranchRow(CruxThemeData theme, GitStatus status) {
    final children = <Component>[
      Text('⎇ ', style: TextStyle(color: theme.accent)),
      Text(
        status.branch.isEmpty ? '(no branch)' : status.branch,
        style: TextStyle(
          color: theme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    ];
    if (status.ahead > 0) {
      children.add(
        Text(' ↑${status.ahead}', style: TextStyle(color: theme.successColor)),
      );
    }
    if (status.behind > 0) {
      children.add(
        Text(' ↓${status.behind}', style: TextStyle(color: theme.warningColor)),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }

  /// `● 2 staged · ~1 modified · ? 3 untracked · ! 1 conflict` — only the
  /// non-zero buckets, each with an explicit label. Returns null when the
  /// tree is clean so the caller can fall back to the `✓ clean` row.
  Component? _buildCountsRow(CruxThemeData theme, GitStatus status) {
    final parts = <Component>[];
    void bucket(String glyph, int count, String label, Color color) {
      if (count <= 0) return;
      if (parts.isNotEmpty) {
        parts.add(Text(' · ', style: TextStyle(color: theme.onSurfaceDim)));
      }
      parts.add(
        Text('$glyph $count $label', style: TextStyle(color: color)),
      );
    }

    bucket('●', status.stagedFiles, 'staged', theme.accent);
    bucket('~', status.modifiedFiles, 'modified', theme.warningColor);
    bucket('?', status.untrackedFiles, 'untracked', theme.onSurfaceDim);
    bucket('!', status.conflictedFiles, 'conflict', theme.errorColor);

    if (parts.isEmpty) return null;
    return Row(mainAxisSize: MainAxisSize.min, children: parts);
  }
}
