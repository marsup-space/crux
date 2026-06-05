import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import 'package:nocterm/nocterm.dart';
import 'package:crux/crux.dart';

const _version = 'v0.1.0';

void main(List<String> args) async {
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
  final builtInDir = _resolveBuiltInProvidersDir();
  final userDir = _resolveUserProvidersDir();

  // Run two isolates concurrently and wait for both to finish before
  // launching the UI:
  //
  //   1. Animation isolate: renders the full logo splash. Always runs
  //      for the full 904ms (504ms sweep + 400ms post-pause), regardless
  //      of how fast the loading is.
  //
  //   2. Loading isolate: does all warmup work — seeding example TOMLs
  //      into the user dir, initializing the syntax highlighter, etc.
  //
  // Total wall time = max(904ms, loading_time):
  //   - Fast loading (< 904ms): user sees the full animation, then app.
  //   - Slow loading (> 904ms): animation ends at 904ms, then we wait
  //     on the loading isolate to finish, then app starts immediately
  //     (no extra post-pause — the static-logo hold replaced it).
  final seederResults = await _runLaunchIsolates(
    builtInDirPath: builtInDir.path,
    userDirPath: userDir.path,
  );

  // Log seeder changes after the splash is done, so the stderr lines
  // don't interleave with the logo frames.
  for (final r in seederResults) {
    if (r.action == SeedAction.unchanged) continue;
    stderr.writeln('  ${r.action.name}: ${r.fileName}');
  }

  await runApp(
    _CruxApp(
      userProvidersDir: userDir.path,
      builtInProvidersDir: builtInDir.existsSync() ? builtInDir.path : null,
    ),
  );
}

/// Run the loading and animation isolates in parallel; return the seeder
/// results once both have finished.
///
/// Errors from either isolate are propagated. The isolates are always
/// killed on exit (success or failure) so we don't leak OS processes.
Future<List<SeedResult>> _runLaunchIsolates({
  required String builtInDirPath,
  required String userDirPath,
}) async {
  // ── Loading isolate ────────────────────────────────────────────────
  final loadingPort = ReceivePort();
  final loadingResult = Completer<List<SeedResult>>();
  loadingPort.listen(
    (msg) {
      if (msg is List<SeedResult>) {
        loadingResult.complete(msg);
      } else if (msg is _IsolateError) {
        loadingResult.completeError(msg.error, msg.stack);
      }
    },
    onError: (e, st) => loadingResult.completeError(e, st),
  );
  final loadingIsolate = await Isolate.spawn<_LoadingArgs>(
    _loadingIsolateEntry,
    _LoadingArgs(
      builtInDirPath: builtInDirPath,
      userDirPath: userDirPath,
      resultPort: loadingPort.sendPort,
    ),
  );

  // ── Animation isolate ──────────────────────────────────────────────
  final animationPort = ReceivePort();
  final animationDone = Completer<void>();
  animationPort.listen(
    (msg) {
      if (identical(msg, _doneSentinel)) {
        animationDone.complete();
      } else if (msg is _IsolateError) {
        animationDone.completeError(msg.error, msg.stack);
      }
    },
    onError: (e, st) => animationDone.completeError(e, st),
  );
  final animationIsolate = await Isolate.spawn<_AnimationArgs>(
    _animationIsolateEntry,
    _AnimationArgs(donePort: animationPort.sendPort),
  );

  try {
    // Wait for the animation first — that's our 904ms floor. If loading
    // is faster, awaiting it next returns immediately. If loading is
    // slower, this wait extends until loading is done.
    await animationDone.future;
    return await loadingResult.future;
  } finally {
    loadingPort.close();
    animationPort.close();
    loadingIsolate.kill(priority: Isolate.immediate);
    animationIsolate.kill(priority: Isolate.immediate);
  }
}

// ── Isolate arguments and messages ────────────────────────────────────

class _LoadingArgs {
  final String builtInDirPath;
  final String userDirPath;
  final SendPort resultPort;
  const _LoadingArgs({
    required this.builtInDirPath,
    required this.userDirPath,
    required this.resultPort,
  });
}

class _AnimationArgs {
  final SendPort donePort;
  const _AnimationArgs({required this.donePort});
}

class _IsolateError {
  final Object error;
  final StackTrace stack;
  const _IsolateError(this.error, this.stack);
}

