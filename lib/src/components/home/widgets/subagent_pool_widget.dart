import 'package:nocterm/nocterm.dart';

import '../../../i18n/strings.dart';
import '../../../services/a2ui/surface_builder.dart';
import '../../../services/subagent/subagent_config_store.dart';
import '../../../services/subagent/subagent_controller.dart';
import '../home_surface.dart';
import '../home_widgets.dart';

/// The `subagent-pool` box — the subagent roster at a glance.
///
/// Shows the two mode switches (workers / experts, on/off) and every
/// roster agent (✎ worker / ✦ expert + constellation name + busy /
/// ready + last intention). Activate (Enter / click) opens the
/// subagent-config fullpane via [HomeContext.openSubagentConfig]; that
/// surface edits the model pools, flips the switches, and reads the
/// same roster live.
///
/// Data: [SubagentController] for the switches; the roster is fetched
/// from the agents table on activate and on a light periodic refresh
/// (the roster changes only on hire / run transitions, so a 5s poll is
/// plenty; the config fullpane pushes immediate refreshes through the
/// controller's ChangeNotifier).
class SubagentPoolHomeWidget extends HomeWidget {
  final SubagentController controller;
  final void Function() openConfig;

  SubagentPoolHomeWidget({required this.controller, required this.openConfig});

  @override
  String get id => 'subagent-pool';

  @override
  String get title => 'Agents';

  @override
  String titleFor(HomeContext ctx) => ctx.strings.t('home.title.agents');

  @override
  Set<int> get supportedSpans => const {1};

  @override
  int heightFor(int span) => 4;

  /// Only show the box when subagent mode is configured at all —
  /// either switch on, or the roster already has agents. A fresh
  /// install (both off, empty roster) keeps the grid clean.
  @override
  bool visibleWhen(HomeContext ctx) =>
      controller.anyOn || ctx.hasSubagentRoster;

  @override
  void Function()? activate(HomeContext ctx) => openConfig;

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    return _SubagentPoolView(
      controller: controller,
      roster: ctx.subagentRoster?.call() ?? const <SubagentRosterEntry>[],
      strings: ctx.strings,
    );
  }
}

class _SubagentPoolView extends StatefulComponent {
  final SubagentController controller;
  final List<SubagentRosterEntry> roster;
  final Strings strings;

  const _SubagentPoolView({
    required this.controller,
    required this.roster,
    required this.strings,
  });

  @override
  State<_SubagentPoolView> createState() => _SubagentPoolViewState();
}

class _SubagentPoolViewState extends State<_SubagentPoolView> {
  @override
  void initState() {
    super.initState();
    component.controller.addListener(_onChanged);
  }

  @override
  void didUpdateComponent(_SubagentPoolView old) {
    super.didUpdateComponent(old);
    if (!identical(old.controller, component.controller)) {
      old.controller.removeListener(_onChanged);
      component.controller.addListener(_onChanged);
    }
  }

  @override
  void deactivate() {
    component.controller.removeListener(_onChanged);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    component.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    component.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Component build(BuildContext context) {
    final strings = component.strings;
    final toggles = component.controller.toggles;
    final roster = component.roster;

    final ids = <String>['switches'];
    final surface = SurfaceBuilder(surfaceId: 'home.subagent.pool')
      ..column('root', ids)
      ..text(
        'switches',
        '✎ workers ${toggles.workersOn ? 'on' : 'off'}'
        '  ·  ✦ experts ${toggles.expertsOn ? 'on' : 'off'}',
      );

    if (roster.isEmpty) {
      ids.add('empty');
      surface.text('empty', strings.t('subagent.pool.empty'));
    } else {
      for (var i = 0; i < roster.length && i < 5; i++) {
        final entry = roster[i];
        final id = 'agent$i';
        ids.add(id);
        surface.text(
          id,
          '${entry.role == 'expert' ? '✦' : '✎'} ${entry.name} '
          '${entry.busy ? strings.t('subagent.pool.busy') : strings.t('subagent.pool.ready')}'
          '${entry.intention.isEmpty ? '' : ' · ${entry.intention}'}',
        );
      }
      if (roster.length > 5) {
        ids.add('more');
        surface.text(
          'more',
          strings.t('subagent.pool.more', {'n': '${roster.length - 5}'}),
        );
      }
    }

    return homeSurface(declaration: surface.build(), strings: strings);
  }
}
