import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import 'package:nocterm/nocterm.dart';
import 'package:crux/crux.dart';
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

  // Resolve the provider search dirs:
  // - built-in: next to the executable (portable install), else ./providers/
  //   (development). May not exist; the seeder is a no-op in that case.
  // - user: per-user XDG config dir. Always writable; created if missing.
  final userDir = _resolveUserProvidersDir();
  final userThemesDir = _resolveUserThemesDir();
  final themeConfigFile = File(
    p.join(_resolveUserConfigDir().path, 'config.toml'),
  );

  // Run the splash and the loading work in the same isolate. The splash
  // runs as a Future that takes a `loadingDone` callback; it renders the
  // full animation unless loading beats it, in which case it bails out
  // and we still get the 904ms minimum (504ms sweep + 400ms pause).
  //
  // Why a single isolate (and not two with `Isolate.spawn`):
  //   The TUI's startup sequence writes `\x1B[?1049h` (alt screen) and
  //   other CSI codes to stdout. If those writes interleave with a
  //   still-flushing splash from another isolate, conhost in vanilla
  //   CMD/PowerShell can split the escape sequences and end up in a
  //   bad state (blank screen, alt screen ignored). Tabby is more
  //   tolerant; the legacy Windows console is not. Single-isolate
  //   sequencing avoids the race entirely.
  //
  // Behavior:
  //   - Fast loading (< 504ms): splash runs to completion (504ms) +
  //     400ms post-pause = 904ms wall time. App starts.
  //   - Slow loading (>= 504ms): splash bails out at the frame where
  //     loading completes, then `await loadingDone` extends the hold
  //     on the static logo until loading is done. Total wall time =
  //     loading_time (animation ≤ loading_time ≤ 904ms).
  final results = await _runSplashAndLoading(
    builtInDir: builtInDir,
    userDir: userDir,
    builtInThemesDir: builtInThemesDir,
    userThemesDir: userThemesDir,
    themeConfigFile: themeConfigFile,
  );

  // Log seeder changes after the splash is done, so the stderr lines
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
      startupWarnings: [
        ...results.themeController.registry.loadErrors.entries.map(
          (entry) => 'Theme ${p.basename(entry.key)}: ${entry.value}',
        ),
        if (results.themeController.startupWarning != null)
          results.themeController.startupWarning!,
      ],
    ),
  );
}

/// Run the splash animation and the loading work concurrently in the
/// current isolate. Returns provider seeding and initialized theme state.
///
/// The animation always runs for at least 504ms (the sweep). If loading
/// finishes during the sweep, the sweep bails out and we run a 400ms
/// post-pause. If loading takes longer than the sweep, we hold the
/// static logo until loading is done — no post-pause, just the wait.
///
/// Total wall time is `max(loading_time, 904ms)` when loading < 504ms,
/// or just `loading_time` when loading >= 504ms.
Future<_LoadingResults> _runSplashAndLoading({
  required Directory builtInDir,
  required Directory userDir,
  required Directory builtInThemesDir,
  required Directory userThemesDir,
  required File themeConfigFile,
}) async {
  // Start the loading work as a Future. It's mostly I/O (file reads,
  // SHA computation, and HighlightService's grammar compile) so it
  // cooperates with the splash's `Future.delayed` between frames.
  final loadingFuture = _doLoading(
    builtInDir,
    userDir,
    builtInThemesDir,
    userThemesDir,
    themeConfigFile,
  );

  // Run the splash, with a callback that lets it know when loading is
  // done so it can bail out early.
  await _showSplashLoading(loadingFuture);

  // Defensive: the splash only returns after both it and loading are
  // done, but `await` again is cheap insurance.
  return await loadingFuture;
}

/// All the warmup work the app needs before the UI appears.
class _LoadingResults {
  final List<SeedResult> providerSeedResults;
  final ThemeController themeController;

  const _LoadingResults({
    required this.providerSeedResults,
    required this.themeController,
  });
}

Future<_LoadingResults> _doLoading(
  Directory builtInDir,
  Directory userDir,
  Directory builtInThemesDir,
  Directory userThemesDir,
  File themeConfigFile,
) async {
  final providerSeedResults = await seedExampleProviders(
    builtInDir: builtInDir,
    userDir: userDir,
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
  return _LoadingResults(
    providerSeedResults: providerSeedResults,
    themeController: themeController,
  );
}

// ── Splash renderer ──────────────────────────────────────────────────

/// Run the splash logo animation concurrently with [loading].
///
/// The two run in parallel via the event loop (no isolates needed — the
/// splash's `Future.delayed` yields control between frames, so the
/// loading work can run in the gaps).
///
/// Behavior:
/// - If [loading] completes during the ~1s animation: animation finishes
///   normally, brief post-pause, then return.
/// - If [loading] is still running after the animation: the static logo
///   stays on screen (cursor hidden, no more redraws) until [loading]
///   completes, then return.
/// - This function only returns after BOTH the animation cycle and
///   [loading] have finished — so the caller can safely call `runApp`
///   right after, knowing the warmup work is done.
Future<void> _showSplashLoading(Future<void> loading) async {
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

  // Bail out of the sweep early if loading finishes while the animation
  // is running. The Future is shared with the loading task — when it
  // completes, this loop's `&& !loadingDone` flips false and we drop
  // into the post-animation hold below.
  var loadingDone = false;
  loading.whenComplete(() => loadingDone = true);

  for (
    int sweep = -bandWidth;
    sweep <= artWidth + bandWidth && !loadingDone;
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

  // Move cursor below the logo and restore it. This is the "last write"
  // of the splash — the TUI's first write (`\x1B[?1049h` for alt screen)
  // will follow immediately. Both go to the same file descriptor in
  // the same isolate, so there's no inter-isolate race.
  stdout.write('\x1B[${art.length}B');
  stdout.write('\x1B[?25h');
  await stdout.flush();

  if (!loadingDone) {
    // Animation ended naturally but loading is still in flight — hold
    // the static logo on screen (no more redraws) until it finishes.
    await loading;
  } else {
    // Animation bailed out because loading completed mid-sweep, OR
    // finished naturally and loading was already done. Give the user
    // a brief post-pause so they register the final frame.
    await Future.delayed(Duration(milliseconds: postAnimationPauseMs));
  }
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
  final List<String> startupWarnings;

  const _CruxApp({
    required this.userProvidersDir,
    this.builtInProvidersDir,
    required this.themeController,
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
  }

  void _handleThemeChanged() => setState(() {});

  @override
  void dispose() {
    component.themeController.removeListener(_handleThemeChanged);
    component.themeController.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final theme = component.themeController.activeTheme;
    return NoctermApp(
      title: 'Crux',
      theme: theme.toTuiThemeData(),
      child: CruxTheme(
        data: theme,
        child: ChatPanel(
          userProvidersDir: component.userProvidersDir,
          builtInProvidersDir: component.builtInProvidersDir,
          themeController: component.themeController,
          startupWarnings: component.startupWarnings,
        ),
      ),
    );
  }
}
