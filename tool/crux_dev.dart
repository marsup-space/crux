// Hot-reload dev harness for Crux UI work.
//
// Runs a Crux component fullscreen in a real terminal, with nocterm's
// file-watching hot reload active, so an agent (or you) can edit
// lib/src/components/... and see the result in place without a
// quit/relaunch cycle.
//
// Usage (in a spare terminal next to the agent's):
//
//   dart --enable-vm-service tool/crux_dev.dart home [--size WxH] [--stubs]
//
// Targets:
//   home    The home screen, live: real git service (pushed refresh),
//           Directory.current as the workspace, the five built-in boxes.
//           esc exits the harness (there is no chat behind it).
//
// Flags:
//   --size WxH   Start with a fake terminal size (e.g. --size 100x30)
//                to test grid reflow; removed on the first real resize.
//   --stubs      Fill the grid with StubHomeWidgets instead of the
//                built-ins, for pure layout work.
//
// Hot reload notes:
// - `--enable-vm-service` is required; without it nocterm's
//   HotReloadBinding logs a refusal to .dart_tool/nocterm_hot_reload.log
//   and just runs statically.
// - nocterm watches bin/, lib/, test/ and example/ relative to the CWD,
//   so launch from the repo root (package_config.json must be there —
//   that's also why this lives in tool/: `dart run` resolves the
//   project root from the entrypoint's location).
// - nocterm performs a full reassemble after each reload: State objects
//   are preserved but build() runs again from the root, so one-shot
//   service kick-offs belong in initState (as usual), not build.
// - tool/ itself is NOT watched; editing this file means restarting.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:nocterm/nocterm.dart';

import 'package:crux/src/components/chat_panel.dart' show loadChatPanelBootState;
import 'package:crux/src/components/home/home_screen.dart';
import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/services/skills/skill.dart';
import 'package:crux/src/components/home/widgets/stub_widget.dart';
import 'package:crux/src/services/auxiliary_service.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  var target = 'home';
  Size? fakeSize;
  var stubs = false;
  var live = false;

  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--stubs') {
      stubs = true;
    } else if (arg == '--live') {
      live = true;
    } else if (arg == '--size' && i + 1 < args.length) {
      fakeSize = _parseSize(args[++i]);
      if (fakeSize == null) {
        stderr.writeln('Invalid --size "${args[i]}" (want WxH, e.g. 100x30)');
        exit(64);
      }
    } else if (arg.startsWith('-')) {
      stderr.writeln('Unknown flag: $arg');
      exit(64);
    } else {
      rest.add(arg);
    }
  }
  if (rest.isNotEmpty) target = rest.first;

  if (target != 'home') {
    stderr.writeln('Unknown target "$target" — only "home" exists for now.');
    exit(64);
  }

  final git = GitStatusService();
  // Push liveness: refresh now and keep polling, so the git box and the
  // hero branch line update while you iterate (matching how the real
  // app's boxes behave). Widgets that listen via addListener rebuild
  // without a hot reload too.
  git.start();

  final base = HomeContext.minimal(
    close: () => shutdownApp(),
  );

  HomeContext context;
  if (live) {
    // Live mode: real sessions + a real auxiliary summarizer, so the
    // Yesterday box exercises its LLM path instead of the static
    // fallback. Loads the same boot state the real panel uses (sessions
    // for this workspace), then wires an AuxiliaryService over the real
    // provider config / message store. Needs an auxiliary model
    // configured (`/auxiliary` in the real app); without one the box
    // falls back to the session list exactly as it does in production.
    // Mirror bin/crux.dart: user providers in ~/.config/crux/providers,
    // built-ins in the repo's providers/ dir. The built-in dir is where
    // the real providers (zhipu, deepseek, kimi, …) live — without it the
    // auxiliary model can't resolve and the Yesterday box always falls
    // back. API keys + auxiliaryModel come from the user-data auth.toml.
    final userProvidersDir = p.join(_home(), '.config', 'crux', 'providers');
    final builtInDir = p.join(Directory.current.path, 'providers');
    final boot = await loadChatPanelBootState(
      userProvidersDir: userProvidersDir,
      builtInProvidersDir: Directory(builtInDir).existsSync() ? builtInDir : null,
    );
    final aux = AuxiliaryService(boot.providerService, boot.store.messageStore);
    final sessions = [...boot.sessions, ...boot.chats]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    context = base.copyWithDev(
      gitStatusService: git,
      projectPath: Directory.current.path,
      sessions: () => sessions,
      currentSessionId: () => boot.currentSessionId,
      activeModel: () {
        final id = boot.currentSessionId;
        for (final s in sessions) {
          if (s.id == id) return s.model.isEmpty ? null : s.model;
        }
        return null;
      },
      summarizeYesterday: aux.summarizeYesterday,
      // Activity box: token-per-day heatmap over this workspace,
      // scoped to the same project path the real panel uses.
      dailyTokenTotals: ({required sinceDays}) =>
          boot.store.messageStore.dailyTokenTotals(
        sinceDaysAgo: sinceDays,
        projectPath: Directory.current.path,
      ),
    );
  } else {
    context = base.copyWithDev(
      gitStatusService: git,
      projectPath: Directory.current.path,
    );
  }

  // Control server must be reachable from HomeScreen's exit callbacks
  // (esc, Ctrl+C) — `late final` so the callbacks can close over it
  // even though it's constructed after the component tree.
  late final _DevControlServer control;

  final root = _DevApp(
    fakeSize: fakeSize,
    child: CruxTheme(
      data: CruxThemeData.draculaFallback,
      child: HomeScreen(
        onExit: () {
          control.deleteStateFileSync();
          shutdownApp();
        },
        // Ctrl+C on home: same exit path as esc — delete the state
        // file FIRST. shutdownApp → StdioBackend.requestExit → bare
        // exit(0) kills the process before `main`'s post-runApp
        // cleanup can run, so the file must go before the exit.
        quitApp: () {
          control.deleteStateFileSync();
          shutdownApp();
        },
        context_: context,
        widgets: stubs ? _stubWidgets() : null,
      ),
    ),
  );

  control = _DevControlServer(
    root: root,
    stateFile: File('.dart_tool/crux_dev.json'),
    logFile: File('.dart_tool/nocterm_hot_reload.log'),
  );
  await control.start();
  stdout.writeln(
    'crux dev control: http://127.0.0.1:${control.port} '
    '(state: .dart_tool/crux_dev.json)',
  );

  await runApp(root);

  // runApp returned = the app is shutting down (esc → shutdownApp, or
  // a control-channel close). Drop the state file so the sidebar
  // switches to "not running", then exit explicitly — lingering
  // timers (git polling, heartbeat) would otherwise keep the process
  // alive forever.
  await control.close();
  git.dispose();
  exit(0);
}

