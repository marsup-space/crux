/// Downloads and installs the latest published Crux release in place.
///
/// `/upgrade` replaces the running binary rather than shelling out to
/// `install.sh`, because the script has to *guess* where Crux lives while the
/// running process simply knows: [Platform.resolvedExecutable] is the path the
/// user actually launched. Guessing from `CRUX_INSTALL_DIR` or `$HOME` breaks
/// the moment someone installed into a non-default directory — and the two
/// answers disagreeing is how you end up with two installations.
///
/// This service owns the *decision* and the *file work*, never the wording: it
/// returns a structured [UpgradeResult] and lets the command layer phrase it, so
/// every user-visible string stays translatable in one place.
///
/// Everything it cannot know by itself (the network, whether the build is
/// AOT-compiled, where the binary lives) arrives through constructor seams, so
/// the whole flow is testable offline.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../utils/bundled_executable.dart' show currentRuntimeTarget;
import '../utils/github_release_transport.dart';
import '../utils/system_proxy.dart';

/// GitHub coordinates the release assets are published under.
const String kCruxReleaseRepo = 'marsup-space/crux';

/// The targets `.github/workflows/release.yml` actually publishes.
///
/// Kept in step with the workflow's matrix. Both this and `install.sh` refuse an
/// unpublished target with an actionable message instead of requesting an asset
/// that doesn't exist and surfacing a bare download failure.
const Set<String> kPublishedCruxTargets = {
  'macos-arm64',
  'linux-x64',
  'windows-x64',
};

/// Why an upgrade stopped, or that it succeeded.
///
/// Each refusal is a distinct status because each needs a different user action:
/// nothing (already latest), build from source (unpublished target), reinstall
/// with permissions (read-only install), or nothing ever (not an installed
/// build).
enum UpgradeStatus {
  upgraded,
  upToDate,
  unsupportedPlatform,
  notAnInstalledBuild,
  installDirNotWritable,
  failed,
}

/// Structured outcome. [detail] carries whatever the caller needs to explain the
/// refusal — an error string, a directory, a target — without this layer
/// deciding how to phrase it.
class UpgradeResult {
  final UpgradeStatus status;

  /// The version that matters: the new one after an upgrade, the current one
  /// when already up to date.
  final String? version;

  /// Machine-specific specific of the outcome: published target list, install
  /// directory, or a raw error message.
  final String? detail;

  const UpgradeResult(this.status, {this.version, this.detail});

  bool get isSuccess => status == UpgradeStatus.upgraded;
}

/// Fetches raw bytes for [url], following redirects.
typedef UpgradeDownloader = Future<Uint8List> Function(String url);

/// Reports coarse progress so a long download is not a silent freeze.
typedef UpgradeProgress = void Function(String stage);

class UpgradeService {
  final String repo;
  final String currentVersion;

  /// Asset target for this machine, e.g. `macos-arm64`.
  final String target;

  /// Path of the running executable; its directory is the install directory.
  final String executablePath;

  /// False for `dart run` / JIT builds, which must never be replaced: there the
  /// "executable" is the Dart SDK's own binary, and writing over it would
  /// destroy the user's toolchain rather than upgrade Crux.
  final bool isCompiledBuild;

  final UpgradeDownloader download;

  /// Resolves the newest published version, or null when it cannot be
  /// determined (offline, rate-limited). Never throws.
  final Future<String?> Function() fetchLatestVersion;

  final Set<String> publishedTargets;

  UpgradeService({
    required this.currentVersion,
    required this.executablePath,
    required this.download,
    required this.fetchLatestVersion,
    this.repo = kCruxReleaseRepo,
    String? target,
    bool? isCompiledBuild,
    this.publishedTargets = kPublishedCruxTargets,
  }) : target = target ?? _defaultTarget,
       isCompiledBuild = isCompiledBuild ?? _defaultIsCompiled;

  static String get _defaultTarget => currentRuntimeTarget();

  /// Mirrors `kIsJit` in `components/version_badge.dart`, duplicated as a getter
  /// rather than imported so this service carries no component dependency — a
  /// service importing a widget helper is a layering bug even when the helper is
  /// a one-line const.
  static bool get _defaultIsCompiled =>
      const bool.fromEnvironment('dart.vm.product');

