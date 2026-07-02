import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:crux/src/utils/bundled_executable.dart';

const _targetSettings = <String, ({String os})>{
  'macos-arm64': (os: 'macos'),
  'macos-x64': (os: 'macos'),
  'linux-arm64': (os: 'linux'),
  'linux-x64': (os: 'linux'),
  'windows-arm64': (os: 'windows'),
  'windows-x64': (os: 'windows'),
};

Future<void> main(List<String> args) async {
  var target = currentRuntimeTarget();
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--target':
        target = args[++i];
      case '--help':
      case '-h':
        _usage();
        return;
      default:
        stderr.writeln('Unknown argument: ${args[i]}');
        _usage();
        exitCode = 64;
        return;
    }
  }

  final settings = _targetSettings[target];
  if (settings == null) {
    stderr.writeln('Unsupported target: $target');
    _usage();
    exitCode = 64;
    return;
  }
  final runtimeTarget = currentRuntimeTarget();
  if (target != runtimeTarget) {
    stderr.writeln(
      'dart build cli builds for the current runtime only: $runtimeTarget.',
    );
    stderr.writeln('Run this target on a compatible host to build $target.');
    exitCode = 64;
    return;
  }

  final root = p.normalize(
    p.join(p.dirname(Platform.script.toFilePath()), '..'),
  );
  await _run(Platform.resolvedExecutable, [
    'run',
    'tool/third_party.dart',
    'fetch',
    '--target',
    target,
  ], root);

  // Copy the libcrux_grammars dylib out of the semble-dart submodule so
  // the existing `third_party/bin/<target>/` → bundle copy picks it up
  // alongside ripgrep. The dylib is a build product of
  // `semble-dart/tool/build_native.dart` — submodule ships a prebuilt
  // copy at `<submodule>/third_party/bin/<target>/libcrux_grammars.<ext>`,
  // so a fresh clone only needs the submodule init, not a full rebuild.
  await _ensureLibcruxGrammars(root: root, target: target);

  final bundle = Directory(p.join(root, 'build', 'releases', 'crux-$target'));
  if (bundle.existsSync()) await bundle.delete(recursive: true);
  await bundle.create(recursive: true);

  final cliOutput = Directory(p.join(root, 'build', 'cli', target));
  if (cliOutput.existsSync()) await cliOutput.delete(recursive: true);
  await _run(Platform.resolvedExecutable, [
    'build',
    'cli',
    '--target',
    'bin/crux.dart',
    '-o',
    cliOutput.path,
    '--verbosity',
    'warning',
  ], root);

  await _copyDirectory(Directory(p.join(cliOutput.path, 'bundle')), bundle);
  final executable = File(
    p.join(bundle.path, 'bin', settings.os == 'windows' ? 'crux.exe' : 'crux'),
  );
  if (!await executable.exists()) {
    stderr.writeln('Missing dart build cli executable: ${executable.path}');
    exit(1);
  }
  if (settings.os != 'windows') {
    await _run('chmod', ['+x', executable.path], root);
  }

  await cliOutput.delete(recursive: true);

  await _copyDirectory(
    Directory(p.join(root, 'providers')),
    Directory(p.join(bundle.path, 'providers')),
  );
  await _copyDirectory(
    Directory(p.join(root, 'themes')),
    Directory(p.join(bundle.path, 'themes')),
  );
  await _copyDirectory(
    Directory(p.join(root, 'third_party', 'bin', target)),
    Directory(p.join(bundle.path, 'third_party', 'bin')),
  );
  await _copyDirectory(
    Directory(p.join(root, 'third_party', 'licenses')),
    Directory(p.join(bundle.path, 'third_party', 'licenses')),
  );
  // Copy manifest.toml (preferred format); JSON kept for backward compat.
  for (final manifestName in ['manifest.toml', 'manifest.json']) {
    final source = File(p.join(root, 'third_party', manifestName));
    if (await source.exists()) {
      await source.copy(p.join(bundle.path, 'third_party', manifestName));
    }
  }

  stdout.writeln('Release bundle: ${bundle.path}');
}

Future<void> _run(
  String executable,
  List<String> arguments,
  String workingDirectory, {
  String? failureHint,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  final result = await process.exitCode;
  if (result != 0) {
    if (failureHint != null) {
      stderr.writeln();
      stderr.writeln(failureHint);
    }
    exit(result);
  }
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final targetPath = p.join(destination.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(targetPath));
    } else if (entity is File) {
      await entity.copy(targetPath);
    }
  }
}

const _libExtension = <String, String>{
  'macos-arm64': 'dylib',
  'macos-x64': 'dylib',
  'linux-arm64': 'so',
  'linux-x64': 'so',
  'windows-arm64': 'dll',
  'windows-x64': 'dll',
};

/// Copy the prebuilt `libcrux_grammars.<ext>` from the
/// `semble-dart` submodule into the main repo's
/// `third_party/bin/<target>/` so the bundle assembly picks it up.
Future<void> _ensureLibcruxGrammars({
  required String root,
  required String target,
}) async {
  final ext = _libExtension[target];
  if (ext == null) {
    stderr.writeln(
      'libcrux_grammars: unknown target $target — skipping dylib bundle',
    );
    return;
  }
  final fileName = 'libcrux_grammars.$ext';
  final sourcePath = p.join(
    root,
    'semble-dart',
    'third_party',
    'bin',
    target,
    fileName,
  );
  final destDir = Directory(p.join(root, 'third_party', 'bin', target));
  await destDir.create(recursive: true);
  final destPath = p.join(destDir.path, fileName);

  final source = File(sourcePath);
  if (!await source.exists()) {
    stderr.writeln(
      '✖ libcrux_grammars: dylib not found at $sourcePath\n'
      '  Build one with:\n'
      '    cd semble-dart && dart run tool/build_native.dart --target $target',
    );
    exit(1);
  }

  // Delete any existing file/link at the destination so the copy
  // always produces a regular file — _copyDirectory skips symlinks
  // (followLinks: false), so a leftover symlink would silently drop
  // the dylib from the release bundle.
  final dest = File(destPath);
  if (await dest.exists()) await dest.delete();
  await source.copy(destPath);
  // Copy resolves symlinks — the destination is a regular file, not
  // a symlink, so the bundle's _copyDirectory below picks it up.
  stdout.writeln('  ✔ libcrux_grammars: $sourcePath → $destPath');
}

void _usage() {
  stdout.writeln(
    'Usage: dart run tool/build_release.dart '
    '[--target ${_targetSettings.keys.join('|')}]',
  );
}