/// The built-ins as the real home screen would create them, but with
/// stubs — see [HomeScreen]'s `_defaultWidgets`.
List<HomeWidget> _stubWidgets() => [
  StubHomeWidget('alpha'),
  StubHomeWidget('beta'),
  StubHomeWidget('gamma', supportedSpans: const {1}),
  StubHomeWidget('delta', supportedSpans: const {1}),
  StubHomeWidget('epsilon'),
];

Size? _parseSize(String s) {
  final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(s);
  if (m == null) return null;
  return Size(
    double.parse(m.group(1)!),
    double.parse(m.group(2)!),
  );
}

/// The user's home directory (for locating `~/.config/crux/providers`).
String _home() =>
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';

extension on HomeContext {
  /// HomeContext has no copyWith; the harness overrides the live fields
  /// on top of [HomeContext.minimal]. Null args keep the base value.
  HomeContext copyWithDev({
    GitStatusService? gitStatusService,
    String? projectPath,
    List<Session> Function()? sessions,
    int? Function()? currentSessionId,
    String? Function()? activeModel,
    Future<String?> Function(List<Session>)? summarizeYesterday,
    void Function(SkillInfo)? showSkill,
    Future<Map<String, int>> Function({required int sinceDays})?
        dailyTokenTotals,
  }) {
    return HomeContext(
      runCommand: runCommand,
      close: close,
      seedInput: seedInput,
      gitStatusService: gitStatusService ?? this.gitStatusService,
      sessions: sessions ?? this.sessions,
      currentSessionId: currentSessionId ?? this.currentSessionId,
      switchSession: switchSession,
      projectPath: projectPath ?? this.projectPath,
      activeModel: activeModel ?? this.activeModel,
      summarizeYesterday: summarizeYesterday ?? this.summarizeYesterday,
      showSkill: showSkill ?? this.showSkill,
      dailyTokenTotals: dailyTokenTotals ?? this.dailyTokenTotals,
    );
  }
}

