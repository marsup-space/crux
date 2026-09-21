import 'package:nocterm/nocterm.dart';

import '../../../services/a2ui/surface_builder.dart';
import '../../../services/subagent/subagent_config_store.dart';
import '../home_surface.dart';
import '../home_widgets.dart';

/// The `subagent-pool` box — the subagent roster at a glance.
///
/// One chip row per roster agent: `✎ antlia` (role glyph + name)
/// followed by three badges — domain, model short name (the segment
/// after the last `/`), and status (`busy` warning / `ready`
/// success). The intention is deliberately left out: a badge row has
/// no room for it, and the config fullpane still shows it per agent.
/// The agent rows render in a scrollable `List` (capped at four
/// visible rows) so a long roster scrolls instead of truncating.
/// Activate (Enter / click) opens the subagent-config fullpane via
/// [HomeContext.openSubagentConfig]; that surface edits the global
/// model pools and reads the same roster live.
///
/// The workers / experts switches are deliberately NOT here: they
/// are per-session state (the controller loads them per session),
/// while this box is a global workspace view. The chat agent bar —
/// which lives inside the session — owns them.
///
/// Data: the roster is fetched from the agents table on activate and
/// on a light periodic refresh (the roster changes only on hire / run
/// transitions, so a 5s poll is plenty; the config fullpane pushes
/// immediate refreshes through its own notification path).
class SubagentPoolHomeWidget extends HomeWidget {
  final void Function() openConfig;

  SubagentPoolHomeWidget({required this.openConfig});

  @override
  String get id => 'subagent-pool';

  @override
  String get title => 'Agents';

  @override
  String titleFor(HomeContext ctx) => ctx.strings.t('home.title.agents');

  @override
  Set<int> get supportedSpans => const {1};

  @override
  int heightFor(int span) => 6;

  /// Only show the box when the workspace roster has agents — the
  /// switches are per-session state and do not belong in this global
  /// view. A fresh install (empty roster) keeps the grid clean.
  @override
  bool visibleWhen(HomeContext ctx) => ctx.hasSubagentRoster;

  @override
  void Function()? activate(HomeContext ctx) => openConfig;

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    final roster = ctx.subagentRoster?.call() ?? const <SubagentRosterEntry>[];
    final strings = ctx.strings;

    final ids = <String>[];
    final surface = SurfaceBuilder(surfaceId: 'home.subagent.pool')
      ..column('root', ids);

    if (roster.isEmpty) {
      ids.add('empty');
      surface.text('empty', strings.t('subagent.pool.empty'));
    } else {
      final rowIds = <String>[];
      for (var i = 0; i < roster.length; i++) {
        final entry = roster[i];
        final rowId = 'agent${i}Row';
        final nameId = 'agent${i}Name';
        final domainId = 'agent${i}Domain';
        final modelId = 'agent${i}Model';
        final statusId = 'agent${i}Status';
        rowIds.add(rowId);
        surface
          ..row(rowId, [nameId, domainId, modelId, statusId], gap: 1)
          ..text(nameId, '${entry.role == 'expert' ? '✦' : '✎'} ${entry.name}')
          ..badge(domainId, text: entry.domain)
          ..badge(modelId, text: _shortModel(entry.model))
          ..badge(
            statusId,
            text: entry.busy
                ? strings.t('subagent.pool.busy')
                : strings.t('subagent.pool.ready'),
            tone: entry.busy ? 'warning' : 'success',
          );
      }
      ids.add('agentList');
      surface.list('agentList', rowIds, maxHeight: 4);
    }

    return homeSurface(declaration: surface.build(), strings: strings);
  }
}

/// Model badge text: the last `/` segment of a composite model key
/// (`deepseek/deepseek-v4-flash` → `deepseek-v4-flash`), so a provider
/// prefix can't eat the chip's width. Keys without a `/` pass through.
String _shortModel(String model) {
  final slash = model.lastIndexOf('/');
  return slash < 0 ? model : model.substring(slash + 1);
}
