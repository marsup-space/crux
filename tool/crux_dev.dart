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
//   dart --enable-vm-service tool/crux_dev.dart setup
//
// Targets:
//   home    The home screen, live: real git service (pushed refresh),
//           Directory.current as the workspace, the five built-in boxes.
//           esc exits the harness (there is no chat behind it).
//   setup   The setup checklist box in all four states (all pending,
//           partially done, all set) side by side, driven by fixed
//           items via the widget's itemsOverride — so it renders the
//           same no matter how the real app is configured.
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
import 'package:crux/src/components/home/widgets/setup_widget.dart';
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

  if (target != 'home' && target != 'setup') {
    stderr.writeln(
      'Unknown target "$target" — known targets: home, setup.',
    );
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

  // Control server must be reachable from HomeScreen's exit callbacks
  // (esc, Ctrl+C) — `late final` so the callbacks can close over it
  // even though it's constructed after the component tree.
  late final _DevControlServer control;

  void exitHarness() {
    control.deleteStateFileSync();
    shutdownApp();
  }

  // The screen this target renders. `setup` gets its own debug screen
  // (all box states side by side); everything else is the home grid.
  final Component screen = target == 'setup'
      ? _SetupDebugScreen(onExit: exitHarness, quitApp: exitHarness)
      : HomeScreen(
          onExit: exitHarness,
          // Ctrl+C on home: same exit path as esc — delete the state
          // file FIRST. shutdownApp → StdioBackend.requestExit → bare
          // exit(0) kills the process before `main`'s post-runApp
          // cleanup can run, so the file must go before the exit.
          quitApp: exitHarness,
          context_: await _homeContext(base, git, live: live),
          widgets: stubs ? _stubWidgets() : null,
        );

  final root = _DevApp(
    fakeSize: fakeSize,
    child: CruxTheme(
      data: CruxThemeData.draculaFallback,
      child: screen,
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

/// The [HomeContext] for the `home` target: [base] (the minimal stub)
/// with the live git service and workspace path, plus — in `--live`
/// mode — real sessions, a real auxiliary summarizer, and the token
/// heatmap store.
Future<HomeContext> _homeContext(
  HomeContext base,
  GitStatusService git, {
  required bool live,
}) async {
  if (!live) {
    return base.copyWithDev(
      gitStatusService: git,
      projectPath: Directory.current.path,
    );
  }
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
  return base.copyWithDev(
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
}

/// The `setup` target's screen: the setup checklist box rendered in
/// every state it can take, side by side, each driven by fixed items
/// through [SetupHomeWidget.itemsOverride]. Because the items are
/// fixed, the screen looks the same no matter how the real app is
/// configured — that's the point: you can see the pending/partial/done
/// rendering without unsetting your own config.
///
/// esc / Ctrl+C exit the harness (same path as home).
///
/// Interactive: click a box to focus it (its selection highlight turns
/// on; the others dim), ↑↓ moves the selection inside the focused box,
/// and Enter/click on a pending row "activates" it — the debug screen
/// intercepts the seed/close and reports the would-be command in the
/// status line instead of exiting, so activation is testable without
/// leaving the screen.
class _SetupDebugScreen extends StatefulComponent {
  final VoidCallback onExit;
  final VoidCallback quitApp;

  const _SetupDebugScreen({required this.onExit, required this.quitApp});

  @override
  State<_SetupDebugScreen> createState() => _SetupDebugScreenState();
}

class _SetupDebugScreenState extends State<_SetupDebugScreen> {
  static const _pending = [
    SetupItem(label: 'provider key', done: false, seedText: '/provider '),
    SetupItem(label: 'aux model', done: false, seedText: '/auxiliary '),
    SetupItem(label: 'web provider', done: false, seedText: '/web-provider '),
    SetupItem(label: 'workspace', done: false, detail: 'open crux in a project directory'),
  ];

  static const _partial = [
    SetupItem(label: 'provider key', done: true, detail: 'connected'),
    SetupItem(label: 'aux model', done: true, detail: 'glm-4.5-air'),
    SetupItem(label: 'web provider', done: false, seedText: '/web-provider '),
    SetupItem(label: 'workspace', done: true, detail: 'crux'),
  ];

  /// The live widgets behind the two *rendered* fixed variants, so ↑↓
  /// can drive their selection. The all-done variant isn't in this list:
  /// it demonstrates the hidden state (visibleWhen → false), so there's
  /// no box to focus. (The live-context variant is likewise display-only.)
  late final List<SetupHomeWidget> _widgets = [
    SetupHomeWidget(itemsOverride: (_) => _pending),
    SetupHomeWidget(itemsOverride: (_) => _partial),
  ];

  /// Which rendered variant currently holds the highlight (0-1), or -1
  /// for none.
  int _focusedBox = -1;

  /// The last activation report (`would seed "/provider "`), or the idle
  /// help line when nothing has been activated yet.
  String _status =
      'click a box to focus it · ↑↓ select · enter/click a pending row to activate · esc quit';

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    return Focusable(
      focused: true,
      onKeyEvent: _handleKey,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section('setup — all pending (fresh install)'),
            _box(0),
            _section('setup — partially done (2 of 4 set)'),
            _box(1),
            _section('setup — all set (box hides itself — nothing renders below)'),
            _allSetNote(theme),
            _section('setup — live context (driven by this terminal\'s config)'),
            _liveBox(),
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(_status, style: TextStyle(color: theme.onSurfaceDim)),
            ),
          ],
        ),
      ),
    );
  }

  bool _handleKey(KeyboardEvent event) {
    switch (event.logicalKey) {
      case LogicalKey.escape:
        component.onExit();
        return true;
      case LogicalKey.arrowUp:
        _move(-1);
        return true;
      case LogicalKey.arrowDown:
        _move(1);
        return true;
      case LogicalKey.enter:
        _activate();
        return true;
      default:
        return false;
    }
  }

  /// ↑↓ inside the focused box. With no focus, focuses the first box.
  /// The all-set variant has no selectable rows (every row is done), so
  /// selection moves stay within boxes that have pending items — but we
  /// let the widget wrap anyway; the highlight just sits on an inert row.
  void _move(int delta) {
    setState(() {
      if (_focusedBox < 0) {
        _focusedBox = 0;
        return;
      }
      _widgets[_focusedBox].moveSelection(delta);
    });
  }

  /// Enter on the focused box's selected row. The report (instead of the
  /// real seed+close) is produced by the per-box context's seedInput —
  /// see [_ctxFor].
  void _activate() {
    if (_focusedBox < 0) return;
    final widget = _widgets[_focusedBox];
    final action = widget.activateItem(_ctxFor(_focusedBox), widget.selectedIndex);
    if (action == null) {
      setState(() => _status = 'row ${widget.selectedIndex + 1}: nothing to do (done or no command)');
      return;
    }
    action(); // → the intercepted seedInput updates _status
  }

  Component _section(String label) => Padding(
        padding: const EdgeInsets.only(top: 1, bottom: 0),
        child: Text(label),
      );

  /// The all-set state renders nothing on home (visibleWhen hides the
  /// box), so the debug screen shows this note in place of the box —
  /// the point of the section is to demonstrate that absence.
  Component _allSetNote(CruxThemeData theme) => Container(
        width: 40,
        decoration: BoxDecoration(border: BoxBorder.all()),
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Text(
          '(hidden — visibleWhen is false,\nso home skips this cell entirely)',
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );

  /// The context for one fixed variant: identical to the minimal one
  /// (the override feeds the items), except seedInput/close are
  /// intercepted so activation is safe — it reports the would-be
  /// command in the status line instead of seeding a dead input and
  /// shutting the harness down.
  HomeContext _ctxFor(int box) => HomeContext.minimal(
        close: () {},
      )._withSeed((text) {
        setState(() {
          _status = 'box ${box + 1} row ${_widgets[box].selectedIndex + 1}: '
              'would seed "$text" and close home';
        });
      });

  /// Renders one fixed variant with its border chrome. Focused (click or
  /// first ↑↓) = the selection highlight shows; unfocused boxes render
  /// without it, matching home's one-highlight-at-a-time rule.
  Component _box(int index) {
    final focused = _focusedBox == index;
    final widget = _widgets[index];
    final ctx = _ctxFor(index);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // Focus follows the click; the row's own tap (if it hit a row)
        // already activated via the widget's GestureDetector — here we
        // just make sure the highlight lands on this box.
        setState(() => _focusedBox = index);
      },
      child: Container(
        width: 40,
        decoration: BoxDecoration(border: BoxBorder.all()),
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Builder(
          builder: (context) => widget.build(context, ctx, 1, focused: focused),
        ),
      ),
    );
  }

  /// The live-context variant: display-only (no override → the harness's
  /// minimal context reports everything pending). Passive — clicking it
  /// does nothing, and it never takes the keyboard highlight.
  Component _liveBox() {
    final ctx = HomeContext.minimal(close: () {});
    return Container(
      width: 40,
      decoration: BoxDecoration(border: BoxBorder.all()),
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Builder(
        builder: (context) =>
            SetupHomeWidget().build(context, ctx, 1, focused: false),
      ),
    );
  }
}

