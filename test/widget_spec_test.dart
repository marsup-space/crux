// Tests for the spec-widget schema (Phase B): TOML parsing, status
// evaluation, template substitution, and the project-keyed registry.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/services/spec_widget.dart';
import 'package:crux/src/services/spec_widget_registry.dart';

const _devHarnessSpec = '''
id = "dev-harness"
label = "⟳ crux dev · {state}"
refresh_ms = 2000

[status]
path = ".dart_tool/crux_dev.json"
heartbeat_field = "heartbeatAt"
stale_after_seconds = 15

[[status.state_rules]]
when = { field = "lastReload.result", equals = "succeeded" }
text = "✓ {lastReload.at@HH:MM}"
color = "normal"

[[status.state_rules]]
when = { field = "lastReload.result", equals = "failed" }
text = "✗ reload failed"
color = "error"

fallback_alive_text = "●"
fallback_stale_text = "stale"
fallback_absent_text = "not running"

[[actions]]
label = "reload"
url = "http://127.0.0.1:{controlPort}/reload"

[[actions]]
label = "close"
url = "http://127.0.0.1:{controlPort}/close"
''';

SpecWidget? _parseString(String content, {String name = 'dev-harness'}) {
  final dir = Directory.systemTemp.createTempSync('spec_widget_test_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  final file = File('${dir.path}/$name.toml')..writeAsStringSync(content);
  return SpecWidget.parse(file);
}

void main() {
  group('SpecWidget.parse', () {
    test('parses the full dev-harness spec', () {
      final spec = _parseString(_devHarnessSpec)!;

      expect(spec.id, 'dev-harness');
      expect(spec.title, 'dev-harness'); // no title in spec → defaults to id
      expect(spec.labelTemplate, '⟳ crux dev · {state}');
      expect(spec.refresh, const Duration(seconds: 2));
      expect(spec.statusPath, '.dart_tool/crux_dev.json');
      expect(spec.heartbeatField, 'heartbeatAt');
      expect(spec.staleAfter, const Duration(seconds: 15));
      expect(spec.stateRules, hasLength(2));
      expect(spec.stateRules[0].field, 'lastReload.result');
      expect(spec.stateRules[0].equals, 'succeeded');
      expect(spec.stateRules[0].text, '✓ {lastReload.at@HH:MM}');
      expect(spec.stateRules[1].color, SpecStateColor.error);
      expect(spec.aliveText, '●');
      expect(spec.staleText, 'stale');
      expect(spec.absentText, 'not running');
      expect(spec.actions, hasLength(2));
      expect(spec.actions[0].label, 'reload');
      expect(
        spec.actions[0].url,
        'http://127.0.0.1:{controlPort}/reload',
      );
    });

    test('id must match the file name', () {
      expect(_parseString(_devHarnessSpec, name: 'other'), isNull);
    });

    test('missing label or status.path is invalid', () {
      expect(_parseString('id = "dev-harness"\nlabel = "x"'), isNull);
      expect(
        _parseString(
          'id = "dev-harness"\n'
          'label = "x"\n'
          '[status]\n'
          'heartbeat_field = "h"\n',
        ),
        isNull,
      );
    });

    test('malformed TOML is invalid', () {
      expect(_parseString('id = "dev-harness"\nlabel = "x"\n[[['), isNull);
    });

    test('parses launch-kind actions', () {
      final spec = _parseString('''
id = "dev-harness"
label = "⟳ {state}"
[status]
path = "s.json"

[[actions]]
label = "start"
kind = "launch"
command = "dart --enable-vm-service tool/crux_dev.dart home"

[[actions]]
label = "reload"
url = "http://127.0.0.1:{controlPort}/reload"
''')!;

      expect(spec.actions, hasLength(2));
      expect(spec.actions[0].kind, SpecActionKind.launch);
      expect(spec.actions[0].command, 'dart --enable-vm-service '
          'tool/crux_dev.dart home');
      expect(spec.actions[0].url, isNull);
      expect(spec.actions[1].kind, SpecActionKind.http);
      expect(spec.actions[1].url, isNotNull);
    });

    test('launch action without a command is dropped', () {
      final spec = _parseString('''
id = "dev-harness"
label = "⟳ {state}"
[status]
path = "s.json"

[[actions]]
label = "start"
kind = "launch"
''')!;
      expect(spec.actions, isEmpty);
    });

    test('parses prompt-kind (quick) actions', () {
      final spec = _parseString('''
id = "dev-harness"
label = "⟳ {state}"
[status]
path = "s.json"

[[actions]]
label = "review"
kind = "prompt"
prompt = "Review my uncommitted changes and report by severity."
''')!;

      expect(spec.actions, hasLength(1));
      expect(spec.actions[0].kind, SpecActionKind.prompt);
      expect(
        spec.actions[0].prompt,
        'Review my uncommitted changes and report by severity.',
      );
    });

    test('prompt action without a prompt is dropped', () {
      final spec = _parseString('''
id = "dev-harness"
label = "⟳ {state}"
[status]
path = "s.json"

[[actions]]
label = "review"
kind = "prompt"
''')!;
      expect(spec.actions, isEmpty);
    });

    test('parses shell-kind actions', () {
      final spec = _parseString('''
id = "dev-harness"
label = "⟳ {state}"
[status]
path = "s.json"

[[actions]]
label = "test"
kind = "shell"
command = "dart test"
''')!;
      expect(spec.actions, hasLength(1));
      expect(spec.actions[0].kind, SpecActionKind.shell);
      expect(spec.actions[0].command, 'dart test');
    });

    test('shell action without a command is dropped', () {
      final spec = _parseString('''
id = "dev-harness"
label = "⟳ {state}"
[status]
path = "s.json"

[[actions]]
label = "test"
kind = "shell"
''')!;
      expect(spec.actions, isEmpty);
    });

    test('parses screen-kind actions', () {
      final spec = _parseString('''
id = "my-notes"
label = "{display}"
[status]
path = "s.json"

[[actions]]
label = "open"
kind = "screen"
screen = "notes"
''', name: 'my-notes')!;
      expect(spec.actions, hasLength(1));
      expect(spec.actions[0].kind, SpecActionKind.screen);
      expect(spec.actions[0].screen, 'notes');
      expect(spec.actions[0].url, isNull);
    });

    test('screen action without a screen is dropped', () {
      final spec = _parseString('''
id = "my-notes"
label = "{display}"
[status]
path = "s.json"

[[actions]]
label = "open"
kind = "screen"
''', name: 'my-notes')!;
      expect(spec.actions, isEmpty);
    });

    test('record defaults to true; record=false parses', () {
      final loud = _parseString('''
id = "my-notes"
label = "{display}"
[status]
path = "s.json"

[[actions]]
label = "open"
kind = "screen"
screen = "notes"
''', name: 'my-notes')!;
      expect(loud.actions.single.record, isTrue);

      final quiet = _parseString('''
id = "my-notes"
label = "{display}"
[status]
path = "s.json"

[[actions]]
label = "open"
kind = "screen"
screen = "notes"
record = false
''', name: 'my-notes')!;
      expect(quiet.actions.single.record, isFalse);
    });

    test('parses a multi-line label template', () {
      final spec = _parseString('''
id = "dev-harness"
label = """
line one {price}
line two {delta}"""
[status]
path = "s.json"
''')!;
      expect(spec.labelTemplate, contains('\n'));
      expect(spec.labelTemplate, contains('line one {price}'));
      expect(spec.labelTemplate, contains('line two {delta}'));
    });
  });

  group('evaluateSpecStatus', () {
    late Directory tmp;
    late File statusFile;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('spec_status_test_');
      statusFile = File('${tmp.path}/status.json');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    SpecWidget spec({bool heartbeat = true}) => SpecWidget(
          id: 'dev-harness',
          labelTemplate: '⟳ crux dev · {state}',
          refresh: const Duration(seconds: 2),
          statusPath: 'status.json',
          heartbeatField: heartbeat ? 'heartbeatAt' : null,
          staleAfter: const Duration(seconds: 15),
          stateRules: [
            const SpecStateRule(
              field: 'lastReload.result',
              equals: 'succeeded',
              text: '✓ {lastReload.at@HH:MM}',
            ),
            const SpecStateRule(
              field: 'lastReload.result',
              equals: 'failed',
              text: '✗ reload failed',
              color: SpecStateColor.error,
            ),
          ],
          actions: const [
            SpecAction(label: 'reload', url: 'http://x/{controlPort}/r'),
          ],
        );

    Map<String, dynamic> data({
      DateTime? heartbeat,
      String? reloadResult,
    }) =>
        {
          if (heartbeat != null)
            'heartbeatAt': heartbeat.toUtc().toIso8601String(),
          if (reloadResult != null)
            'lastReload': {
              'at': DateTime(2026, 8, 4, 16, 53).toUtc().toIso8601String(),
              'result': reloadResult,
            },
          'controlPort': 5555,
        };

    void write(Map<String, dynamic> d) =>
        statusFile.writeAsStringSync(jsonEncode(d));

    test('absent when the status file is missing', () {
      final s = evaluateSpecStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, SpecAlive.absent);
      expect(s.stateText, 'not running');
      expect(s.label, '⟳ crux dev · not running');
      expect(s.color, SpecStateColor.dim);
    });

    test('alive + rule hit renders the rule text with time', () {
      write(
        data(
          heartbeat: DateTime.now(),
          reloadResult: 'succeeded',
        ),
      );
      final s = evaluateSpecStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, SpecAlive.alive);
      // Regex: local HH:MM of the fixture's UTC timestamp.
      expect(s.label, matches(RegExp(r'^⟳ crux dev · ✓ \d{2}:\d{2}$')));
    });

    test('alive + failed rule renders error state', () {
      write(
        data(
          heartbeat: DateTime.now(),
          reloadResult: 'failed',
        ),
      );
      final s = evaluateSpecStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, SpecAlive.alive);
      expect(s.label, '⟳ crux dev · ✗ reload failed');
      expect(s.color, SpecStateColor.error);
    });

    test('alive without reload uses the fallback', () {
      write(data(heartbeat: DateTime.now()));
      final s = evaluateSpecStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, SpecAlive.alive);
      expect(s.label, '⟳ crux dev · ●');
    });

    test('stale heartbeat renders stale', () {
      write(
        data(heartbeat: DateTime.now().subtract(const Duration(minutes: 5))),
      );
      final s = evaluateSpecStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, SpecAlive.stale);
      expect(s.label, '⟳ crux dev · stale');
      expect(s.color, SpecStateColor.warning);
    });

    test('no heartbeat field: file presence is liveness', () {
      final noHeartbeat = spec(heartbeat: false);
      write({'a': 1});
      expect(
        evaluateSpecStatus(noHeartbeat, statusFile, DateTime.now()).alive,
        SpecAlive.alive,
      );
      expect(
        evaluateSpecStatus(noHeartbeat, File('${tmp.path}/nope.json'),
                DateTime.now())
            .alive,
        SpecAlive.absent,
      );
    });

    test('corrupt JSON renders as absent', () {
      statusFile.writeAsStringSync('not json{{');
      final s = evaluateSpecStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, SpecAlive.absent);
    });

    test('multi-line label template renders per-line content', () {
      final monitor = SpecWidget(
        id: 'gold',
        labelTemplate: 'XAU {price}/oz\n{arrow} {delta} today',
        refresh: const Duration(minutes: 1),
        statusPath: 'status.json',
        // No heartbeatField → file presence = alive.
      );
      write({'price': 2411.5, 'delta': '+0.8%', 'arrow': '▲'});
      final s = evaluateSpecStatus(monitor, statusFile, DateTime.now());
      expect(s.alive, SpecAlive.alive);
      expect(s.labelLines, ['XAU 2411.5/oz', '▲ +0.8% today']);
    });

    test('labelLines drops blank lines and trims trailing space', () {
      final w = SpecWidget(
        id: 'x',
        labelTemplate: 'a  \n\n  \nb',
        refresh: const Duration(seconds: 1),
        statusPath: 'status.json',
      );
      write({'k': 1});
      final s = evaluateSpecStatus(w, statusFile, DateTime.now());
      expect(s.labelLines, ['a', 'b']);
    });
  });

  group('renderTemplate', () {
    test('substitutes fields, dotted paths, and state', () {
      final data = {
        'lastReload': {'result': 'succeeded'},
        'controlPort': 5555,
      };
      expect(
        renderTemplate('{state} · {lastReload.result}', data, '✓ 16:53'),
        '✓ 16:53 · succeeded',
      );
      expect(renderTemplate(':{controlPort}:', data, ''), ':5555:');
    });

    test('HH:MM formats ISO timestamps as local time', () {
      final data = {
        'at': DateTime(2026, 8, 4, 16, 53).toUtc().toIso8601String(),
      };
      expect(
        renderTemplate('{at@HH:MM}', data, ''),
        matches(RegExp(r'^\d{2}:\d{2}$')),
      );
    });

    test('unknown fields render as the literal placeholder', () {
      expect(
        renderTemplate('{nope}', const {}, ''),
        '{nope}',
      );
    });

    test('renderActionUrl substitutes status fields', () {
      final action = SpecAction(
        label: 'r',
        url: 'http://127.0.0.1:{controlPort}/reload',
      );
      expect(
        renderActionUrl(action, {'controlPort': 7777}),
        'http://127.0.0.1:7777/reload',
      );
    });

    test('renderActionPrompt substitutes status fields', () {
      final action = SpecAction(
        label: 'triage',
        kind: SpecActionKind.prompt,
        prompt: 'The {service} on :{port} is failing — triage it.',
      );
      expect(
        renderActionPrompt(action, {'service': 'api', 'port': 8080}),
        'The api on :8080 is failing — triage it.',
      );
    });

    test('renderActionCommand substitutes status fields', () {
      final action = SpecAction(
        label: 'test',
        kind: SpecActionKind.shell,
        command: 'dart test --name {focus}',
      );
      expect(
        renderActionCommand(action, {'focus': 'widget'}),
        'dart test --name widget',
      );
    });
  });

  group('runSpecShellAction', () {
    test('runs a command and captures the exit code + output tail',
        () async {
      final action = SpecAction(
        label: 'hello',
        kind: SpecActionKind.shell,
        command: 'echo hello-from-widget',
      );
      final result = await runSpecShellAction(
        action,
        const {},
        Directory.systemTemp.path,
      );
      expect(result.ok, isTrue);
      expect(result.exitCode, 0);
      expect(result.tail, contains('hello-from-widget'));
    });

    test('non-zero exit is reported, not thrown', () async {
      final action = SpecAction(
        label: 'fail',
        kind: SpecActionKind.shell,
        command: 'echo oops && exit 3',
      );
      final result = await runSpecShellAction(
        action,
        const {},
        Directory.systemTemp.path,
      );
      expect(result.ok, isFalse);
      expect(result.exitCode, 3);
      expect(result.tail, contains('oops'));
    });

    test('renders the command template against the status data',
        () async {
      final action = SpecAction(
        label: 't',
        kind: SpecActionKind.shell,
        command: 'echo {marker}',
      );
      final result = await runSpecShellAction(
        action,
        const {'marker': 'templated-value'},
        Directory.systemTemp.path,
      );
      expect(result.tail, contains('templated-value'));
    });
  });

  group('SpecWidgetRegistry', () {
    late Directory project;

    setUp(() {
      project = Directory.systemTemp.createTempSync('spec_registry_test_');
    });

    tearDown(() {
      try {
        project.deleteSync(recursive: true);
      } catch (_) {}
    });

    File writeSpec(String name, String content) {
      final dir = Directory('${project.path}/.crux/widgets');
      dir.createSync(recursive: true);
      final file = File('${dir.path}/$name.toml');
      file.writeAsStringSync(content);
      return file;
    }

    test('discovers specs written by other sessions', () {
      writeSpec(
        'dev-harness',
        'id = "dev-harness"\n'
            'label = "⟳ {state}"\n'
            '[status]\n'
            'path = "s.json"\n',
      );
      final registry = SpecWidgetRegistry(projectPath: project.path);
      registry.scan();

      expect(registry.widgets, hasLength(1));
      expect(registry.widgets.first.id, 'dev-harness');
      registry.dispose();
    });

    test('picks up new specs on a later scan; drops deleted ones', () {
      final registry = SpecWidgetRegistry(projectPath: project.path);
      registry.scan();
      expect(registry.widgets, isEmpty);

      writeSpec(
        'a',
        'id = "a"\nlabel = "A · {state}"\n[status]\npath = "s.json"\n',
      );
      registry.scan();
      expect(registry.widgets.map((w) => w.id), contains('a'));

      writeSpec(
        'b',
        'id = "b"\nlabel = "B · {state}"\n[status]\npath = "s.json"\n',
      );
      registry.scan();
      expect(registry.widgets.map((w) => w.id), containsAll(['a', 'b']));

      File('${project.path}/.crux/widgets/a.toml').deleteSync();
      registry.scan();
      expect(registry.widgets.map((w) => w.id), ['b']);

      registry.dispose();
    });

    test('invalid specs are skipped and reported as warnings', () {
      writeSpec('broken', 'id = "mismatch"\nlabel = "x"\n[status]\n');
      final registry = SpecWidgetRegistry(projectPath: project.path);
      registry.scan();

      expect(registry.widgets, isEmpty);
      expect(registry.lastWarnings, hasLength(1));
      expect(registry.lastWarnings.first, contains('broken'));
      registry.dispose();
    });

    test('scan without changes does not notify', () {
      writeSpec(
        'a',
        'id = "a"\nlabel = "A · {state}"\n[status]\npath = "s.json"\n',
      );
      final registry = SpecWidgetRegistry(projectPath: project.path);
      var notifications = 0;
      registry.addListener(() => notifications++);

      registry.scan(); // first scan: change
      expect(notifications, 1);
      registry.scan(); // unchanged: no notification
      expect(notifications, 1);
      registry.dispose();
    });

    test('watcher reloads a modified spec without waiting for the poll',
        () async {
      writeSpec(
        'a',
        'id = "a"\nlabel = "A · {state}"\n[status]\npath = "s.json"\n',
      );
      // Polling effectively disabled: only the file watcher can pick
      // up the rewrite below.
      final registry = SpecWidgetRegistry(
        projectPath: project.path,
        scanInterval: const Duration(hours: 1),
      );
      registry.start();
      expect(registry.widgets.single.labelTemplate, contains('A'));

      // Rewrite the spec — the watcher should re-scan (debounced).
      writeSpec(
        'a',
        'id = "a"\nlabel = "B · {state}"\n[status]\npath = "s.json"\n',
      );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(registry.widgets.single.labelTemplate, contains('B'));

      registry.dispose();
    });
  });
}
