// Rust language server actor (rust-analyzer).
//
// Mirrors OpenCode's RustAnalyzer root logic: find the nearest
// Cargo.toml, then keep walking up while parent Cargo.tomls declare a
// `[workspace]` — the workspace root gives rust-analyzer full
// cross-crate resolution. No auto-install: rust-analyzer ships with
// rustup (`rustup component add rust-analyzer`).

import 'dart:io';

import 'package:path/path.dart' as p;

import '../actor.dart';
import '../find_up.dart';
import '../protocol.dart';
import '../spawn_util.dart';

class RustServerActor extends LspServerActor {
  @override
  String get id => 'rust';

  @override
  List<String> get extensions => const ['.rs'];

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    final bin = whichBinary('rust-analyzer');
    if (bin == null) return null;

    final crateRoot = await findUp(
      markers: const ['Cargo.toml', 'Cargo.lock'],
      start: file,
      stop: root,
    );
    var projectRoot = crateRoot ?? root;

    // Walk up to the enclosing workspace root, if any.
    var dir = projectRoot;
    final stopNorm = p.normalize(p.absolute(root));
    while (true) {
      final parent = p.dirname(dir);
      if (parent == dir) break; // filesystem root
      if (!p.isWithin(stopNorm, parent) && parent != stopNorm) break;
      final cargoToml = File(p.join(parent, 'Cargo.toml'));
      if (!cargoToml.existsSync()) break;
      String content;
      try {
        content = await cargoToml.readAsString();
      } catch (_) {
        break;
      }
      if (content.contains('[workspace]')) {
        projectRoot = parent;
        dir = parent;
      } else {
        break;
      }
    }

    return LspServerSpec(
      root: projectRoot,
      command: [bin],
      env: const {},
      initialization: const {},
    );
  }
}
