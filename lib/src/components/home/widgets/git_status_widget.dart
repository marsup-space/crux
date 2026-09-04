import 'package:nocterm/nocterm.dart';

import '../../../i18n/strings.dart';
import '../../../services/a2ui/surface_builder.dart';
import '../../../services/git_status_service.dart';
import '../home_surface.dart';
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
  String titleFor(HomeContext ctx) => ctx.strings.t('home.title.git');

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
    return _GitStatusHomeView(service: service, strings: ctx.strings);
  }
}

/// Stateful view so the widget rebuilds when the service notifies.
class _GitStatusHomeView extends StatefulComponent {
  final GitStatusService service;
  final Strings strings;

  const _GitStatusHomeView({required this.service, required this.strings});

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
    final status = component.service.current;

    if (!status.isRepo) {
      return homeSurface(
        declaration: SurfaceBuilder(
          surfaceId: 'home.git.empty',
        ).text('root', component.strings.t('home.notGitRepo')).build(),
        strings: component.strings,
      );
    }
    final branch = StringBuffer(
      status.branch.isEmpty
          ? component.strings.t('home.noBranch')
          : status.branch,
    );
    if (status.ahead > 0) branch.write(' ↑${status.ahead}');
    if (status.behind > 0) branch.write(' ↓${status.behind}');
    final ids = <String>['branch'];
    final surface = SurfaceBuilder(surfaceId: 'home.git')
      ..column('root', ids)
      ..keyValue('branch', label: '⎇', value: branch.toString());
    if (status.addedLines > 0 || status.deletedLines > 0) {
      ids.add('changes');
      surface.text('changes', '+${status.addedLines}  −${status.deletedLines}');
    }
    final buckets = <String>[];
    void add(String glyph, int count, String label) {
      if (count > 0) buckets.add('$glyph $count $label');
    }

    add('●', status.stagedFiles, component.strings.t('home.git.staged'));
    add('~', status.modifiedFiles, component.strings.t('home.git.modified'));
    add('?', status.untrackedFiles, component.strings.t('home.git.untracked'));
    add('!', status.conflictedFiles, component.strings.t('home.git.conflict'));
    if (buckets.isNotEmpty) {
      ids.add('files');
      surface.text('files', buckets.join(' · '));
    } else if (status.addedLines == 0 && status.deletedLines == 0) {
      ids.add('clean');
      surface.text('clean', '✓ ${component.strings.t('home.git.clean')}');
    }
    return homeSurface(
      declaration: surface.build(),
      strings: component.strings,
    );
  }
}
