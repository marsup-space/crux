import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Identifies the terminal emulator hosting Crux, from environment
/// variables the terminals themselves export. Mirrors the detection
/// conventions in `utils/terminal_symbols.dart` and nocterm's image
/// protocol detection.
enum TerminalHost {
  windowsTerminal,
  vscode,
  wezterm,
  iterm2,
  appleTerminal,
  ghostty,
  kitty,
  alacritty,
}

TerminalHost? detectTerminalHost([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  if (env['WT_SESSION']?.isNotEmpty == true) {
    return TerminalHost.windowsTerminal;
  }
  switch (env['TERM_PROGRAM']?.toLowerCase()) {
    case 'vscode':
      return TerminalHost.vscode;
    case 'wezterm':
      return TerminalHost.wezterm;
    case 'iterm.app':
      return TerminalHost.iterm2;
    case 'apple_terminal':
      return TerminalHost.appleTerminal;
    case 'ghostty':
      return TerminalHost.ghostty;
    case 'kitty':
      return TerminalHost.kitty;
    case 'alacritty':
      return TerminalHost.alacritty;
  }
  if (env['KITTY_WINDOW_ID']?.isNotEmpty == true) return TerminalHost.kitty;
  return null;
}

/// The `font.cellWidth` presets offered in setup. Windows Terminal only;
/// the values are the tuning steps this card was built around.
enum CellWidthPreset {
  defaultWidth(null),
  compact('0.95ch'),
  tighter('0.9ch'),
  tightest('0.85ch');

  /// The literal settings.json value, or null to remove the override.
  final String? value;
  const CellWidthPreset(this.value);
}

/// Snapshot of the Windows Terminal settings this service manages.
class TerminalFontStatus {
  final File settingsFile;
  final String? fontFace;
  final String? cellWidth;

  const TerminalFontStatus({
    required this.settingsFile,
    this.fontFace,
    this.cellWidth,
  });

  CellWidthPreset? get cellWidthPreset => CellWidthPreset.values
      .where((preset) => preset.value == cellWidth)
      .firstOrNull;
}

/// A `profiles.defaults.font` edit. A null field keeps whatever the
/// settings file already has; a null-`value` preset ([CellWidthPreset.defaultWidth])
/// removes `cellWidth` from the font object.
class FontSettingsEdit {
  final String? face;
  final CellWidthPreset? cellWidthPreset;

  const FontSettingsEdit({this.face, this.cellWidthPreset});
}

/// Reads and surgically edits Windows Terminal's JSONC settings file for
/// the one thing setup needs: `profiles.defaults.font`.
///
/// Windows Terminal writes settings as JSONC (comments, trailing
/// commas), so decoding strips comments first. Writes never re-serialize
/// the whole document — that would destroy the user's comments and key
/// order — only the `font` object's body is rebuilt, and insertions only
/// happen at closing braces that sit on their own line (the layout WT
/// itself writes). Anything else is reported as unsupported rather than
/// risk corrupting a hand-written file.
class TerminalFontService {
  /// Where `LOCALAPPDATA` comes from. Production uses the real
  /// environment; tests inject a temp directory.
  final String? Function()? localAppData;

  const TerminalFontService({this.localAppData});

  String? _localAppData() =>
      localAppData?.call() ?? Platform.environment['LOCALAPPDATA'];

  /// Locates the settings file for either the Store-packaged or the
  /// unpackaged Windows Terminal install. Null when neither exists.
  File? findSettingsFile() {
    final base = _localAppData();
    if (base == null) return null;
    // A machine without Store-packaged apps has no Packages directory at
    // all; that is a normal "no install", not an error.
    final packagesDir = Directory(p.join(base, 'Packages'));
    final packaged = packagesDir.existsSync()
        ? packagesDir
              .listSync()
              .whereType<Directory>()
              .where(
                (dir) => p
                    .basename(dir.path)
                    .startsWith('Microsoft.WindowsTerminal'),
              )
              .map(
                (dir) => File(p.join(dir.path, 'LocalState', 'settings.json')),
              )
        : const Iterable<File>.empty();
    final candidates = <File>[
      // Store (packaged) installs keep a per-package directory whose
      // name ends in the publisher hash; match the prefix.
      ...packaged,
      // Unpackaged / scoop-style install.
      File(p.join(base, 'Microsoft', 'Windows Terminal', 'settings.json')),
    ];
    for (final file in candidates) {
      if (file.existsSync()) return file;
    }
    return null;
  }

  Future<TerminalFontStatus?> loadStatus() async {
    final file = findSettingsFile();
    if (file == null) return null;
    final doc = FontDoc.parse(await file.readAsString());
    return TerminalFontStatus(
      settingsFile: file,
      fontFace: doc.defaultsFont?['face'] as String?,
      cellWidth: doc.defaultsFont?['cellWidth'] as String?,
    );
  }

  /// Applies [edit] to `profiles.defaults.font`. When the settings file
  /// has no `font` object one is inserted (into `profiles.defaults`, or
  /// new `defaults`/`profiles` skeletons as needed). Throws
  /// [UnsupportedError] when the needed insertion point is not a
  /// brace on its own line. Returns the edited file, or null when no
  /// settings file exists.
  Future<File?> applyFontSettings(FontSettingsEdit edit) async {
    final file = findSettingsFile();
    if (file == null) return null;
    final doc = FontDoc.parse(await file.readAsString());
    final updated = doc.editDefaultsFont(edit);
    await file.writeAsString(updated);
    return file;
  }
}

/// Parsed view over one settings document.
class FontDoc {
  final String source;

  /// The `profiles.defaults.font` map, when present and the file parses.
  final Map<String, Object?>? defaultsFont;

  /// Source line range (inclusive) of the `font` object's braces.
  final BlockRange? fontRange;

  /// Line (0-based) of the closing brace of `profiles.defaults`, when
  /// that brace sits on its own line — the insertion point for a new
  /// `font` key. Same for [profilesCloseLine] and [rootCloseLine].
  final int? defaultsCloseLine;
  final int? profilesCloseLine;
  final int? rootCloseLine;

  const FontDoc._(
    this.source,
    this.defaultsFont,
    this.fontRange,
    this.defaultsCloseLine,
    this.profilesCloseLine,
    this.rootCloseLine,
  );

  static FontDoc parse(String source) {
    final stripped = stripJsoncComments(source);
    final font = _decodeDefaultsFont(stripped);
    final layout = _scanLayout(stripped, source);
    return FontDoc._(
      source,
      font,
      layout.fontRange,
      layout.defaultsCloseLine,
      layout.profilesCloseLine,
      layout.rootCloseLine,
    );
  }

  static Map<String, Object?>? _decodeDefaultsFont(String stripped) {
    try {
      final decoded = jsonDecode(stripped);
      if (decoded is! Map) return null;
      final profiles = decoded['profiles'];
      if (profiles is! Map) return null;
      final defaults = profiles['defaults'];
      if (defaults is! Map) return null;
      final font = defaults['font'];
      if (font is! Map) return null;
      return font.cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  /// One pass over the comment-stripped text (whose line structure
  /// matches the original) tracking brace depth, recording the font
  /// block range and the stand-alone closing-brace lines.
  static _Layout _scanLayout(String stripped, String source) {
    var line = 0;
    var depth = 0;
    var inString = false;
    var sawRootClose = false;
    var profilesDepth = -1; // inner depth of the `profiles` block
    var defaultsDepth = -1; // inner depth of the `defaults` block
    var fontDepth = -1; // inner depth of the `font` block
    var fontOpenLine = -1;
    BlockRange? fontRange;
    int? defaultsClose;
    int? profilesClose;
    int? rootClose;
    final lines = const LineSplitter().convert(source);

    void onCloseAt(int currentLine) {
      if (depth == fontDepth && fontDepth > 0) {
        fontRange = BlockRange(fontOpenLine, currentLine);
        fontDepth = -1;
      } else if (depth == defaultsDepth && defaultsDepth > 0) {
        if (_isStandAloneClose(lines, currentLine)) {
          defaultsClose = currentLine;
        }
        defaultsDepth = -1;
      } else if (depth == profilesDepth && profilesDepth > 0) {
        if (_isStandAloneClose(lines, currentLine)) {
          profilesClose = currentLine;
        }
        profilesDepth = -1;
      } else if (depth == 1 && !sawRootClose) {
        if (_isStandAloneClose(lines, currentLine)) {
          rootClose = currentLine;
        }
        sawRootClose = true;
      }
    }

    var i = 0;
    while (i < stripped.length) {
      final ch = stripped[i];
      if (ch == '\n') {
        line++;
        i++;
        continue;
      }
      if (inString) {
        if (ch == r'\') {
          i += 2;
          continue;
        }
        if (ch == '"') inString = false;
        i++;
        continue;
      }
      if (ch == '"') {
        // Read the string token, then decide whether it is a block key.
        var j = i + 1;
        while (j < stripped.length && stripped[j] != '"') {
          if (stripped[j] == r'\') j++;
          j++;
        }
        final token = stripped.substring(i, j + 1);
        var k = j + 1;
        while (k < stripped.length && _isSpaceNotNewline(stripped[k])) {
          k++;
        }
        final isKeyToBlock =
            k < stripped.length &&
            stripped[k] == ':' &&
            (token == '"profiles"' ||
                token == '"defaults"' ||
                token == '"font"');
        if (isKeyToBlock) {
          // Find the value's opening brace, crossing newlines.
          var m = k + 1;
          while (m < stripped.length && _isSpace(stripped[m])) {
            if (stripped[m] == '\n') line++;
            m++;
          }
          if (m < stripped.length && stripped[m] == '{') {
            final inner = depth + 1;
            if (token == '"profiles"' && depth == 1) {
              profilesDepth = inner;
            } else if (token == '"defaults"' &&
                depth > 0 &&
                profilesDepth == depth) {
              defaultsDepth = inner;
            } else if (token == '"font"' &&
                depth > 0 &&
                defaultsDepth == depth) {
              fontDepth = inner;
              fontOpenLine = line;
            }
            // Consume up to (not including) the brace; the main loop's
            // `{` handler adjusts depth.
            i = m;
            continue;
          }
        }
        i = j + 1;
        continue;
      }
      if (ch == '{') {
        depth++;
        i++;
        continue;
      }
      if (ch == '}') {
        onCloseAt(line);
        depth--;
        i++;
        continue;
      }
      i++;
    }
    return _Layout(
      fontRange,
      defaultsClose,
      profilesClose,
      rootClose,
    );
  }

  static bool _isSpace(String ch) =>
      ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n';

  static bool _isSpaceNotNewline(String ch) =>
      ch == ' ' || ch == '\t' || ch == '\r';

  /// A closing brace that starts its own line (`}`, `},`, with only
  /// whitespace before it) — the only safe textual insertion point.
  static bool _isStandAloneClose(List<String> lines, int lineIndex) {
    if (lineIndex < 0 || lineIndex >= lines.length) return false;
    final text = lines[lineIndex];
    return text.trimLeft().startsWith('}');
  }

  /// Rewrites the `font` object body, or inserts a new
  /// `profiles.defaults.font` block when absent.
  String editDefaultsFont(FontSettingsEdit edit) {
    final face = edit.face;
    final cellWidthPreset = edit.cellWidthPreset;
    if (fontRange != null) {
      return _rewriteFontBlock(face, cellWidthPreset);
    }
    return _insertFontBlock(face, cellWidthPreset);
  }

  String _rewriteFontBlock(String? face, CellWidthPreset? cellWidthPreset) {
    final range = fontRange!;
    final lines = const LineSplitter().convert(source);
    final blockLines = lines.sublist(range.startLine, range.endLine + 1);

    // Preserve entries for keys other than face/cellWidth verbatim. face
    // itself is re-emitted below (when kept) so the rewritten block has a
    // single, consistently-encoded face entry; `cellWidth` is dropped
    // unless the edit sets a non-default preset.
    final preserved = <String>[];
    final keys = defaultsFont?.keys.toList() ?? const <String>[];
    for (final key in keys) {
      if (key == 'cellWidth' || key == 'face') continue;
      final found = _findEntryLine(blockLines, key);
      if (found != null) preserved.add(found);
    }

    final nextFace = face ?? defaultsFont?['face'] as String?;
    final nextCellWidth = cellWidthPreset == null
        ? (defaultsFont?['cellWidth'] as String?)
        : cellWidthPreset.value;

    final encoder = const JsonEncoder();
    final entries = <String>[
      ...preserved,
      if (nextFace != null) '"face": ${encoder.convert(nextFace)}',
      if (nextCellWidth != null)
        '"cellWidth": ${encoder.convert(nextCellWidth)}',
    ];

    final indentMatch = RegExp(r'^(\s*)\{').firstMatch(blockLines.first);
    final pad = indentMatch?.group(1) ?? '            ';
    final body = entries.join(',\n').split('\n').map((l) => '$pad    $l');
    final rebuilt = ['$pad{', ...body, '$pad}'].join('\n');
    return [
      ...lines.sublist(0, range.startLine),
      ...rebuilt.split('\n'),
      ...lines.sublist(range.endLine + 1),
    ].join('\n');
  }

  /// A single-line `"key": value(,)?` entry, comma stripped, indented
  /// from the source line. Null when the entry spans multiple lines
  /// (not produced by WT's writer nor by this service).
  String? _findEntryLine(List<String> blockLines, String key) {
    final regex = RegExp(
      '"${RegExp.escape(key)}"\\s*:\\s*(?:"(?:[^"\\\\]|\\\\.)*"|-?\\d+(?:\\.\\d+)?|true|false|null)\\s*,?',
    );
    for (final line in blockLines) {
      final match = regex.firstMatch(line);
      if (match != null) {
        return line
            .substring(0, match.end)
            .trimLeft()
            .replaceFirst(RegExp(r',\s*$'), '');
      }
    }
    return null;
  }

  String _insertFontBlock(String? face, CellWidthPreset? cellWidthPreset) {
    final encoder = const JsonEncoder();
    final raw = <String>[
      if (face != null) '"face": ${encoder.convert(face)}',
      if (cellWidthPreset != null && cellWidthPreset.value != null)
        '"cellWidth": ${encoder.convert(cellWidthPreset.value)}',
    ];
    // Every entry line but the last needs a trailing comma.
    final entries = <String>[
      for (var i = 0; i < raw.length; i++)
        i == raw.length - 1 ? raw[i] : '${raw[i]},',
    ];
    if (entries.isEmpty) return source;

    final lines = const LineSplitter().convert(source).toList();
    List<String> inserted;
    int beforeLine;
    if (defaultsCloseLine case final close?) {
      // `profiles.defaults` exists without a `font` object.
      final indent = '${_indentOf(lines[close])}    ';
      inserted = [
        '$indent"font":',
        '$indent{',
        ...entries.map((e) => '$indent    $e'),
        '$indent}',
      ];
      beforeLine = close;
    } else if (profilesCloseLine case final close?) {
      // `profiles` exists without `defaults`.
      final indent = '${_indentOf(lines[close])}    ';
      inserted = [
        '$indent"defaults":',
        '$indent{',
        '$indent    "font":',
        '$indent    {',
        ...entries.map((e) => '$indent        $e'),
        '$indent    }',
        '$indent}',
      ];
      beforeLine = close;
    } else if (rootCloseLine case final close?) {
      final indent = '${_indentOf(lines[close])}    ';
      inserted = [
        '$indent"profiles":',
        '$indent{',
        '$indent    "defaults":',
        '$indent    {',
        '$indent        "font":',
        '$indent        {',
        ...entries.map((e) => '$indent            $e'),
        '$indent        }',
        '$indent    }',
        '$indent}',
      ];
      beforeLine = close;
    } else {
      throw UnsupportedError(
        'Windows Terminal settings layout is not recognized; '
        'refusing to insert font settings',
      );
    }

    // The last entry before the insertion point needs a trailing comma
    // unless it already has one or the block is still empty.
    final prevIndex = _previousContentLine(lines, beforeLine);
    if (prevIndex >= 0) {
      final prev = lines[prevIndex];
      final trimmed = prev.trimRight();
      if (!trimmed.endsWith(',') &&
          !trimmed.endsWith('{') &&
          !trimmed.endsWith('[')) {
        lines[prevIndex] = '$trimmed,';
      }
    }
    lines.insertAll(beforeLine, inserted);
    return lines.join('\n');
  }

  static String _indentOf(String line) {
    final match = RegExp(r'^\s*').firstMatch(line);
    return match?.group(0) ?? '';
  }

  /// The closest preceding line with content (not blank).
  static int _previousContentLine(List<String> lines, int before) {
    for (var i = before - 1; i >= 0; i--) {
      if (lines[i].trim().isNotEmpty) return i;
    }
    return -1;
  }
}

/// Inclusive source line range of a block.
class BlockRange {
  final int startLine;
  final int endLine;
  const BlockRange(this.startLine, this.endLine);
}

class _Layout {
  final BlockRange? fontRange;
  final int? defaultsCloseLine;
  final int? profilesCloseLine;
  final int? rootCloseLine;

  const _Layout(
    this.fontRange,
    this.defaultsCloseLine,
    this.profilesCloseLine,
    this.rootCloseLine,
  );
}

/// Removes `//` and `/* */` comments outside string literals, keeping
/// newlines so line numbers stay aligned with the original source.
String stripJsoncComments(String source) {
  final out = StringBuffer();
  var inString = false;
  var inLineComment = false;
  var inBlockComment = false;
  for (var i = 0; i < source.length; i++) {
    final ch = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (inLineComment) {
      if (ch == '\n') {
        inLineComment = false;
        out.write(ch);
      }
      continue;
    }
    if (inBlockComment) {
      if (ch == '*' && next == '/') {
        inBlockComment = false;
        i++;
      } else if (ch == '\n') {
        out.write('\n');
      }
      continue;
    }
    if (inString) {
      out.write(ch);
      if (ch == r'\' && next.isNotEmpty) {
        out.write(next);
        i++;
      } else if (ch == '"') {
        inString = false;
      }
      continue;
    }
    if (ch == '"') {
      inString = true;
      out.write(ch);
      continue;
    }
    if (ch == '/' && next == '/') {
      inLineComment = true;
      i++;
      continue;
    }
    if (ch == '/' && next == '*') {
      inBlockComment = true;
      i++;
      continue;
    }
    out.write(ch);
  }
  return out.toString();
}
