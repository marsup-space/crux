// Smoke test: drive a real `dart language-server` through the actor
// model. Writes a broken Dart file, opens it, waits for diagnostics.

import 'dart:io';

import 'package:crux/src/lsp/actors/dart.dart';
import 'package:crux/src/lsp/diagnostic.dart';
import 'package:crux/src/lsp/manager.dart';
import 'package:crux/src/lsp/protocol.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('lsp_smoke_');
  try {
    final pkgYaml = File(p.join(tmp.path, 'pubspec.yaml'))
      ..writeAsStringSync('name: smoke\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n');
    final broken = File(p.join(tmp.path, 'broken.dart'))
      ..writeAsStringSync(
        'int main() {\n'
        '  return "missing semicolon"\n'
        '  var x = ;\n'
        '}\n',
      );

    print('Created ${broken.path}');

    final manager = await LspManager.create(
      workingDirectory: tmp.path,
      actorFactories: {'dart': DartServerActor.new},
    );

    print('Manager created. Calling touchFileAndWait...');
    final sw = Stopwatch()..start();
    final diagnostics = await manager
        .touchFileAndWait(broken.path, timeout: const Duration(seconds: 15))
        .timeout(const Duration(seconds: 20), onTimeout: () {
      print('TIMEOUT after ${sw.elapsed}');
      return const [];
    });
    sw.stop();

    print('Got ${diagnostics.length} diagnostics after ${sw.elapsed}:');
    for (final d in diagnostics) {
      print('  ${prettyDiagnostic(d)}');
    }

    if (diagnostics.isEmpty) {
      print('\nFAIL: no diagnostics returned for broken file');
      exit(1);
    }
    print('\nPASS: real Dart server produced diagnostics');

    await manager.shutdown();
    await pkgYaml.delete();
  } finally {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  }
}