/// Sentinel for the animation isolate's "I'm done" message. Using a
/// constant instance avoids allocating a new object per launch.
const _doneSentinel = Object();

// ── Isolate entry points (must be top-level functions) ─────────────────

/// Runs in the loading isolate.
///
/// Does all warmup work that's safe to run before the UI appears:
/// 1. Seeds example provider TOMLs into the user dir (and reports
///    what it did back to the main isolate for logging).
/// 2. Initializes the syntax highlighter.
///
/// Stdout/stderr is left alone — the loading isolate doesn't log
/// directly, so its output never interleaves with the splash frames.
void _loadingIsolateEntry(_LoadingArgs args) async {
  try {
    final results = await seedExampleProviders(
      builtInDir: Directory(args.builtInDirPath),
      userDir: Directory(args.userDirPath),
    );
    await HighlightService.initialize();
    args.resultPort.send(results);
  } catch (e, st) {
    args.resultPort.send(_IsolateError(e, st));
  }
}

/// Runs in the animation isolate.
///
/// Always renders the full splash — the 504ms sweep, then a 400ms
/// post-pause — for a total of 904ms. There's no "skip ahead if
/// loading is done" optimization here; the main isolate coordinates
/// the wait for both to finish, so the animation is the floor.
void _animationIsolateEntry(_AnimationArgs args) async {
  try {
    await _runSplashAnimation();
    args.donePort.send(_doneSentinel);
  } catch (e, st) {
    args.donePort.send(_IsolateError(e, st));
  }
}

// ── Splash renderer (runs inside the animation isolate) ────────────────

/// Render the full logo splash: 504ms sweep + 400ms post-pause = 904ms.
/// Writes the animation to stdout via ANSI escapes, then shows the
/// cursor and waits briefly so the user registers the final frame.
Future<void> _runSplashAnimation() async {
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

  for (int sweep = -bandWidth; sweep <= artWidth + bandWidth; sweep += sweepStep) {
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

  await Future.delayed(Duration(milliseconds: postAnimationPauseMs));
}

// ── Dir resolution (unchanged) ────────────────────────────────────────

/// Find the built-in provider examples directory.
///
/// Search order:
/// 1. `<exe-dir>/providers/` — portable install next to the binary.
/// 2. `./providers/` — development / running from the project root.
///
/// May return a non-existent directory; callers must check
/// [Directory.existsSync] before using it.
Directory _resolveBuiltInProvidersDir() {
  try {
    final exePath = Platform.resolvedExecutable;
    final exeDir = p.dirname(exePath);
    final sibling = Directory(p.join(exeDir, 'providers'));
    if (sibling.existsSync()) return sibling;
  } catch (_) {
    // `Platform.resolvedExecutable` may throw in some contexts; fall
    // through to the CWD-based resolution.
  }
  return Directory(p.normalize(p.absolute('providers')));
}

/// Find the per-user provider config directory.
///
/// Follows XDG:
/// - Linux/macOS: `$XDG_CONFIG_HOME/crux/providers/`
///   (defaults to `~/.config/crux/providers/`)
/// - Windows: `%LOCALAPPDATA%\crux\providers\`
///   (falls back to `%APPDATA%\crux\providers\`)
Directory _resolveUserProvidersDir() {
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
  return Directory(p.join(configHome, 'crux', 'providers'));
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
    stdout.writeln('  ✓ Schema is up to date (v${db.schemaVersion})');

    stdout.writeln();
    stdout.writeln('[2/2] Purging sessions not bound to a project path...');
    final count = await store.deleteByProjectPath('');
    if (count > 0) {
      stdout.writeln('  ✓ Deleted $count orphaned session(s)');
    } else {
      stdout.writeln('  ✓ No orphaned sessions found');
    }

    stdout.writeln();
    stdout.writeln('Done. No issues found.');
  } finally {
    await db.close();
  }
}

class _CruxApp extends StatelessComponent {
  final String userProvidersDir;
  final String? builtInProvidersDir;
  const _CruxApp({
    required this.userProvidersDir,
    this.builtInProvidersDir,
  });

  @override
  Component build(BuildContext context) {
    return ChatPanel(
      userProvidersDir: userProvidersDir,
      builtInProvidersDir: builtInProvidersDir,
    );
  }
}
