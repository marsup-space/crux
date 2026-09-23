import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crux/src/services/upgrade_service.dart';
import 'package:crux/src/utils/github_release_transport.dart';
import 'package:crux/src/utils/system_proxy.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Builds a release-shaped zip in memory, so the whole upgrade flow runs
/// offline against real archive bytes rather than a stubbed decoder.
Uint8List releaseZip({
  required String cruxBody,
  String? daemonBody,
  bool includeCrux = true,
}) {
  final archive = Archive();
  void add(String name, String body) {
    final bytes = utf8.encode(body);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  // Mirrors the real bundle layout produced by tool/build_release.dart.
  if (includeCrux) add('crux-test-target/bin/crux', cruxBody);
  if (daemonBody != null) add('crux-test-target/bin/cruxd', daemonBody);
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// The install-side file name for [base] on the host: the service installs
/// `crux.exe` on Windows and `crux` elsewhere, so assertions must follow.
String hostBinary(String base) =>
    Platform.isWindows ? '$base.exe' : base;

void main() {
  group('version comparison', () {
    test('orders release versions numerically, not lexically', () {
      expect(compareVersions('1.2.0', '1.1.0'), 1);
      expect(compareVersions('1.10.0', '1.9.0'), 1);
      expect(compareVersions('1.1.0', '1.2.0'), -1);
      expect(compareVersions('1.2.0', '1.2.0'), 0);
    });

    test('tolerates a v prefix and missing segments', () {
      expect(normaliseVersion('v1.2.0'), '1.2.0');
      expect(normaliseVersion(' 1.2.0 '), '1.2.0');
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1.2', '1.2.1'), -1);
      // A nonsense tag must never look newer than a real version.
      expect(compareVersions('nightly', '0.0.1'), -1);
    });
  });

  group('release reference parsing', () {
    test('reads the tag out of a releases/latest redirect Location', () {
      expect(
        versionFromReleaseReference(
          'https://github.com/marsup-space/crux/releases/tag/v1.0.2',
        ),
        'v1.0.2',
      );
      expect(
        versionFromReleaseReference(
          'https://github.com/o/r/releases/tag/1.2.3',
        ),
        '1.2.3',
      );
    });

    test('reads the tag out of a release page a mirror returned', () {
      // Measured: gh-proxy mirrors answer `releases/latest` with the page
      // instead of a redirect (or refuse HTML entirely), so the same pattern
      // has to cover markup as well as a header.
      const page =
          '<html><head><link rel="canonical" '
          'href="https://github.com/marsup-space/crux/releases/tag/v1.0.2">'
          '</head><body>…</body></html>';
      expect(versionFromReleaseReference(page), 'v1.0.2');
    });

    test('returns null rather than guessing when there is no tag', () {
      expect(versionFromReleaseReference(null), isNull);
      expect(versionFromReleaseReference(''), isNull);
      expect(
        versionFromReleaseReference('https://github.com/o/r/releases'),
        isNull,
      );
      // A download-only mirror's refusal carries no tag and must read as a miss.
      expect(
        versionFromReleaseReference(
          'Web page content is not allowed. This service is for resource '
          'downloads only.',
        ),
        isNull,
      );
    });
  });

  group('github transport chain', () {
    tearDown(SystemProxyDetector.resetForTesting);

    test('uses the direct connection and stops there', () async {
      final tried = <String?>[];
      final result = await withGithubTransports<String>(
        url: 'https://github.com/o/r',
        mirrors: const ['https://mirror.test/'],
        attempt: (url, proxy) async {
          tried.add(proxy?.httpsUrl);
          return 'direct-ok';
        },
      );
      expect(result, 'direct-ok');
      expect(tried, [null], reason: 'a working direct path must not fan out');
    });

    test('falls back to the system proxy before any mirror', () async {
      SystemProxyDetector.overrideForTesting(
        const SystemProxy(httpsUrl: 'http://127.0.0.1:7897'),
      );
      final tried = <String>[];
      final result = await withGithubTransports<String>(
        url: 'https://github.com/o/r',
        mirrors: const ['https://mirror-a.test/'],
        attempt: (url, proxy) async {
          tried.add(proxy == null ? 'direct' : 'proxy:${proxy.httpsUrl}');
          if (tried.length < 3) throw const SocketException('blocked');
          return 'mirror-ok';
        },
      );
      expect(result, 'mirror-ok');
      expect(tried, [
        'direct',
        'proxy:http://127.0.0.1:7897',
        'direct',
      ], reason: 'the user-own proxy must be preferred over a third party');
    });

    test('stops at the first mirror that answers', () async {
      SystemProxyDetector.overrideForTesting(null);
      final tried = <String>[];
      final result = await withGithubTransports<String>(
        url: 'https://github.com/o/r/x.zip',
        mirrors: const ['https://a.test/', 'https://b.test/'],
        attempt: (url, proxy) async {
          tried.add(url);
          if (!url.contains('b.test')) throw const SocketException('blocked');
          return 'b-ok';
        },
      );
      expect(result, 'b-ok');
      expect(tried.last, 'https://b.test/https://github.com/o/r/x.zip');
    });

    test('mirror prefixes compose with or without a trailing slash', () {
      expect(
        mirrorUrl('https://gh-proxy.com/', 'https://github.com/o/r/x.zip'),
        'https://gh-proxy.com/https://github.com/o/r/x.zip',
      );
      expect(
        mirrorUrl('https://ghfast.top', 'https://github.com/o/r/x.zip'),
        'https://ghfast.top/https://github.com/o/r/x.zip',
      );
    });

    test('an empty mirror list disables the step', () async {
      SystemProxyDetector.overrideForTesting(null);
      var calls = 0;
      await expectLater(
        withGithubTransports<String>(
          url: 'https://github.com/o/r',
          mirrors: const [],
          attempt: (url, proxy) async {
            calls++;
            throw const SocketException('nope');
          },
        ),
        throwsA(isA<SocketException>()),
      );
      expect(calls, 1, reason: 'direct only, no mirrors to try');
    });

    test('a non-connection error is not retried elsewhere', () async {
      var calls = 0;
      await expectLater(
        withGithubTransports<String>(
          url: 'https://github.com/o/r',
          mirrors: const ['https://a.test/'],
          attempt: (url, proxy) async {
            calls++;
            throw const FormatException('bad payload');
          },
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        calls,
        1,
        reason:
            'a payload bug is not a transport problem; mirrors cannot fix it',
      );
    });

    test(
      'reports the last failure once every transport is exhausted',
      () async {
        SystemProxyDetector.overrideForTesting(null);
        await expectLater(
          withGithubTransports<String>(
            url: 'https://github.com/o/r',
            mirrors: const ['https://a.test/'],
            attempt: (url, proxy) async => throw const SocketException('nope'),
          ),
          throwsA(isA<SocketException>()),
        );
      },
    );
  });

  group('refusals', () {
    late Directory installDir;

    setUp(() async {
      installDir = await Directory.systemTemp.createTemp('crux_upgrade_');
    });
    tearDown(() async {
      if (await installDir.exists()) await installDir.delete(recursive: true);
    });

    UpgradeService service({
      bool isCompiled = true,
      String target = 'test-target',
      String? executable,
      Set<String> published = const {'test-target'},
      Future<String?> Function()? latest,
    }) => UpgradeService(
      currentVersion: '1.0.0',
      executablePath: executable ?? p.join(installDir.path, 'crux'),
      isCompiledBuild: isCompiled,
      target: target,
      publishedTargets: published,
      download: (_) async => throw StateError('download must not be reached'),
      fetchLatestVersion:
          latest ?? () async => throw StateError('check must not be reached'),
    );

    test('refuses to replace a JIT build and does no I/O at all', () async {
      // The dangerous case: under `dart run` the "executable" is the Dart SDK
      // binary, so an upgrade that proceeded would overwrite the toolchain.
      final result = await service(isCompiled: false).run();
      expect(result.status, UpgradeStatus.notAnInstalledBuild);
      expect(result.detail, isNull, reason: 'a dev build has no directory');
    });

    test('refuses a target the release workflow does not publish', () async {
      final result = await service(
        target: 'linux-arm64',
        published: const {'macos-arm64', 'linux-x64', 'windows-x64'},
      ).run();
      expect(result.status, UpgradeStatus.unsupportedPlatform);
      // The published list is passed through so the caller can name it.
      expect(result.detail, 'linux-x64, macos-arm64, windows-x64');
    });

    test(
      'reports a missing install directory rather than guessing one',
      () async {
        final result = await service(
          executable: p.join(installDir.path, 'gone', 'crux'),
        ).run();
        expect(result.status, UpgradeStatus.notAnInstalledBuild);
        expect(result.detail, contains('gone'));
      },
    );

    test(
      'reports an unreachable version check as failed, not as success',
      () async {
        final result = await service(latest: () async => null).run();
        expect(result.status, UpgradeStatus.failed);
      },
    );

    test('is a no-op when already on the latest version', () async {
      final result = await service(latest: () async => 'v1.0.0').run();
      expect(result.status, UpgradeStatus.upToDate);
      expect(result.version, '1.0.0');
    });
  });

  group('upgrade', () {
    late Directory installDir;
    late String daemonLog;

    setUp(() async {
      installDir = await Directory.systemTemp.createTemp('crux_upgrade_');
      daemonLog = p.join(installDir.path, 'daemon-calls.log');
    });
    tearDown(() async {
      if (await installDir.exists()) await installDir.delete(recursive: true);
    });

    // Writes a fake pre-existing binary under the host's naming so the
    // assertions below read back what the service actually replaces.
    File seedOldBinary([String base = 'crux']) =>
        File(p.join(installDir.path, hostBinary(base)))
          ..writeAsStringSync('OLD-CRUX');

    Future<UpgradeResult> upgradeWith(
      Uint8List zip, {
      String latest = 'v1.1.0',
    }) => UpgradeService(
      currentVersion: '1.0.0',
      executablePath: p.join(installDir.path, 'crux'),
      isCompiledBuild: true,
      target: 'test-target',
      publishedTargets: const {'test-target'},
      download: (_) async => zip,
      fetchLatestVersion: () async => latest,
    ).run();

    test('replaces crux and cruxd, and stops the old daemon first', () async {
      File(p.join(installDir.path, 'crux')).writeAsStringSync('OLD-CRUX');
      // A real script, so the stop call is observable rather than assumed. This
      // is the regression guard for "new crux talking to a stale daemon".
      final existingDaemon = File(p.join(installDir.path, 'cruxd'));
      // Escaped `$` on purpose: Dart interpolates inside single quotes too, and
      // this is shell syntax that must reach the script verbatim.
      existingDaemon.writeAsStringSync(
        '#!/bin/sh\necho "\$*" >> "$daemonLog"\n',
      );
      Process.runSync('chmod', ['755', existingDaemon.path]);

      final result = await upgradeWith(
        releaseZip(cruxBody: 'NEW-CRUX', daemonBody: 'NEW-DAEMON'),
      );

      expect(result.status, UpgradeStatus.upgraded, reason: result.detail);
      expect(result.version, '1.1.0');
      expect(
        File(p.join(installDir.path, 'crux')).readAsStringSync(),
        'NEW-CRUX',
      );
      expect(
        File(p.join(installDir.path, 'cruxd')).readAsStringSync(),
        'NEW-DAEMON',
      );
      expect(
        File(daemonLog).readAsStringSync(),
        contains('stop'),
        reason: 'the previous daemon must be asked to stop before replacement',
      );
      // The temp files the atomic install goes through must not survive.
      expect(
        Directory(installDir.path)
            .listSync()
            .map((entity) => p.basename(entity.path))
            .where((name) => name.contains('.tmp.')),
        isEmpty,
      );
    }, skip: Platform.isWindows ? 'POSIX script stub' : null);

    test(
      'leaves the existing binaries alone when already up to date',
      () async {
        seedOldBinary();
        final result = await upgradeWith(
          releaseZip(cruxBody: 'NEW-CRUX'),
          latest: 'v1.0.0',
        );
        expect(result.status, UpgradeStatus.upToDate);
        expect(
          File(p.join(installDir.path, hostBinary('crux'))).readAsStringSync(),
          'OLD-CRUX',
        );
      },
    );

    test('fails cleanly when the archive has no crux binary', () async {
      seedOldBinary();
      final result = await upgradeWith(
        releaseZip(cruxBody: '', includeCrux: false),
      );
      expect(result.status, UpgradeStatus.failed);
      expect(result.detail, contains('crux'));
      // The old binary must survive a bad download.
      expect(
        File(p.join(installDir.path, hostBinary('crux'))).readAsStringSync(),
        'OLD-CRUX',
      );
    });

    test('keeps working when the bundle ships no daemon sidecar', () async {
      seedOldBinary();
      final result = await upgradeWith(releaseZip(cruxBody: 'NEW-CRUX'));
      expect(result.status, UpgradeStatus.upgraded, reason: result.detail);
      expect(
        File(p.join(installDir.path, hostBinary('crux'))).readAsStringSync(),
        'NEW-CRUX',
      );
    });
  });
}