/// Root component: theme is provided by the caller's [child]; this just
/// applies the optional fake-size wrapper.
class _DevApp extends StatelessComponent {
  final Size? fakeSize;
  final Component child;

  const _DevApp({this.fakeSize, required this.child});

  @override
  Component build(BuildContext context) {
    var content = child;
    final size = fakeSize;
    if (size != null) {
      // Fixed-size window into the app: lets a wide real terminal
      // pretend to be narrow so grid reflow is testable. Overflow is
      // clipped by the container bounds.
      content = Container(
        width: size.width,
        height: size.height,
        child: content,
      );
    }
    return NoctermApp(title: 'Crux Dev — home', child: content);
  }
}

/// Heartbeat state file + loopback HTTP control channel for the dev
/// harness.
///
/// Writes `.dart_tool/crux_dev.json` every 5 s (atomically, via tmp +
/// rename) so any reader — most notably the running Crux session's
/// sidebar widget — can tell this harness is alive by heartbeat
/// freshness alone, without touching process tables.
///
///   {
///     "pid": 71225,
///     "startedAt": "...", "heartbeatAt": "...",
///     "controlPort": 54321,
///     "lastReload": {"at": "...", "result": "succeeded", "path": "..."}
///   }
///
/// HTTP endpoints (loopback only, random port):
///   GET  /status   → same JSON as the state file, fresh
///   POST /reload   → VM-service reloadSources (all libraries) + reassemble
///   POST /remount  → re-attach the root component (initState re-runs)
///   POST /close    → clean shutdown (shutdownApp)
///
/// The reload log is polled so auto-reloads (nocterm's file watcher)
/// also land in `lastReload` — the state file stays the single source
/// of truth for the reader.
class _DevControlServer {
  final Component root;
  final File stateFile;
  final File logFile;

  HttpServer? _server;
  Timer? _heartbeat;
  Timer? _logPoll;
  final DateTime _startedAt = DateTime.now();
  int _lastLogLength = 0;
  String? _lastChangePath;
  Map<String, dynamic>? _lastReload;

  int get port => _server?.port ?? 0;

  _DevControlServer({
    required this.root,
    required this.stateFile,
    required this.logFile,
  });

