// Measure the speedup from read-time LSP warming.
//
// Scenario 1 (cold): edit a .dart file with no prior read.
//   → manager spawns dart language-server, opens doc, waits ~1s
//     for first diagnostic.
//
// Scenario 2 (warm): first `read` the .dart file, then `edit` it.
//   → read fires the spawn in the background. By the time the
//     edit arrives, the server is initialized and the file is
//     analyzed. Diagnostic collection should be sub-second.

import 'dart:async';
import 'dart:io';
import 'package:crux/src/lsp/actors/dart.dart';
import 'package:crux/src/lsp/manager.dart' show LspManager;

Future<int> _measureColdEdit(String projectRoot, String filePath) async {
  final manager = LspManager(
    workingDirectory: projectRoot,
    actorFactories: const {'dart': DartServerActor.new},
  );
  final t0 = DateTime.now();
  await manager.touchFileAndWait(
    filePath,
    timeout: const Duration(seconds: 10),
  );
  final elapsed = DateTime.now().difference(t0).inMilliseconds;
  await manager.shutdown();
  return elapsed;
}

Future<({int warmEditMs, int diagnosticsCount})> _measureWarmEdit(
    String projectRoot, String filePath) async {
  final manager = LspManager(
    workingDirectory: projectRoot,
    actorFactories: const {'dart': DartServerActor.new},
  );

  // Fire the warm — returns immediately but spawns the server
  // and starts analysis in the background.
  final tWarmStart = DateTime.now();
  unawaited(manager.touchFileAndForget(filePath));
  // Give it time to spawn and analyze. 2s should be plenty for
  // a 3.7k LOC project per the earlier spinup measurement.
  await Future.delayed(const Duration(seconds: 2));

  final tEditStart = DateTime.now();
  final diagnostics = await manager.touchFileAndWait(
    filePath,
    timeout: const Duration(seconds: 5),
  );
  final warmEditMs = DateTime.now().difference(tEditStart).inMilliseconds;

  // ignore: avoid_print
  print('  total warmup+wait+edit: '
      '${DateTime.now().difference(tWarmStart).inMilliseconds}ms');

  await manager.shutdown();
  return (warmEditMs: warmEditMs, diagnosticsCount: diagnostics.length);
}

Future<void> main() async {
  final projectRoot = Directory.current.path;
  // Pick a known small tool file for stable timing. dart's
  // analyzer cost is dominated by import resolution; a small
  // file with few imports is the baseline.
  const filePath = 'lib/src/tools/file_read_tracker.dart';
  if (!File(filePath).existsSync()) {
    // ignore: avoid_print
    print('expected $filePath to exist');
    exit(1);
  }
  // ignore: avoid_print
  print('Target: $filePath\n');

  // Scenario 1: cold edit (no prior warm).
  // ignore: avoid_print
  print('Scenario 1: cold edit (no prior warm)');
  final coldMs = await _measureColdEdit(projectRoot, filePath);
  // ignore: avoid_print
  print('  cold edit took: ${coldMs}ms\n');

  // Scenario 2: warm edit (read fired background warm, then 2s wait).
  // ignore: avoid_print
  print('Scenario 2: warm edit (read fired background warm)');
  final warm = await _measureWarmEdit(projectRoot, filePath);
  // ignore: avoid_print
  print('  warm edit took: ${warm.warmEditMs}ms');
  // ignore: avoid_print
  print('  diagnostics received: ${warm.diagnosticsCount}');

  // ignore: avoid_print
  print('\n=== Summary ===');
  // ignore: avoid_print
  print('Cold edit:  $coldMs ms');
  // ignore: avoid_print
  print('Warm edit:  ${warm.warmEditMs} ms');
  final speedup = coldMs / (warm.warmEditMs == 0 ? 1 : warm.warmEditMs);
  // ignore: avoid_print
  print('Speedup:    ~${speedup.toStringAsFixed(1)}×');

  exit(0);
}
