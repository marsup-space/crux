// Dart language server actor.
//
// Uses `dart language-server`, which ships with the Dart SDK
// (https://dart.dev/tools/dart-tool). For Phase 2.0 we resolve the
// root as the nearest `pubspec.yaml`. Phase 2.1 may add monorepo
// (melos) support.

import '../actor.dart';
import '../find_up.dart';
import '../protocol.dart';
import '../spawn_util.dart';

/// Actor for the Dart analysis server.
///
/// On startup:
///   1. Find the nearest `pubspec.yaml` walking up from [file].
///   2. Spawn `dart language-server --lsp` with that as cwd.
///   3. Initialize with `initializationOptions` driving the analyzer.
///
/// Returns null from [resolveSpec] if `dart` isn't on PATH.
class DartServerActor extends LspServerActor {
  @override
  String get id => 'dart';

  @override
  List<String> get extensions => const ['.dart'];

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    final dart = whichBinary('dart');
    if (dart == null) return null;

    final projectRoot = await findUpOrStop(
      markers: const ['pubspec.yaml'],
      start: file,
      stop: root,
    );

    return LspServerSpec(
      root: projectRoot,
      command: [dart, 'language-server', '--lsp'],
      env: const {},
      initialization: const {},
    );
  }
}
