import 'dart:io';

const _usage = '''
Usage: dart run tool/prepare_release.dart <version> [--tag]

Examples:
  dart run tool/prepare_release.dart 0.7.1
  dart run tool/prepare_release.dart v0.7.1 --tag

This updates the version in:
  - pubspec.yaml            (single source of truth)
  - lib/src/version.dart    (generated from pubspec.yaml)
  - README.md / README.zh-CN.md install commands
  - install.sh examples and install.ps1's default version

The compiled `crux --version` output reads from the
generated `lib/src/version.dart`, so the runtime version
cannot drift from what `pub` reports. The `v` prefix is
added at the print site in `bin/crux.dart` — the generated
constant stays a plain semver string.

With --tag, it also creates the matching annotated git tag, for example
v0.7.1 (`git tag -a v0.7.1 -m "Release v0.7.1"`).
Push the commit and tag to trigger GitHub release packaging:
  git push origin main
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
  final pubspec = File('${root.path}/pubspec.yaml');
  final versionDart = File('${root.path}/lib/src/version.dart');
  final readmes = [
    File('${root.path}/README.md'),
    File('${root.path}/README.zh-CN.md'),
  ];
  final installSh = File('${root.path}/install.sh');
  final installPs1 = File('${root.path}/install.ps1');

  _replace(pubspec, [
    (RegExp(r'^version:\s+.+$', multiLine: true), 'version: $version'),
  ]);
  // Regenerate the compile-time version constant from the
  // same value we just wrote into pubspec.yaml. The `v` prefix
  // is a presentation concern that lives in the print site
  // (see bin/crux.dart), so this file stays a plain semver
  // string — matching what pubspec.yaml declares, so `pub`
  // and `crux --version` can never disagree.
  versionDart.writeAsStringSync(_versionDartContents(version));
  for (final readme in readmes) {
    _replace(readme, [
      (
        RegExp(
          r'raw\.githubusercontent\.com/marsup-space/crux/v[0-9A-Za-z.+-]+/install\.sh',
        ),
        'raw.githubusercontent.com/marsup-space/crux/$tag/install.sh',
      ),
      (RegExp(r'--version v[0-9A-Za-z.+-]+'), '--version $tag'),
      (RegExp(r'-Version [0-9A-Za-z.+-]+'), '-Version $version'),
    ]);
    // The narrative "Current version" / "当前版本" lines in
    // the README are documentation, not code — they describe
    // the project state for a human reader. The `CRUX_VERSION`
    // example IS code (it's what users put in their CI env),
    // so it must stay in sync with the tag, which is `v`-prefixed.
    _replace(readme, [
      (RegExp(r'CRUX_VERSION=v[0-9A-Za-z.+-]+'), 'CRUX_VERSION=$tag'),
    ], requireAll: false);
  }
  _replace(installSh, [
    (RegExp(r'--version v[0-9A-Za-z.+-]+'), '--version $tag'),
    (RegExp(r'\(e\.g\.?[,]? v[0-9A-Za-z.+-]+\)'), '(e.g. $tag)'),
  ]);
  _replace(installPs1, [
    (RegExp(r'-Version [0-9A-Za-z.+-]+'), '-Version $version'),
    (
      RegExp(r"\[string\]\$Version = '[0-9A-Za-z.+-]+'"),
      "[string]\$Version = '$version'",
    ),
  ]);

  stdout.writeln('Prepared Crux $tag.');

  if (createTag) {
    // Convention: annotated tags only — lightweight tags break the
    // release-notes tooling expectations (see .agents/skills/crux-release).
    _run('git', ['tag', '-a', tag, '-m', 'Release $tag'], root);
    stdout.writeln('Created annotated git tag $tag.');
  }

  stdout.writeln('');
  stdout.writeln('Next steps:');
  stdout.writeln(
    '  git diff -- pubspec.yaml lib/src/version.dart README*.md install.sh install.ps1',
  );
  stdout.writeln(
    '  git add pubspec.yaml lib/src/version.dart README.md README.zh-CN.md install.sh install.ps1',
  );
  stdout.writeln('  git commit -m "Release $tag"');
  if (!createTag) {
    stdout.writeln('  git tag -a $tag -m "Release $tag"');
  }
  stdout.writeln('  git push origin main');
  stdout.writeln('  git push origin $tag');
}

String _versionDartContents(String version) {
  // Indentation: 2 spaces, matching the rest of lib/src/.
  // The header comment must stay short — it lives at the
  // top of every grep result for this file and shows up
  // in every PR that touches the version.
  return '''// GENERATED FILE — do not edit by hand.
//
// The single source of truth for the Crux version is
// `pubspec.yaml` (`version: X.Y.Z`). This file is
// regenerated from it by `tool/prepare_release.dart` on
// every release, so the compiled `crux --version` output
// can never drift away from what `pub` reports.
//
// Edit `pubspec.yaml` and re-run
// `dart run tool/prepare_release.dart <new-version>` to
// regenerate. The `v` prefix is added at the print site
// in `bin/crux.dart`, so this constant stays a plain
// semver string (matching what `pubspec.yaml` declares).

const String kCruxVersion = '$version';
''';
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
