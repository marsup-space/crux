import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

class ThemeConfigStore {
  final File file;

  const ThemeConfigStore(this.file);

  Future<String?> readThemeId() async {
    if (!await file.exists()) return null;
    final map = TomlDocument.parse(await file.readAsString()).toMap();
    final ui = map['ui'];
    if (ui is! Map) return null;
    final theme = ui['theme'];
    return theme is String && theme.isNotEmpty ? theme : null;
  }

  Future<void> writeThemeId(String themeId) async {
    Map<String, dynamic> map = {};
    if (await file.exists()) {
      map = TomlDocument.parse(await file.readAsString()).toMap();
    }
    final ui = map['ui'] is Map
        ? Map<String, dynamic>.from(map['ui'] as Map)
        : <String, dynamic>{};
    ui['theme'] = themeId;
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