  Future<UpgradeResult> run({UpgradeProgress? onProgress}) async {
    if (!isCompiledBuild) {
      return const UpgradeResult(UpgradeStatus.notAnInstalledBuild);
    }

    final directory = p.dirname(executablePath);
    if (!Directory(directory).existsSync()) {
      return UpgradeResult(
        UpgradeStatus.notAnInstalledBuild,
        detail: directory,
      );
    }

    if (!publishedTargets.contains(target)) {
      return UpgradeResult(
        UpgradeStatus.unsupportedPlatform,
        detail: (publishedTargets.toList()..sort()).join(', '),
      );
    }

    onProgress?.call('checking');
    final String latest;
    try {
      final resolved = await fetchLatestVersion();
      if (resolved == null || resolved.isEmpty) {
        return const UpgradeResult(
          UpgradeStatus.failed,
          detail: 'Could not reach GitHub to check the latest version.',
        );
      }
      latest = normaliseVersion(resolved);
    } catch (error) {
      return UpgradeResult(UpgradeStatus.failed, detail: '$error');
    }

    if (compareVersions(latest, normaliseVersion(currentVersion)) <= 0) {
      return UpgradeResult(UpgradeStatus.upToDate, version: currentVersion);
    }

    if (!_isWritable(directory)) {
      return UpgradeResult(
        UpgradeStatus.installDirNotWritable,
        detail: directory,
      );
    }

    try {
      onProgress?.call('downloading');
      final bytes = await download(
        'https://github.com/$repo/releases/download/v$latest/'
        'crux-$target.zip',
      );
      onProgress?.call('verifying');
      // `verify: true` checks the archive's own structure. Hashing the whole
      // asset would be stronger, but the release workflow publishes no checksum
      // — this is the best check available today, and it at least guarantees a
      // truncated download can never be installed as a binary.
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      final binaries = _locateBinaries(archive);
      final crux = binaries.crux;
      if (crux == null) {
        return const UpgradeResult(
          UpgradeStatus.failed,
          detail: 'Archive does not contain the crux binary.',
        );
      }

      onProgress?.call('installing');
      // Stop a running daemon before replacing its binary, so the next Crux
      // launch bootstraps the new one instead of talking to a stale process.
      await _stopDaemonIfRunning(directory);
      _installFile(crux, p.join(directory, _hostBinaryName('crux')));
      final daemon = binaries.daemon;
      if (daemon != null) {
        _installFile(daemon, p.join(directory, _hostBinaryName('cruxd')));
      }

      return UpgradeResult(UpgradeStatus.upgraded, version: latest);
    } catch (error) {
      return UpgradeResult(UpgradeStatus.failed, detail: '$error');
    }
  }

  String _hostBinaryName(String base) =>
      Platform.isWindows ? '$base.exe' : base;

  bool _isWritable(String directory) {
    final probe = File(p.join(directory, '.crux-upgrade-probe.$pid'));
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Installs one archive entry with write-to-temp + rename, so a failure
  /// halfway through never leaves a truncated file where `crux` used to be.
  ///
  /// The rename also sidesteps macOS 26 provenance tracking, which can SIGKILL
  /// an adhoc-signed binary written over an existing flagged path — the same
  /// reason `install.sh` refuses to copy in place.
  void _installFile(ArchiveFile entry, String destination) {
    final staging = '$destination.tmp.$pid';
    final file = File(staging);
    file.writeAsBytesSync(entry.content as List<int>, flush: true);
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['755', staging]);
    }
    file.renameSync(destination);
  }

  Future<void> _stopDaemonIfRunning(String directory) async {
    final daemon = File(p.join(directory, _hostBinaryName('cruxd')));
    if (!daemon.existsSync()) return;
    try {
      await Process.run(daemon.path, ['stop'], stdoutEncoding: null);
    } catch (_) {
      // Best effort: a wedged daemon must not block the upgrade, and crux
      // detects and replaces a stale daemon on its next bootstrap regardless.
    }
  }

  /// Finds the two executables in a release zip, tolerating both bundle layouts
  /// (`<root>/bin/crux` current, `<root>/crux` legacy).
  ({ArchiveFile? crux, ArchiveFile? daemon}) _locateBinaries(Archive archive) {
    ArchiveFile? find(String base) {
      for (final candidate in [
        'bin/$base',
        'bin/$base.exe',
        base,
        '$base.exe',
      ]) {
        final exact = archive.files
            .where((file) => file.name == candidate)
            .firstOrNull;
        if (exact != null) return exact;
      }
      // Fall back to a basename match so a bundle that nests the binaries one
      // level deeper still upgrades instead of failing on layout.
      return archive.files
          .where(
            (file) =>
                p.basename(file.name) == base ||
                p.basename(file.name) == '$base.exe',
          )
          .firstOrNull;
    }

    return (crux: find('crux'), daemon: find('cruxd'));
  }
}

/// Strips a leading `v` so `v1.2.0` and `1.2.0` compare equal.
String normaliseVersion(String value) {
  final trimmed = value.trim();
  return trimmed.startsWith('v') ? trimmed.substring(1) : trimmed;
}

/// Compares two dot-separated numeric versions.
///
/// Deliberately tiny: releases are plain `MAJOR.MINOR.PATCH`, and a prerelease
/// grammar would be more code than the problem needs. Missing or non-numeric
/// segments count as 0, so `1.2` < `1.2.1` and a nonsense tag never looks newer
/// than a real one.
int compareVersions(String a, String b) {
  final left = _segments(a);
  final right = _segments(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var index = 0; index < length; index++) {
    final l = index < left.length ? left[index] : 0;
    final r = index < right.length ? right[index] : 0;
    if (l != r) return l < r ? -1 : 1;
  }
  return 0;
}

