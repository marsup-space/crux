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
      final warnings = <String>[];
      try {
        final theme = await loadFile(file, id: id, warnings: warnings);
        if (overrideExisting || !themes.containsKey(id)) {
          themes[id] = theme;
        }
        // Non-fatal diagnostics (per-token Dracula fallbacks) ride the
        // same channel as hard load failures; the startup code in
        // bin/crux.dart already reports these entries as
        // "theme warning" lines and in-app toasts.
        if (warnings.isNotEmpty) {
          errors[file.path] =
              'fallback defaults applied: ${warnings.join('; ')}';
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

  static Future<CruxThemeData> loadFile(
    File file, {
    String? id,
    List<String>? warnings,
  }) async {
    final content = await file.readAsString();
    return parse(
      content,
      id: id ?? p.basenameWithoutExtension(file.path),
      warnings: warnings,
    );
  }

  /// Parses a theme TOML document.
  ///
  /// `name` and `brightness` are required. Every color token is
  /// optional: a missing token falls back to the built-in Dracula
  /// value and is reported through [warnings] (when provided).
  /// Malformed values (non-string, bad color format, bad table
  /// shapes) still reject the whole file with a [FormatException].
  /// Colors accept `#RRGGBB` and the `#RGB` shorthand.
  static CruxThemeData parse(
    String source, {
    required String id,
    List<String>? warnings,
  }) {
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
    const fallback = CruxThemeData.draculaFallback;
    final colors = _section(map, 'colors', id: id, warnings: warnings);
    final markdown = _section(map, 'markdown', id: id, warnings: warnings);
    final syntax = _section(map, 'syntax', id: id, warnings: warnings);

    // Required-role token: falls back per-token to the Dracula
    // default when absent (with a warning). A missing section was
    // already reported once by [_section], so per-token warnings are
    // skipped in that case to avoid noise.
    Color color(
      Map<String, dynamic>? section,
      String sectionName,
      String key,
      Color fallbackColor,
    ) {
      final raw = section?[key];
      if (raw == null) {
        if (section != null) {
          warnings?.add('missing [$sectionName] "$key"; using Dracula default');
        }
        return fallbackColor;
      }
      return _parseColor(raw, id: id, key: key);
    }

    // Truly optional token: absent means "derive at runtime"
    // (see CruxThemeData getters); no warning is recorded.
    Color? optionalColor(Map<String, dynamic>? section, String key) {
      final raw = section?[key];
      if (raw == null) return null;
      return _parseColor(raw, id: id, key: key);
    }

    final surfaceVariant = color(
      colors,
      'colors',
      'surface_variant',
      fallback.surfaceVariant,
    );

    return CruxThemeData(
      id: id,
      name: name,
      brightness: brightness,
      background: color(colors, 'colors', 'background', fallback.background),
      surface: color(colors, 'colors', 'surface', fallback.surface),
      surfaceVariant: surfaceVariant,
      primary: color(colors, 'colors', 'primary', fallback.primary),
      onPrimary: color(colors, 'colors', 'on_primary', fallback.onPrimary),
      secondary: color(colors, 'colors', 'secondary', fallback.secondary),
      onSecondary: color(
        colors,
        'colors',
        'on_secondary',
        fallback.onSecondary,
      ),
      accent: color(colors, 'colors', 'accent', fallback.accent),
      error: color(colors, 'colors', 'error', fallback.error),
      onError: color(colors, 'colors', 'on_error', fallback.onError),
      warning: color(colors, 'colors', 'warning', fallback.warning),
      onWarning: color(colors, 'colors', 'on_warning', fallback.onWarning),
      success: color(colors, 'colors', 'success', fallback.success),
      onSuccess: color(colors, 'colors', 'on_success', fallback.onSuccess),
      info: color(colors, 'colors', 'info', fallback.info),
      text: color(colors, 'colors', 'text', fallback.text),
      textMuted: color(colors, 'colors', 'text_muted', fallback.textMuted),
      border: color(colors, 'colors', 'border', fallback.border),
      borderActive: color(
        colors,
        'colors',
        'border_active',
        fallback.borderActive,
      ),
      borderSubtle: color(
        colors,
        'colors',
        'border_subtle',
        fallback.borderSubtle,
      ),
      selection: color(colors, 'colors', 'selection', fallback.selection),
      selectedText: color(
        colors,
        'colors',
        'selected_text',
        fallback.selectedText,
      ),
      markdownText: color(markdown, 'markdown', 'text', fallback.markdownText),
      markdownHeading: color(
        markdown,
        'markdown',
        'heading',
        fallback.markdownHeading,
      ),
      markdownLink: color(markdown, 'markdown', 'link', fallback.markdownLink),
      markdownCode: color(markdown, 'markdown', 'code', fallback.markdownCode),
      markdownBlockQuote: color(
        markdown,
        'markdown',
        'block_quote',
        fallback.markdownBlockQuote,
      ),
      markdownEmphasis: color(
        markdown,
        'markdown',
        'emphasis',
        fallback.markdownEmphasis,
      ),
      markdownStrong: color(
        markdown,
        'markdown',
        'strong',
        fallback.markdownStrong,
      ),
      markdownRule: color(markdown, 'markdown', 'rule', fallback.markdownRule),
      markdownList: color(markdown, 'markdown', 'list', fallback.markdownList),
      markdownCodeBlock: color(
        markdown,
        'markdown',
        'code_block',
        fallback.markdownCodeBlock,
      ),
      syntaxDefault: color(syntax, 'syntax', 'default', fallback.syntaxDefault),
      syntaxComment: color(syntax, 'syntax', 'comment', fallback.syntaxComment),
      syntaxKeyword: color(syntax, 'syntax', 'keyword', fallback.syntaxKeyword),
      syntaxStorage: color(syntax, 'syntax', 'storage', fallback.syntaxStorage),
      syntaxFunction: color(
        syntax,
        'syntax',
        'function',
        fallback.syntaxFunction,
      ),
      syntaxType: color(syntax, 'syntax', 'type', fallback.syntaxType),
      syntaxString: color(syntax, 'syntax', 'string', fallback.syntaxString),
      syntaxConstant: color(
        syntax,
        'syntax',
        'constant',
        fallback.syntaxConstant,
      ),
      syntaxNumber: color(syntax, 'syntax', 'number', fallback.syntaxNumber),
      syntaxVariable: color(
        syntax,
        'syntax',
        'variable',
        fallback.syntaxVariable,
      ),
      syntaxTag: color(syntax, 'syntax', 'tag', fallback.syntaxTag),
      syntaxAttribute: color(
        syntax,
        'syntax',
        'attribute',
        fallback.syntaxAttribute,
      ),
      syntaxOperator: color(
        syntax,
        'syntax',
        'operator',
        fallback.syntaxOperator,
      ),
      syntaxPunctuation: color(
        syntax,
        'syntax',
        'punctuation',
        fallback.syntaxPunctuation,
      ),
      syntaxMeta: color(syntax, 'syntax', 'meta', fallback.syntaxMeta),
      // Chip background is optional in user theme TOML — we
      // fall back to `surface_variant` when not provided.
      chipBackground:
          optionalColor(colors, 'chip_background') ?? surfaceVariant,
      // Optional tokens with runtime-derived defaults (no warnings).
      assistantColor: optionalColor(colors, 'assistant'),
      diffAddedColor: optionalColor(colors, 'diff_added'),
      diffRemovedColor: optionalColor(colors, 'diff_removed'),
      diffAddedBackgroundColor: optionalColor(colors, 'diff_added_bg'),
      diffRemovedBackgroundColor: optionalColor(colors, 'diff_removed_bg'),
      markdownH1: optionalColor(markdown, 'h1'),
      markdownH2: optionalColor(markdown, 'h2'),
      markdownH3: optionalColor(markdown, 'h3'),
      markdownH4: optionalColor(markdown, 'h4'),
      markdownH5: optionalColor(markdown, 'h5'),
      markdownH6: optionalColor(markdown, 'h6'),
    );
  }

  /// Parses a `#RRGGBB` or `#RGB` color literal.
  static Color _parseColor(
    Object raw, {
    required String id,
    required String key,
  }) {
    final value = raw is String ? raw : '';
    final match = RegExp(r'^#([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6})$')
        .firstMatch(value);
    if (match == null) {
      throw FormatException(
        'Theme "$id": "$key" must be a #RRGGBB or #RGB color',
      );
    }
    var hex = match.group(1)!;
    if (hex.length == 3) {
      // Expand shorthand: #abc → #aabbcc.
      hex = hex.split('').map((digit) => '$digit$digit').join();
    }
    return Color(int.parse(hex, radix: 16));
  }

  /// Returns the table at [key], or null (with a warning) when the
  /// section is absent — per-token Dracula fallbacks then apply.
  /// A present-but-non-table value remains a hard error.
  static Map<String, dynamic>? _section(
    Map<String, dynamic> map,
    String key, {
    required String id,
    List<String>? warnings,
  }) {
    final value = map[key];
    if (value == null) {
      warnings?.add('missing [$key] section; using Dracula defaults');
      return null;
    }
    if (value is! Map) {
      throw FormatException('Theme "$id": [$key] must be a table');
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
