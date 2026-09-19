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
      expect(text, contains('report granularity'));
      expect(text, isNot(contains('Expert consultation')));
    });

    test('experts on: consultation guidance', () {
      final text = subagentModeAnnouncement(workersOn: false, expertsOn: true);
      expect(text, contains('Expert consultation is ON'));
      expect(text, isNot(contains('Worker dispatch is ON')));
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

  group('workers-mode guard in ToolExecutor', () {
    test('hands-on tool blocked while workers on; reads pass; off passes all',
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
    });

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
