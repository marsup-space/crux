import 'dart:io';

import 'package:crux/src/components/subagent_config_fullpane.dart';
import 'package:crux/src/services/subagent/subagent_config_store.dart';
import 'package:crux/src/services/subagent/subagent_controller.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

/// A config.toml whose GLOBAL switch defaults are `workers on / experts
/// off` — the pair the config fullpane used to print. The pane must show
/// neither: the switches are per-session (`sessions.subagent_workers_on`
/// / `subagent_experts_on`) and live in the always-mounted agent bar.
const _config = '''
[subagent]
workers_on = true
experts_on = false

[subagent.workers]
models = [{ model = "zhipu/glm-4.5", concurrency = 2 }]

[subagent.experts]
models = [{ model = "zhipu/glm-4.5", concurrency = 1 }]
''';

/// A config whose workers pool holds TWO models, so pool rows can be
/// checked for adjacency (the single-entry [_config] cannot).
const _twoModelConfig = '''
[subagent.workers]
models = [{ model = "zhipu/glm-4.5", concurrency = 2 }, { model = "zhipu/glm-4.5-air", concurrency = 3 }]

[subagent.experts]
models = [{ model = "zhipu/glm-4.5", concurrency = 1 }]
''';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('crux-subagent-fullpane');
    file = File('${dir.path}/config.toml');
    await file.writeAsString(_config);
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('renders no mode-switch state — switches are per-session', () async {
    await testNocterm('subagent config fullpane', (tester) async {
      await _mount(tester, file);
      final text = tester.terminalState.getText();

      // The old pane printed the global defaults (`✎ workers: on`),
      // which contradicted the current session's real state.
      expect(text, isNot(contains('workers:')));
      expect(text, isNot(contains('experts:')));
      expect(text, isNot(contains('· on (')));
      expect(text, isNot(contains('· off (')));

      // Pools keep only their entry count; roster + Save stay.
      expect(text, contains('✎ workers (1)'));
      expect(text, contains('✦ experts (1)'));
      expect(text, contains('zhipu/glm-4.5 ×2'));
      expect(text, contains('ready'));
      expect(text, contains('Save'));
    }, size: const Size(100, 40));
  });

  test('saving pools never rewrites the global switch defaults', () async {
    await testNocterm('subagent config pool save', (tester) async {
      await _mount(tester, file);

      // Two pool columns each carry an `+ add model` button — click the
      // workers one (leftmost).
      final add = tester.terminalState
          .findText('add model')
          .reduce((a, b) => a.x < b.x ? a : b);
      await tester.tap(add.x + 1, add.y);
      await _pumpAsync(tester);

      final option = tester.terminalState.findText('GLM 4.5').single;
      await tester.tap(option.x + 1, option.y);
      await _pumpAsync(tester);
      expect(tester.terminalState.getText(), contains('✎ workers (2)'));
      expect(tester.terminalState.getText(), contains('unsaved'));

      // `Save` appears twice: the top-row button and the footer hint
      // (`Ctrl+S Save`). The button sits higher up.
      final save = tester.terminalState
          .findText('Save')
          .reduce((a, b) => a.y < b.y ? a : b);
      await tester.tap(save.x + 1, save.y);
      await _pumpAsync(tester);

      final store = SubagentConfigStore(file);
      expect(
        await store.readToggles(),
        const SubagentRuntimeToggles(workersOn: true, expertsOn: false),
      );
      final pools = await store.readPools();
      expect(pools.workers.models, hasLength(2));
      expect(pools.experts.models, hasLength(1));
    }, size: const Size(100, 40));
  });

  test('pool entries and roster rows stack flush — no blank rows', () async {
    await testNocterm('subagent config row spacing', (tester) async {
      await file.writeAsString(_twoModelConfig);
      await _mount(
        tester,
        file,
        roster: const [
          SubagentRosterEntry(
            name: 'apus',
            role: 'worker',
            domain: 'dbx',
            model: 'zhipu/glm-4.5',
            intention: 'row one',
            busy: false,
          ),
          SubagentRosterEntry(
            name: 'volans',
            role: 'worker',
            domain: 'uiz',
            model: 'zhipu/glm-4.5',
            intention: 'row two',
            busy: false,
          ),
        ],
      );

      final ts = tester.terminalState;

      // Pool rows: consecutive model entries sit on adjacent rows.
      final first = ts.findText('zhipu/glm-4.5 ×2').single;
      final second = ts.findText('zhipu/glm-4.5-air ×3').single;
      expect(second.y - first.y, 1);

      // …while the add-model button keeps ONE blank row below the list
      // (the pool list and the button are separate blocks).
      final add = ts.findText('add model').reduce((a, b) => a.x < b.x ? a : b);
      expect(add.y - second.y, 2);

      // Roster: header keeps its gap, the agent rows are flush.
      final header = ts.findText('Roster').single;
      final rosterFirst = ts.findText('dbx').single;
      final rosterSecond = ts.findText('uiz').single;
      expect(rosterFirst.y - header.y, 2);
      expect(rosterSecond.y - rosterFirst.y, 1);
    }, size: const Size(100, 40));
  });
}

Future<void> _mount(
  dynamic tester,
  File file, {
  List<SubagentRosterEntry>? roster,
}) async {
  final controller = await SubagentController.create(
    configStore: SubagentConfigStore(file),
  );
  await tester.pumpComponent(
    Container(
      width: 100,
      height: 40,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: SubagentConfigFullpane(
          controller: controller,
          configStore: SubagentConfigStore(file),
          availableModels: const [(key: 'zhipu/glm-4.5', label: 'GLM 4.5')],
          loadRoster: () async =>
              roster ??
              const [
                SubagentRosterEntry(
                  name: 'apus',
                  role: 'worker',
                  domain: 'db',
                  model: 'zhipu/glm-4.5',
                  intention: 'smoke',
                  busy: false,
                ),
              ],
          deleteAgent: (name) async {},
          onClose: () {},
        ),
      ),
    ),
  );
  await _pumpAsync(tester);
}

Future<void> _pumpAsync(dynamic tester) async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump();
  }
}
