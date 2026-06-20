import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import 'package:nocterm/nocterm.dart';
import 'package:crux/crux.dart';
import 'package:crux/src/services/recent_projects_store.dart';
import 'package:crux/src/utils/windows_vt.dart';
import 'package:crux/src/utils/terminal_symbols.dart';

const _version = 'v0.1.0';

void main(List<String> args) async {
  // Enable ANSI/VT escape processing on the Windows stdout console BEFORE
  // anything writes an escape sequence. Without this, the legacy Windows
  // console drops `\x1B[...` codes and the splash + TUI render as a
  // blank screen. No-op on non-Windows and when stdout is redirected.
  enableWindowsVt();

  for (final arg in args) {
    if (arg == '--help' || arg == '-h') {
      stdout.writeln('Usage: crux [path]');
      stdout.writeln();
      stdout.writeln('Arguments:');
      stdout.writeln(
        '  path    Directory to open (defaults to current directory)',
      );
      stdout.writeln();
      stdout.writeln('Options:');
      stdout.writeln('  -h, --help       Show this help message');
      stdout.writeln('  -v, --version    Show version');
      stdout.writeln('      --doctor     Diagnose and fix issues');
      return;
    }
    if (arg == '--version' || arg == '-v') {
      stdout.writeln(_version);
      return;
    }
    if (arg == '--doctor') {
      await _runDoctor();
      return;
    }
  }

  // Resolve bundled resources before changing Directory.current to the
  // project being opened. Package-root lookup also keeps source checkouts
  // working when `dart run` is invoked from outside the repository.
  final builtInDir = await resolveBundledDirectory('providers');
  final builtInThemesDir = await resolveBundledDirectory('themes');

  if (args.isNotEmpty && !args.first.startsWith('-')) {
    final target = p.normalize(p.absolute(args.first));
    final dir = Directory(target);
    if (!dir.existsSync()) {
      stderr.writeln('Error: directory not found: $target');
      exit(1);
    }
    Directory.current = dir;
  }

  // Kick off the recent-projects bookkeeping *now* so it runs in
  // parallel with the splash + provider-seed work below. We can't
  // do this fire-and-forget: the chat panel needs to bind to the
  // same `RecentProjectsStore` instance we use here, otherwise the
  // cwd we add wouldn't be visible to the autocomplete overlay
  // (each instance keeps its own in-memory copy). So we hold onto
  // the future and `await` it right before `runApp` — the splash
  // covers the cost in the common case where the on-disk read +
  // write finish inside the 504ms sweep.
  final recentProjectsStoreFuture = _loadAndRecordCurrentProject();

  // Resolve the provider search dirs:
  // - built-in: next to the executable (portable install), else ./providers/
  //   (development). May not exist; the seeder is a no-op in that case.
  // - user: per-user XDG config dir. Always writable; created if missing.
  final userDir = _resolveUserProvidersDir();
  final userThemesDir = _resolveUserThemesDir();
  final themeConfigFile = File(
    p.join(_resolveUserConfigDir().path, 'config.toml'),
  );

  // Start the loading work before rendering the main-buffer splash so
  // sessions warm up while the logo animation is visible.
  final bootFuture = _doLoading(
    builtInDir,
    userDir,
    builtInThemesDir,
    userThemesDir,
    themeConfigFile,
    recentProjectsStoreFuture,
  );
  final results = await _showSplashLoading(bootFuture);

  // Disable nocterm's default Ctrl+C handler. Without this,
  // an unhandled Ctrl+C (e.g. while the chat input isn't
  // focused, or in any other component that doesn't return
  // `true` for it) would hit `CtrlCBehavior.immediateExit`,
  // which calls `StdioBackend.requestExit(0)` → bare
  // `exit(0)`. That kills the process before the per-run
  // summary can be printed — exactly the bug we hit on the
  // first cut of this feature.
  //
  // With `disabled`, the synthetic Ctrl+C keyboard event
  // nocterm synthesises from SIGINT is still routed through
  // the component tree as before, but if no component
  // handles it nocterm does *nothing*. The chat input is
  // the canonical consumer; it returns `true` (consumed)
  // and triggers `ChatPanel._quitAndPrintSummary`, which
  // writes the summary, flushes stdout, and then calls
  // `shutdownApp(0)` for a clean terminal teardown. Any
  // in-flight OS-level SIGINT that does manage to escape
  // (e.g. closing the terminal window) is a SIGKILL and
  // there's nothing we can do about it; the user gets no
  // summary in that case, which matches every other CLI
  // tool's behaviour.
  TerminalBinding.setCtrlCBehavior(CtrlCBehavior.disabled);

  // Log seeder/theme warnings after the splash is done, so stderr lines
  // don't interleave with the logo frames.
  for (final r in results.providerSeedResults) {
    if (r.action == SeedAction.unchanged) continue;
    stderr.writeln('  ${r.action.name}: ${r.fileName}');
  }
  for (final entry in results.themeController.registry.loadErrors.entries) {
    stderr.writeln('  theme warning: ${entry.key}: ${entry.value}');
  }
  if (results.themeController.startupWarning case final warning?) {
    stderr.writeln('  theme warning: $warning');
  }

  // Wire uncaught errors to the toast hub so the user sees them as
  // red error toasts rather than silent failures. The hub's static
  // instance is only live while the chat panel is mounted, so we
  // null-check before calling it.
  //
  // We use `Isolate.current.addErrorListener` because `dart:ui`'s
  // `PlatformDispatcher` is a Flutter API and we're a pure Dart CLI app.
  Isolate.current.addErrorListener(
    RawReceivePort((dynamic message) {
      // The error listener delivers a two-element list: [error, stack].
      if (message is List<dynamic> && message.length == 2) {
        final Object error = message[0];
        final StackTrace stack = message[1] as StackTrace;
        final inst = ToastHubState.globalInstance;
        if (inst != null) {
          final msg = error is String ? error : '$error';
          inst.show('Internal error: $msg', mode: ToastMode.error);
        }
        stderr.writeln('FATAL: $error\n$stack');
      }
    }).sendPort,
  );

  await runApp(
    _CruxApp(
      userProvidersDir: userDir.path,
      builtInProvidersDir: builtInDir.existsSync() ? builtInDir.path : null,
      themeController: results.themeController,
      bootState: results.chatPanelBootState,
      gitStatusService: results.gitStatusService,
      recentProjectsStore: results.recentProjectsStore,
      startupWarnings: [
        ...results.themeController.registry.loadErrors.entries.map(
          (entry) => 'Theme ${p.basename(entry.key)}: ${entry.value}',
        ),
        if (results.themeController.startupWarning != null)
          results.themeController.startupWarning!,
        // When launched under `--observe` / `--enable-vm-service`,
        // the Dart runtime prints the VM service URL to stderr
        // BEFORE our app enters alt-screen mode, so the user
        // can't see it. Surface it as a startup toast instead.
        // The exact auth token isn't reachable from inside the
        // app, so we tell the user how to recover the URL they
        // already have on stderr (or how to disable auth so the
        // URL is token-free).
        ..._vmServiceStartupWarnings(),
      ],
    ),
  );

  // `runApp` has returned, which means the TUI tore down
  // the alt-screen and the terminal is back in the user's
  // shell's "main buffer". Print the per-run summary here
  // so the user sees it in the same place they'd see the
  // output of any other command — not inside the now-defunct
  // alt-screen.
  //
  // The summary aggregates tokens, turn count, and duration
  // across every session the user touched in this Crux run
  // (see `RunMetrics`). The `--doctor` path returns before
  // this line, so doctor runs never see the summary.
  //
  // Note: with `setCtrlCBehavior(disabled)` set above, the
  // Ctrl+C exit path goes through
  // `ChatPanel._quitAndPrintSummary` rather than `runApp`
  // returning — that path prints the summary itself and
  // then calls `shutdownApp(0)`, which still routes
  // through this same `await runApp(...)` because the
  // binding's event loop breaks. So this line is the
  // fallback for the case where something else (e.g. the
  // user closes stdin, or a future feature wires another
  // exit path) makes `runApp` return without going through
  // the panel's quit callback. Both paths are idempotent:
  // printing the summary twice is harmless.
  _printRunSummary();
}

