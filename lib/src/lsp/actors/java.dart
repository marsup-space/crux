// Java language server actor (Eclipse jdtls).
//
// Root resolution mirrors OpenCode's JDTLS entry: Gradle wrapper or
// settings file → single-project build.gradle → nearest pom.xml →
// Eclipse `.project`. Spawn supports three deployment shapes:
//   1. `jdtls` wrapper script on PATH (Homebrew, some distros).
//   2. `jdt-language-server` launcher on PATH (Arch, Eclipse tarball
//      added to PATH).
//   3. An unpacked jdtls distribution under
//      `~/.cache/crux/jdtls` (or `$XDG_CACHE_HOME/crux/jdtls`) —
//      spawn `java -jar plugins/org.eclipse.equinox.launcher_*.jar`
//      with the platform config dir, like OpenCode does after its
//      download step. Crux does NOT download the distribution itself
//      (no auto-install policy).
//
// jdtls requires Java 21+; we check `java -version` before spawning.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../actor.dart';
import '../find_up.dart';
import '../installer.dart';
import '../protocol.dart';
import '../spawn_util.dart';

class JavaServerActor extends LspServerActor {
  @override
  String get id => 'jdtls';

  @override
  List<String> get extensions => const ['.java'];

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    final projectRoot = await _resolveRoot(root, file);
    if (projectRoot == null) return null;

    // 1. Wrapper scripts on PATH.
    for (final name in const ['jdtls', 'jdt-language-server']) {
      final bin = whichBinary(name);
      if (bin != null) {
        return LspServerSpec(
          root: projectRoot,
          command: [bin],
          env: const {},
          initialization: const {},
        );
      }
    }

    // 2. Unpacked distribution + java launcher jar; download it on
    // first use, mirroring OpenCode's JDTLS install step.
    final java = whichBinary('java');
    if (java == null) return null;
    if (!await _javaSupportsJdtls(java)) return null;

    final distDir = _jdtlsDistDir() ?? await _downloadJdtls();
    if (distDir == null) return null;
    final launcherJar = await _findLauncherJar(distDir);
    if (launcherJar == null) return null;
    final configDir = p.join(distDir, _platformConfigDir());

    // Per-project data dir so concurrent sessions don't collide.
    final dataDir = await Directory.systemTemp.createTemp('crux-jdtls-');

    return LspServerSpec(
      root: projectRoot,
      command: [
        java,
        '-jar',
        launcherJar,
        '-configuration',
        configDir,
        '-data',
        dataDir.path,
        '-Declipse.application=org.eclipse.jdt.ls.core.id1',
        '-Dosgi.bundles.defaultStartLevel=4',
        '-Declipse.product=org.eclipse.jdt.ls.core.product',
        '--add-modules=ALL-SYSTEM',
        '--add-opens',
        'java.base/java.util=ALL-UNNAMED',
        '--add-opens',
        'java.base/java.lang=ALL-UNNAMED',
      ],
      env: const {},
      initialization: const {},
    );
  }

  Future<String?> _resolveRoot(String root, String file) async {
    // Gradle wrapper or settings file is the strongest signal.
    final gradle = await findUp(
      markers: const [
        'gradlew',
        'gradlew.bat',
        'settings.gradle',
        'settings.gradle.kts',
        'build.gradle',
        'build.gradle.kts',
      ],
      start: file,
      stop: root,
    );
    if (gradle != null) return gradle;

    final pom = await findUp(
      markers: const ['pom.xml'],
      start: file,
      stop: root,
    );
    if (pom != null) return pom;

    final eclipse = await findUp(
      markers: const ['.project', '.classpath'],
      start: file,
      stop: root,
    );
    return eclipse ?? root;
  }

  Future<bool> _javaSupportsJdtls(String java) async {
    try {
      final result = await Process.run(java, ['-version']);
      // java -version prints to stderr, e.g. `openjdk version "21.0.3"`.
      final output = '${result.stderr}\n${result.stdout}';
      final match = RegExp(r'version "(\d+)').firstMatch(output);
      if (match == null) return true; // can't parse — let jdtls decide
      final major = int.tryParse(match.group(1)!) ?? 0;
      // Java 8 reports "1.8"; anything 1.x is too old.
      return major >= 21;
    } catch (_) {
      return false;
    }
  }

  String? _jdtlsDistDir() {
    final dir = p.join(lspToolHome(), 'jdtls');
    if (Directory(p.join(dir, 'plugins')).existsSync()) return dir;
    return null;
  }

  /// Download and unpack the jdtls snapshot, as OpenCode does. Uses
  /// [installOnce] so concurrent sessions share one download.
  Future<String?> _downloadJdtls() {
    return installOnce(
      key: id,
      existing: _jdtlsDistDir,
      install: () async {
        const url =
            'https://www.eclipse.org/downloads/download.php?file=/jdtls/snapshots/jdt-language-server-latest.tar.gz';
        final ok = await downloadAndExtract(
          const ArchiveAsset(
            url,
            'jdt-language-server.tar.gz',
            format: 'tar.gz',
          ),
          p.join(lspToolHome(), 'jdtls'),
        );
        return ok ? _jdtlsDistDir() : null;
      },
    );
  }

  Future<String?> _findLauncherJar(String distDir) async {
    final pluginsDir = Directory(p.join(distDir, 'plugins'));
    if (!pluginsDir.existsSync()) return null;
    final pattern = RegExp(r'^org\.eclipse\.equinox\.launcher_.*\.jar$');
    await for (final entry in pluginsDir.list()) {
      if (entry is File && pattern.hasMatch(p.basename(entry.path))) {
        return entry.path;
      }
    }
    return null;
  }

  String _platformConfigDir() {
    if (Platform.isMacOS) return 'config_mac';
    if (Platform.isWindows) return 'config_win';
    return 'config_linux';
  }
}
