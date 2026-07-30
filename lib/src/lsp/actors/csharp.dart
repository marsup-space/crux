// C# language server actor (Roslyn).
//
// Mirrors OpenCode's CSharp entry minus the auto-install: looks for
// `roslyn-language-server` on PATH, then in the dotnet global tools
// directory (`~/.dotnet/tools`). Walks above the session root for a
// `.sln` — solutions commonly live one level above a per-project repo.
// Root falls back to the nearest `.csproj` directory, else the
// session root.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../actor.dart';
import '../find_up.dart';
import '../installer.dart';
import '../protocol.dart';
import '../spawn_util.dart';

class CSharpServerActor extends LspServerActor {
  @override
  String get id => 'csharp';

  @override
  List<String> get extensions => const ['.cs', '.csx'];

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    var bin = _findBinary();
    bin ??= await installOnce(
      key: id,
      existing: _findBinary,
      install: _installRoslyn,
    );
    if (bin == null) return null;

    // Prefer a solution root even if it's above the session root —
    // Roslyn needs the whole solution to resolve project references.
    var projectRoot = await findUp(
      markers: const ['.sln', '.slnx'],
      start: file,
      stop: p.dirname(p.normalize(p.absolute(root))),
    );
    projectRoot ??= await findUp(
      markers: const ['.csproj', 'global.json'],
      start: file,
      stop: root,
    );

    return LspServerSpec(
      root: projectRoot ?? root,
      command: [bin, '--stdio', '--autoLoadProjects'],
      env: const {},
      initialization: const {},
    );
  }

  String? _findBinary() {
    final onPath = whichBinary('roslyn-language-server');
    if (onPath != null) return onPath;
    final home =
        Platform.environment['DOTNET_CLI_HOME'] ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'];
    if (home == null) return null;
    final ext = Platform.isWindows ? '.exe' : '';
    for (final candidate in [
      p.join(home, '.dotnet', 'tools', 'roslyn-language-server$ext'),
      p.join(lspBinDir(), 'roslyn-language-server$ext'),
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// `dotnet tool install`, as in OpenCode's roslyn install step.
  Future<String?> _installRoslyn() async {
    final dotnet = whichBinary('dotnet');
    if (dotnet == null) return null;
    try {
      final result = await Process.run(dotnet, [
        'tool',
        'install',
        'roslyn-language-server',
        '--tool-path',
        lspBinDir(),
        '--prerelease',
      ]).timeout(const Duration(minutes: 3));
      if (result.exitCode != 0) return null;
    } catch (_) {
      return null;
    }
    return _findBinary();
  }
}
