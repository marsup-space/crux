import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crux/src/utils/bundled_executable.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:toml/toml.dart';

/// Pins the one fact several artifacts have to agree on: which platforms a
/// release actually ships.
///
/// It used to live in four places — [kPublishedCruxTargets], the workflow
/// matrix, the shell installer's gate, and the local release builder — and they
/// had already drifted: the matrix listed three targets while a comment beside
/// it said "all 5 matrix targets". Adding or dropping a platform means editing
/// all of them, and this test is what says so.
void main() {
  late Directory root;

  setUpAll(() async {
    // Resolve the repository root from the package URI rather than the process
    // cwd: `dart test` runs suites concurrently, and one of them reassigns
    // `Directory.current`.
    final packageUri = await Isolate.resolvePackageUri(
      Uri.parse('package:crux/crux.dart'),
    );
    if (packageUri == null || packageUri.scheme != 'file') {
      fail('could not resolve package:crux to locate the repository root');
    }
    root = Directory(p.dirname(p.dirname(packageUri.toFilePath())));
  });

  test('the workflow matrix publishes exactly the published targets', () async {
    final workflow = await File(
      p.join(root.path, '.github', 'workflows', 'release.yml'),
    ).readAsString();
    final matrix = RegExp(
      r'^\s*-\s*target:\s*(\S+)\s*$',
      multiLine: true,
    ).allMatches(workflow).map((match) => match.group(1)!).toSet();

    expect(
      matrix,
      kPublishedCruxTargets,
      reason:
          'release.yml decides what actually exists on the release page, '
          'kPublishedCruxTargets decides what /upgrade and build_release accept',
    );
  });

  test('the shell installer gates on exactly the published targets', () async {
    final installer = await File(p.join(root.path, 'install.sh'))
        .readAsString();
    final declared = RegExp(
      r'^\s*published_targets="([^"]+)"',
      multiLine: true,
    ).firstMatch(installer);
    expect(
      declared,
      isNotNull,
      reason: 'install.sh must declare the published targets exactly once',
    );

    final gated = declared!
        .group(1)!
        .split(RegExp(r'\s+'))
        .where((entry) => entry.isNotEmpty)
        .toSet();

    expect(
      gated,
      kPublishedCruxTargets,
      reason:
          'the shell cannot import the Dart constant, so this test is the only '
          'thing keeping the two lists equal',
    );
    expect(
      installer,
      contains(r'*" ${os}-${arch} "*'),
      reason:
          'the gate must be driven by published_targets, or the declaration is '
          'decorative and the list has a second copy again',
    );
  });

  test('every published target has a bundled ripgrep to install', () async {
    final manifest = TomlDocument.parse(
      await File(p.join(root.path, 'third_party', 'manifest.toml'))
          .readAsString(),
    ).toMap();
    final targets =
        ((manifest['tools'] as Map)['ripgrep'] as Map)['targets'] as Map;

    for (final target in kPublishedCruxTargets) {
      expect(
        targets.containsKey(target),
        isTrue,
        reason:
            'a published target with no ripgrep entry ships a Crux whose '
            'semantic search cannot fetch its own dependency',
      );
    }
  });

  test('every published target is one the builder can name', () {
    final producible = <String>{};
    for (final abi in Abi.values) {
      try {
        producible.add(currentRuntimeTarget(abi: abi));
      } on UnsupportedError {
        // An ABI Crux does not build for at all.
      }
    }

    expect(
      producible,
      containsAll(kPublishedCruxTargets),
      reason:
          'a published target must be reachable from currentRuntimeTarget, or '
          'the release would publish an asset nothing can install',
    );
  });
}
