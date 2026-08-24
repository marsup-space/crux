// Tests for the plugins tool (Phase B): list / inspect / trigger
// against real spec files and a real loopback HTTP server.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/tools/plugins_tool.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  late Directory project;
  late PluginsTool tool;

  ToolContext ctxOf() => ToolContext(
        sessionId: 1,
        messageId: 0,
        abort: AbortSignal(),
        workingDirectory: project.path,
      );

  setUp(() {
    project = Directory.systemTemp.createTempSync('plugin_tool_test_');
    // A hermetic fake home: the registry also scans the GLOBAL roots
    // (`~/.crux/plugins/`, `~/.crux/widgets/`), so a developer with
    // real global plugins installed (e.g. `gold`) would otherwise
    // leak them into these counts — the tests assert what THIS
    // project's specs produce, not what's installed on the machine.
    final fakeHome = Directory.systemTemp.createTempSync('plugin_tool_home_');
    addTearDown(() {
      try {
        project.deleteSync(recursive: true);
      } catch (_) {}
      try {
        fakeHome.deleteSync(recursive: true);
      } catch (_) {}
    });
    tool = PluginsTool(homeOverride: fakeHome.path);
  });

  void writeSpec(String id, {String statusPath = 's.json'}) {
    final dir = Directory('${project.path}/.crux/plugins');
    dir.createSync(recursive: true);
    File('${dir.path}/$id.toml').writeAsStringSync('''
id = "$id"
label = "⟳ $id · {state}"
refresh_ms = 2000

[status]
path = "$statusPath"
heartbeat_field = "heartbeatAt"

[[status.state_rules]]
when = { field = "lastReload.result", equals = "succeeded" }
text = "✓ {lastReload.at@HH:MM}"

[[actions]]
label = "start"
kind = "launch"
command = "dart tool/crux_dev.dart home"

[[actions]]
label = "reload"
url = "http://127.0.0.1:{controlPort}/reload"
''');
  }

  void writeStatus({
    DateTime? heartbeat,
    String? reloadResult,
    int? controlPort,
  }) {
    final f = File('${project.path}/s.json');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(jsonEncode({
      'pid': 1,
      if (heartbeat != null)
        'heartbeatAt': heartbeat.toUtc().toIso8601String(),
      if (reloadResult != null)
        'lastReload': {
          'at': DateTime(2026, 8, 4, 16, 53).toUtc().toIso8601String(),
          'result': reloadResult,
        },
      if (controlPort != null) 'controlPort': controlPort,
    }));
  }

  group('plugins tool — list', () {
    test('lists widgets with live status and actions', () async {
      writeSpec('dev-harness');
      writeStatus(
        heartbeat: DateTime.now(),
        reloadResult: 'succeeded',
        controlPort: 1,
      );

      final result = await tool.execute({'action': 'list'}, ctxOf());

      expect(result.output, contains('dev-harness'));
      expect(result.output, contains('alive'));
      expect(result.output, contains('✓'));
      expect(result.output, contains('reload'));
      expect(result.metadata['plugins'], 1);
    });

    test('empty project reports none', () async {
      final result = await tool.execute({'action': 'list'}, ctxOf());
      expect(result.output, contains('(none'));
    });

    test('invalid spec files are skipped', () async {
      final dir = Directory('${project.path}/.crux/plugins');
      dir.createSync(recursive: true);
      File('${dir.path}/broken.toml').writeAsStringSync(
        'id = "mismatch"\nlabel = "x"\n',
      );

      final result = await tool.execute({'action': 'list'}, ctxOf());
      expect(result.output, isNot(contains('broken')));
      expect(result.output, contains('(none'));
    });
  });

  group('plugins tool — inspect', () {
    test('shows full status JSON and actions', () async {
      writeSpec('dev-harness');
      writeStatus(heartbeat: DateTime.now(), controlPort: 1234);

      final result = await tool.execute(
        {'action': 'inspect', 'id': 'dev-harness'},
        ctxOf(),
      );

      expect(result.output, contains('dev-harness'));
      expect(result.output, contains('alive'));
      expect(result.output, contains('controlPort'));
      expect(result.output, contains('reload'));
      expect(result.output, contains('http://127.0.0.1:{controlPort}/reload'));
    });

    test('unknown id errors with available ids', () async {
      writeSpec('a');
      final result = await tool.execute(
        {'action': 'inspect', 'id': 'nope'},
        ctxOf(),
      );
      expect(result.title, 'Error');
      expect(result.output, contains('nope'));
      expect(result.output, contains('a'));
    });
  });

  group('plugins tool — trigger', () {
    test('fires the action via HTTP POST and reports ok', () async {
      final hits = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((req) async {
        hits.add('${req.method} ${req.uri.path}');
        req.response.statusCode = 200;
        await req.response.close();
      });

      writeSpec('dev-harness');
      writeStatus(heartbeat: DateTime.now(), controlPort: server.port);

      final result = await tool.execute(
        {'action': 'trigger', 'id': 'dev-harness', 'action_label': 'reload'},
        ctxOf(),
      );

      expect(hits, contains('POST /reload'));
      expect(result.output, contains('ok'));
      expect(result.metadata['ok'], isTrue);

      await sub.cancel();
      await server.close(force: true);
    });

    test('refuses to trigger while the widget is not alive', () async {
      writeSpec('dev-harness');
      final result = await tool.execute(
        {'action': 'trigger', 'id': 'dev-harness', 'action_label': 'reload'},
        ctxOf(),
      );
      expect(result.title, 'Error');
      expect(result.output, contains('absent'));
    });

    test('unknown action label errors', () async {
      writeSpec('dev-harness');
      writeStatus(heartbeat: DateTime.now(), controlPort: 1);
      final result = await tool.execute(
        {'action': 'trigger', 'id': 'dev-harness', 'action_label': 'nope'},
        ctxOf(),
      );
      expect(result.title, 'Error');
      expect(result.output, contains('nope'));
      expect(result.output, contains('reload'));
    });

    test('connection failure reports failure without throwing', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      writeSpec('dev-harness');
      writeStatus(heartbeat: DateTime.now(), controlPort: port);

      final result = await tool.execute(
        {'action': 'trigger', 'id': 'dev-harness', 'action_label': 'reload'},
        ctxOf(),
      );
      expect(result.metadata['ok'], isFalse);
      expect(result.output, contains('Failed'));
    });

    test('launch actions run the launcher without a liveness gate', () async {
      final launched = <String>[];
      final fakeTool = PluginsTool(
        launchFn: (action, projectPath) async {
          launched.add('${action.command} @ $projectPath');
          return true;
        },
      );
      writeSpec('dev-harness');

      final result = await fakeTool.execute(
        {'action': 'trigger', 'id': 'dev-harness', 'action_label': 'start'},
        ctxOf(),
      );

      expect(launched, hasLength(1));
      expect(launched.first, contains('dart tool/crux_dev.dart home'));
      expect(result.output, contains('Launched'));
      expect(result.metadata['ok'], isTrue);
    });

    test('launch action failure is reported', () async {
      final fakeTool = PluginsTool(
        launchFn: (action, projectPath) async => false,
      );
      writeSpec('dev-harness');
      final result = await fakeTool.execute(
        {'action': 'trigger', 'id': 'dev-harness', 'action_label': 'start'},
        ctxOf(),
      );
      expect(result.metadata['ok'], isFalse);
      expect(result.output, contains('Failed to launch'));
    });

    test('unknown action errors', () async {
      final result = await tool.execute({'action': 'nope'}, ctxOf());
      expect(result.title, 'Error');
    });

    test('prompt action returns the rendered quick-action message', () async {
      // Rewrite the spec with a prompt action.
      final dir = Directory('${project.path}/.crux/plugins')
        ..createSync(recursive: true);
      File('${dir.path}/dev-harness.toml').writeAsStringSync('''
id = "dev-harness"
label = "⟳ dev · {state}"
[status]
path = "s.json"

[[actions]]
label = "review"
kind = "prompt"
prompt = "Review the config on port {controlPort}."
''');
      writeStatus(heartbeat: DateTime.now(), controlPort: 9090);

      final result = await tool.execute(
        {'action': 'trigger', 'id': 'dev-harness', 'action_label': 'review'},
        ctxOf(),
      );

      expect(result.metadata['ok'], isTrue);
      expect(result.metadata['prompt'], 'Review the config on port 9090.');
      expect(result.output, contains('Review the config on port 9090.'));
    });

    test('shell action runs the command and reports exit + tail', () async {
      final dir = Directory('${project.path}/.crux/plugins')
        ..createSync(recursive: true);
      File('${dir.path}/dev-harness.toml').writeAsStringSync('''
id = "dev-harness"
label = "⟳ dev · {state}"
[status]
path = "s.json"

[[actions]]
label = "test"
kind = "shell"
command = "echo from-shell-action"
''');
      writeStatus(heartbeat: DateTime.now());

      final result = await tool.execute(
        {'action': 'trigger', 'id': 'dev-harness', 'action_label': 'test'},
        ctxOf(),
      );

      expect(result.metadata['ok'], isTrue);
      expect(result.metadata['exitCode'], 0);
      expect(result.output, contains('from-shell-action'));
    });
  });
}
