// Auto-install hooks for archive-distributed language servers.
//
// Each function mirrors the download block of the matching entry in
// OpenCode's `server.ts` (Zls, Clangd, LuaLS, TerraformLS, Tinymist,
// TexLab): query the latest GitHub/HashiCorp release, pick the asset
// for the current platform/arch, download + extract into Crux's tool
// dir, and return the binary path.
//
// npm-based installers (typescript-language-server, pyright, etc.)
// live inline in `registry.dart` via `npmInstall`.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../installer.dart';

String _installDir(String name) => p.join(lspToolHome(), name);

// ---------------------------------------------------------------------------
// zls (OpenCode's Zls)
// ---------------------------------------------------------------------------

Future<String?> installZls() async {
  final bin = p.join(lspBinDir(), exeName('zls'));
  if (File(bin).existsSync()) return bin;

  final release = await fetchJson(
    'https://api.github.com/repos/zigtools/zls/releases/latest',
  );
  if (release is! Map) return null;
  final assets = release['assets'];
  if (assets is! List) return null;

  final arch = currentArch() == 'arm64' ? 'aarch64' : 'x86_64';
  final platform = currentPlatformToken();
  final ext = Platform.isWindows ? 'zip' : 'tar.xz';
  final assetName = 'zls-$arch-$platform.$ext';

  const supported = {
    'zls-x86_64-linux.tar.xz',
    'zls-x86_64-macos.tar.xz',
    'zls-x86_64-windows.zip',
    'zls-aarch64-linux.tar.xz',
    'zls-aarch64-macos.tar.xz',
    'zls-aarch64-windows.zip',
    'zls-x86-linux.tar.xz',
    'zls-x86-windows.zip',
  };
  if (!supported.contains(assetName)) return null;

  final url = _assetUrl(assets, assetName);
  if (url == null) return null;

  if (!await downloadAndExtract(ArchiveAsset(url, assetName), lspBinDir())) {
    return null;
  }
  await chmodExecutable(bin);
  return File(bin).existsSync() ? bin : null;
}

// ---------------------------------------------------------------------------
// clangd (OpenCode's Clangd)
// ---------------------------------------------------------------------------

Future<String?> installClangd() async {
  // Existing direct binary or previously extracted release.
  final direct = p.join(lspBinDir(), exeName('clangd'));
  if (File(direct).existsSync()) return direct;
  final existing = await _findClangdInReleases();
  if (existing != null) return existing;

  final release = await fetchJson(
    'https://api.github.com/repos/clangd/clangd/releases/latest',
  );
  if (release is! Map) return null;
  final tag = release['tag_name'];
  final assets = release['assets'];
  if (tag is! String || assets is! List) return null;

  final token = switch (currentPlatformToken()) {
    'macos' => 'mac',
    'windows' => 'windows',
    _ => 'linux',
  };

  String? name;
  String? url;
  for (final suffix in const ['.zip', '.tar.xz', '']) {
    for (final asset in assets) {
      if (asset is! Map) continue;
      final n = asset['name'];
      final u = asset['browser_download_url'];
      if (n is! String || u is! String) continue;
      if (!n.contains(token) || !n.contains(tag)) continue;
      if (suffix.isNotEmpty && !n.endsWith(suffix)) continue;
      name = n;
      url = u;
      break;
    }
    if (url != null) break;
  }
  if (name == null || url == null) return null;

  final home = lspToolHome();
  if (!await downloadAndExtract(ArchiveAsset(url, name), home)) return null;

  final bin = p.join(home, 'clangd_$tag', 'bin', exeName('clangd'));
  if (!File(bin).existsSync()) return null;
  await chmodExecutable(bin);
  return bin;
}

