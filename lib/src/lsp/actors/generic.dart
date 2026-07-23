// Generic PATH-based LSP server actor, with optional auto-install.
//
// Most language servers follow the same shape (see OpenCode's
// `server.ts` — the majority of its `Info` entries are exactly this):
//   1. Find the binary on PATH (possibly with fallback candidates).
//   2. Resolve the project root by walking up for marker files.
//   3. Spawn `binary [args...]` with the root as cwd.
//
// [WhichServerActor] covers that whole class declaratively, so each
// language is a one-line entry in `registry.dart`. Languages needing
// custom logic (Dart, TypeScript with its deno override, Python with
// venv detection, jdtls, C#) get their own actor files.
//
// Auto-install mirrors OpenCode: when no candidate is on PATH, the
// optional [install] hook downloads the server into Crux's per-user
// tool dir (`~/.cache/crux/lsp`) and the resulting binary is used
// from then on. Set `CRUX_DISABLE_LSP_DOWNLOAD=1` to opt out.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../actor.dart';
import '../find_up.dart';
import '../installer.dart';
import '../protocol.dart';
import '../spawn_util.dart';

/// Downloads the server binary and returns its path, or null on
/// failure. Called at most once per server id (see [installOnce]).
typedef LspInstaller = Future<String?> Function();

/// Declarative actor for servers whose binary lives on PATH or can
/// be auto-installed.
class WhichServerActor extends LspServerActor {
  @override
  final String id;

  @override
  final List<String> extensions;

  @override
  final List<String> bareFilenames;

  /// Marker files that identify the project root, in priority order
  /// (first match walking up wins). If empty, the session root is used
  /// directly — for servers like bash-language-server that are happy
  /// analyzing standalone scripts.
  final List<String> rootMarkers;

  /// Walk past the session's working directory when looking for
  /// markers. OpenCode walks up to the filesystem root; Crux keeps the
  /// default bounded at the session root to avoid hijacking a parent
  /// project's config. Set true for servers where a parent config is
  /// still the right root (e.g. C# `.sln` above the repo).
  final bool walkAboveRoot;

  /// Command candidates tried in order. The first candidate whose
  /// binary is found (PATH, then Crux's tool dir) wins.
  final List<List<String>> commandCandidates;

  /// Optional auto-install hook. Invoked when no [commandCandidates]
  /// binary is found; the returned path replaces the binary name of
  /// the winning candidate. Null (default) = never download.
  final LspInstaller? install;

  /// `initializationOptions` sent with the `initialize` request.
  final Map<String, dynamic> initializationOptions;

  WhichServerActor({
    required this.id,
    required this.extensions,
    this.bareFilenames = const [],
    this.rootMarkers = const [],
    this.walkAboveRoot = false,
    required this.commandCandidates,
    this.install,
    this.initializationOptions = const {},
  });

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    List<String>? command;
    for (final candidate in commandCandidates) {
      final bin = whichBinary(candidate.first) ??
          _installedBinary(candidate.first);
      if (bin != null) {
        command = [bin, ...candidate.skip(1)];
        break;
      }
    }
    if (command == null && install != null) {
      final installed = await installOnce(
        key: id,
        existing: () {
          for (final candidate in commandCandidates) {
            final bin = _installedBinary(candidate.first);
            if (bin != null) return bin;
          }
          return null;
        },
        install: install!,
      );
      if (installed != null) {
        command = [installed, ...commandCandidates.last.skip(1)];
      }
    }
    if (command == null) return null;

    final String projectRoot;
    if (rootMarkers.isEmpty) {
      projectRoot = root;
    } else {
      final found = await findUp(
        markers: rootMarkers,
        start: file,
        stop: root,
      );
      // Fallback to the session root when no marker is found —
      // matches OpenCode's NearestRoot fallback to the instance
      // directory.
      projectRoot = found ?? root;
    }

    return LspServerSpec(
      root: projectRoot,
      command: command,
      env: const {},
      initialization: initializationOptions,
    );
  }

  /// A binary previously installed into Crux's tool dir.
  String? _installedBinary(String name) {
    for (final candidate in [exeName(name), name]) {
      final path = p.join(lspBinDir(), candidate);
      if (File(path).existsSync()) return path;
    }
    return npmInstalled(name);
  }
}