List<int> _segments(String version) => version
    .split(RegExp(r'[.+-]'))
    .map((part) => int.tryParse(part) ?? 0)
    .toList(growable: false);

/// Extracts a version from anything that references a release tag.
///
/// Two shapes reach this, because the transports answer differently:
/// a direct (or system-proxy) connection to `releases/latest` returns 302 with
/// the tag in its Location header, while a mirror returns the release page
/// itself and the tag appears in its markup. One pattern covers both — measured
/// against the live mirrors, whose capabilities are not interchangeable.
///
/// Pure, so the parsing is testable without a network round trip.
String? versionFromReleaseReference(String? text) {
  if (text == null) return null;
  final match = RegExp("/releases/tag/([^/?#\\s\"'<>]+)").firstMatch(text);
  if (match == null) return null;
  try {
    return Uri.decodeComponent(match.group(1)!);
  } on FormatException {
    return match.group(1);
  }
}

/// Builds an [HttpClient] routed through [proxy] when one is in scope.
HttpClient _clientFor(SystemProxy? proxy) {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  if (proxy != null) client.findProxy = proxy.findProxyFor;
  return client;
}

bool _looksLikeZip(Uint8List bytes) {
  if (bytes.length < 4) return false;
  if (bytes[0] != 0x50 || bytes[1] != 0x4b) return false; // "PK"
  final third = bytes[2];
  final fourth = bytes[3];
  return (third == 0x03 && fourth == 0x04) ||
      (third == 0x05 && fourth == 0x06) ||
      (third == 0x07 && fourth == 0x08);
}

Future<String?> _headLocation(HttpClient client, String url) async {
  final request = await client.headUrl(Uri.parse(url));
  // A 302 is the answer we want here, so don't follow it away.
  request.followRedirects = false;
  final response = await request.close();
  final location = response.headers.value('location');
  await response.drain<void>();
  return location;
}

/// Reads at most [maxBytes] of a text resource.
///
/// The tag sits in the document head, so a bounded read is enough — and it keeps
/// a mirror with a pathological body from being read into memory in full.
Future<String> _readTextHead(
  HttpClient client,
  String url, {
  int maxBytes = 64 * 1024,
}) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  if (response.statusCode != 200) {
    await response.drain<void>();
    throw HttpException('HTTP ${response.statusCode} for $url');
  }
  final buffer = <int>[];
  await for (final chunk in response) {
    buffer.addAll(chunk);
    if (buffer.length >= maxBytes) break;
  }
  if (buffer.length > maxBytes) buffer.removeRange(maxBytes, buffer.length);
  return utf8.decode(buffer, allowMalformed: true);
}

/// Default downloader: walks the transport chain until a real zip arrives.
///
/// The zip signature is checked *inside* each attempt so a mirror that answers
/// 200 with an error page counts as a miss and the next transport is tried —
/// otherwise the caller would surface a decode error that names no cause and
/// offers no next step.
Future<Uint8List> httpDownloadBytes(String url) => withGithubTransports(
  url: url,
  attempt: (candidate, proxy) async {
    final client = _clientFor(proxy);
    try {
      final request = await client.getUrl(Uri.parse(candidate));
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('HTTP ${response.statusCode} for $candidate');
      }
      final chunks = <int>[];
      await for (final chunk in response) {
        chunks.addAll(chunk);
      }
      final bytes = Uint8List.fromList(chunks);
      if (!_looksLikeZip(bytes)) {
        throw HttpException('$candidate did not return a zip archive');
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  },
);

/// Default version resolver: walks the transport chain for the release page.
///
/// Returns null rather than throwing, so "cannot tell" stays distinguishable
/// from a real failure at the call site.
Future<String?> httpFetchLatestVersion({String repo = kCruxReleaseRepo}) async {
  try {
    return await withGithubTransports<String>(
      url: 'https://github.com/$repo/releases/latest',
      attempt: (candidate, proxy) async {
        final client = _clientFor(proxy);
        try {
          final location = await _headLocation(client, candidate);
          final fromHeader = versionFromReleaseReference(location);
          if (fromHeader != null) return fromHeader;
          // A mirror answers with the page instead of a redirect; a
          // download-only mirror answers with a refusal, which has no tag and
          // therefore counts as a miss for the next transport.
          final fromBody = versionFromReleaseReference(
            await _readTextHead(client, candidate),
          );
          if (fromBody == null) {
            throw HttpException('no release tag at $candidate');
          }
          return fromBody;
        } finally {
          client.close(force: true);
        }
      },
    );
  } catch (_) {
    return null;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