Future<String?> _findClangdInReleases() async {
  final home = Directory(lspToolHome());
  if (!home.existsSync()) return null;
  await for (final entry in home.list()) {
    if (entry is! Directory) continue;
    if (!p.basename(entry.path).startsWith('clangd_')) continue;
    final candidate = p.join(entry.path, 'bin', exeName('clangd'));
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

// ---------------------------------------------------------------------------
// lua-language-server (OpenCode's LuaLS)
// ---------------------------------------------------------------------------

Future<String?> installLuaLs() async {
  final platform = switch (currentPlatformToken()) {
    'macos' => 'darwin',
    'windows' => 'win32',
    _ => 'linux',
  };
  final arch = currentArch(); // arm64 / x64
  final installDir = _installDir('lua-language-server-$arch-$platform');
  final bin = p.join(installDir, 'bin', exeName('lua-language-server'));
  if (File(bin).existsSync()) return bin;

  final release = await fetchJson(
    'https://api.github.com/repos/LuaLS/lua-language-server/releases/latest',
  );
  if (release is! Map) return null;
  final tag = release['tag_name'];
  final assets = release['assets'];
  if (tag is! String || assets is! List) return null;

  final ext = Platform.isWindows ? 'zip' : 'tar.gz';
  final assetName = 'lua-language-server-$tag-$platform-$arch.$ext';

  const supported = {
    'darwin-arm64.tar.gz',
    'darwin-x64.tar.gz',
    'linux-x64.tar.gz',
    'linux-arm64.tar.gz',
    'win32-x64.zip',
    'win32-ia32.zip',
  };
  if (!supported.contains('$platform-$arch.$ext')) return null;

  final url = _assetUrl(assets, assetName);
  if (url == null) return null;

  // Clean reinstall — the archive contains support files (meta/,
  // locale/) the binary needs next to it.
  final existing = Directory(installDir);
  if (existing.existsSync()) await existing.delete(recursive: true);

  if (!await downloadAndExtract(ArchiveAsset(url, assetName), installDir)) {
    return null;
  }
  await chmodExecutable(bin);
  return File(bin).existsSync() ? bin : null;
}

// ---------------------------------------------------------------------------
// terraform-ls (OpenCode's TerraformLS)
// ---------------------------------------------------------------------------

Future<String?> installTerraformLs() async {
  final bin = p.join(lspBinDir(), exeName('terraform-ls'));
  if (File(bin).existsSync()) return bin;

  final release = await fetchJson(
    'https://api.releases.hashicorp.com/v1/releases/terraform-ls/latest',
  );
  if (release is! Map) return null;
  final builds = release['builds'];
  if (builds is! List) return null;

  final arch = currentArch() == 'arm64' ? 'arm64' : 'amd64';
  final platform = Platform.isWindows ? 'windows' : currentPlatformToken();

  String? url;
  for (final build in builds) {
    if (build is! Map) continue;
    if (build['arch'] == arch && build['os'] == platform) {
      url = build['url'];
      break;
    }
  }
  if (url is! String) return null;

  if (!await downloadAndExtract(
    ArchiveAsset(url, 'terraform-ls.zip', format: 'zip'),
    lspBinDir(),
  )) {
    return null;
  }
  await chmodExecutable(bin);
  return File(bin).existsSync() ? bin : null;
}

// ---------------------------------------------------------------------------
// tinymist (OpenCode's Tinymist)
// ---------------------------------------------------------------------------

Future<String?> installTinymist() async {
  final bin = p.join(lspBinDir(), exeName('tinymist'));
  if (File(bin).existsSync()) return bin;

  final release = await fetchJson(
    'https://api.github.com/repos/Myriad-Dreamin/tinymist/releases/latest',
  );
  if (release is! Map) return null;
  final assets = release['assets'];
  if (assets is! List) return null;

  final arch = currentArch() == 'arm64' ? 'aarch64' : 'x86_64';
  final (platform, ext) = switch (currentPlatformToken()) {
    'macos' => ('apple-darwin', 'tar.gz'),
    'windows' => ('pc-windows-msvc', 'zip'),
    _ => ('unknown-linux-gnu', 'tar.gz'),
  };
  final assetName = 'tinymist-$arch-$platform.$ext';

  final url = _assetUrl(assets, assetName);
  if (url == null) return null;

  // tinymist tarballs nest the binary one level deep — extract then
  // promote it next to the bin dir.
  final extractDir = _installDir('tinymist');
  if (!await downloadAndExtract(ArchiveAsset(url, assetName), extractDir)) {
    return null;
  }
  final nested = await _findFile(extractDir, exeName('tinymist'));
  if (nested == null) return null;
  await File(nested).rename(bin).catchError((_) async {
    await File(nested).copy(bin);
    return File(bin);
  });
  await chmodExecutable(bin);
  return File(bin).existsSync() ? bin : null;
}

// ---------------------------------------------------------------------------
// texlab (OpenCode's TexLab)
// ---------------------------------------------------------------------------

Future<String?> installTexlab() async {
  final bin = p.join(lspBinDir(), exeName('texlab'));
  if (File(bin).existsSync()) return bin;

  final release = await fetchJson(
    'https://api.github.com/repos/latex-lsp/texlab/releases/latest',
  );
  if (release is! Map) return null;
  final assets = release['assets'];
  if (assets is! List) return null;

  final arch = currentArch() == 'arm64' ? 'aarch64' : 'x86_64';
  final platform = currentPlatformToken();
  final ext = Platform.isWindows ? 'zip' : 'tar.gz';
  final assetName = 'texlab-$arch-$platform.$ext';

  final url = _assetUrl(assets, assetName);
  if (url == null) return null;

  if (!await downloadAndExtract(ArchiveAsset(url, assetName), lspBinDir())) {
    return null;
  }
  await chmodExecutable(bin);
  return File(bin).existsSync() ? bin : null;
}

// ---------------------------------------------------------------------------
// kotlin-lsp (OpenCode's KotlinLS)
// ---------------------------------------------------------------------------

Future<String?> installKotlinLs() async {
  final distDir = _installDir('kotlin-ls');
  final script = Platform.isWindows
      ? p.join(distDir, 'kotlin-lsp.cmd')
      : p.join(distDir, 'kotlin-lsp.sh');
  if (File(script).existsSync()) return script;

  final release = await fetchJson(
    'https://api.github.com/repos/Kotlin/kotlin-lsp/releases/latest',
  );
  if (release is! Map) return null;
  final name = release['name'];
  if (name is! String) return null;
  final version = name.replaceFirst(RegExp('^v'), '');
  if (version.isEmpty) return null;

  final arch = currentArch() == 'arm64' ? 'aarch64' : 'x64';
  final platform = switch (currentPlatformToken()) {
    'macos' => 'mac',
    'windows' => 'win',
    _ => 'linux',
  };
  const supported = {
    'mac-x64',
    'mac-aarch64',
    'linux-x64',
    'linux-aarch64',
    'win-x64',
    'win-aarch64',
  };
  if (!supported.contains('$platform-$arch')) return null;

  final assetName = 'kotlin-lsp-$version-$platform-$arch.zip';
  final url =
      'https://download-cdn.jetbrains.com/kotlin-lsp/$version/$assetName';

  if (!await downloadAndExtract(ArchiveAsset(url, assetName), distDir)) {
    return null;
  }
  // The archive nests the launcher under kotlin-lsp-<version>-<platform>/.
  final found = await _findFile(distDir, p.basename(script));
  if (found == null) return null;
  await chmodExecutable(found);
  return found;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

String? _assetUrl(List<dynamic> assets, String name) {
  for (final asset in assets) {
    if (asset is! Map) continue;
    if (asset['name'] == name) {
      final url = asset['browser_download_url'];
      return url is String ? url : null;
    }
  }
  return null;
}

/// Depth-first search for [basename] under [dir].
Future<String?> _findFile(String dir, String basename) async {
  final root = Directory(dir);
  if (!root.existsSync()) return null;
  final queue = <Directory>[root];
  while (queue.isNotEmpty) {
    final current = queue.removeAt(0);
    await for (final entry in current.list()) {
      if (entry is File && p.basename(entry.path) == basename) {
        return entry.path;
      }
      if (entry is Directory) queue.add(entry);
    }
  }
  return null;
}
