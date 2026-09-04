import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../../../i18n/strings.dart';
import '../../../components/surface_host.dart';
import '../../../services/a2ui/basic_catalog_items.dart';
import '../../../services/a2ui/surface_builder.dart';
import '../home_widgets.dart';

final _workspaceSurfaceCatalog = createBasicCatalog();

/// The `workspace` box — basic facts about where Crux is open: the
/// project directory, the git branch, the active model, and how many
/// sessions live here. Answers "where am I and what am I running" at a
/// glance.
///
/// Data sources: [HomeContext.projectPath] (the cwd the app was opened
/// on), [HomeContext.gitStatusService] (branch, live), [HomeContext
/// .activeModel] (the current session's model), and [HomeContext
/// .sessions] (session count). All read on each build; no timer.
///
/// Passive box — `activate` returns null; there's no primary action.
class WorkspaceHomeWidget extends HomeWidget {
  @override
  String get id => 'workspace';

  @override
  String get title => 'Workspace';

  @override
  String titleFor(HomeContext ctx) => ctx.strings.t('home.title.workspace');

  @override
  Set<int> get supportedSpans => const {1, 2};

  @override
  int heightFor(int span) => 4;

  @override
  void Function()? activate(HomeContext ctx) => null; // passive

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    final s = ctx.strings;

    // Directory: show the basename (what the user calls the project),
    // falling back to the raw path when it's empty or just a separator.
    final dir = _dirName(ctx.projectPath, s);

    // Branch: from the live git service; empty when not a repo.
    final status = ctx.gitStatusService.current;
    final branch = status.isRepo
        ? (status.branch.isEmpty ? s.t('home.noBranch') : status.branch)
        : s.t('home.notGitRepo');

    // Model: the active model's composite key, or a setup hint.
    final model = ctx.activeModel() ?? s.t('home.ws.noModel');

    // Sessions: the workspace sessions only (chats are global), so the
    // count means "how much work lives in this directory".
    final sessionCount = ctx
        .sessions()
        .where((s) => s.projectPath.isNotEmpty)
        .length;

    final surface = SurfaceBuilder(surfaceId: 'home.workspace')
      ..column('root', ['dir', 'branch', 'model', 'sessions'])
      ..keyValue('dir', label: s.t('home.ws.dir'), value: dir)
      ..keyValue('branch', label: s.t('home.ws.branch'), value: branch)
      ..keyValue('model', label: s.t('home.ws.model'), value: model)
      ..keyValue(
        'sessions',
        label: s.t('home.ws.sessions'),
        value: s.t('home.ws.sessionsCount', {'n': '$sessionCount'}),
      );
    return SurfaceHost(
      declaration: surface.build(),
      catalog: _workspaceSurfaceCatalog,
      instanceKey: 'home.workspace',
      retainState: false,
      submitOnAction: false,
      strings: s,
    );
  }

  static String _dirName(String path, Strings s) {
    if (path.isEmpty) return s.t('home.ws.unknown');
    final base = p.basename(path);
    return base.isEmpty ? path : base;
  }
}