  Future<void> start() async {
    try {
      _lastLogLength = logFile.lengthSync();
    } catch (_) {
      _lastLogLength = 0;
    }
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
    _heartbeat = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _writeState(),
    );
    _logPoll = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollReloadLog(),
    );
    _writeState();
  }

  Future<void> close() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    _logPoll?.cancel();
    _logPoll = null;
    try {
      if (stateFile.existsSync()) stateFile.deleteSync();
    } catch (_) {}
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  // ── State file ──────────────────────────────────────────────────

  /// Delete the heartbeat state file synchronously. Must run on EVERY
  /// exit path before `shutdownApp`: its `StdioBackend.requestExit`
  /// is a bare `exit(0)` that kills the process before `main`'s
  /// post-runApp cleanup can run. Without this, a stale file lingers
  /// and the sidebar widget waits out the heartbeat timeout before
  /// flipping to "not running".
  void deleteStateFileSync() {
    try {
      if (stateFile.existsSync()) stateFile.deleteSync();
    } catch (_) {}
  }

  Map<String, dynamic> _stateJson() => {
        'pid': pid,
        'startedAt': _startedAt.toUtc().toIso8601String(),
        'heartbeatAt': DateTime.now().toUtc().toIso8601String(),
        'controlPort': port,
        'lastReload': _lastReload,
      };

  void _writeState() {
    try {
      final tmp = File('${stateFile.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(_stateJson()));
      tmp.renameSync(stateFile.path);
    } catch (e) {
      // Best-effort: a read-only .dart_tool must not kill the harness.
      stderr.writeln('crux dev: state write failed: $e');
    }
  }

  // ── Reload log polling (auto-reloads) ───────────────────────────

  void _pollReloadLog() {
    int length;
    try {
      length = logFile.lengthSync();
    } catch (_) {
      return;
    }
    if (length <= _lastLogLength) return;
    String tail;
    try {
      final raf = logFile.openSync();
      try {
        raf.setPositionSync(_lastLogLength);
        tail = utf8.decode(raf.readSync(length - _lastLogLength));
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return;
    }
    _lastLogLength = length;
    for (final line in tail.split('\n')) {
      final change = RegExp(r'Change detected: (.+)$').firstMatch(line);
      if (change != null) {
        _lastChangePath = change.group(1);
        continue;
      }
      String? result;
      if (line.contains('Hot reload succeeded')) {
        result = 'succeeded';
      } else if (line.contains('Hot reload partially succeeded')) {
        result = 'partial';
      } else if (line.contains('Hot reload FAILED')) {
        result = 'failed';
      }
      if (result != null) {
        _lastReload = {
          'at': DateTime.now().toUtc().toIso8601String(),
          'result': result,
          'path': _lastChangePath,
        };
        _writeState();
      }
    }
  }

  // ── HTTP handlers ───────────────────────────────────────────────

  Future<void> _handleRequest(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/status') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(_stateJson()));
      } else if (req.method == 'POST' && path == '/reload') {
        final ok = await _vmReload();
        _lastReload = {
          'at': DateTime.now().toUtc().toIso8601String(),
          'result': ok ? 'succeeded' : 'failed',
          'path': _lastChangePath ?? 'manual',
        };
        _writeState();
        res.write(ok ? 'ok' : 'failed');
      } else if (req.method == 'POST' && path == '/remount') {
        TerminalBinding.instance.attachRootComponent(root);
        TerminalBinding.instance.scheduleFrame();
        res.write('ok');
      } else if (req.method == 'POST' && path == '/close') {
        // Delete the state file HERE, not (only) in [close]: the
        // shutdown path below calls StdioBackend.requestExit → bare
        // exit(0), which kills the process before `main`'s post-runApp
        // cleanup can run. The 50 ms delay before shutdownApp leaves
        // no room for a heartbeat rewrite (next tick is 5 s away).
        deleteStateFileSync();
        res.write('ok');
        // Let the response flush before the event loop unwinds.
        unawaited(
          Future<void>.delayed(
            const Duration(milliseconds: 50),
            () => shutdownApp(0),
          ),
        );
      } else {
        res.statusCode = 404;
        res.write('not found');
      }
    } catch (e) {
      res.statusCode = 500;
      res.write('$e');
    } finally {
      await res.close();
    }
  }

  // ── VM-service reload (the "r" in the sidebar) ───────────────────

  /// Full reloadSources across every loaded library, then a manual
  /// reassemble + frame. This is the same mechanism nocterm's own
  /// file watcher uses; doing it on demand covers edits the watcher
  /// can't see (tool/, providers/, …) and gives the user a manual
  /// trigger after a failed auto-reload is fixed.
  Future<bool> _vmReload() async {
    try {
      final info = await developer.Service.getInfo();
      final wsUrl = info.serverWebSocketUri;
      if (wsUrl == null) return false;
      final ws = await WebSocket.connect(wsUrl.toString())
          .timeout(const Duration(seconds: 5));
      var id = 0;
      final pending = <String, Completer<Map<String, dynamic>>>{};
      ws.listen((raw) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        pending.remove(msg['id'])?.complete(msg);
      });
      Future<Map<String, dynamic>> call(
        String method, [
        Map<String, dynamic>? params,
      ]) {
        final myId = '${++id}';
        final c = Completer<Map<String, dynamic>>();
        pending[myId] = c;
        ws.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': myId,
          'method': method,
          'params': params ?? {},
        }));
        return c.future.timeout(const Duration(seconds: 10));
      }

      final vm = await call('getVM');
      final isolateId =
          (vm['result']?['isolates'] as List?)?[0]?['id'] as String?;
      if (isolateId == null) return false;
      final iso = await call('getIsolate', {'isolateId': isolateId});
      final libs = (iso['result']?['libraries'] as List? ?? const [])
          .map((l) => (l as Map)['id'])
          .whereType<String>()
          .toList();
      final res = await call('reloadSources', {
        'isolateId': isolateId,
        'libraries': libs,
        'pause': false,
      });
      await ws.close();
      if (res['error'] != null) return false;
      // Code is swapped; rebuild the tree + paint a frame. (Nocterm's
      // own reload path does the same via its onAfterReload hook.)
      TerminalBinding.instance.reassemble();
      TerminalBinding.instance.scheduleFrame();
      return true;
    } catch (_) {
      return false;
    }
  }
}
