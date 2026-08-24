// Tests for the spec-widget schema (Phase B): TOML parsing, status
// evaluation, template substitution, and the project-keyed registry.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/services/plugin.dart';
import 'package:crux/src/services/plugin_registry.dart';

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

Plugin? _parseString(String content, {String name = 'dev-harness'}) {
  final dir = Directory.systemTemp.createTempSync('plugin_spec_test_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  final file = File('${dir.path}/$name.toml')..writeAsStringSync(content);
  return Plugin.parse(file);
}

void main() {
  group('Plugin.parse', () {
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
      expect(spec.stateRules[1].color, PluginStateColor.error);
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
      expect(spec.actions[0].kind, PluginActionKind.launch);
      expect(spec.actions[0].command, 'dart --enable-vm-service '
          'tool/crux_dev.dart home');
      expect(spec.actions[0].url, isNull);
      expect(spec.actions[1].kind, PluginActionKind.http);
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
      expect(spec.actions[0].kind, PluginActionKind.prompt);
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
      expect(spec.actions[0].kind, PluginActionKind.shell);
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
      expect(spec.actions[0].kind, PluginActionKind.screen);
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

    test('action style parses: segment default, button opt-in', () {
      final spec = _parseString('''
id = "my-notes"
label = "{display}"
[status]
path = "s.json"

[[actions]]
label = "start"
kind = "launch"
command = "run.sh"

[[actions]]
label = "refresh"
kind = "shell"
command = "fetch.sh"
style = "button"

[[actions]]
label = "bogus"
kind = "shell"
command = "x.sh"
style = "diagonal"
''', name: 'my-notes')!;
      // Default and unknown styles are segment; "button" opts in.
      expect(spec.actions[0].style, PluginActionStyle.segment);
      expect(spec.actions[1].style, PluginActionStyle.button);
      expect(spec.actions[2].style, PluginActionStyle.segment);
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

  group('evaluatePluginStatus', () {
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

    Plugin spec({bool heartbeat = true}) => Plugin(
          id: 'dev-harness',
          labelTemplate: '⟳ crux dev · {state}',
          refresh: const Duration(seconds: 2),
          statusPath: 'status.json',
          heartbeatField: heartbeat ? 'heartbeatAt' : null,
          staleAfter: const Duration(seconds: 15),
          stateRules: [
            const PluginStateRule(
              field: 'lastReload.result',
              equals: 'succeeded',
              text: '✓ {lastReload.at@HH:MM}',
            ),
            const PluginStateRule(
              field: 'lastReload.result',
              equals: 'failed',
              text: '✗ reload failed',
              color: PluginStateColor.error,
            ),
          ],
          actions: const [
            PluginAction(label: 'reload', url: 'http://x/{controlPort}/r'),
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
      final s = evaluatePluginStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, PluginAlive.absent);
      expect(s.stateText, 'not running');
      expect(s.label, '⟳ crux dev · not running');
      expect(s.color, PluginStateColor.dim);
    });

    test('alive + rule hit renders the rule text with time', () {
      write(
        data(
          heartbeat: DateTime.now(),
          reloadResult: 'succeeded',
        ),
      );
      final s = evaluatePluginStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, PluginAlive.alive);
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
      final s = evaluatePluginStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, PluginAlive.alive);
      expect(s.label, '⟳ crux dev · ✗ reload failed');
      expect(s.color, PluginStateColor.error);
    });

    test('alive without reload uses the fallback', () {
      write(data(heartbeat: DateTime.now()));
      final s = evaluatePluginStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, PluginAlive.alive);
      expect(s.label, '⟳ crux dev · ●');
    });

    test('stale heartbeat renders stale', () {
      write(
        data(heartbeat: DateTime.now().subtract(const Duration(minutes: 5))),
      );
      final s = evaluatePluginStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, PluginAlive.stale);
      expect(s.label, '⟳ crux dev · stale');
      expect(s.color, PluginStateColor.warning);
    });

    test('no heartbeat field: file presence is liveness', () {
      final noHeartbeat = spec(heartbeat: false);
      write({'a': 1});
      expect(
        evaluatePluginStatus(noHeartbeat, statusFile, DateTime.now()).alive,
        PluginAlive.alive,
      );
      expect(
        evaluatePluginStatus(noHeartbeat, File('${tmp.path}/nope.json'),
                DateTime.now())
            .alive,
        PluginAlive.absent,
      );
    });

    test('corrupt JSON renders as absent', () {
      statusFile.writeAsStringSync('not json{{');
      final s = evaluatePluginStatus(spec(), statusFile, DateTime.now());
      expect(s.alive, PluginAlive.absent);
    });

    test('multi-line label template renders per-line content', () {
      final monitor = Plugin(
        id: 'gold',
        labelTemplate: 'XAU {price}/oz\n{arrow} {delta} today',
        refresh: const Duration(minutes: 1),
        statusPath: 'status.json',
        // No heartbeatField → file presence = alive.
      );
      write({'price': 2411.5, 'delta': '+0.8%', 'arrow': '▲'});
      final s = evaluatePluginStatus(monitor, statusFile, DateTime.now());
      expect(s.alive, PluginAlive.alive);
      expect(s.labelLines, ['XAU 2411.5/oz', '▲ +0.8% today']);
    });

    test('spanLines mark substituted values vs literal text', () {
      final monitor = Plugin(
        id: 'gold',
        // `!` marks emphasis-colored values (e.g. the price); the
        // arrow/timestamp stay neutral.
        labelTemplate: 'Au {price!}/oz\n{arrow} {delta!} ({pct}%)',
        refresh: const Duration(seconds: 10),
        statusPath: 'status.json',
        stateRules: const [
          PluginStateRule(
            field: 'trend',
            equals: 'down',
            text: '▼',
            color: PluginStateColor.success,
          ),
        ],
      );
      write({
        'price': '953.56',
        'arrow': '▼',
        'delta': '-1.20',
        'pct': '-0.03',
        'trend': 'down',
      });
      final s = evaluatePluginStatus(monitor, statusFile, DateTime.now());
      expect(s.spanLines, hasLength(2));

      // Line 1: dim literal, EMPHASIS value, dim literal.
      expect(
        s.spanLines[0]
            .map((sp) => (sp.text, sp.isValue, sp.emphasize))
            .toList(),
        [
          ('Au ', false, false),
          ('953.56', true, true),
          ('/oz', false, false),
        ],
      );

      // Line 2: neutral arrow value, emphasis delta, neutral pct.
      expect(
        s.spanLines[1].map((sp) => (sp.text, sp.isValue, sp.emphasize)).toList(),
        [
          ('▼', true, false),
          (' ', false, false),
          ('-1.20', true, true),
          (' (', false, false),
          ('-0.03', true, false),
          ('%)', false, false),
        ],
      );

      // Span text always reassembles into the plain label lines.
      for (var i = 0; i < s.spanLines.length; i++) {
        expect(
          s.spanLines[i].map((sp) => sp.text).join(),
          s.labelLines[i],
        );
      }
    });

    test('dead states render spanLines as single literal spans', () {
      final monitor = Plugin(
        id: 'gold',
        labelTemplate: 'Au {price}/oz\n{arrow} {delta}',
        refresh: const Duration(seconds: 10),
        statusPath: 'status.json',
        heartbeatField: 'heartbeatAt',
        staleText: 'no update',
      );
      // No status file → absent.
      final s = evaluatePluginStatus(monitor, statusFile, DateTime.now());
      expect(s.alive, PluginAlive.absent);
      expect(s.spanLines, [
        [(text: 'not running', isValue: false, emphasize: false)],
      ]);
    });

    test('dead label is the fallback text when template has no {state}',
        () {
      // Content plugins (price monitors) reference data fields the
      // missing/stale file can't supply — the dead label must be the
      // plain fallback, not raw `{field}` placeholders.
      final monitor = Plugin(
        id: 'gold',
        labelTemplate: 'Au {price}/oz\n{arrow} {delta} today',
        refresh: const Duration(seconds: 10),
        statusPath: 'status.json',
        heartbeatField: 'heartbeatAt',
        staleAfter: const Duration(seconds: 35),
        staleText: 'no update',
        absentText: 'tracker not running',
      );

      final absent =
          evaluatePluginStatus(monitor, statusFile, DateTime.now());
      expect(absent.alive, PluginAlive.absent);
      expect(absent.label, 'tracker not running');

      write({
        'heartbeatAt':
            DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String(),
      });
      final stale = evaluatePluginStatus(monitor, statusFile, DateTime.now());
      expect(stale.alive, PluginAlive.stale);
      expect(stale.label, 'no update');
    });

    test('parses the success state color', () {
      final spec = Plugin(
        id: 'gold',
        labelTemplate: '{arrow} {delta}',
        refresh: const Duration(seconds: 10),
        statusPath: 'status.json',
        stateRules: const [
          PluginStateRule(
            field: 'trend',
            equals: 'down',
            text: '▼ down',
            color: PluginStateColor.success,
          ),
        ],
      );
      write({'trend': 'down', 'arrow': '▼', 'delta': '-3.2'});
      final s = evaluatePluginStatus(spec, statusFile, DateTime.now());
      expect(s.alive, PluginAlive.alive);
      expect(s.color, PluginStateColor.success);
      expect(s.labelLines, ['▼ -3.2']);
    });

    test('labelLines drops blank lines and trims trailing space', () {
      final w = Plugin(
        id: 'x',
        labelTemplate: 'a  \n\n  \nb',
        refresh: const Duration(seconds: 1),
        statusPath: 'status.json',
      );
      write({'k': 1});
      final s = evaluatePluginStatus(w, statusFile, DateTime.now());
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
      final action = PluginAction(
        label: 'r',
        url: 'http://127.0.0.1:{controlPort}/reload',
      );
      expect(
        renderActionUrl(action, {'controlPort': 7777}),
        'http://127.0.0.1:7777/reload',
      );
    });

    test('renderActionPrompt substitutes status fields', () {
      final action = PluginAction(
        label: 'triage',
        kind: PluginActionKind.prompt,
        prompt: 'The {service} on :{port} is failing — triage it.',
      );
      expect(
        renderActionPrompt(action, {'service': 'api', 'port': 8080}),
        'The api on :8080 is failing — triage it.',
      );
    });

    test('renderActionCommand substitutes status fields', () {
      final action = PluginAction(
        label: 'test',
        kind: PluginActionKind.shell,
        command: 'dart test --name {focus}',
      );
      expect(
        renderActionCommand(action, {'focus': 'widget'}),
        'dart test --name widget',
      );
    });
  });

  group('runPluginShellAction', () {
    test('runs a command and captures the exit code + output tail',
        () async {
      final action = PluginAction(
        label: 'hello',
        kind: PluginActionKind.shell,
        command: 'echo hello-from-widget',
      );
      final result = await runPluginShellAction(
        action,
        const {},
        Directory.systemTemp.path,
      );
      expect(result.ok, isTrue);
      expect(result.exitCode, 0);
      expect(result.tail, contains('hello-from-widget'));
    });

    test('non-zero exit is reported, not thrown', () async {
      final action = PluginAction(
        label: 'fail',
        kind: PluginActionKind.shell,
        command: 'echo oops && exit 3',
      );
      final result = await runPluginShellAction(
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
      final action = PluginAction(
        label: 't',
        kind: PluginActionKind.shell,
        command: 'echo {marker}',
      );
      final result = await runPluginShellAction(
        action,
        const {'marker': 'templated-value'},
        Directory.systemTemp.path,
      );
      expect(result.tail, contains('templated-value'));
    });
  });

  group('PluginRegistry', () {
    late Directory project;
    late Directory home;

    setUp(() {
      project = Directory.systemTemp.createTempSync('spec_registry_test_');
      // Sealed home: without the override the registry would scan the
      // REAL ~/.crux/plugins and pick up whatever the user installed
      // there, breaking the length/id expectations below.
      home = Directory.systemTemp.createTempSync('spec_registry_home_');
    });

    tearDown(() {
      try {
        project.deleteSync(recursive: true);
      } catch (_) {}
      try {
        home.deleteSync(recursive: true);
      } catch (_) {}
    });

    File writeSpec(String name, String content) {
      final dir = Directory('${project.path}/.crux/plugins');
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
      final registry = PluginRegistry(
        projectPath: project.path,
        homeOverride: home.path,
      );
      registry.scan();

      expect(registry.plugins, hasLength(1));
      expect(registry.plugins.first.id, 'dev-harness');
      registry.dispose();
    });

    test('picks up new specs on a later scan; drops deleted ones', () {
      final registry = PluginRegistry(
        projectPath: project.path,
        homeOverride: home.path,
      );
      registry.scan();
      expect(registry.plugins, isEmpty);

      writeSpec(
        'a',
        'id = "a"\nlabel = "A · {state}"\n[status]\npath = "s.json"\n',
      );
      registry.scan();
      expect(registry.plugins.map((w) => w.id), contains('a'));

      writeSpec(
        'b',
        'id = "b"\nlabel = "B · {state}"\n[status]\npath = "s.json"\n',
      );
      registry.scan();
      expect(registry.plugins.map((w) => w.id), containsAll(['a', 'b']));

      File('${project.path}/.crux/plugins/a.toml').deleteSync();
      registry.scan();
      expect(registry.plugins.map((w) => w.id), ['b']);

      registry.dispose();
    });

    test('invalid specs are skipped and reported as warnings', () {
      writeSpec('broken', 'id = "mismatch"\nlabel = "x"\n[status]\n');
      final registry = PluginRegistry(
        projectPath: project.path,
        homeOverride: home.path,
      );
      registry.scan();

      expect(registry.plugins, isEmpty);
      expect(registry.lastWarnings, hasLength(1));
      expect(registry.lastWarnings.first, contains('broken'));
      registry.dispose();
    });

    test('scan without changes does not notify', () {
      writeSpec(
        'a',
        'id = "a"\nlabel = "A · {state}"\n[status]\npath = "s.json"\n',
      );
      final registry = PluginRegistry(
        projectPath: project.path,
        homeOverride: home.path,
      );
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
      final registry = PluginRegistry(
        projectPath: project.path,
        homeOverride: home.path,
        scanInterval: const Duration(hours: 1),
      );
      registry.start();
      expect(registry.plugins.single.labelTemplate, contains('A'));

      // Rewrite the spec — the watcher should re-scan (debounced).
      writeSpec(
        'a',
        'id = "a"\nlabel = "B · {state}"\n[status]\npath = "s.json"\n',
      );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(registry.plugins.single.labelTemplate, contains('B'));

      registry.dispose();
    });

    test('placement parses: sidebar default, home, both', () {
      writeSpec(
        'p-default',
        'id = "p-default"\nlabel = "x {state}"\n[status]\npath = "s.json"\n',
      );
      writeSpec(
        'p-home',
        'id = "p-home"\nplacement = "home"\nlabel = "x {state}"\n'
            '[status]\npath = "s.json"\n',
      );
      writeSpec(
        'p-both',
        'id = "p-both"\nplacement = "both"\nlabel = "x {state}"\n'
            '[status]\npath = "s.json"\n',
      );
      final registry = PluginRegistry(
        projectPath: project.path,
        homeOverride: home.path,
      );
      registry.scan();
      final byId = {for (final p in registry.plugins) p.id: p};
      expect(byId['p-default']!.placement, PluginPlacement.sidebar);
      expect(byId['p-home']!.placement, PluginPlacement.home);
      expect(byId['p-both']!.placement, PluginPlacement.both);
      // Placement filters drive the two surfaces.
      expect(
        registry.sidebarPlugins.map((p) => p.id),
        containsAll(['p-default', 'p-both']),
      );
      expect(registry.sidebarPlugins.map((p) => p.id), isNot(contains('p-home')));
      expect(
        registry.homePlugins.map((p) => p.id),
        containsAll(['p-home', 'p-both']),
      );
      expect(
          registry.homePlugins.map((p) => p.id), isNot(contains('p-default')));
      registry.dispose();
    });

    test('legacy .crux/widgets/ specs are still scanned', () {
      final dir = Directory('${project.path}/.crux/widgets')
        ..createSync(recursive: true);
      File('${dir.path}/legacy.toml').writeAsStringSync(
        'id = "legacy"\nlabel = "old {state}"\n[status]\npath = "s.json"\n',
      );
      final registry = PluginRegistry(
        projectPath: project.path,
        homeOverride: home.path,
      );
      registry.scan();
      expect(registry.plugins.map((p) => p.id), ['legacy']);
      registry.dispose();
    });

    test('plugins/ wins over a legacy widgets/ spec with the same id', () {
      writeSpec(
        'dup',
        'id = "dup"\nlabel = "new {state}"\n[status]\npath = "s.json"\n',
      );
      final dir = Directory('${project.path}/.crux/widgets')
        ..createSync(recursive: true);
      File('${dir.path}/dup.toml').writeAsStringSync(
        'id = "dup"\nlabel = "old {state}"\n[status]\npath = "s.json"\n',
      );
      final registry = PluginRegistry(
        projectPath: project.path,
        homeOverride: home.path,
      );
      registry.scan();
      expect(registry.plugins.single.labelTemplate, contains('new'));
      registry.dispose();
    });

    test('global ~/.crux/plugins/ specs are scanned and flagged isGlobal',
        () {
      final home = Directory.systemTemp.createTempSync('plugin_home_test_');
      addTearDown(() {
        try {
          home.deleteSync(recursive: true);
        } catch (_) {}
      });
      final globalDir = Directory('${home.path}/.crux/plugins')
        ..createSync(recursive: true);
      File('${globalDir.path}/globaltool.toml').writeAsStringSync(
        'id = "globaltool"\nlabel = "g {state}"\n[status]\npath = "s.json"\n',
      );

      final registry = PluginRegistry(
        projectPath: project.path,
        homeOverride: home.path,
      );
      registry.scan();
      expect(registry.plugins.map((p) => p.id), ['globaltool']);
      expect(registry.plugins.single.isGlobal, isTrue);
      registry.dispose();
    });
  });
}
