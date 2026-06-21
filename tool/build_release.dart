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

void _usage() {
  stdout.writeln(
    'Usage: dart run tool/build_release.dart '
    '[--target ${_targetSettings.keys.join('|')}]',
  );
}
