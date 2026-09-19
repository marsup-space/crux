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
        expect(workerIds, isNot(contains(zodiac.id)),
            reason: '${zodiac.id} must be expert-only');
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
        role: SubagentRole.worker,
        model: 'zhipu/glm-5.3',
      );
      expect(first.name, 'andromeda'); // first unsuffixed worker id
      expect(first.role, 'worker');
      expect(first.status, 'ready');

      final expert = await store.hire(
        role: SubagentRole.expert,
        model: 'zhipu/glm-5.3',
      );
      expect(expert.name, 'aries'); // first zodiac id
    });

    test('busy → ready lifecycle + restart self-healing', () async {
      final agent = await store.hire(
        role: SubagentRole.worker,
        model: 'zhipu/glm-5.3',
      );
      await store.markBusy(agent.name, sessionId: 7, intention: 'fix race');
      final busy = await store.byName(agent.name);
      expect(busy!.status, 'busy');
      expect(busy.lastIntention, 'fix race');
      expect(busy.runOwnerSessionId, 7);

      await store.markReady(agent.name);
      final ready = await store.byName(agent.name);
      expect(ready!.status, 'ready');
      expect(ready.runOwnerSessionId, isNull);
      // Intention survives for the "(previous task)" tooltip line.
      expect(ready.lastIntention, 'fix race');

      // Crash-orphan self-healing: a busy row left over from a dead
      // process resets on next startup.
      await store.markBusy(agent.name, sessionId: 9, intention: 'again');
      await store.resetAllToReady();
      final healed = await store.byName(agent.name);
      expect(healed!.status, 'ready');
    });

    test('distillation write path', () async {
      final agent = await store.hire(
        role: SubagentRole.expert,
        model: 'zhipu/glm-5.3',
      );
      await store.writeDistilled(
        name: agent.name,
        knowledge: 'token refresh must single-flight',
        worklog: 'fixed race in refresh()',
      );
      final reloaded = await store.byName(agent.name);
      expect(reloaded!.knowledge, 'token refresh must single-flight');
      expect(reloaded.worklog, 'fixed race in refresh()');
    });

    test('pool exhaustion cycles with numeric suffixes', () async {
      final names = <String>{};
      for (var i = 0; i < 14; i++) {
        final agent = await store.hire(
          role: SubagentRole.expert,
          model: 'm',
        );
        expect(names.add(agent.name), isTrue,
            reason: 'duplicate ${agent.name}');
      }
      // The 13th hire must be the first suffixed name.
      final all = await store.listByRole(SubagentRole.expert);
      expect(all.length, 14);
      expect(all.map((a) => a.name), contains('aries-2'));
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
          workers: SubagentModelConfig(models: [
            SubagentModelEntry(model: 'a/one', concurrency: 2),
            SubagentModelEntry(model: 'b/two', concurrency: 8),
          ]),
          experts: SubagentModelConfig(models: [
            SubagentModelEntry(model: 'c/three'),
          ]),
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
    test('parses agent:// names; code-span exclusion follows backgroundColor',
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
    });

    test('styles ref regions without touching other text', () {
      const text = 'see agent://orion now';
      final spans = [const nt.TextSpan(text: text)];
      final refs = parseAgentRefs(spans);
      final styled = applyAgentLinkStyles(
        spans,
        refs,
        const nt.TextStyle(decoration: nt.TextDecoration.underline),
      );
      final flat = styled.cast<nt.TextSpan>();
      expect(flat.length, 3); // before · link · after
      expect(flat[0].text, 'see ');
      expect(flat[1].text, 'agent://orion');
      expect(flat[1].style!.decoration, nt.TextDecoration.underline);
      expect(flat[2].text, ' now');
    });
  });
}
