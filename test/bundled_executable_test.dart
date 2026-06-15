import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/utils/bundled_executable.dart';

void main() {
  group('resolveBundledExecutable', () {
    test('finds the flattened executable beside a release binary', () async {
      final root = await Directory.systemTemp.createTemp('crux_release_');
      addTearDown(() => root.delete(recursive: true));
      final bundled = File(p.join(root.path, 'third_party', 'bin', 'rg'));
      await bundled.create(recursive: true);

      final resolved = await resolveBundledExecutable(
        'rg',
        executablePath: p.join(root.path, 'crux'),
        scriptUri: Uri.file(p.join(root.path, 'other', 'crux.dart')),
        launchDirectory: p.join(root.path, 'other'),
        runtimeTarget: 'linux-x64',
        packageUriResolver: (_) async => null,
      );

      expect(p.equals(resolved, bundled.path), isTrue);
    });

    test('finds a target-specific executable in a source checkout', () async {
      final root = await Directory.systemTemp.createTemp('crux_source_');
      addTearDown(() => root.delete(recursive: true));
      final bundled = File(
        p.join(root.path, 'third_party', 'bin', 'windows-arm64', 'rg.exe'),
      );
      await bundled.create(recursive: true);

      final resolved = await resolveBundledExecutable(
        'rg.exe',
        executablePath: p.join(root.path, 'elsewhere', 'dart'),
        scriptUri: Uri.file(p.join(root.path, 'elsewhere', 'crux.dart')),
        launchDirectory: p.join(root.path, 'elsewhere'),
        runtimeTarget: 'windows-arm64',
        packageUriResolver: (_) async =>
            Uri.file(p.join(root.path, 'lib', 'crux.dart')),
      );

      expect(p.equals(resolved, bundled.path), isTrue);
    });

    test('falls back to PATH when no bundled executable exists', () async {
      final root = await Directory.systemTemp.createTemp('crux_missing_');
      addTearDown(() => root.delete(recursive: true));

      final resolved = await resolveBundledExecutable(
        'rg',
        executablePath: p.join(root.path, 'dart'),
        scriptUri: Uri.file(p.join(root.path, 'crux.dart')),
        launchDirectory: root.path,
        runtimeTarget: 'linux-x64',
        packageUriResolver: (_) async => null,
      );

      expect(resolved, 'rg');
    });
  });
}
