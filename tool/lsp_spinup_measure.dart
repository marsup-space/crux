// Measure LSP server cold-start latency on the Crux codebase:
//
//   1. Process spawn     — `Process.start` to process exists
//   2. Initialize        — `initialize` request to response
//   3. Did-open to first diagnostic — `didOpen` to first publishDiagnostics
//
// Run a few iterations to get min/avg/max.

import 'dart:async';
import 'dart:io';
import 'package:crux/src/lsp/peer.dart' show RpcPeer;
import 'package:path/path.dart' as p;

class _Timing {
  final int spawnMs;
  final int initMs;
  final int? firstDiagMs;
  _Timing(this.spawnMs, this.initMs, this.firstDiagMs);
}

Future<_Timing> _measureOne(String projectRoot) async {
  // Find one real file to open.
  String? targetFile;
  for (final e in Directory(projectRoot).listSync(recursive: true)) {
    if (e is! File) continue;
    if (p.extension(e.path) != '.dart') continue;
    if (e.path.contains('.dart_tool') || e.path.contains('/build/')) continue;
    targetFile = e.path;
    break;
  }
  if (targetFile == null) {
    throw StateError('no .dart file found in $projectRoot');
  }

  // 1. Process spawn.
  final t0 = DateTime.now();
  final p1 = await Process.start('/opt/homebrew/bin/dart', [
    'language-server',
    '--lsp',
  ], workingDirectory: projectRoot);
  final t1 = DateTime.now();

  final peer = RpcPeer.create(
    input: p1.stdout,
    output: p1.stdin,
    tag: 'spinup-test',
    onFatal: (_, _) {},
  );

  // 2. Initialize.
  final initFut = peer.request('initialize', {
    'processId': pid,
    'rootUri': Uri.file(projectRoot).toString(),
    'capabilities': {
      'workspace': {'configuration': true},
      'textDocument': {
        'synchronization': {'didSave': true},
        'publishDiagnostics': {'versionSupport': false},
      },
    },
  });
  await initFut;
  final t2 = DateTime.now();
  peer.notify('initialized', {});

  // 3. didOpen + wait for first publishDiagnostics.
  final diagCompleter = Completer<DateTime>();
  peer.onNotification('textDocument/publishDiagnostics', (params) {
    if (!diagCompleter.isCompleted) {
      diagCompleter.complete(DateTime.now());
    }
  });
  final content = await File(targetFile).readAsString();
  final t3 = DateTime.now();
  peer.notify('textDocument/didOpen', {
    'textDocument': {
      'uri': Uri.file(targetFile).toString(),
      'languageId': 'dart',
      'version': 0,
      'text': content,
    },
  });

  int? firstDiagMs;
  try {
    final t4 = await diagCompleter.future.timeout(const Duration(seconds: 10));
    firstDiagMs = t4.difference(t3).inMilliseconds;
  } on TimeoutException {
    firstDiagMs = null;
  }

  p1.kill();
  await Future.delayed(const Duration(milliseconds: 500));

  return _Timing(
    t1.difference(t0).inMilliseconds,
    t2.difference(t1).inMilliseconds,
    firstDiagMs,
  );
}

Future<void> main() async {
  final projectRoot = Directory.current.path;
  // ignore: avoid_print
  print('Workspace: $projectRoot');
  // ignore: avoid_print
  print('Iterations: 3 (cold each time)\n');

  final timings = <_Timing>[];
  for (var i = 0; i < 3; i++) {
    final t = await _measureOne(projectRoot);
    timings.add(t);
    // ignore: avoid_print
    print(
      'Iter ${i + 1}: spawn=${t.spawnMs}ms '
      'init=${t.initMs}ms '
      'firstDiag=${t.firstDiagMs ?? "(no diag in 10s)"}ms',
    );
  }

  // ignore: avoid_print
  print('\n=== Summary (3 cold starts) ===');
  int sum(int Function(_Timing) sel) =>
      timings.map(sel).reduce((a, b) => a + b);
  int avg(int Function(_Timing) sel) => sum(sel) ~/ timings.length;
  int mn(int Function(_Timing) sel) =>
      timings.map(sel).reduce((a, b) => a < b ? a : b);
  int mx(int Function(_Timing) sel) =>
      timings.map(sel).reduce((a, b) => a > b ? a : b);
  // ignore: avoid_print
  print(
    'spawn:    min=${mn((t) => t.spawnMs)}ms '
    'avg=${avg((t) => t.spawnMs)}ms '
    'max=${mx((t) => t.spawnMs)}ms',
  );
  // ignore: avoid_print
  print(
    'init:     min=${mn((t) => t.initMs)}ms '
    'avg=${avg((t) => t.initMs)}ms '
    'max=${mx((t) => t.initMs)}ms',
  );
  final diags = timings.map((t) => t.firstDiagMs).whereType<int>().toList();
  if (diags.isNotEmpty) {
    // ignore: avoid_print
    print(
      '1stDiag:  min=${diags.reduce((a, b) => a < b ? a : b)}ms '
      'avg=${diags.reduce((a, b) => a + b) ~/ diags.length}ms '
      'max=${diags.reduce((a, b) => a > b ? a : b)}ms',
    );
  } else {
    // ignore: avoid_print
    print('1stDiag:  (no diagnostics in any iteration)');
  }
  exit(0);
}