/// Write the per-run summary block to stdout. Called once, after
/// `runApp()` returns, so the TUI has already restored the
/// terminal to its normal mode — the text lands in the user's
/// shell buffer (the "main buffer"), not inside the now-defunct
/// alt-screen.
///
/// Force ASCII on Windows consoles that don't support rich
/// terminal symbols so the box-drawing characters don't
/// degrade into a wall of `?`. Other platforms (macOS, Linux,
/// Windows Terminal / ConEmu / WSL) get the Unicode variant.
///
/// Quiet the ANSI noise on non-TTY stdout (e.g. when the user
/// pipes `crux ... > out.txt` or runs under a CI capture) by
/// just using the ASCII frame even on POSIX — the box chars
/// still render fine in a text file, and we don't have to
/// worry about raw escape sequences polluting a pipe.
void _printRunSummary() {
  // The chat panel's `_quitAndPrintSummary` stashed the
  // active theme on the aggregator just before exit, so
  // `formatStyledSummary` can produce a coloured version
  // here without having to look at the (already-disposed)
  // ThemeController. If the chat panel never ran (very
  // early `--doctor` exit, or some future shutdown path
  // that bypasses the panel), `formatStyledSummary`
  // transparently falls back to the plain uncoloured
  // string, so this call is safe in every situation.
  final summary = RunMetrics.instance.formatStyledSummary();
  stdout.writeln();
  stdout.writeln(summary);
  stdout.writeln();
}

