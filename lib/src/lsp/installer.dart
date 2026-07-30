// Auto-install support for LSP servers.
//
// Mirrors OpenCode's download flow (`packages/opencode/src/lsp/
// server.ts` + `Npm.which`): when a language server binary is missing
// from PATH, Crux downloads it once into a per-user directory and
// reuses it afterwards. Installs never block the edit path — the
// manager's `touchFileAndWait` timeout keeps running while an install
// is in flight, and concurrent requests for the same server coalesce
// into one download.
//
// Layout (opencode installs into `Global.Path.bin`; Crux uses the
// XDG cache dir):
//   $XDG_CACHE_HOME/crux/lsp/bin/<binary>        — npm shims, go tools
//   $XDG_CACHE_HOME/crux/lsp/<name>/…            — unpacked archives
//
// Override with `CRUX_LSP_HOME` (tests) or disable all downloads with
// `CRUX_DISABLE_LSP_DOWNLOAD=1` (OpenCode's `disableLspDownload`).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'spawn_util.dart';

/// True when LSP auto-download is disabled (OpenCode's
/// `disableLspDownload` runtime flag, as an env var).
bool get lspDownloadDisabled =>
    _downloadDisabledOverride ??
    Platform.environment['CRUX_DISABLE_LSP_DOWNLOAD'] == '1';

/// Test-only override for [lspDownloadDisabled].
bool? _downloadDisabledOverride;

/// Root of Crux's downloaded-tool area. Overridable for tests.
String lspToolHome() =>
    _toolHomeOverride ??
    Platform.environment['CRUX_LSP_HOME'] ??
    _defaultToolHome();

/// Test-only override for [lspToolHome]. Set to null to restore.
String? _toolHomeOverride;

/// Set a test-only tool home (bypasses env lookup).
void debugSetLspToolHome(String? path) {
  _toolHomeOverride = path;
}

/// Set a test-only download-disabled flag.
void debugSetLspDownloadDisabled(bool? disabled) {
  _downloadDisabledOverride = disabled;
}

String _defaultToolHome() {
  final cache = Platform.environment['XDG_CACHE_HOME'];
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  final base = (cache != null && cache.isNotEmpty)
      ? cache
      : p.join(home ?? Directory.systemTemp.path, '.cache');
  return p.join(base, 'crux', 'lsp');
}

/// Directory holding downloaded single binaries and npm shims.
String lspBinDir() => p.join(lspToolHome(), 'bin');

// ---------------------------------------------------------------------------
// Install coalescing + cross-process locking
// ---------------------------------------------------------------------------

/// In-flight installs keyed by a caller-chosen id (e.g. server id).
/// Concurrent [installOnce] calls for the same id share one install.
final Map<String, Future<String?>> _inflight = {};

/// Run [install] at most once per [key] per process, serialized across
/// processes via a lock file. Returns the installed binary path, or
/// null if the install failed or downloads are disabled.
///
/// If another process holds the lock, waits up to [lockWait] for it to
/// finish, then re-checks [existing]. This mirrors OpenCode's
/// `roslynLanguageServerInstall ||= …` memoization, extended across
/// processes.
Future<String?> installOnce({
  required String key,
  required String? Function() existing,
  required Future<String?> Function() install,
  Duration lockWait = const Duration(minutes: 3),
}) async {
  final found = existing();
  if (found != null) return found;
  if (lspDownloadDisabled) return null;

  final inflight = _inflight[key];
  if (inflight != null) return inflight;

  final future = _installWithLock(key, existing, install, lockWait);
  _inflight[key] = future;
  try {
    return await future;
  } finally {
    _inflight.remove(key);
  }
}

