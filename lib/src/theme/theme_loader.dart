import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'crux_theme.dart';
import 'theme_registry.dart';

class ThemeLoader {
  final Directory bundledDirectory;
  final Directory userDirectory;

  const ThemeLoader({
    required this.bundledDirectory,
    required this.userDirectory,
  });

  Future<ThemeRegistry> load() async {
    final themes = <String, CruxThemeData>{};
    final errors = <String, String>{};

    await _loadDirectory(
      bundledDirectory,
      themes: themes,
      errors: errors,
      overrideExisting: true,
    );

    themes.putIfAbsent('dracula', () => CruxThemeData.draculaFallback);

    await _seedExample();
    await _loadDirectory(
      userDirectory,
      themes: themes,
      errors: errors,
      overrideExisting: true,
    );

    final curated = curatedThemeIds.where(themes.containsKey);
    final custom =
        themes.keys.where((id) => !curatedThemeIds.contains(id)).toList()
          ..sort();

    return ThemeRegistry(
      themes: themes,
      orderedIds: [...curated, ...custom],
      loadErrors: errors,
    );
  }

  Future<void> _loadDirectory(
    Directory directory, {
    required Map<String, CruxThemeData> themes,
    required Map<String, String> errors,
    required bool overrideExisting,
  }) async {
    if (!await directory.exists()) return;
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.toml'))
            .where((file) => !p.basename(file.path).startsWith('example.'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      final id = p.basenameWithoutExtension(file.path);
      try {
        final theme = await loadFile(file, id: id);
        if (overrideExisting || !themes.containsKey(id)) {
          themes[id] = theme;
        }
      } catch (error) {
        errors[file.path] = error.toString();
      }
    }
  }

  Future<void> _seedExample() async {
    final source = File(p.join(bundledDirectory.path, 'example.theme.toml'));
    if (!await source.exists()) return;
    await userDirectory.create(recursive: true);
    final target = File(p.join(userDirectory.path, 'example.theme.toml'));
    final content = await source.readAsString();
    if (!await target.exists() || await target.readAsString() != content) {
      await target.writeAsString(content, flush: true);
    }
  }

  static Future<CruxThemeData> loadFile(File file, {String? id}) async {
    final content = await file.readAsString();
    return parse(content, id: id ?? p.basenameWithoutExtension(file.path));
  }

  static CruxThemeData parse(String source, {required String id}) {
    final map = TomlDocument.parse(source).toMap();
    final name = _string(map, 'name');
    final brightnessValue = _string(map, 'brightness');
    final brightness = switch (brightnessValue) {
      'dark' => Brightness.dark,
      'light' => Brightness.light,
      _ => throw FormatException(
        'Theme "$id": brightness must be "dark" or "light"',
      ),
    };
    final colors = _section(map, 'colors');
    final markdown = _section(map, 'markdown');
    final syntax = _section(map, 'syntax');

    Color color(Map<String, dynamic> section, String key) {
      final value = _string(section, key);
      if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(value)) {
        throw FormatException('Theme "$id": "$key" must be a #RRGGBB color');
      }
      return Color(int.parse(value.substring(1), radix: 16));
    }

    return CruxThemeData(
      id: id,
      name: name,
      brightness: brightness,
      background: color(colors, 'background'),
      surface: color(colors, 'surface'),
      surfaceVariant: color(colors, 'surface_variant'),
      primary: color(colors, 'primary'),
      onPrimary: color(colors, 'on_primary'),
      secondary: color(colors, 'secondary'),
      onSecondary: color(colors, 'on_secondary'),
      accent: color(colors, 'accent'),
      error: color(colors, 'error'),
      onError: color(colors, 'on_error'),
      warning: color(colors, 'warning'),
      onWarning: color(colors, 'on_warning'),
      success: color(colors, 'success'),
      onSuccess: color(colors, 'on_success'),
      info: color(colors, 'info'),
      text: color(colors, 'text'),
      textMuted: color(colors, 'text_muted'),
      border: color(colors, 'border'),
      borderActive: color(colors, 'border_active'),
      borderSubtle: color(colors, 'border_subtle'),
      selection: color(colors, 'selection'),
      selectedText: color(colors, 'selected_text'),
      markdownText: color(markdown, 'text'),
      markdownHeading: color(markdown, 'heading'),
      markdownLink: color(markdown, 'link'),
      markdownCode: color(markdown, 'code'),
      markdownBlockQuote: color(markdown, 'block_quote'),
      markdownEmphasis: color(markdown, 'emphasis'),
      markdownStrong: color(markdown, 'strong'),
      markdownRule: color(markdown, 'rule'),
      markdownList: color(markdown, 'list'),
      markdownCodeBlock: color(markdown, 'code_block'),
      syntaxDefault: color(syntax, 'default'),
      syntaxComment: color(syntax, 'comment'),
      syntaxKeyword: color(syntax, 'keyword'),
      syntaxStorage: color(syntax, 'storage'),
      syntaxFunction: color(syntax, 'function'),
      syntaxType: color(syntax, 'type'),
      syntaxString: color(syntax, 'string'),
      syntaxConstant: color(syntax, 'constant'),
      syntaxNumber: color(syntax, 'number'),
      syntaxVariable: color(syntax, 'variable'),
      syntaxTag: color(syntax, 'tag'),
      syntaxAttribute: color(syntax, 'attribute'),
      syntaxOperator: color(syntax, 'operator'),
      syntaxPunctuation: color(syntax, 'punctuation'),
      syntaxMeta: color(syntax, 'meta'),
    );
  }

  static Map<String, dynamic> _section(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! Map) {
      throw FormatException('Missing [$key] section');
    }
    return Map<String, dynamic>.from(value);
  }

  static String _string(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Missing required string "$key"');
    }
    return value;
  }
}