/// Detect if the Dart VM service is active and return startup warnings
/// explaining how to recover the VM service URL (it was printed to stderr
/// before the app entered alt-screen mode).
List<String> _vmServiceStartupWarnings() {
  try {
    final uri = Uri.parse(Platform.environment['VmServiceUrl'] ?? '');
    if (uri.isAbsolute) {
      return [
        'VM service is active: $uri',
        'To disable auth, relaunch with --no-authenticate-vm-service',
      ];
    }
  } catch (_) {
    // Ignore – env var not set or not a valid URI.
  }
  return [];
}

/// Load the recent-projects JSON from disk and record the current
/// working directory in it. Returns the live store (not just the
/// entries) so the chat panel can bind to it and observe future
/// mutations from `/project` switches without a second disk read.
///
/// Errors are swallowed: `RecentProjectsStore.add` already does
/// best-effort persistence, so a read-only home dir during a CI
/// smoke test yields an empty list rather than crashing the binary.
Future<RecentProjectsStore> _loadAndRecordCurrentProject() async {
  try {
    final store = await RecentProjectsStore.load();
    await store.add(Directory.current.path);
    return store;
  } catch (_) {
    // Fall back to an empty store pointing at the canonical file
    // path so downstream `add` calls still have a place to write.
    // This keeps the TUI functional even when the JSON file is
    // unreadable for some platform-specific reason.
    return RecentProjectsStore.empty();
  }
}

/// All the warmup work the app needs before the UI appears.
class _LoadingResults {
  final List<SeedResult> providerSeedResults;
  final ThemeController themeController;
  final ChatPanelBootState chatPanelBootState;
  final GitStatusService gitStatusService;
  final RecentProjectsStore recentProjectsStore;

  const _LoadingResults({
    required this.providerSeedResults,
    required this.themeController,
    required this.chatPanelBootState,
    required this.gitStatusService,
    required this.recentProjectsStore,
  });
}

Future<_LoadingResults> _doLoading(
  Directory builtInDir,
  Directory userDir,
  Directory builtInThemesDir,
  Directory userThemesDir,
  File themeConfigFile,
  Future<RecentProjectsStore> recentProjectsStoreFuture,
) async {
  final gitStatusService = GitStatusService();
  final gitStatusFuture = gitStatusService.refresh();
  final providerSeedResults = await seedExampleProviders(
    builtInDir: builtInDir,
    userDir: userDir,
  );
  final chatPanelBootState = await loadChatPanelBootState(
    userProvidersDir: userDir.path,
    builtInProvidersDir: builtInDir.existsSync() ? builtInDir.path : null,
  );
  final themeRegistry = await ThemeLoader(
    bundledDirectory: builtInThemesDir,
    userDirectory: userThemesDir,
  ).load();
  final themeController = await ThemeController.create(
    registry: themeRegistry,
    configStore: ThemeConfigStore(themeConfigFile),
  );
  await HighlightService.initialize();
  await gitStatusFuture;
  gitStatusService.start(refreshImmediately: false);
  final recentProjectsStore = await recentProjectsStoreFuture;
  return _LoadingResults(
    providerSeedResults: providerSeedResults,
    themeController: themeController,
    chatPanelBootState: chatPanelBootState,
    gitStatusService: gitStatusService,
    recentProjectsStore: recentProjectsStore,
  );
}