Future<String?> _installWithLock(
  String key,
  String? Function() existing,
  Future<String?> Function() install,
  Duration lockWait,
) async {
  final home = Directory(lspToolHome());
  await home.create(recursive: true);
  final lockFile = File(p.join(home.path, '$key.lock'));

  RandomAccessFile? lock;
  final deadline = DateTime.now().add(lockWait);
  while (true) {
    try {
      lock = await lockFile.open(mode: FileMode.write);
      await lock.lock(FileLock.blockingExclusive);
      break;
    } catch (_) {
      try {
        await lock?.close();
      } catch (_) {}
      lock = null;
      if (DateTime.now().isAfter(deadline)) return null;
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  try {
    // Another process may have finished while we waited.
    final recheck = existing();
    if (recheck != null) return recheck;
    return await install();
  } catch (_) {
    return null;
  } finally {
    try {
      await lock.unlock();
      await lock.close();
      await lockFile.delete();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------------------
// npm packages (OpenCode's `Npm.which`)
// ---------------------------------------------------------------------------

/// Find a previously npm-installed binary (no install).
String? npmInstalled(String binaryName) {
  final ext = Platform.isWindows ? '.cmd' : '';
  for (final candidate in [
    p.join(lspBinDir(), 'bin', '$binaryName$ext'),
    p.join(lspBinDir(), '$binaryName$ext'),
  ]) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// Install [packageSpec] into [lspBinDir] via `npm install -g
/// --prefix`, then return the shim for [binaryName] (defaults to the
/// package name). Returns null if npm is unavailable or install fails.
Future<String?> npmInstall(String packageSpec, [String? binaryName]) async {
  final npm =
      whichBinary(Platform.isWindows ? 'npm.cmd' : 'npm') ?? whichBinary('npm');
  if (npm == null) return null;

  final binDir = lspBinDir();
  await Directory(binDir).create(recursive: true);

  ProcessResult result;
  try {
    result = await Process.run(npm, [
      'install',
      '-g',
      '--prefix',
      binDir,
      packageSpec,
    ]).timeout(const Duration(minutes: 3));
  } catch (_) {
    return null;
  }
  if (result.exitCode != 0) return null;

  final name = binaryName ?? packageSpec.split('/').last.split('@').first;
  return npmInstalled(name);
}

// ---------------------------------------------------------------------------
// GitHub release archives (OpenCode's per-server download blocks)
// ---------------------------------------------------------------------------

/// Metadata for one downloadable archive.
class ArchiveAsset {
  final String url;
  final String filename;

  /// `zip`, `tar.gz`, `tar.xz` — inferred from [filename] when null.
  final String? format;

  const ArchiveAsset(this.url, this.filename, {this.format});

  String get resolvedFormat =>
      format ??
      (filename.endsWith('.zip')
          ? 'zip'
          : filename.endsWith('.tar.xz')
          ? 'tar.xz'
          : 'tar.gz');
}

/// Download [asset] and extract it into [destDir]. Returns true on
/// success. Uses the system `tar` for tarballs and `unzip` (with a
/// pure-Dart fallback) for zips.
Future<bool> downloadAndExtract(ArchiveAsset asset, String destDir) async {
  final dest = Directory(destDir);
  await dest.create(recursive: true);
  final tempPath = p.join(lspToolHome(), '.tmp', asset.filename);
  await Directory(p.dirname(tempPath)).create(recursive: true);

  if (!await _download(asset.url, tempPath)) return false;

  final ok = await _extract(tempPath, asset.resolvedFormat, destDir);
  try {
    await File(tempPath).delete();
  } catch (_) {}
  return ok;
}

/// Download [url] to [path], following redirects (GitHub release
/// assets 302 to a CDN). Returns true on HTTP 200.
Future<bool> _download(String url, String path) async {
  final client = HttpClient();
  try {
    var uri = Uri.parse(url);
    for (var redirects = 0; redirects < 5; redirects++) {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 30));
      request.headers.set('user-agent', 'crux-lsp');
      final response = await request.close();
      if (response.statusCode == 200) {
        final sink = File(path).openWrite();
        try {
          await response.pipe(sink);
        } finally {
          await sink.close();
        }
        return true;
      }
      final location = response.headers.value('location');
      if (location == null ||
          (response.statusCode != 301 &&
              response.statusCode != 302 &&
              response.statusCode != 307 &&
              response.statusCode != 308)) {
        await response.drain<void>();
        return false;
      }
      uri = uri.resolve(location);
      await response.drain<void>();
    }
    return false;
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

Future<bool> _extract(String archive, String format, String destDir) async {
  if (format == 'zip') {
    final unzip = whichBinary('unzip');
    if (unzip != null) {
      final result = await Process.run(unzip, [
        '-o',
        '-q',
        archive,
        '-d',
        destDir,
      ]);
      return result.exitCode == 0;
    }
    return _extractZipDart(archive, destDir);
  }
  final tar = whichBinary('tar');
  if (tar == null) return false;
  final args = format == 'tar.xz'
      ? ['-xJf', archive, '-C', destDir]
      : ['-xzf', archive, '-C', destDir];
  final result = await Process.run(tar, args);
  return result.exitCode == 0;
}

/// Minimal zip extraction (stored + deflate entries) for platforms
/// without `unzip` — avoids pulling in package:archive.
Future<bool> _extractZipDart(String archivePath, String destDir) async {
  try {
    final bytes = await File(archivePath).readAsBytes();
    final data = ByteData.sublistView(bytes);

    // Find End of Central Directory record.
    var eocd = -1;
    for (var i = bytes.length - 22; i >= 0 && i > bytes.length - 65558; i--) {
      if (data.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return false;
    final entryCount = data.getUint16(eocd + 10, Endian.little);
    var offset = data.getUint32(eocd + 16, Endian.little);

    for (var e = 0; e < entryCount; e++) {
      if (data.getUint32(offset, Endian.little) != 0x02014b50) return false;
      final method = data.getUint16(offset + 10, Endian.little);
      final compressedSize = data.getUint32(offset + 20, Endian.little);
      final nameLength = data.getUint16(offset + 28, Endian.little);
      final extraLength = data.getUint16(offset + 30, Endian.little);
      final commentLength = data.getUint16(offset + 32, Endian.little);
      final localHeaderOffset = data.getUint32(offset + 42, Endian.little);
      final name = utf8.decode(
        bytes.sublist(offset + 46, offset + 46 + nameLength),
      );

      if (!name.endsWith('/')) {
        // Local file header: skip its name/extra to reach the data.
        final lhNameLen = data.getUint16(localHeaderOffset + 26, Endian.little);
        final lhExtraLen = data.getUint16(
          localHeaderOffset + 28,
          Endian.little,
        );
        final dataStart = localHeaderOffset + 30 + lhNameLen + lhExtraLen;
        final compressed = bytes.sublist(dataStart, dataStart + compressedSize);

        final List<int> content;
        if (method == 0) {
          content = compressed;
        } else if (method == 8) {
          content = ZLibDecoder(raw: true).convert(compressed);
        } else {
          return false; // unsupported compression
        }

        final outPath = p.join(destDir, name);
        // Guard against zip-slip.
        if (!p.isWithin(destDir, p.normalize(outPath))) return false;
        await Directory(p.dirname(outPath)).create(recursive: true);
        await File(outPath).writeAsBytes(content);
      }
      offset += 46 + nameLength + extraLength + commentLength;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Fetch JSON from [url] (follows redirects). Returns null on failure.
Future<dynamic> fetchJson(String url) async {
  final client = HttpClient();
  try {
    var uri = Uri.parse(url);
    for (var redirects = 0; redirects < 3; redirects++) {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.headers.set('user-agent', 'crux-lsp');
      request.headers.set('accept', 'application/json');
      final response = await request.close();
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        return jsonDecode(body);
      }
      final location = response.headers.value('location');
      if (location == null ||
          (response.statusCode != 301 &&
              response.statusCode != 302 &&
              response.statusCode != 307 &&
              response.statusCode != 308)) {
        await response.drain<void>();
        return null;
      }
      uri = uri.resolve(location);
      await response.drain<void>();
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

// ---------------------------------------------------------------------------
// Platform mapping helpers (OpenCode's per-server arch/os matrices)
// ---------------------------------------------------------------------------

/// Current CPU arch: `arm64` or `x64`.
String currentArch() => _cachedArch ??= _probeArch();

String? _cachedArch;

String _probeArch() {
  if (Platform.isWindows) {
    final arch = Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '';
    return arch.toUpperCase().contains('ARM64') ? 'arm64' : 'x64';
  }
  try {
    final result = Process.runSync('uname', ['-m']);
    final arch = result.stdout.toString().trim();
    if (arch == 'arm64' || arch == 'aarch64') return 'arm64';
    return 'x64';
  } catch (_) {
    return 'x64';
  }
}

/// `macos`, `linux`, or `windows` (GitHub-release naming).
String currentPlatformToken() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  return 'linux';
}

/// Make [path] executable (no-op on Windows).
Future<void> chmodExecutable(String path) async {
  if (Platform.isWindows) return;
  try {
    await Process.run('chmod', ['755', path]);
  } catch (_) {}
}

/// Binary name with the platform extension.
String exeName(String base) => Platform.isWindows ? '$base.exe' : base;
