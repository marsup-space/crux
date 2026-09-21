import 'dart:io';

import 'package:crux/src/components/subagent_config_fullpane.dart';
import 'package:crux/src/models/subagent.dart';
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

      var ts = tester.terminalState;

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

  group('round limit', () {
    test(
      'absent max_rounds renders the 40 default and the ∞ end state',
      () async {
        await testNocterm('subagent round limit default', (tester) async {
          await _mount(tester, file);
          final text = tester.terminalState.getText();

          expect(text, contains('Round limit'));
          expect(text, contains('40 rounds'));
          expect(text, contains('drag to set'));
          // The slider row carries both the `├` min stop and the `∞` end
          // state (the label row's `∞ unlimited` has no `├` beside it).
          final inf = _sliderInf(tester.terminalState);
          final left = _sliderLeft(tester.terminalState, inf);
          expect(inf.x - left.x, greaterThan(60)); // a wide draggable track
        }, size: const Size(100, 40));
      },
    );

    test(
      'dragging sets values live, marks unsaved, and save persists',
      () async {
        await testNocterm('subagent round limit drag', (tester) async {
          await _mount(tester, file);
          var ts = tester.terminalState;
          final inf = _sliderInf(ts);
          final left = _sliderLeft(ts, inf);
          final width = inf.x - left.x + 1; // includes the ∞ cell

          // Midpoint of the finite range 32..100 → 66 rounds.
          final midCell = (width - 2) ~/ 2;
          await _dragSlider(tester, left.x + midCell, inf.y, left.x + midCell);
          ts = tester.terminalState;
          expect(ts.getText(), contains('66 rounds'));
          expect(ts.getText(), contains('unsaved'));

          // Far right of the finite range → 100 rounds.
          await _dragSlider(tester, left.x + midCell, inf.y, inf.x - 1);
          ts = tester.terminalState;
          expect(ts.getText(), contains('100 rounds'));

          // Onto the ∞ cell → unlimited.
          await _dragSlider(tester, inf.x - 1, inf.y, inf.x);
          ts = tester.terminalState;
          expect(ts.getText(), contains('∞ unlimited'));

          // Save persists `max_rounds = "unlimited"`.
          final save = ts.findText('Save').reduce((a, b) => a.y < b.y ? a : b);
          await tester.tap(save.x + 1, save.y);
          await _pumpAsync(tester);

          final store = SubagentConfigStore(file);
          expect((await store.readPools()).maxRounds, isNull);
          expect(file.readAsStringSync(), contains("max_rounds = 'unlimited'"));
        }, size: const Size(100, 40));
      },
    );
  });

  group('max_rounds config round trip', () {
    test('absent → 40 default; out-of-range clamps to 32..100', () async {
      await file.writeAsString('''
[subagent]
max_rounds = 999
''');
      final store = SubagentConfigStore(file);
      expect((await store.readPools()).maxRounds, 100);

      await file.writeAsString('''
[subagent]
max_rounds = 5
''');
      expect((await store.readPools()).maxRounds, 32);

      await file.writeAsString('''
[subagent]
''');
      expect((await store.readPools()).maxRounds, 40);
    });

    test(
      '"unlimited" reads as null; writes persist int / "unlimited"',
      () async {
        await file.writeAsString('''
[subagent]
max_rounds = "unlimited"
''');
        final store = SubagentConfigStore(file);
        expect((await store.readPools()).maxRounds, isNull);

        await store.writePools(const SubagentConfig(maxRounds: 40));
        expect(file.readAsStringSync(), contains('max_rounds = 40'));
        expect((await store.readPools()).maxRounds, 40);

        await store.writePools(const SubagentConfig(maxRounds: null));
        // The TOML serializer writes strings single-quoted.
        expect(file.readAsStringSync(), contains("max_rounds = 'unlimited'"));
        expect((await store.readPools()).maxRounds, isNull);
      },
    );
  });
  group('roster reasoning effort cycle', () {
    const presets = [('off', 'off'), ('low', 'low'), ('normal', 'normal'),
      ('high', 'high'), ('max', 'max')];

    /// Hover the first roster row so its MultiButton morphs into
    /// segments, then return the terminal state.
    Future<void> hoverRosterRow(dynamic tester) async {
      final row = tester.terminalState.findText('db').single;
      await tester.sendMouseEvent(
        MouseEvent(
          button: MouseButton.left,
          x: row.x,
          y: row.y,
          pressed: false,
        ),
      );
      await _pumpAsync(tester);
    }

    test('cycle segment renders the NEXT effort; label shows current',
        () async {
      await testNocterm('subagent effort cycle render', (tester) async {
        await _mount(
          tester,
          file,
          roster: const [
            SubagentRosterEntry(
              name: 'apus',
              role: 'worker',
              domain: 'db',
              model: 'zhipu/glm-4.5',
              intention: 'smoke',
              busy: false,
              reasoningEffort: 'high',
            ),
          ],
          effortOptionsFor: (_) => presets,
        );
        // Idle label carries the current value suffix.
        expect(tester.terminalState.getText(), contains('✶high'));
        // Hover: the segment offers the next preset (max).
        await hoverRosterRow(tester);
        expect(tester.terminalState.getText(), contains('✶max'));
      }, size: const Size(100, 40));
    });

    test('null effort: no suffix; segment offers the first preset',
        () async {
      await testNocterm('subagent effort cycle default', (tester) async {
        await _mount(
          tester,
          file,
          roster: const [
            SubagentRosterEntry(
              name: 'apus',
              role: 'worker',
              domain: 'db',
              model: 'zhipu/glm-4.5',
              intention: 'smoke',
              busy: false,
            ),
          ],
          effortOptionsFor: (_) => presets,
        );
        await hoverRosterRow(tester);
        // No current-override suffix in the idle label (server
        // default); the segment offers the first preset (off).
        final idle = tester.terminalState.getText();
        expect(idle, isNot(contains('· ✶')));
        expect(idle, contains('✶off'));
      }, size: const Size(100, 40));
    });

    test('clicking the segment cycles and persists via the callback',
        () async {
      await testNocterm('subagent effort cycle click', (tester) async {
        String? saved;
        await _mount(
          tester,
          file,
          roster: const [
            SubagentRosterEntry(
              name: 'apus',
              role: 'worker',
              domain: 'db',
              model: 'zhipu/glm-4.5',
              intention: 'smoke',
              busy: false,
              reasoningEffort: 'high',
            ),
          ],
          effortOptionsFor: (_) => presets,
          setReasoningEffort: (name, effort) async => saved = effort,
        );
        await hoverRosterRow(tester);
        final seg = tester.terminalState.findText('✶max').single;
        await tester.tap(seg.x + 1, seg.y);
        await _pumpAsync(tester);
        expect(saved, 'max');
      }, size: const Size(100, 40));
    });

    test('no options resolver → no cycle segment (plain delete row)',
        () async {
      await testNocterm('subagent effort cycle absent', (tester) async {
        await _mount(tester, file);
        await hoverRosterRow(tester);
        expect(tester.terminalState.getText(), contains('delete'));
        expect(tester.terminalState.findText('✶'), isEmpty);
      }, size: const Size(100, 40));
    });
  });
}
/// track stop and an `∞` (the value label's `∞ unlimited` never sits on
/// the track).
TextMatch _sliderInf(TerminalState ts) => ts
    .findText('∞')
    .firstWhere(
      (m) => ts.findText('├').any((t) => t.y == m.y),
      orElse: () => throw StateError('slider ∞ cell not found'),
    );

/// The `├` min stop on the slider row (same row as [inf]).
TextMatch _sliderLeft(TerminalState ts, TextMatch inf) => ts
    .findText('├')
    .firstWhere(
      (t) => t.y == inf.y,
      orElse: () => throw StateError('slider ├ stop not found'),
    );

/// Press on the track, let the tracker flush the parked press, then
/// move (still held) to the target cell and release — a real drag.
Future<void> _dragSlider(dynamic tester, int x0, int y, int x1) async {
  await tester.press(x0, y);
  // The tracker parks the first left press for 50ms; wait it out so the
  // press is delivered before the move.
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await tester.pump();
  await tester.sendMouseEvent(
    MouseEvent(button: MouseButton.left, x: x1, y: y, pressed: true),
  );
  await tester.pump();
  await tester.release(x1, y);
  await _pumpAsync(tester);
}

Future<void> _mount(
  dynamic tester,
  File file, {
  List<SubagentRosterEntry>? roster,
  List<(String, String)>? Function(String)? effortOptionsFor,
  Future<void> Function(String name, String? effort)? setReasoningEffort,
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
          effortOptionsFor: effortOptionsFor,
          setReasoningEffort: setReasoningEffort,
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
