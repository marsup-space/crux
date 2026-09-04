// Tests for the generic spec-driven sidebar widget renderer (Phase B).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/plugin_content.dart' show PluginHost;
import 'package:crux/src/components/plugin_sidebar_box.dart';
import 'package:crux/src/services/plugin.dart';
import 'package:crux/src/theme/crux_theme.dart';

/// A spec whose status file lives in [project] and whose actions point
/// at a port read from the status JSON (mirrors dev-harness.toml).
Plugin _spec({Duration refresh = const Duration(hours: 1)}) => Plugin(
  id: 'dev-harness',
  labelTemplate: '⟳ crux dev · {state}',
  refresh: refresh,
  statusPath: '.dart_tool/crux_dev.json',
  heartbeatField: 'heartbeatAt',
  staleAfter: const Duration(seconds: 15),
  stateRules: const [
    PluginStateRule(
      field: 'lastReload.result',
      equals: 'succeeded',
      text: '✓ {lastReload.at@HH:MM}',
    ),
    PluginStateRule(
      field: 'lastReload.result',
      equals: 'failed',
      text: '✗ reload failed',
      color: PluginStateColor.error,
    ),
  ],
  actions: const [
    // Launch actions: shown only while the service is dead.
    PluginAction(
      label: 'start',
      kind: PluginActionKind.launch,
      command: 'dart tool/crux_dev.dart home',
    ),
    // http actions: shown only while the service is alive.
    PluginAction(label: 'reload', url: 'http://127.0.0.1:{controlPort}/reload'),
    PluginAction(label: 'close', url: 'http://127.0.0.1:{controlPort}/close'),
  ],
);

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('plugin_box_render_');
  });

  tearDown(() {
    try {
      project.deleteSync(recursive: true);
    } catch (_) {}
  });

  File statusFile() => File('${project.path}/.dart_tool/crux_dev.json');

  void writeStatus({
    DateTime? heartbeat,
    String? reloadResult,
    int? controlPort,
  }) {
    statusFile().parent.createSync(recursive: true);
    statusFile().writeAsStringSync(
      jsonEncode({
        'pid': 1,
        if (heartbeat != null)
          'heartbeatAt': heartbeat.toUtc().toIso8601String(),
        if (reloadResult != null)
          'lastReload': {
            'at': DateTime(2026, 8, 4, 16, 53).toUtc().toIso8601String(),
            'result': reloadResult,
          },
        if (controlPort != null) 'controlPort': controlPort,
      }),
    );
  }

  Future<void> pump(dynamic tester, {Plugin? spec}) async {
    await tester.pumpComponent(
      Container(
        width: 80,
        height: 8,
        child: CruxTheme(
          data: CruxThemeData.draculaFallback,
          child: PluginSidebarBox(
            plugin: spec ?? _spec(),
            host: PluginHost(projectPath: project.path),
          ),
        ),
      ),
    );
  }

  /// Hover the row by locating the label text on screen — the bordered
  /// box shifts the button by a row and the border title ("crux dev")
  /// sits above the content, so anchor on the label's ⟳ glyph instead.
  Future<void> hoverLabel(dynamic tester) async {
    final pos = tester.terminalState.findText('⟳').first;
    await tester.hover(pos.x + 2, pos.y);
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  group('PluginSidebarBox — label states', () {
    test('renders the spec title inline on the box border', () async {
      await testNocterm('plugin box title', (tester) async {
        writeStatus(heartbeat: DateTime.now());
        // title defaults to the spec id ('dev-harness') — the border
        // chrome must show it on screen alongside the status label.
        await pump(tester, spec: _spec());
        expect(tester.terminalState.containsText('dev-harness'), isTrue);
        expect(tester.terminalState.containsText('crux dev'), isTrue);
      });
    });

    test('absent: "not running"', () async {
      await testNocterm('spec widget absent', (tester) async {
        await pump(tester);
        expect(tester.terminalState.containsText('not running'), isTrue);
      });
    });

    test('alive with succeeded reload shows ✓ + time', () async {
      await testNocterm('spec widget ok', (tester) async {
        writeStatus(heartbeat: DateTime.now(), reloadResult: 'succeeded');
        await pump(tester);
        expect(
          tester.terminalState.getText(),
          matches(RegExp(r'crux dev · ✓ \d{2}:\d{2}')),
        );
      });
    });

    test('failed reload shows the error label', () async {
      await testNocterm('spec widget failed', (tester) async {
        writeStatus(heartbeat: DateTime.now(), reloadResult: 'failed');
        await pump(tester);
        expect(tester.terminalState.containsText('✗ reload failed'), isTrue);
      });
    });

    test('stale heartbeat shows stale', () async {
      await testNocterm('spec widget stale', (tester) async {
        writeStatus(
          heartbeat: DateTime.now().subtract(const Duration(minutes: 5)),
        );
        await pump(tester);
        expect(tester.terminalState.containsText('stale'), isTrue);
      });
    });
  });

  group('PluginSidebarBox — action segments', () {
    test('alive harness exposes reload/close on hover', () async {
      await testNocterm('spec widget segments', (tester) async {
        writeStatus(heartbeat: DateTime.now(), controlPort: 1);
        await pump(tester);

        await hoverLabel(tester);

        final text = tester.terminalState.getText();
        expect(text.contains('reload'), isTrue);
        expect(text.contains('close'), isTrue);
      });
    });

    test(
      'absent harness renders a start segment, no control segments',
      () async {
        await testNocterm('spec widget no segments', (tester) async {
          await pump(tester);

          // Idle label before hover still shows the dead state.
          expect(tester.terminalState.containsText('not running'), isTrue);

          // Dead service: hover reveals the launch action only.
          await hoverLabel(tester);

          final text = tester.terminalState.getText();
          expect(text.contains('reload'), isFalse);
          expect(text.contains('close'), isFalse);
          expect(text.contains('start'), isTrue);
        });
      },
    );

    test('alive harness hides the start segment', () async {
      await testNocterm('spec widget no start when alive', (tester) async {
        writeStatus(heartbeat: DateTime.now(), controlPort: 1);
        await pump(tester);

        await hoverLabel(tester);

        final text = tester.terminalState.getText();
        expect(text.contains('start'), isFalse);
        expect(text.contains('reload'), isTrue);
        expect(text.contains('close'), isTrue);
      });
    });

    test(
      'clicking reload POSTs to the control port from the status JSON',
      () async {
        final hits = <String>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final sub = server.listen((req) async {
          hits.add('${req.method} ${req.uri.path}');
          req.response.statusCode = 200;
          await req.response.close();
        });

        await testNocterm('spec widget action', (tester) async {
          writeStatus(heartbeat: DateTime.now(), controlPort: server.port);
          await pump(tester);

          // Hover to reveal segments, then click the first (reload).
          await hoverLabel(tester);
          final seg = tester.terminalState.findText('reload').first;
          await tester.tap(seg.x + 5, seg.y);
          await tester.pump();
          // Real HTTP round-trip — pumpAndSettle can't drive real sockets.
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pump();

          expect(hits, contains('POST /reload'));
        });

        await sub.cancel();
        await server.close(force: true);
      },
    );

    test('http click records the SUCCESS outcome into onAction', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((req) async {
        req.response.statusCode = 200;
        await req.response.close();
      });
      final notes = <String>[];

      await testNocterm('spec widget action note ok', (tester) async {
        writeStatus(heartbeat: DateTime.now(), controlPort: server.port);
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: _spec(),
                host: PluginHost(
                  projectPath: project.path,
                  onAction: (note) async => notes.add(note),
                ),
              ),
            ),
          ),
        );

        await hoverLabel(tester);
        final seg = tester.terminalState.findText('reload').first;
        await tester.tap(seg.x + 5, seg.y);
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();

        expect(notes, hasLength(1));
        expect(notes.single, contains('clicked `reload`'));
        expect(notes.single, contains('succeeded'));
        expect(notes.single, isNot(contains('FAILED')));
      });

      await sub.cancel();
      await server.close(force: true);
    });

    test('http click records the FAILURE outcome into onAction', () async {
      // Bind a port, close it → the POST is refused.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final notes = <String>[];

      await testNocterm('plugin action note fail', (tester) async {
        writeStatus(heartbeat: DateTime.now(), controlPort: port);
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: _spec(),
                host: PluginHost(
                  projectPath: project.path,
                  onAction: (note) async => notes.add(note),
                ),
              ),
            ),
          ),
        );

        await hoverLabel(tester);
        final seg = tester.terminalState.findText('reload').first;
        await tester.tap(seg.x + 5, seg.y);
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();

        expect(notes, hasLength(1));
        expect(notes.single, contains('FAILED'));
      });
    });

    test('action failure (connection refused) does not crash', () async {
      // Bind a port, note it, close it → nothing listens there.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();

      await testNocterm('spec widget dead action', (tester) async {
        writeStatus(heartbeat: DateTime.now(), controlPort: port);
        await pump(tester);

        await hoverLabel(tester);
        final seg = tester.terminalState.findText('reload').first;
        await tester.tap(seg.x + 5, seg.y);
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();

        // Still renders (stale data); no crash.
        expect(tester.terminalState.containsText('crux dev'), isTrue);
      });
    });
  });

  group('PluginSidebarBox — quick (prompt) actions', () {
    Plugin promptSpec() => Plugin(
      id: 'dev-harness',
      labelTemplate: '⟳ crux dev · {state}',
      refresh: const Duration(hours: 1),
      statusPath: '.dart_tool/crux_dev.json',
      heartbeatField: 'heartbeatAt',
      actions: const [
        PluginAction(
          label: 'review',
          kind: PluginActionKind.prompt,
          prompt: 'Review port {controlPort} config.',
        ),
      ],
    );

    test('clicking a prompt segment submits the rendered message', () async {
      String? submitted;
      await testNocterm('spec widget prompt action', (tester) async {
        writeStatus(heartbeat: DateTime.now(), controlPort: 7777);
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: promptSpec(),
                host: PluginHost(
                  projectPath: project.path,
                  onPromptAction: (action, rendered) => submitted = rendered,
                ),
              ),
            ),
          ),
        );

        await hoverLabel(tester);
        final seg = tester.terminalState.findText('review').first;
        await tester.tap(seg.x + 5, seg.y);
        await tester.pump();

        expect(submitted, 'Review port 7777 config.');
      });
    });

    test('prompt segments render even when the service is dead', () async {
      await testNocterm('spec widget prompt when dead', (tester) async {
        // No status file → absent.
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: promptSpec(),
                host: PluginHost(
                  projectPath: project.path,
                  onPromptAction: (_, __) {},
                ),
              ),
            ),
          ),
        );

        await hoverLabel(tester);
        expect(tester.terminalState.containsText('review'), isTrue);
      });
    });

    test('no onPromptAction callback → prompt segments hidden', () async {
      await testNocterm('spec widget prompt hidden', (tester) async {
        writeStatus(heartbeat: DateTime.now(), controlPort: 1);
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: promptSpec(),
                host: PluginHost(projectPath: project.path),
              ),
            ),
          ),
        );

        await hoverLabel(tester);
        expect(tester.terminalState.containsText('review'), isFalse);
      });
    });
  });

  group('PluginSidebarBox — multi-line labels', () {
    test('a multi-line label renders each line as its own row', () async {
      await testNocterm('spec widget multiline', (tester) async {
        final monitor = Plugin(
          id: 'gold',
          title: 'gold',
          labelTemplate: 'XAU {price}/oz\n{arrow} {delta} today',
          refresh: const Duration(hours: 1),
          statusPath: '.dart_tool/crux_dev.json',
          // No heartbeatField → file presence = alive.
        );
        writeStatus(controlPort: 1); // file exists → alive
        // Overwrite with gold-shaped data.
        statusFile().writeAsStringSync(
          jsonEncode({'price': 2411.5, 'delta': '+0.8%', 'arrow': '▲'}),
        );

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: monitor,
                host: PluginHost(projectPath: project.path),
              ),
            ),
          ),
        );

        final text = tester.terminalState.getText();
        expect(text.contains('XAU 2411.5/oz'), isTrue);
        expect(text.contains('▲ +0.8% today'), isTrue);
      });
    });
  });

  group('PluginSidebarBox — gold A2UI surface', () {
    Plugin goldSpec() => Plugin(
      id: 'gold',
      title: 'gold',
      labelTemplate:
          r'${usdOz!}/oz {usdArrow}{usdDelta!}'
          '\n¥{cnyG!}/g {cnyArrow}{cnyDelta!}',
      refresh: const Duration(hours: 1),
      statusPath: '.dart_tool/crux_dev.json',
      heartbeatField: 'heartbeatAt',
      actions: const [
        PluginAction(
          label: 'start tracker',
          kind: PluginActionKind.shell,
          command: 'echo restarted',
        ),
      ],
    );

    void writeGoldStatus() {
      statusFile().parent.createSync(recursive: true);
      statusFile().writeAsStringSync(
        jsonEncode({
          'heartbeatAt': DateTime.now().toUtc().toIso8601String(),
          'usdOz': '4470.30',
          'usdArrow': '▲',
          'usdDelta': '+1.60',
          'usdTrend': 'up',
          'cnyG': '968.05',
          'cnyArrow': '▼',
          'cnyDelta': '-0.35',
          'cnyTrend': 'down',
        }),
      );
    }

    test('keeps the two price rows without a manual tracker action', () async {
      await testNocterm('gold A2UI surface', (tester) async {
        writeGoldStatus();
        await tester.pumpComponent(
          Container(
            width: 44,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: goldSpec(),
                host: PluginHost(projectPath: project.path),
              ),
            ),
          ),
        );

        final text = tester.terminalState.getText();
        expect(text.contains('XAU / oz  4470.30 ▲+1.60'), isTrue);
        expect(text.contains('CNY / g  ¥968.05 ▼-0.35'), isTrue);
        expect(text.contains('start tracker'), isFalse);
      });
    });
  });

  group('PluginSidebarBox — screen actions', () {
    Plugin notesSpec() => Plugin(
      id: 'my-notes',
      title: 'my notes',
      labelTemplate: '{display}',
      refresh: const Duration(hours: 1),
      statusPath: '.dart_tool/crux_dev.json',
      // No heartbeatField → file presence = alive.
      actions: const [
        PluginAction(
          label: 'open',
          kind: PluginActionKind.screen,
          screen: 'notes',
        ),
      ],
    );

    test('screen button is always visible (no hover) and fires '
        'onScreenAction', () async {
      PluginAction? opened;
      await testNocterm('spec widget screen action', (tester) async {
        // File exists → alive, so the todo label renders.
        writeStatus(controlPort: 1);
        statusFile().writeAsStringSync(jsonEncode({'display': 'no todos'}));
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: notesSpec(),
                host: PluginHost(
                  projectPath: project.path,
                  onScreenAction: (action) => opened = action,
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // The open button is an always-visible Button (NOT a
        // hover-reveal segment), so it's present at rest.
        expect(tester.terminalState.containsText('open'), isTrue);

        final seg = tester.terminalState.findText('open').first;
        await tester.hover(seg.x + 2, seg.y);
        await tester.pump();
        await tester.tap(seg.x + 2, seg.y);
        await tester.pump();

        expect(opened, isNotNull);
        expect(opened!.screen, 'notes');
      });
    });

    test('screen button renders even when the status file is absent', () async {
      await testNocterm('spec widget screen when dead', (tester) async {
        // No status file → absent, but screen actions still render. The
        // label is the literal `{display}` placeholder (no data).
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: notesSpec(),
                host: PluginHost(
                  projectPath: project.path,
                  onScreenAction: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        // Visible without any hover.
        expect(tester.terminalState.containsText('open'), isTrue);
      });
    });

    test('no onScreenAction callback → screen button hidden', () async {
      await testNocterm('spec widget screen hidden', (tester) async {
        writeStatus(controlPort: 1);
        statusFile().writeAsStringSync(jsonEncode({'display': 'no todos'}));
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: notesSpec(),
                host: PluginHost(projectPath: project.path),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.terminalState.containsText('open'), isFalse);
      });
    });

    test('a multi-line todo label renders each item once (no dup)', () async {
      await testNocterm('spec widget notes no dup', (tester) async {
        writeStatus(controlPort: 1);
        statusFile().writeAsStringSync(
          jsonEncode({
            'display': '2 todos',
            'todos': [
              {'text': 'fix bug', 'line': 0},
              {'text': 'write tests', 'line': 1},
            ],
          }),
        );
        await tester.pumpComponent(
          Container(
            width: 60,
            height: 10,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: notesSpec(),
                host: PluginHost(
                  projectPath: project.path,
                  onScreenAction: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final text = tester.terminalState.getText();
        expect('☐ fix bug'.allMatches(text).length, 1);
        expect('☐ write tests'.allMatches(text).length, 1);
        expect('2 todos'.allMatches(text).length, 1);
      });
    });

    test('count line and open button share one row (inline)', () async {
      await testNocterm('spec widget notes inline', (tester) async {
        writeStatus(controlPort: 1);
        statusFile().writeAsStringSync(jsonEncode({'display': '1 todo'}));
        await tester.pumpComponent(
          Container(
            width: 60,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: notesSpec(),
                host: PluginHost(
                  projectPath: project.path,
                  onScreenAction: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final count = tester.terminalState.findText('1 todo');
        final open = tester.terminalState.findText('open');
        expect(count, isNotEmpty);
        expect(open, isNotEmpty);
        // Same terminal row → inline, not stacked.
        expect(count.first.y, open.first.y);
      });
    });

    test(
      'todo rows are clickable and fire onTodoToggle with text + line',
      () async {
        String? toggledText;
        int? toggledLine;
        bool? toggledDone;
        await testNocterm('spec widget todo toggle', (tester) async {
          writeStatus(controlPort: 1);
          statusFile().writeAsStringSync(
            jsonEncode({
              'display': '2 todos',
              'todos': [
                {'text': 'fix bug', 'line': 0},
                {'text': 'write tests', 'line': 1},
              ],
            }),
          );
          await tester.pumpComponent(
            Container(
              width: 60,
              height: 10,
              child: CruxTheme(
                data: CruxThemeData.draculaFallback,
                child: PluginSidebarBox(
                  plugin: notesSpec(),
                  host: PluginHost(
                    projectPath: project.path,
                    onScreenAction: (_) {},
                    onTodoToggle: (text, line, done) {
                      toggledText = text;
                      toggledLine = line;
                      toggledDone = done;
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          final row = tester.terminalState.findText('write tests').first;
          await tester.hover(row.x + 2, row.y);
          await tester.pump();
          await tester.tap(row.x + 2, row.y);
          await tester.pump();

          expect(toggledText, 'write tests');
          expect(toggledLine, 1);
          expect(toggledDone, isTrue);
          // The row now renders checked (☑), not open (☐).
          expect(
            tester.terminalState.containsText('☑ write tests'),
            isTrue,
            reason: 'checked row stays visible after click',
          );
        });
      },
    );

    test(
      'clicking a checked todo inside the window undoes it (done=false)',
      () async {
        final toggles = <bool>[];
        await testNocterm('spec widget todo undo', (tester) async {
          writeStatus(controlPort: 1);
          statusFile().writeAsStringSync(
            jsonEncode({
              'display': '1 todo',
              'todos': [
                {'text': 'fix bug', 'line': 0},
              ],
            }),
          );
          await tester.pumpComponent(
            Container(
              width: 60,
              height: 10,
              child: CruxTheme(
                data: CruxThemeData.draculaFallback,
                child: PluginSidebarBox(
                  plugin: notesSpec(),
                  host: PluginHost(
                    projectPath: project.path,
                    onScreenAction: (_) {},
                    onTodoToggle: (_, _, done) => toggles.add(done),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          // Check it: row flips to ☑.
          var row = tester.terminalState.findText('fix bug').first;
          await tester.hover(row.x + 2, row.y);
          await tester.pump();
          await tester.tap(row.x + 2, row.y);
          await tester.pump();
          expect(tester.terminalState.containsText('☑ fix bug'), isTrue);

          // Click again inside the window → undo.
          row = tester.terminalState.findText('fix bug').first;
          await tester.tap(row.x + 2, row.y);
          await tester.pump();

          expect(toggles, [true, false]);
          expect(tester.terminalState.containsText('☐ fix bug'), isTrue);
        });
      },
    );

    test('a checked todo disappears after the undo TTL', () async {
      // Short refresh so the widget re-reads the projection the host
      // rewrites on click (the real app polls every 2s; the default
      // notesSpec polls hourly).
      final ttlSpec = Plugin(
        id: 'my-notes',
        title: 'my notes',
        labelTemplate: '{display}',
        refresh: const Duration(milliseconds: 40),
        statusPath: '.dart_tool/crux_dev.json',
        actions: const [
          PluginAction(
            label: 'open',
            kind: PluginActionKind.screen,
            screen: 'notes',
          ),
        ],
      );
      await testNocterm('spec widget todo ttl', (tester) async {
        writeStatus(controlPort: 1);
        statusFile().writeAsStringSync(
          jsonEncode({
            'display': '1 todo',
            'todos': [
              {'text': 'fix bug', 'line': 0},
            ],
          }),
        );
        await tester.pumpComponent(
          Container(
            width: 60,
            height: 10,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: ttlSpec,
                host: PluginHost(
                  projectPath: project.path,
                  onScreenAction: (_) {},
                  onTodoToggle: (_, _, done) {
                    // Mirror the real host: marking done rewrites the
                    // projection so the open `todos` list drops the row.
                    if (done) {
                      statusFile().writeAsStringSync(
                        jsonEncode({
                          'display': 'no todos',
                          'todos': <Map<String, dynamic>>[],
                        }),
                      );
                    }
                  },
                ),
                todoCheckedTtl: const Duration(milliseconds: 100),
              ),
            ),
          ),
        );
        await tester.pump();

        final row = tester.terminalState.findText('fix bug').first;
        await tester.hover(row.x + 2, row.y);
        await tester.pump();
        await tester.tap(row.x + 2, row.y);
        await tester.pump();
        expect(tester.terminalState.containsText('☑ fix bug'), isTrue);

        // After the TTL the checked row expires.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
        expect(
          tester.terminalState.containsText('fix bug'),
          isFalse,
          reason: 'checked row expires after the undo TTL',
        );
      });
    });

    test('record=false actions do not fire onAction', () async {
      final notes = <String>[];
      final quietSpec = Plugin(
        id: 'my-notes',
        title: 'my notes',
        labelTemplate: '{display}',
        refresh: const Duration(hours: 1),
        statusPath: '.dart_tool/crux_dev.json',
        actions: const [
          PluginAction(
            label: 'open',
            kind: PluginActionKind.screen,
            screen: 'notes',
            record: false,
          ),
        ],
      );
      await testNocterm('spec widget screen quiet', (tester) async {
        writeStatus(controlPort: 1);
        statusFile().writeAsStringSync(jsonEncode({'display': '1 todo'}));
        await tester.pumpComponent(
          Container(
            width: 60,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: quietSpec,
                host: PluginHost(
                  projectPath: project.path,
                  onScreenAction: (_) {},
                  onAction: (note) async => notes.add(note),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        final seg = tester.terminalState.findText('open').first;
        await tester.hover(seg.x + 2, seg.y);
        await tester.pump();
        await tester.tap(seg.x + 2, seg.y);
        await tester.pump();

        // No event recorded for a record=false action.
        expect(notes, isEmpty);
      });
    });
  });

  group('PluginSidebarBox — scrolling todo list', () {
    Plugin notesSpec() => Plugin(
      id: 'my-notes',
      title: 'my notes',
      labelTemplate: '{display}',
      refresh: const Duration(hours: 1),
      statusPath: '.dart_tool/crux_dev.json',
      actions: const [
        PluginAction(
          label: 'open',
          kind: PluginActionKind.screen,
          screen: 'notes',
        ),
      ],
    );

    test('long todo list caps its height and scrolls (no "+N more")', () async {
      await testNocterm('spec widget notes scroll', (tester) async {
        writeStatus(controlPort: 1);
        statusFile().writeAsStringSync(
          jsonEncode({
            'display': '12 todos',
            'todos': [
              for (var i = 1; i <= 12; i++)
                {'text': 'todo $i of 12', 'line': i},
            ],
          }),
        );
        await tester.pumpComponent(
          Container(
            width: 60,
            height: 40,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: notesSpec(),
                host: PluginHost(projectPath: project.path),
              ),
            ),
          ),
        );
        await tester.pump();

        // Early items visible, later items clipped (past the row cap).
        expect(tester.terminalState.containsText('☐ todo 1 of 12'), isTrue);
        expect(tester.terminalState.containsText('☐ todo 10 of 12'), isTrue);
        expect(tester.terminalState.containsText('todo 11 of 12'), isFalse);
        // No overflow-collapse line — the list scrolls instead.
        expect(tester.terminalState.containsText('more'), isFalse);

        // Wheel down inside the list → hidden rows scroll into view.
        final row = tester.terminalState.findText('todo 1 of 12').first;
        await tester.sendMouseEvent(
          MouseEvent(
            button: MouseButton.wheelDown,
            x: row.x + 2,
            y: row.y,
            pressed: false,
          ),
        );
        await tester.pump();
        expect(tester.terminalState.containsText('☐ todo 12 of 12'), isTrue);
        expect(tester.terminalState.containsText('☐ todo 1 of 12'), isFalse);
      });
    });

    test('short todo list keeps natural height (no scrollbar)', () async {
      await testNocterm('spec widget notes short', (tester) async {
        writeStatus(controlPort: 1);
        statusFile().writeAsStringSync(
          jsonEncode({
            'display': '2 todos',
            'todos': [
              {'text': 'solo', 'line': 0},
              {'text': 'duo', 'line': 1},
            ],
          }),
        );
        await tester.pumpComponent(
          Container(
            width: 60,
            height: 20,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: PluginSidebarBox(
                plugin: notesSpec(),
                host: PluginHost(projectPath: project.path),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.terminalState.containsText('☐ solo'), isTrue);
        expect(tester.terminalState.containsText('☐ duo'), isTrue);
        // No scrollbar chrome on a short list.
        expect(tester.terminalState.containsText('▲'), isFalse);
        expect(tester.terminalState.containsText('▼'), isFalse);
      });
    });
  });
}
