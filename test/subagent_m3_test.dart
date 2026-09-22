import 'dart:io';

import 'package:crux/src/models/subagent.dart';
import 'package:crux/src/services/subagent/subagent_config_store.dart';
import 'package:crux/src/services/subagent/subagent_controller.dart';
import 'package:crux/src/services/subagent/subagent_prompts.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:test/test.dart';

void main() {
  group('subagentModeAnnouncement', () {
    test('workers on: dispatch discipline + workflow guide', () {
      final text = subagentModeAnnouncement(workersOn: true, expertsOn: false);
      expect(text.startsWith('[Crux system note — subagent mode on]'), isTrue);
      expect(text, contains('MUST go to a worker'));
      expect(text, contains('send_agent'));
      expect(text, contains('find_agents'));
      expect(text, contains('HARD RULE — domain match is mandatory'));
      expect(
        text,
        contains('idle "CI 修复" agent must not receive a subagent-runtime bug'),
      );
      expect(text, contains('report granularity'));
      expect(text, contains('Parallelize'));
      expect(text, contains('DIFFERENT worker'));
      expect(text, isNot(contains('Expert consultation')));
    });

    test('experts on: consultation guidance', () {
      final text = subagentModeAnnouncement(workersOn: false, expertsOn: true);
      expect(text, contains('Expert consultation is ON'));
      expect(text, isNot(contains('Worker dispatch is ON')));
      expect(text, isNot(contains('Parallelize')));
    });

    test('both on: middle mode names both', () {
      final text = subagentModeAnnouncement(workersOn: true, expertsOn: true);
      expect(text, contains('Worker dispatch is ON'));
      expect(text, contains('Expert consultation is ON'));
    });

    test('off: symmetric exit announcement', () {
      final text = subagentModeAnnouncement(workersOn: false, expertsOn: false);
      expect(text.startsWith('[Crux system note — subagent mode off]'), isTrue);
      expect(text, contains('turned OFF'));
      expect(text, contains('stay on the roster'));
      expect(text, contains('yours to use directly'));
    });
  });

  group('announcement one-shot consumption', () {
    late Directory dir;
    late SubagentController controller;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('subagent_m3_');
      controller = await SubagentController.create(
        configStore: SubagentConfigStore(File('${dir.path}/config.toml')),
      );
      addTearDown(() => dir.delete(recursive: true));
    });

    test('no announcement before any flip', () {
      expect(controller.announcementPending, isFalse);
      expect(controller.consumePendingAnnouncement(), isFalse);
    });

    test('flip arms once; first consume takes it, second is dry', () async {
      await controller.setToggle(SubagentRole.worker, true);
      expect(controller.announcementPending, isTrue);
      expect(controller.consumePendingAnnouncement(), isTrue);
      expect(controller.consumePendingAnnouncement(), isFalse);

      // A second flip re-arms — each toggle change gets its message.
      await controller.setToggle(SubagentRole.expert, true);
      expect(controller.consumePendingAnnouncement(), isTrue);
    });

    test('off-flip also arms (symmetric exit announcement)', () async {
      await controller.setToggle(SubagentRole.worker, true);
      controller.consumePendingAnnouncement();
      await controller.setToggle(SubagentRole.worker, false);
      expect(controller.consumePendingAnnouncement(), isTrue);
    });
  });

  group('per-session switches', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('subagent_m3_ps_');
      addTearDown(() => dir.delete(recursive: true));
    });

    test(
      'sessions that never flipped fall back to the global default',
      () async {
        // config.toml says workers on globally.
        final file = File('${dir.path}/config.toml');
        await file.writeAsString('[subagent]\nworkers_on = true\n');
        final controller = await SubagentController.create(
          configStore: SubagentConfigStore(file),
          loadToggles: (sessionId) async => (workers: null, experts: null),
        );
        // Session 7 never flipped anything: global default applies.
        await controller.attachSession(7);
        expect(controller.workersOn, isTrue);
        expect(controller.expertsOn, isFalse);
      },
    );

    test('a flipped session wins over the global default', () async {
      final file = File('${dir.path}/config.toml');
      await file.writeAsString('[subagent]\nworkers_on = true\n');
      final controller = await SubagentController.create(
        configStore: SubagentConfigStore(file),
        loadToggles: (sessionId) async =>
            (workers: sessionId == 7 ? false : null, experts: null),
      );
      // Session 7 flipped workers OFF (against the global on).
      await controller.attachSession(7);
      expect(controller.workersOn, isFalse);
      // Switching to session 8 (never flipped) restores the default.
      await controller.attachSession(8);
      expect(controller.workersOn, isTrue);
    });

    test(
      'setToggle persists to the active session and arms the announcement',
      () async {
        final persisted = <int, ({bool? workers, bool? experts})>{};
        final controller = await SubagentController.create(
          configStore: SubagentConfigStore(File('${dir.path}/config.toml')),
          persistToggles:
              (sessionId, {required workersOn, required expertsOn}) async {
                persisted[sessionId] = (workers: workersOn, experts: expertsOn);
              },
          loadToggles: (sessionId) async =>
              (workers: null, experts: sessionId == 3 ? true : null),
        );
        await controller.attachSession(3);
        // The loaded value shows through immediately.
        expect(controller.expertsOn, isTrue);

        await controller.setToggle(SubagentRole.worker, true);
        expect(controller.workersOn, isTrue);
        // Persisted with BOTH fields for session 3 (experts kept).
        expect(persisted[3]!.workers, isTrue);
        expect(persisted[3]!.experts, isTrue);
        // Announcement armed.
        expect(controller.consumePendingAnnouncement(), isTrue);

        // Session 4: fresh state, the flip on session 3 stays there.
        await controller.attachSession(4);
        expect(controller.workersOn, isFalse);
        expect(controller.expertsOn, isFalse);
      },
    );

    test('rapid A→B→A switching drops stale loads', () async {
      final file = File('${dir.path}/config.toml');
      final controller = await SubagentController.create(
        configStore: SubagentConfigStore(file),
        loadToggles: (sessionId) async {
          // Session 7 loads slowly; session 8 instantly.
          if (sessionId == 7) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return (workers: true, experts: null);
          }
          return (workers: null, experts: null);
        },
      );
      // Fire 7, then switch to 8 before 7's load lands.
      final slow = controller.attachSession(7);
      await controller.attachSession(8);
      await slow;
      // The stale load for 7 must NOT have overwritten session 8's
      // state (which reads as the global default: off).
      expect(controller.workersOn, isFalse);
    });
  });

  group('workers-mode guard in ToolExecutor', () {
    test(
      'hands-on tool blocked while workers on; reads pass; off passes all',
      () async {
        final registry = ToolRegistry();
        registry.register(_EchoTool('edit'));
        registry.register(_EchoTool('read'));

        var workersOn = true;
        ToolResult? guard(String toolName) {
          if (toolName == 'edit' && workersOn) {
            return ToolResult(
              title: 'worker mode',
              output: '[Crux system note — workers mode redirect]',
            );
          }
          return null;
        }

        final executor = ToolExecutor(registry, subagentWorkersGuard: guard);
        final ctx = ToolContext(
          sessionId: 1,
          messageId: 0,
          abort: AbortSignal(),
          workingDirectory: Directory.current.path,
        );

        final blocked = await executor.executeTool(
          ToolCall(callId: '1', name: 'edit', input: {}),
          ctx,
        );
        expect(blocked.output, contains('workers mode redirect'));

        final allowedRead = await executor.executeTool(
          ToolCall(callId: '2', name: 'read', input: {}),
          ctx,
        );
        expect(allowedRead.output, 'echo:read');

        workersOn = false;
        final allowedEdit = await executor.executeTool(
          ToolCall(callId: '3', name: 'edit', input: {}),
          ctx,
        );
        expect(allowedEdit.output, 'echo:edit');
      },
    );

    test('null guard (subagent runner path) never blocks', () async {
      final registry = ToolRegistry();
      registry.register(_EchoTool('bash'));
      final executor = ToolExecutor(registry);
      final result = await executor.executeTool(
        ToolCall(callId: '1', name: 'bash', input: {}),
        ToolContext(
          sessionId: 1,
          messageId: 0,
          abort: AbortSignal(),
          workingDirectory: Directory.current.path,
        ),
      );
      expect(result.output, 'echo:bash');
    });
  });

  group('engineering rules shared skeleton', () {
    test('worker and expert prompts both carry the shared rules', () {
      for (final role in SubagentRole.values) {
        final prompt = subagentSystemPrompt(
          agentName: 'orion',
          role: role,
          domain: 'd',
          knowledge: '',
          worklog: '',
          intention: 'i',
          userLanguage: 'English',
        );
        expect(prompt, contains('Codebase exploration'));
        expect(prompt, contains('no godfiles, always reuse'));
        expect(prompt, contains('Dense shell commands'));
      }
    });
  });
}

/// Tiny echo tool for guard-path tests.
class _EchoTool extends ToolDef {
  @override
  final String name;
  _EchoTool(this.name);

  @override
  String get description => 'echo';

  @override
  Map<String, dynamic> get parametersSchema => {'type': 'object'};

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    return ToolResult(title: name, output: 'echo:$name');
  }
}
