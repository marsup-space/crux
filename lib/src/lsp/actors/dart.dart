// Dart language server actor.
//
// Uses `dart language-server`, which ships with the Dart SDK
// (https://dart.dev/tools/dart-tool). For Phase 2.0 we resolve the
// root as the nearest `pubspec.yaml`. Phase 2.1 may add monorepo
// (melos) support.

import 'dart:io';

import '../actor.dart';
import '../find_up.dart';
import '../protocol.dart';

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
    final dart = _whichDart();
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

  /// Locate the `dart` executable. In production we shell out to
  /// `which dart`. Tests inject a path or override this method.
  String? _whichDart() {
    final env = Platform.environment;
    final pathVar = env['PATH'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final ext = Platform.isWindows ? '.exe' : '';
    for (final dir in pathVar.split(separator)) {
      if (dir.isEmpty) continue;
      final candidate = '$dir${Platform.pathSeparator}dart$ext';
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }
}