// ── Splash renderer ──────────────────────────────────────────────────

/// Render the Crux boot logo in the terminal's main buffer while [loading]
/// warms up providers, themes, sessions, and message state.
///
/// This returns only after both the full logo animation and [loading] finish.
Future<_LoadingResults> _showSplashLoading(
  Future<_LoadingResults> loading,
) async {
  const art = [
    '  ██████╗   ██████╗  ██╗   ██╗ ██╗  ██╗',
    ' ██╔════╝  ██╔══██╗ ██║   ██║  ██╗██╔╝',
    ' ██║      ██████╔╝ ██║   ██║   ███╔╝ ',
    ' ██║      ██╔══██╗ ██║   ██║  ██╔██╗ ',
    '  ██████╗ ██║  ██║  █████╔╝ ██╔╝ ██╗',
  ];

  final artWidth = art.first.length;

  const baseR = 224, baseG = 189, baseB = 255;
  const glossR = 255, glossG = 255, glossB = 255;
  const bandWidth = 12;
  const sweepStep = 2;
  const versionLabelR = 146, versionLabelG = 153, versionLabelB = 166;
  const frameDelayMs = 18;
  const postAnimationPauseMs = 400;

  stdout.write('\x1B[?25l');
  stdout.writeln();
  stdout.writeln();

  var loadingDone = false;
  loading.whenComplete(() => loadingDone = true);

  for (
    int sweep = -bandWidth;
    sweep <= artWidth + bandWidth;
    sweep += sweepStep
  ) {
    for (int l = 0; l < art.length; l++) {
      final line = art[l];
      final buf = StringBuffer();
      for (int i = 0; i < line.length; i++) {
        final dist = (i - sweep).abs();
        if (dist < bandWidth) {
          final t = 1 - dist / bandWidth;
          final ease = t * t * (3 - 2 * t);
          final cr = (baseR + (glossR - baseR) * ease).round();
          final cg = (baseG + (glossG - baseG) * ease).round();
          final cb = (baseB + (glossB - baseB) * ease).round();
          buf
            ..write('\x1B[38;2;')
            ..write(cr)
            ..write(';')
            ..write(cg)
            ..write(';')
            ..write(cb)
            ..write('m')
            ..write(line[i]);
        } else {
          buf
            ..write('\x1B[38;2;')
            ..write(baseR)
            ..write(';')
            ..write(baseG)
            ..write(';')
            ..write(baseB)
            ..write('m')
            ..write(line[i]);
        }
      }
      if (l == art.length - 1) {
        buf
          ..write(
            '\x1B[0m\x1B[1C\x1B[38;2;$versionLabelR;$versionLabelG;$versionLabelB m',
          )
          ..write(_version)
          ..write('\x1B[0m');
      } else {
        buf.write('\x1B[0m');
      }
      stdout.writeln(buf);
    }
    stdout.write('\x1B[${art.length}A');
    await Future.delayed(Duration(milliseconds: frameDelayMs));
  }

  stdout.write('\x1B[${art.length}B');
  stdout.write('\x1B[?25h');
  await stdout.flush();

  if (!loadingDone) {
    return await loading;
  }

  await Future.delayed(Duration(milliseconds: postAnimationPauseMs));
  return await loading;
}

// ── User directory resolution ─────────────────────────────────────────

/// Find the per-user provider config directory.
///
/// Follows XDG:
/// - Linux/macOS: `$XDG_CONFIG_HOME/crux/providers/`
///   (defaults to `~/.config/crux/providers/`)
/// - Windows: `%LOCALAPPDATA%\crux\providers\`
///   (falls back to `%APPDATA%\crux\providers\`)
Directory _resolveUserProvidersDir() {
  return Directory(p.join(_resolveUserConfigDir().path, 'providers'));
}

