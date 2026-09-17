import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'bundled_directory.dart' show PackageUriResolver;
import 'user_data_directory.dart';

String currentRuntimeTarget({Abi? abi}) {
  return switch (abi ?? Abi.current()) {
    Abi.macosArm64 => 'macos-arm64',
    Abi.macosX64 => 'macos-x64',
    Abi.linuxArm64 => 'linux-arm64',
    Abi.linuxX64 => 'linux-x64',
    Abi.windowsArm64 => 'windows-arm64',
    Abi.windowsX64 => 'windows-x64',
    final unsupported => throw UnsupportedError(
      'Unsupported platform ABI for bundled executables: $unsupported',
    ),
  };
}

/// The targets `.github/workflows/release.yml` actually publishes.
///
/// This is the single Dart-side home for that fact. Three consumers have to
/// agree on it — `/upgrade`, `install.sh`, and the local release builder — and
/// each used to carry its own copy, which is how one of them ends up listing a
/// platform no asset exists for.
///
/// Deliberately narrower than [currentRuntimeTarget], which answers "what
/// machine is this". This answers "what do we ship": a builder can still produce
/// a local bundle for a target outside this set (see `tool/build_release.dart`),
/// but it cannot be distributed or installed.
const Set<String> kPublishedCruxTargets = {
  'macos-arm64',
  'linux-x64',
  'windows-x64',
};

Future<String> resolveBundledExecutable(
  String executableName, {
  String? executablePath,
  Uri? scriptUri,
  String? launchDirectory,
  String? runtimeTarget,
  String? thirdPartyBinOverride,
  PackageUriResolver packageUriResolver = Isolate.resolvePackageUri,
}) async {
  final target = runtimeTarget ?? currentRuntimeTarget();
  final roots = await _candidateBinRoots(
    executablePath: executablePath,
    scriptUri: scriptUri,
    launchDirectory: launchDirectory,
    thirdPartyBinOverride: thirdPartyBinOverride,
    packageUriResolver: packageUriResolver,
  );

  for (final root in roots) {
    for (final path in [
      p.join(root.path, target, executableName),
      p.join(root.path, executableName),
    ]) {
      if (File(path).existsSync()) return p.normalize(p.absolute(path));
    }
  }

  return executableName;
}

Future<Directory?> resolveBundledBinDirectory({
  String? executablePath,
  Uri? scriptUri,
  String? launchDirectory,
  String? runtimeTarget,
  String? thirdPartyBinOverride,
  PackageUriResolver packageUriResolver = Isolate.resolvePackageUri,
}) async {
  final target = runtimeTarget ?? currentRuntimeTarget();
  final roots = await _candidateBinRoots(
    executablePath: executablePath,
    scriptUri: scriptUri,
    launchDirectory: launchDirectory,
    thirdPartyBinOverride: thirdPartyBinOverride,
    packageUriResolver: packageUriResolver,
  );

  for (final root in roots) {
    final targetDirectory = Directory(p.join(root.path, target));
    if (targetDirectory.existsSync()) return targetDirectory;
    if (root.existsSync()) return root;
  }
  return null;
}

Future<List<Directory>> _candidateBinRoots({
  required String? executablePath,
  required Uri? scriptUri,
  required String? launchDirectory,
  required String? thirdPartyBinOverride,
  required PackageUriResolver packageUriResolver,
}) async {
  final candidates = <Directory>[];

  void addCandidate(String path) {
    final normalized = p.normalize(p.absolute(path));
    if (candidates.any((directory) => directory.path == normalized)) return;
    candidates.add(Directory(normalized));
  }

  // First-run setup downloads missing tools here when a release directory is
  // read-only. Keep it in the normal resolver path for every tool call.
  addCandidate(p.join(resolveUserDataDirectory(), 'bin'));

  final override =
      thirdPartyBinOverride ?? Platform.environment['CRUX_THIRD_PARTY_BIN'];
  if (override != null && override.isNotEmpty) addCandidate(override);

  try {
    addCandidate(
      p.join(
        p.dirname(executablePath ?? Platform.resolvedExecutable),
        'third_party',
        'bin',
      ),
    );
  } catch (_) {}

  try {
    final script = scriptUri ?? Platform.script;
    if (script.scheme == 'file') {
      final scriptDirectory = p.dirname(script.toFilePath());
      addCandidate(p.join(scriptDirectory, 'third_party', 'bin'));
      addCandidate(p.join(scriptDirectory, '..', 'third_party', 'bin'));
    }
  } catch (_) {}

  try {
    final packageUri = await packageUriResolver(
      Uri.parse('package:crux/crux.dart'),
    );
    if (packageUri?.scheme == 'file') {
      addCandidate(
        p.join(p.dirname(packageUri!.toFilePath()), '..', 'third_party', 'bin'),
      );
    }
  } catch (_) {}

  addCandidate(
    p.join(launchDirectory ?? Directory.current.path, 'third_party', 'bin'),
  );
  return candidates;
}
