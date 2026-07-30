// Python language server actor (pyright).
//
// Mirrors OpenCode's Pyright entry: prefer `pyright-langserver` on
// PATH, detect a project venv (`$VIRTUAL_ENV`, `.venv/`, `venv/`) and
// pass its interpreter via `pythonPath` so the server resolves
// third-party packages installed in the venv. No auto-install.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../actor.dart';
import '../find_up.dart';
import '../installer.dart';
import '../protocol.dart';
import '../spawn_util.dart';

class PythonServerActor extends LspServerActor {
  @override
  String get id => 'pyright';

  @override
  List<String> get extensions => const ['.py', '.pyi'];

  static const _rootMarkers = [
    'pyproject.toml',
    'setup.py',
    'setup.cfg',
    'requirements.txt',
    'Pipfile',
    'pyrightconfig.json',
  ];

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    var bin =
        whichBinary('pyright-langserver') ?? npmInstalled('pyright-langserver');
    if (bin == null) {
      bin = await installOnce(
        key: id,
        existing: () => npmInstalled('pyright-langserver'),
        install: () => npmInstall('pyright', 'pyright-langserver'),
      );
      if (bin == null) return null;
    }

    final projectRoot = await findUpOrStop(
      markers: _rootMarkers,
      start: file,
      stop: root,
    );

    // Venv detection, same candidate list as OpenCode: active
    // $VIRTUAL_ENV first, then `.venv` / `venv` next to the root.
    final candidates = <String>[
      if (Platform.environment['VIRTUAL_ENV'] != null)
        Platform.environment['VIRTUAL_ENV']!,
      p.join(projectRoot, '.venv'),
      p.join(projectRoot, 'venv'),
    ];
    final initialization = <String, dynamic>{};
    for (final venv in candidates) {
      final pythonPath = Platform.isWindows
          ? p.join(venv, 'Scripts', 'python.exe')
          : p.join(venv, 'bin', 'python');
      if (File(pythonPath).existsSync()) {
        initialization['pythonPath'] = pythonPath;
        break;
      }
    }

    return LspServerSpec(
      root: projectRoot,
      command: [bin, '--stdio'],
      env: const {},
      initialization: initialization,
    );
  }
}
