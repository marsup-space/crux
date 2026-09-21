import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/home/widgets/subagent_pool_widget.dart';
import 'package:crux/src/services/subagent/subagent_config_store.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

/// Renders a widget's content at a fixed width inside a themed
/// container (same shape as home_widgets_test's _PumpHost, trimmed to
/// this file's needs).
class _PumpHost extends StatefulComponent {
  final HomeWidget widget;
  final HomeContext ctx;

  const _PumpHost(this.widget, this.ctx);

  @override
  State<_PumpHost> createState() => _PumpHostState();
}

class _PumpHostState extends State<_PumpHost> {
  @override
  void initState() {
    super.initState();
    component.widget.onChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  Component build(BuildContext context) {
    return Container(
      width: 60,
      height: 12,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: Builder(
          builder: (context) =>
              component.widget.build(context, component.ctx, 1),
        ),
      ),
    );
  }
}

/// Regression: the `subagent-pool` box must render constellation names
/// through [WorkerNameLocalizer] — a zh-locale home shows `✎ 天燕座`,
/// not the persisted id `apus` (every other subagent surface already
/// localizes; this box was missed).
void main() {
  HomeContext ctxWith(
    String? Function() localeId,
    List<SubagentRosterEntry> roster,
  ) {
    final base = HomeContext.minimal(close: () {});
    return HomeContext(
      runCommand: base.runCommand,
      seedInput: base.seedInput,
      close: base.close,
      gitStatusService: base.gitStatusService,
      sessions: base.sessions,
      currentSessionId: base.currentSessionId,
      switchSession: base.switchSession,
      localeId: localeId,
      subagentRoster: () => roster,
    );
  }

  test('zh locale renders the localized constellation name', () async {
    await testNocterm('subagent pool localization', (tester) async {
      final widget = SubagentPoolHomeWidget(openConfig: () {});
      final ctx = ctxWith(() => 'zh', const [
        SubagentRosterEntry(
          name: 'apus',
          role: 'worker',
          domain: 'db',
          model: 'zhipu/glm-4.5',
          intention: 'smoke',
          busy: false,
        ),
      ]);
      await tester.pumpComponent(_PumpHost(widget, ctx));
      await tester.pump();

      // Localized display name — NOT the raw persisted id.
      expect(tester.terminalState.findText('天燕座'), isNotEmpty);
      expect(tester.terminalState.findText('apus'), isEmpty);
      // The status badge localized too (sanity: strings wired).
      expect(tester.terminalState.findText('空闲'), isNotEmpty);
    });
  });

  test('en locale keeps the Latin constellation name', () async {
    await testNocterm('subagent pool en names', (tester) async {
      final widget = SubagentPoolHomeWidget(openConfig: () {});
      final ctx = ctxWith(() => 'en', const [
        SubagentRosterEntry(
          name: 'apus',
          role: 'worker',
          domain: 'db',
          model: 'zhipu/glm-4.5',
          intention: 'smoke',
          busy: false,
        ),
      ]);
      await tester.pumpComponent(_PumpHost(widget, ctx));
      await tester.pump();

      expect(tester.terminalState.findText('Apus'), isNotEmpty);
    });
  });

  test('unknown legacy names pass through unchanged', () async {
    await testNocterm('subagent pool legacy name', (tester) async {
      final widget = SubagentPoolHomeWidget(openConfig: () {});
      final ctx = ctxWith(() => 'zh', const [
        SubagentRosterEntry(
          name: 'worker-01',
          role: 'worker',
          domain: 'db',
          model: 'zhipu/glm-4.5',
          intention: 'smoke',
          busy: false,
        ),
      ]);
      await tester.pumpComponent(_PumpHost(widget, ctx));
      await tester.pump();

      expect(tester.terminalState.findText('worker-01'), isNotEmpty);
    });
  });
}