extension on HomeContext {
  /// A copy of this context whose [seedInput] is [onSeed]; everything
  /// else (including `close`, kept as-is) is unchanged. Used by the
  /// debug screen to intercept activations.
  HomeContext _withSeed(void Function(String) onSeed) => HomeContext(
        runCommand: runCommand,
        close: close,
        seedInput: onSeed,
        gitStatusService: gitStatusService,
        sessions: sessions,
        currentSessionId: currentSessionId,
        switchSession: switchSession,
        projectPath: projectPath,
        activeModel: activeModel,
        summarizeYesterday: summarizeYesterday,
        showSkill: showSkill,
        dailyTokenTotals: dailyTokenTotals,
        hasProviderKey: hasProviderKey,
        auxModelName: auxModelName,
        hasWebProvider: hasWebProvider,
      );
}

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
    Future<YesterdaySummary?> Function(List<Session>)? summarizeYesterday,
    void Function(SkillInfo)? showSkill,
    Future<Map<String, int>> Function({required int sinceDays})?
        dailyTokenTotals,
    bool Function()? hasProviderKey,
    String? Function()? auxModelName,
    bool Function()? hasWebProvider,
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
      hasProviderKey: hasProviderKey ?? this.hasProviderKey,
      auxModelName: auxModelName ?? this.auxModelName,
      hasWebProvider: hasWebProvider ?? this.hasWebProvider,
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
