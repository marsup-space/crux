import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../../../theme/crux_theme.dart';
import '../home_widgets.dart';

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
    final theme = CruxTheme.of(context);
    final labelStyle = TextStyle(color: theme.onSurfaceDim);
    final valueStyle = TextStyle(color: theme.onSurfaceVariant);

    // Directory: show the basename (what the user calls the project),
    // falling back to the raw path when it's empty or just a separator.
    final dir = _dirName(ctx.projectPath);

    // Branch: from the live git service; empty when not a repo.
    final status = ctx.gitStatusService.current;
    final branch = status.isRepo
        ? (status.branch.isEmpty ? '(no branch)' : status.branch)
        : 'not a git repo';

    // Model: the active model's composite key, or a setup hint.
    final model = ctx.activeModel() ?? 'no model — /provider to connect';

    // Sessions: the workspace sessions only (chats are global), so the
    // count means "how much work lives in this directory".
    final sessionCount =
        ctx.sessions().where((s) => s.projectPath.isNotEmpty).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(labelStyle, valueStyle, 'dir', dir),
        _row(labelStyle, valueStyle, 'branch', branch),
        _row(labelStyle, valueStyle, 'model', model),
        _row(
          labelStyle,
          valueStyle,
          'sessions',
          '$sessionCount in this workspace',
        ),
      ],
    );
  }

  Component _row(
    TextStyle labelStyle,
    TextStyle valueStyle,
    String label,
    String value,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label  ', style: labelStyle),
        Expanded(
          child: Text(value, style: valueStyle, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  static String _dirName(String path) {
    if (path.isEmpty) return '(unknown)';
    final base = p.basename(path);
    return base.isEmpty ? path : base;
  }
}