Directory _resolveUserThemesDir() {
  return Directory(p.join(_resolveUserConfigDir().path, 'themes'));
}

Directory _resolveUserConfigDir() {
  String configHome;
  if (Platform.isWindows) {
    configHome =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
  } else {
    configHome =
        Platform.environment['XDG_CONFIG_HOME'] ??
        p.join(Platform.environment['HOME'] ?? '.', '.config');
  }
  return Directory(p.join(configHome, 'crux'));
}

// ── --doctor and ChatPanel (unchanged) ────────────────────────────────

Future<void> _runDoctor() async {
  stdout.writeln('crux doctor — diagnosing...');
  stdout.writeln();

  final db = CruxDatabase();
  final store = SessionStore(db);

  try {
    stdout.writeln('[1/2] Migrating database to current schema...');
    await db.customSelect('PRAGMA schema_version').get();
    stdout.writeln(
      '  ${terminalSymbol('✓', '+')} Schema is up to date (v${db.schemaVersion})',
    );

    stdout.writeln();
    stdout.writeln('[2/2] Purging sessions not bound to a project path...');
    final count = await store.deleteByProjectPath('');
    if (count > 0) {
      stdout.writeln(
        '  ${terminalSymbol('✓', '+')} Deleted $count orphaned session(s)',
      );
    } else {
      stdout.writeln(
        '  ${terminalSymbol('✓', '+')} No orphaned sessions found',
      );
    }

    stdout.writeln();
    stdout.writeln('Done. No issues found.');
  } finally {
    await db.close();
  }
}

class _CruxApp extends StatefulComponent {
  final String userProvidersDir;
  final String? builtInProvidersDir;
  final ThemeController themeController;
  final ChatPanelBootState bootState;
  final GitStatusService gitStatusService;
  final RecentProjectsStore recentProjectsStore;
  final List<String> startupWarnings;

  const _CruxApp({
    required this.userProvidersDir,
    this.builtInProvidersDir,
    required this.themeController,
    required this.bootState,
    required this.gitStatusService,
    required this.recentProjectsStore,
    this.startupWarnings = const [],
  });

  @override
  State<_CruxApp> createState() => _CruxAppState();
}

class _CruxAppState extends State<_CruxApp> {
  @override
  void initState() {
    super.initState();
    component.themeController.addListener(_handleThemeChanged);
    // Override nocterm's default 30fps to 60fps for smoother animations
    // (streaming text, status indicators, context bar, etc.).
    SchedulerBinding.instance.targetFrameDuration = const Duration(
      microseconds: 16667,
    );
  }

  void _handleThemeChanged() => setState(() {});

  @override
  void dispose() {
    component.themeController.removeListener(_handleThemeChanged);
    component.themeController.dispose();
    // The chat panel already disposed this store, but be defensive:
    // if the panel never mounted (e.g. the app bailed out before
    // its first frame) we still need to release the listener
    // subscriptions to avoid leaking the ChangeNotifier.
    component.recentProjectsStore.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final theme = component.themeController.activeTheme;
    return NoctermApp(
      title: 'Crux',
      theme: theme.toTuiThemeData(),
      // HintOverlay sits just inside the [NoctermApp] so its [Stack]
      // is anchored at the global origin — every hint registered via
      // the app-wide [HintController] draws over the chat panel
      // regardless of where in the tree its source lives. The
      // scrollbar markers (see [AnnotatedScrollbar]) register hints
      // with a zero delay so they show immediately; ordinary
      // components that mix in [HintStateMixin] use the default
      // 500 ms delay.
      child: CruxTheme(
        data: theme,
        child: HintOverlay(
          tooltipBackgroundColor: theme.overlayBackground,
          tooltipBorderColor: theme.overlayBorder,
          child: ChatPanel(
            userProvidersDir: component.userProvidersDir,
            builtInProvidersDir: component.builtInProvidersDir,
            themeController: component.themeController,
            bootState: component.bootState,
            gitStatusService: component.gitStatusService,
            recentProjectsStore: component.recentProjectsStore,
            startupWarnings: component.startupWarnings,
          ),
        ),
      ),
    );
  }
}
