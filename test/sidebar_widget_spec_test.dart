// Tests for the generic spec-driven sidebar widget renderer (Phase B).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/spec_sidebar_widget.dart';
import 'package:crux/src/services/spec_widget.dart';
import 'package:crux/src/theme/crux_theme.dart';

/// A spec whose status file lives in [project] and whose actions point
/// at a port read from the status JSON (mirrors dev-harness.toml).
SpecWidget _spec({Duration refresh = const Duration(hours: 1)}) => SpecWidget(
      id: 'dev-harness',
      labelTemplate: '⟳ crux dev · {state}',
      refresh: refresh,
      statusPath: '.dart_tool/crux_dev.json',
      heartbeatField: 'heartbeatAt',
      staleAfter: const Duration(seconds: 15),
      stateRules: const [
        SpecStateRule(
          field: 'lastReload.result',
          equals: 'succeeded',
          text: '✓ {lastReload.at@HH:MM}',
        ),
        SpecStateRule(
          field: 'lastReload.result',
          equals: 'failed',
          text: '✗ reload failed',
          color: SpecStateColor.error,
        ),
      ],
      actions: const [
        // Launch actions: shown only while the service is dead.
        SpecAction(
          label: 'start',
          kind: SpecActionKind.launch,
          command: 'dart tool/crux_dev.dart home',
        ),
        // http actions: shown only while the service is alive.
        SpecAction(label: 'reload', url: 'http://127.0.0.1:{controlPort}/reload'),
        SpecAction(label: 'close', url: 'http://127.0.0.1:{controlPort}/close'),
      ],
    );

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('spec_widget_render_');
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
    statusFile().writeAsStringSync(jsonEncode({
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

  Future<void> pump(dynamic tester, {SpecWidget? spec}) async {
    await tester.pumpComponent(
      Container(
        width: 80,
        height: 8,
        child: CruxTheme(
          data: CruxThemeData.draculaFallback,
          child: SpecSidebarWidget(
            spec: spec ?? _spec(),
            projectPath: project.path,
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

  group('SpecSidebarWidget — label states', () {
    test('renders the spec title inline on the box border', () async {
      await testNocterm('spec widget title', (tester) async {
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
        expect(
          tester.terminalState.containsText('✗ reload failed'),
          isTrue,
        );
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

  group('SpecSidebarWidget — action segments', () {
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

    test('absent harness renders a start segment, no control segments',
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
    });

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

    test('clicking reload POSTs to the control port from the status JSON',
        () async {
      final hits = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((req) async {
        hits.add('${req.method} ${req.uri.path}');
        req.response.statusCode = 200;
        await req.response.close();
      });

      await testNocterm('spec widget action', (tester) async {
        writeStatus(
          heartbeat: DateTime.now(),
          controlPort: server.port,
        );
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
    });

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
              child: SpecSidebarWidget(
                spec: _spec(),
                projectPath: project.path,
                onAction: (note) async => notes.add(note),
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

      await testNocterm('spec widget action note fail', (tester) async {
        writeStatus(heartbeat: DateTime.now(), controlPort: port);
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: SpecSidebarWidget(
                spec: _spec(),
                projectPath: project.path,
                onAction: (note) async => notes.add(note),
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

  group('SpecSidebarWidget — quick (prompt) actions', () {
    SpecWidget promptSpec() => SpecWidget(
          id: 'dev-harness',
          labelTemplate: '⟳ crux dev · {state}',
          refresh: const Duration(hours: 1),
          statusPath: '.dart_tool/crux_dev.json',
          heartbeatField: 'heartbeatAt',
          actions: const [
            SpecAction(
              label: 'review',
              kind: SpecActionKind.prompt,
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
              child: SpecSidebarWidget(
                spec: promptSpec(),
                projectPath: project.path,
                onPromptAction: (action, rendered) => submitted = rendered,
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
              child: SpecSidebarWidget(
                spec: promptSpec(),
                projectPath: project.path,
                onPromptAction: (_, __) {},
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
              child: SpecSidebarWidget(
                spec: promptSpec(),
                projectPath: project.path,
                // No onPromptAction — e.g. a context with no chat.
              ),
            ),
          ),
        );

        await hoverLabel(tester);
        expect(tester.terminalState.containsText('review'), isFalse);
      });
    });
  });

  group('SpecSidebarWidget — multi-line labels', () {
    test('a multi-line label renders each line as its own row', () async {
      await testNocterm('spec widget multiline', (tester) async {
        final monitor = SpecWidget(
          id: 'gold',
          title: 'gold',
          labelTemplate: 'XAU {price}/oz\n{arrow} {delta} today',
          refresh: const Duration(hours: 1),
          statusPath: '.dart_tool/crux_dev.json',
          // No heartbeatField → file presence = alive.
        );
        writeStatus(controlPort: 1); // file exists → alive
        // Overwrite with gold-shaped data.
        statusFile().writeAsStringSync(jsonEncode({
          'price': 2411.5,
          'delta': '+0.8%',
          'arrow': '▲',
        }));

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 10,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: SpecSidebarWidget(
                spec: monitor,
                projectPath: project.path,
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
}
