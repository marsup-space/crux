import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

/// Reads and writes the `ui.language` and `ui.reply_language` keys of
/// `config.toml`.
///
/// Mirrors `ThemeConfigStore` exactly: a read-modify-write over the whole
/// config file (so `ui.theme`, `[home]`, and any other section survive),
/// persisted with an atomic temp-file + rename so a crash mid-write can't
/// corrupt the config. Only the `language` and `reply_language` keys are
/// this store's concern — the theme store owns `ui.theme` and the
/// home-layout store owns `[home]`.
class LocaleConfigStore {
  final File file;

  const LocaleConfigStore(this.file);

  Future<String?> readLocale() => _readUiKey('language');

  Future<void> writeLocale(String locale) => _writeUiKey('language', locale);

  Future<String?> readReplyLanguage() => _readUiKey('reply_language');

  Future<void> writeReplyLanguage(String mode) =>
      _writeUiKey('reply_language', mode);

  Future<String?> _readUiKey(String key) async {
    if (!await file.exists()) return null;
    final map = TomlDocument.parse(await file.readAsString()).toMap();
    final ui = map['ui'];
    if (ui is! Map) return null;
    final value = ui[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<void> _writeUiKey(String key, String value) async {
    Map<String, dynamic> map = {};
    if (await file.exists()) {
      map = TomlDocument.parse(await file.readAsString()).toMap();
    }
    final ui = map['ui'] is Map
        ? Map<String, dynamic>.from(map['ui'] as Map)
        : <String, dynamic>{};
    ui[key] = value;
    map['ui'] = ui;

    final document = TomlDocument.fromMap(map);
    final printer = TomlPrettyPrinter();
    document.acceptVisitor(printer);

    await file.parent.create(recursive: true);
    final temporary = File(
      p.join(
        file.parent.path,
        '.${p.basename(file.path)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await temporary.writeAsString('${printer.toString()}\n', flush: true);
    try {
      await temporary.rename(file.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}
