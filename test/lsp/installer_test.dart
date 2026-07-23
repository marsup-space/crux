// Tests for LSP auto-install infrastructure.

import 'dart:io';

import 'package:crux/src/lsp/installer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('crux-lsp-install-test-');
    debugSetLspToolHome(tmp.path);
  });

  tearDown(() async {
    debugSetLspToolHome(null);
    debugSetLspDownloadDisabled(null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('paths', () {
    test('lspToolHome honors CRUX_LSP_HOME', () {
      expect(lspToolHome(), tmp.path);
      expect(lspBinDir(), p.join(tmp.path, 'bin'));
    });
  });

  group('installOnce', () {
    test('returns existing binary without running install', () async {
      var installs = 0;
      final result = await installOnce(
        key: 'existing',
        existing: () => '/already/there',
        install: () async {
          installs++;
          return '/new';
        },
      );
      expect(result, '/already/there');
      expect(installs, 0);
    });

    test('coalesces concurrent installs', () async {
      var installs = 0;
      Future<String?> install() async {
        installs++;
        await Future.delayed(const Duration(milliseconds: 50));
        // Simulate the binary landing on disk.
        final bin = p.join(lspBinDir(), 'coalesced');
        await File(bin).create(recursive: true);
        return bin;
      }

      String? existing() {
        final bin = p.join(lspBinDir(), 'coalesced');
        return File(bin).existsSync() ? bin : null;
      }

      final results = await Future.wait([
        installOnce(key: 'coalesced', existing: existing, install: install),
        installOnce(key: 'coalesced', existing: existing, install: install),
        installOnce(key: 'coalesced', existing: existing, install: install),
      ]);
      expect(installs, 1);
      expect(results.toSet().length, 1);
      expect(results.first, isNotNull);
    });

    test('returns null when install fails', () async {
      final result = await installOnce(
        key: 'failing',
        existing: () => null,
        install: () async => throw StateError('boom'),
      );
      expect(result, isNull);
    });

    test('second call sees installed binary', () async {
      final bin = p.join(lspBinDir(), 'second');
      String? existing() => File(bin).existsSync() ? bin : null;

      final first = await installOnce(
        key: 'second',
        existing: existing,
        install: () async {
          await File(bin).create(recursive: true);
          return bin;
        },
      );
      expect(first, bin);

      var installs = 0;
      final second = await installOnce(
        key: 'second',
        existing: existing,
        install: () async {
          installs++;
          return bin;
        },
      );
      expect(second, bin);
      expect(installs, 0);
    });
  });

  group('platform helpers', () {
    test('currentArch returns a known value', () {
      expect(['arm64', 'x64'], contains(currentArch()));
    });

    test('currentPlatformToken matches the host', () {
      final token = currentPlatformToken();
      if (Platform.isMacOS) {
        expect(token, 'macos');
      } else if (Platform.isWindows) {
        expect(token, 'windows');
      } else {
        expect(token, 'linux');
      }
    });

    test('exeName appends .exe only on Windows', () {
      expect(exeName('zls'), Platform.isWindows ? 'zls.exe' : 'zls');
    });
  });

  group('download opt-out', () {
    test('lspDownloadDisabled reads the debug override', () {
      expect(lspDownloadDisabled, isFalse);
      debugSetLspDownloadDisabled(true);
      expect(lspDownloadDisabled, isTrue);
      debugSetLspDownloadDisabled(null);
      expect(lspDownloadDisabled, isFalse);
    });
  });
}
