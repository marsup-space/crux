import 'dart:io';

import 'package:crux/src/models/subagent.dart';
import 'package:crux/src/services/subagent/subagent_config_store.dart';
import 'package:crux/src/storage/agent_store.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/utils/agent_refs.dart';
import 'package:crux/src/utils/worker_constellations.dart';
import 'package:drift/native.dart';
import 'package:nocterm/nocterm.dart' as nt;
import 'package:test/test.dart';

void main() {
  group('constellation pools', () {
    test('zodiac 12 are the expert pool, popular Chinese names', () {
      expect(kExpertConstellations.length, 12);
      // Popular astrology wording, not IAU catalog wording.
      final zh = [for (final c in kExpertConstellations) c.chineseName];
      expect(zh, containsAll(['处女座', '射手座', '水瓶座']));
      expect(zh, isNot(contains('室女座')));
    });

    test('worker pool excludes crux and every zodiac constellation', () {
      expect(kWorkerConstellations.length, 75);
      final workerIds = {for (final c in kWorkerConstellations) c.id};
      expect(workerIds, isNot(contains('crux')));
      for (final zodiac in kExpertConstellations) {
        expect(
          workerIds,
          isNot(contains(zodiac.id)),
          reason: '${zodiac.id} must be expert-only',
        );
      }
    });

    test('resolve works across both pools by id and English name', () {
      expect(constellationForPersistedName('orion')!.chineseName, '猎户座');
      expect(constellationForPersistedName('Virgo')!.id, 'virgo');
      expect(constellationForPersistedName('Boötes')!.id, 'bootes');
      expect(constellationForPersistedName('crux'), isNull);
    });
  });

  group('AgentStore', () {
    late CruxDatabase db;
    late AgentStore store;

    setUp(() {
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = AgentStore(db);
      addTearDown(() => db.close());
    });

    test('hire allocates pool names in order', () async {
      final first = await store.hire(
        projectPath: '/w',
        role: SubagentRole.worker,
        model: 'zhipu/glm-5.3',
      );
      expect(first.name, 'andromeda'); // first unsuffixed worker id
      expect(first.role, 'worker');
      expect(first.status, 'ready');

      final expert = await store.hire(
        projectPath: '/w',
        role: SubagentRole.expert,
        model: 'zhipu/glm-5.3',
      );
      expect(expert.name, 'aries'); // first zodiac id
    });

    test('busy → ready lifecycle + restart self-healing', () async {
      final agent = await store.hire(
        projectPath: '/w',
        role: SubagentRole.worker,
        model: 'zhipu/glm-5.3',
      );
      await store.markBusy('/w', agent.name, sessionId: 7, intention: 'fix race');
      final busy = await store.byName('/w', agent.name);
      expect(busy!.status, 'busy');
      expect(busy.lastIntention, 'fix race');
      expect(busy.runOwnerSessionId, 7);

      await store.markReady('/w', agent.name);
      final ready = await store.byName('/w', agent.name);
      expect(ready!.status, 'ready');
      expect(ready.runOwnerSessionId, isNull);
      // Intention survives for the "(previous task)" tooltip line.
      expect(ready.lastIntention, 'fix race');

      // Crash-orphan self-healing: a busy row left over from a dead
      // process resets on next startup.
      await store.markBusy('/w', agent.name, sessionId: 9, intention: 'again');
      await store.resetAllToReady();
      final healed = await store.byName('/w', agent.name);
      expect(healed!.status, 'ready');
    });

    test('distillation write path', () async {
      final agent = await store.hire(
        projectPath: '/w',
        role: SubagentRole.expert,
        model: 'zhipu/glm-5.3',
      );
      await store.writeDistilled(
        projectPath: '/w',
        name: agent.name,
        knowledge: 'token refresh must single-flight',
        worklog: 'fixed race in refresh()',
      );
      final reloaded = await store.byName('/w', agent.name);
      expect(reloaded!.knowledge, 'token refresh must single-flight');
      expect(reloaded.worklog, 'fixed race in refresh()');
    });

    test('pool exhaustion cycles with numeric suffixes', () async {
      final names = <String>{};
      for (var i = 0; i < 14; i++) {
        final agent = await store.hire(
          projectPath: '/w',
          role: SubagentRole.expert,
          model: 'm',
        );
        expect(
          names.add(agent.name),
          isTrue,
          reason: 'duplicate ${agent.name}',
        );
      }
      // The 13th hire must be the first suffixed name.
      final all = await store.listByRole('/w', SubagentRole.expert);
      expect(all.length, 14);
      expect(all.map((a) => a.name), contains('aries-2'));
    });

    test('rosters are workspace-scoped: names isolate per project', () async {
      // Same constellation id can exist in two workspaces, and each
      // workspace's allocation ignores the other's taken names.
      final a1 = await store.hire(
        projectPath: '/proj-a',
        role: SubagentRole.worker,
        model: 'm',
      );
      final a2 = await store.hire(
        projectPath: '/proj-b',
        role: SubagentRole.worker,
        model: 'm',
      );
      expect(a1.name, 'andromeda');
      expect(a2.name, 'andromeda'); // same first-free name in its own scope
      expect(a1.name, a2.name); // (project_path, name) disambiguates

      // Each workspace sees only its own row.
      expect((await store.listAll('/proj-a')).map((a) => a.name), [
        'andromeda',
      ]);
      expect((await store.listAll('/proj-b')).map((a) => a.name), [
        'andromeda',
      ]);
      expect(await store.listAll('/proj-c'), isEmpty);

      // byName is scoped: proj-a's row is invisible from proj-b's
      // scope by the same name... it IS visible under its own scope
      // only.
      expect((await store.byName('/proj-a', 'andromeda'))!.projectPath,
          '/proj-a');
      expect((await store.byName('/proj-b', 'andromeda'))!.projectPath,
          '/proj-b');

      // Status flips stay scoped: marking proj-a's agent busy must
      // not touch proj-b's row of the same name.
      await store.markBusy('/proj-a', 'andromeda', sessionId: 1, intention: 'x');
      expect((await store.byName('/proj-a', 'andromeda'))!.status, 'busy');
      expect((await store.byName('/proj-b', 'andromeda'))!.status, 'ready');

      // Deletes are scoped too.
      await store.deleteByName('/proj-a', 'andromeda');
      expect(await store.byName('/proj-a', 'andromeda'), isNull);
      expect(await store.byName('/proj-b', 'andromeda'), isNotNull);
    });
  });

  group('SubagentConfigStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('subagent_config_');
      addTearDown(() => dir.delete(recursive: true));
    });

    test('toggles round-trip and default to off', () async {
      final file = File('${dir.path}/config.toml');
      final store = SubagentConfigStore(file);
      expect(await store.readToggles(), const SubagentRuntimeToggles());

      await store.writeToggles(
        const SubagentRuntimeToggles(workersOn: true, expertsOn: false),
      );
      expect(
        await store.readToggles(),
        const SubagentRuntimeToggles(workersOn: true),
      );
    });

    test('v1 advisor key is an alias for experts', () async {
      final file = File('${dir.path}/config.toml');
      await file.writeAsString('''
[subagent]
workers_on = true

[subagent.advisor]
models = [{ model = "zhipu/glm-5.3", concurrency = 1 }]
''');
      final store = SubagentConfigStore(file);
      final pools = await store.readPools();
      expect(pools.experts.primaryModel, 'zhipu/glm-5.3');
      expect(pools.experts.models.first.concurrency, 1);
    });

    test('pools round-trip', () async {
      final file = File('${dir.path}/config.toml');
      final store = SubagentConfigStore(file);
      await store.writePools(
        const SubagentConfig(
          workers: SubagentModelConfig(
            models: [
              SubagentModelEntry(model: 'a/one', concurrency: 2),
              SubagentModelEntry(model: 'b/two', concurrency: 8),
            ],
          ),
          experts: SubagentModelConfig(
            models: [SubagentModelEntry(model: 'c/three')],
          ),
        ),
      );
      final pools = await store.readPools();
      expect(pools.workers.modelIds, ['a/one', 'b/two']);
      expect(pools.workers.concurrencyFor('a/one'), 2);
      expect(pools.workers.concurrencyFor('unknown'), 1);
      expect(pools.experts.primaryModel, 'c/three');
    });
  });

  group('agent refs', () {
    test(
      'parses agent:// names; code-span exclusion follows backgroundColor',
      () {
        const text = 'ask agent://orion or agent://libra-2';
        final spans = [const nt.TextSpan(text: text)];
        final refs = parseAgentRefs(spans);
        expect(refs.map((r) => r.name), ['orion', 'libra-2']);
        expect(refs.first.displayText, 'agent://orion');
        expect(refs.first.containsIndex(refs.first.offset), isTrue);

        // A span carrying a background color (how the markdown visitor
        // marks code spans) is excluded from the walk.
        const code = 'agent://virgo';
        final codeSpans = [
          const nt.TextSpan(
            text: code,
            style: nt.TextStyle(backgroundColor: nt.Color(0xFF333333)),
          ),
        ];
        expect(parseAgentRefs(codeSpans), isEmpty);
      },
    );

    test('styles ref regions without touching other text', () {
      const text = 'see agent://orion now';
      final spans = [const nt.TextSpan(text: text)];
      final refs = parseAgentRefs(spans);
      final styled = applyAgentLinkStyles(
        spans,
        refs,
        linkStyle: const nt.TextStyle(decoration: nt.TextDecoration.underline),
      );
      final flat = styled.cast<nt.TextSpan>();
      expect(flat.length, 3); // before · link · after
      expect(flat[0].text, 'see ');
      expect(flat[1].text, 'agent://orion');
      expect(flat[1].style!.decoration, nt.TextDecoration.underline);
      expect(flat[2].text, ' now');
    });

    test('displayNames localizes the rendered link text', () {
      const text = 'ask agent://orion now';
      final spans = [const nt.TextSpan(text: text)];
      final refs = parseAgentRefs(spans);
      final styled = applyAgentLinkStyles(
        spans,
        refs,
        displayNames: (id) => id == 'orion' ? '猎户座' : id,
      );
      final flat = styled.cast<nt.TextSpan>();
      expect(flat[1].text, '猎户座');
      // Un-localized ids fall back to the raw reference.
      final styledFallback = applyAgentLinkStyles(
        spans,
        refs,
        displayNames: (id) => '',
      );
      expect(styledFallback.cast<nt.TextSpan>()[1].text, 'agent://orion');
    });

    test('chip text (glyph + localized name) replaces the raw reference', () {
      const text = 'dispatch by agent://apus today';
      final spans = [const nt.TextSpan(text: text)];
      final refs = parseAgentRefs(spans);
      final styled = applyAgentLinkStyles(
        spans,
        refs,
        // Chip style: a background block, no underline.
        linkStyle: const nt.TextStyle(backgroundColor: nt.Color(0xFF2B2C39)),
        displayNames: (id) => id == 'apus' ? '✎ 天燕座' : '',
      );
      final flat = styled.cast<nt.TextSpan>();
      expect(flat[0].text, 'dispatch by ');
      expect(flat[1].text, '✎ 天燕座');
      expect(flat[2].text, ' today');
      expect(flat[1].style!.backgroundColor, nt.Color(0xFF2B2C39));
      expect(flat[1].style!.decoration, isNot(nt.TextDecoration.underline));
      // An unknown id (empty chip text and no localized name) falls back to
      // the raw reference, so no glyph leaks in.
      final fallback = applyAgentLinkStyles(
        spans,
        refs,
        displayNames: (id) => '',
      );
      expect(fallback.cast<nt.TextSpan>()[1].text, 'agent://apus');
    });
  });
}
