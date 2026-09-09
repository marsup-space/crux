// Measure dart language-server memory when actively analyzing the
// Crux codebase itself (~3700 LOC, mixed Dart).
//
// 1. Spawn one server with `rootUri` = the Crux project.
// 2. Send `initialize` then `initialized`.
// 3. Open a few real source files to trigger analysis.
// 4. Sample RSS over 30s.

import 'dart:async';
import 'dart:io';

import 'package:crux/src/lsp/peer.dart' show RpcPeer;
import 'package:path/path.dart' as p;

Future<int> _rssKb(int pid) async {
  final r = await Process.run('ps', ['-o', 'rss=', '-p', '$pid']);
  return int.tryParse(r.stdout.toString().trim()) ?? 0;
}

Future<int> main() async {
  // Use this Crux project as the test workspace.
  final projectRoot = Directory.current.path;
  // ignore: avoid_print
  print('Workspace: $projectRoot');

  // Find a handful of files to open.
  final files = <String>[];
  for (final entity in Directory(projectRoot).listSync(recursive: true)) {
    if (entity is! File) continue;
    if (p.extension(entity.path) != '.dart') continue;
    if (entity.path.contains('.dart_tool')) continue;
    if (entity.path.contains('/build/')) continue;
    files.add(entity.path);
    if (files.length >= 5) break;
  }
  // ignore: avoid_print
  print('Opening ${files.length} files for analysis');

  final samples = <int>[];

  final p1 = await Process.start('/opt/homebrew/bin/dart', [
    'language-server',
    '--lsp',
  ], workingDirectory: projectRoot);
  // ignore: avoid_print
  print('Server #1 pid=${p1.pid}');

  // Initialize.
  final peer = RpcPeer.create(
    input: p1.stdout,
    output: p1.stdin,
    tag: 'crux-test',
    onFatal: (_, _) {},
  );
  // Avoid pulling in the helper; just use the public API.

  final initResult = await peer.request('initialize', {
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
  // ignore: avoid_print
  print(
    'Initialize ok, capabilities: '
    '${(initResult as Map)['capabilities']?.keys.toList()}',
  );
  peer.notify('initialized', {});

  // Open each file.
  for (final f in files) {
    final content = await File(f).readAsString();
    peer.notify('textDocument/didOpen', {
      'textDocument': {
        'uri': Uri.file(f).toString(),
        'languageId': 'dart',
        'version': 0,
        'text': content,
      },
    });
  }

  // Sample for 30s.
  for (var t = 0; t < 15; t++) {
    await Future.delayed(const Duration(seconds: 2));
    samples.add(await _rssKb(p1.pid));
  }

  // ignore: avoid_print
  print('\n=== Single dart language-server on Crux codebase ===');
  final minS = samples.reduce((a, b) => a < b ? a : b);
  final maxS = samples.reduce((a, b) => a > b ? a : b);
  final lastS = samples.last;
  final avgS = samples.reduce((a, b) => a + b) ~/ samples.length;
  // ignore: avoid_print
  print(
    'min=${(minS / 1024).toStringAsFixed(0)}MB '
    'avg=${(avgS / 1024).toStringAsFixed(0)}MB '
    'max=${(maxS / 1024).toStringAsFixed(0)}MB '
    'last=${(lastS / 1024).toStringAsFixed(0)}MB',
  );

  p1.kill();
  await Future.delayed(const Duration(milliseconds: 500));
  exit(0);
}
