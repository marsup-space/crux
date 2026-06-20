import 'dart:io';

const _usage = '''
Usage: dart run tool/prepare_release.dart <version> [--tag]

Examples:
  dart run tool/prepare_release.dart 0.7.1
  dart run tool/prepare_release.dart v0.7.1 --tag

This updates the version in:
  - pubspec.yaml
  - bin/crux.dart
  - README.md, when matching version text exists

With --tag, it also creates the matching git tag, for example v0.7.1.
Push the commit and tag to trigger GitHub release packaging:
  git push origin master
  git push origin v0.7.1
''';

void main(List<String> args) {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    stdout.write(_usage);
    return;
  }

  final positional = [...args];
  final createTag = positional.remove('--tag');
  if (positional.length != 1) {
    stderr.write(_usage);
    exitCode = 64;
    return;
  }

  final version = _normalizeVersion(positional.single);
  if (version == null) {
    stderr.writeln('Invalid version: ${positional.single}');
    stderr.writeln('Expected a semver version like 0.7.1 or v0.7.1.');
    exitCode = 64;
    return;
  }

  final tag = 'v$version';
  final root = _repoRoot();
  final files = [
    File('${root.path}/pubspec.yaml'),
    File('${root.path}/bin/crux.dart'),
    File('${root.path}/README.md'),
  ];

  _replace(files[0], [
    (RegExp(r'^version:\s+.+$', multiLine: true), 'version: $version'),
  ]);
  _replace(files[1], [
    (
      RegExp(r"^const _version = 'v[^']+';$", multiLine: true),
      "const _version = '$tag';",
    ),
  ]);
  _replace(files[2], [
    (RegExp(r'当前版本：\*\*[^*]+\*\*'), '当前版本：**$version**'),
    (
      RegExp(r'Current version: \*\*[^*]+\*\*'),
      'Current version: **$version**',
    ),
    (RegExp(r'CRUX_VERSION=v[0-9A-Za-z.+-]+'), 'CRUX_VERSION=$tag'),
  ], requireAll: false);

  stdout.writeln('Prepared Crux $tag.');

  if (createTag) {
    _run('git', ['tag', tag], root);
    stdout.writeln('Created git tag $tag.');
  }

  stdout.writeln('');
  stdout.writeln('Next steps:');
  stdout.writeln('  git diff -- pubspec.yaml bin/crux.dart README.md');
  stdout.writeln('  git add pubspec.yaml bin/crux.dart README.md');
  stdout.writeln('  git commit -m "Release $tag"');
  if (!createTag) {
    stdout.writeln('  git tag $tag');
  }
  stdout.writeln('  git push origin master');
  stdout.writeln('  git push origin $tag');
}

String? _normalizeVersion(String input) {
  final raw = input.startsWith('v') ? input.substring(1) : input;
  final semver = RegExp(
    r'^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
  );
  return semver.hasMatch(raw) ? raw : null;
}

Directory _repoRoot() {
  final script = Platform.script.toFilePath();
  return Directory(File(script).parent.parent.path);
}

void _replace(
  File file,
  List<(RegExp pattern, String replacement)> replacements, {
  bool requireAll = true,
}) {
  var text = file.readAsStringSync();
  for (final replacement in replacements) {
    final (pattern, value) = replacement;
    if (!pattern.hasMatch(text)) {
      if (requireAll) {
        stderr.writeln('Could not find version pattern in ${file.path}.');
        exit(1);
      }
      continue;
    }
    text = text.replaceAll(pattern, value);
  }
  file.writeAsStringSync(text);
}

void _run(String executable, List<String> args, Directory workingDirectory) {
  final result = Process.runSync(
    executable,
    args,
    workingDirectory: workingDirectory.path,
    runInShell: true,
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    exit(result.exitCode);
  }
}
