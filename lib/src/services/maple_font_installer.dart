import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'runtime_setup_service.dart';

/// The font face name Windows Terminal users pick for Maple Mono NF CN.
const mapleFontFaceName = 'Maple Mono NF CN';

const _mapleDownloadUrl =
    'https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMono-NF-CN-unhinted.zip';
const _mapleSha256 =
    'ab88522932cf4015dffeaef6dedc59a22a5fefecdcc6e583d9fcd997da5b7cac';

String? _localAppDataDefault() => Platform.environment['LOCALAPPDATA'];

/// Whether at least one Maple Mono NF CN font file is present in the
/// per-user Windows fonts directory. Always false on non-Windows hosts.
bool isMapleMonoInstalled([String? Function()? localAppData]) {
  if (!Platform.isWindows) return false;
  final base = (localAppData ?? _localAppDataDefault)();
  if (base == null) return false;
  final fontsDir = Directory(p.join(base, 'Microsoft', 'Windows', 'Fonts'));
  if (!fontsDir.existsSync()) return false;
  return fontsDir
      .listSync()
      .whereType<File>()
      .any((file) => p.basename(file.path).startsWith('MapleMono-NF-CN-'));
}

/// Downloads, extracts, and per-user registers Maple Mono NF CN so the
/// terminal font card can offer it in Windows Terminal.
///
/// The zip is fetched through the same verified GitHub transport chain
/// as the runtime assets; every `.ttf` is written into the user's font
/// directory and registered under `HKCU\...\Fonts` with a `(Crux)`
/// suffix so the entry is recognizable and never clobbers a system-wide
/// install of the same family.
///
/// Throws [UnsupportedError] on non-Windows hosts.
Future<void> installMapleMonoNfCn({
  RuntimeProgressCallback? onProgress,
  String? Function()? localAppData,
}) async {
  if (!Platform.isWindows) {
    throw UnsupportedError(
      'Maple Mono NF CN can only be installed automatically on Windows',
    );
  }
  onProgress?.call(0.02, 'checking');
  if (isMapleMonoInstalled(localAppData)) {
    onProgress?.call(1, 'ready');
    return;
  }
  final base = (localAppData ?? _localAppDataDefault)();
  if (base == null) {
    throw StateError('LOCALAPPDATA is not available');
  }

  onProgress?.call(0.05, 'downloading');
  final bytes = await RuntimeSetupService().downloadVerifiedAsset(
    url: _mapleDownloadUrl,
    expectedSha256: _mapleSha256,
    onProgress: (progress, stage, [stats]) =>
        onProgress?.call(0.05 + progress * 0.7, stage, stats),
  );

  onProgress?.call(0.8, 'extracting');
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  final fonts = archive.files.where(
    (file) => file.isFile && file.name.endsWith('.ttf'),
  );
  if (fonts.isEmpty) {
    throw StateError('Maple Mono archive contains no font files');
  }
  final fontsDir = Directory(p.join(base, 'Microsoft', 'Windows', 'Fonts'));
  await fontsDir.create(recursive: true);
  var written = 0;
  final total = fonts.length;
  for (final font in fonts) {
    final file = File(p.join(fontsDir.path, p.basename(font.name)));
    await file.writeAsBytes(font.content as List<int>, flush: true);
    written++;
    final style = _styleOf(p.basename(font.name));
    final register = await Process.run('reg', [
      'add',
      r'HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts',
      '/v',
      'MapleMono NF CN $style (Crux)',
      '/t',
      'REG_SZ',
      '/d',
      file.path,
      '/f',
    ]);
    if (register.exitCode != 0) {
      throw StateError(
        'could not register ${file.path}: ${register.stderr}',
      );
    }
    onProgress?.call(
      0.8 + 0.18 * written / total,
      'extracting',
    );
  }
  onProgress?.call(1, 'ready');
}

/// `MapleMono-NF-CN-Bold.ttf` → `Bold`; unstyled files register as
/// `Regular`.
String _styleOf(String fileName) {
  final stem = fileName.replaceFirst(RegExp(r'\.ttf$'), '');
  final parts = stem.split('-');
  if (parts.length < 4) return 'Regular';
  final style = parts.sublist(3).join(' ');
  return style.isEmpty ? 'Regular' : style;
}
