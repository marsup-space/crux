import 'dart:io';

import 'package:dart_jieba/dart_jieba.dart';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

bool _isCJK(int codeUnit) {
  return (codeUnit >= 0x4E00 && codeUnit <= 0x9FFF) ||
      (codeUnit >= 0x3400 && codeUnit <= 0x4DBF) ||
      (codeUnit >= 0xF900 && codeUnit <= 0xFAFF);
}

bool _isLatinWordChar(int codeUnit) {
  return (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
      (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
      (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      codeUnit == 0x5F;
}

bool _isSpace(int codeUnit) {
  return codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0D;
}

bool _isPunctuation(int codeUnit) {
  return codeUnit == 0x2E ||
      codeUnit == 0x2C ||
      codeUnit == 0x3B ||
      codeUnit == 0x3A ||
      codeUnit == 0x21 ||
      codeUnit == 0x3F ||
      codeUnit == 0x28 ||
      codeUnit == 0x29 ||
      codeUnit == 0x5B ||
      codeUnit == 0x5D ||
      codeUnit == 0x7B ||
      codeUnit == 0x7D ||
      codeUnit == 0x22 ||
      codeUnit == 0x27 ||
      codeUnit == 0x2F ||
      codeUnit == 0x5C;
}

enum _CharClass { cjk, latin, space, punct, other }

_CharClass _classify(int codeUnit) {
  if (_isCJK(codeUnit)) return _CharClass.cjk;
  if (_isLatinWordChar(codeUnit)) return _CharClass.latin;
  if (_isSpace(codeUnit)) return _CharClass.space;
  if (_isPunctuation(codeUnit)) return _CharClass.punct;
  return _CharClass.other;
}

JiebaSegmenter? _jieba;

JiebaSegmenter _getJieba() {
  if (_jieba != null) return _jieba!;
  _jieba = JiebaSegmenter()..initializeSync(dictPath: _resolveJiebaDictPath());
  return _jieba!;
}

/// Resolves the jieba dictionary (`dict.dgz`) without depending on the
/// working directory: `bin/crux.dart` repoints `Directory.current` at the
/// opened project before the first boundary lookup, so dart-jieba's
/// CWD-relative auto-detection crashes any run outside the source tree.
/// Candidate order mirrors `resolveBundledDirectory` in
/// `bundled_directory.dart` — executable-relative first (release bundles
/// ship the dictionary at `third_party/jieba/dict.dgz`, see
/// `tool/build_release.dart`), then script-relative (source checkouts
/// read it from the `dart-jieba` path dependency), with the working
/// directory only as a last resort.
String _resolveJiebaDictPath() {
  final candidates = <String>[];

  void addCandidate(String base, List<String> segments) {
    final path = p.normalize(p.absolute(p.joinAll([base, ...segments])));
    if (!candidates.contains(path)) candidates.add(path);
  }

  const bundled = ['third_party', 'jieba', 'dict.dgz'];
  const sourceTree = ['dart-jieba', 'assets', 'dict.dgz'];

  try {
    final executableDir = p.dirname(Platform.resolvedExecutable);
    // Release layout: <bundle>/bin/crux → <bundle>/third_party/jieba/.
    addCandidate(executableDir, bundled);
    addCandidate(executableDir, ['..', ...bundled]);
  } catch (_) {}

  try {
    final script = Platform.script;
    if (script.scheme == 'file') {
      final scriptDir = p.dirname(script.toFilePath());
      addCandidate(scriptDir, bundled);
      // `dart run bin/crux.dart` from any directory: bin/ → repo root.
      addCandidate(scriptDir, ['..', ...bundled]);
      addCandidate(scriptDir, sourceTree);
      addCandidate(scriptDir, ['..', ...sourceTree]);
    }
  } catch (_) {}

  final launchDirectory = Directory.current.path;
  addCandidate(launchDirectory, bundled);
  addCandidate(launchDirectory, sourceTree);

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  throw StateError(
    'jieba dictionary (dict.dgz) not found — CJK word navigation is '
    'unavailable.\nSearched:\n'
    '${candidates.map((candidate) => '  - $candidate').join('\n')}\n'
    'Release bundles must ship the dictionary at '
    'third_party/jieba/dict.dgz next to the executable; source checkouts '
    'read it from dart-jieba/assets/dict.dgz.',
  );
}

int _previousWordBoundary(String text, int offset) {
  if (offset <= 0) return 0;

  int pos = offset;

  while (pos > 0 && _isSpace(text.codeUnitAt(pos - 1))) {
    pos--;
  }
  if (pos == 0) return 0;

  final charClass = _classify(text.codeUnitAt(pos - 1));

  if (charClass == _CharClass.cjk) {
    final cjkRange = _findCJKRunBackward(text, pos);
    final boundaries = _jiebaBoundaries(text, cjkRange.$1, cjkRange.$2);
    int boundary = cjkRange.$1;
    for (final b in boundaries) {
      if (b < pos) {
        boundary = b;
      } else {
        break;
      }
    }
    return boundary;
  }

  if (charClass == _CharClass.latin) {
    while (pos > 0 && _classify(text.codeUnitAt(pos - 1)) == _CharClass.latin) {
      pos--;
    }
    return pos;
  }

  final startClass = charClass;
  while (pos > 0 && _classify(text.codeUnitAt(pos - 1)) == startClass) {
    pos--;
  }
  return pos;
}

int _nextWordBoundary(String text, int offset) {
  final len = text.length;
  if (offset >= len) return len;

  final charClass = _classify(text.codeUnitAt(offset));

  if (charClass == _CharClass.space) {
    int pos = offset;
    while (pos < len && _isSpace(text.codeUnitAt(pos))) {
      pos++;
    }
    return pos;
  }

  if (charClass == _CharClass.cjk) {
    final cjkRange = _findCJKRunForward(text, offset);
    final boundaries = _jiebaBoundaries(text, cjkRange.$1, cjkRange.$2);
    for (final b in boundaries) {
      if (b > offset) return b;
    }
    return cjkRange.$2;
  }

  if (charClass == _CharClass.latin) {
    int pos = offset;
    while (pos < len && _classify(text.codeUnitAt(pos)) == _CharClass.latin) {
      pos++;
    }
    return pos;
  }

  final startClass = charClass;
  int pos = offset;
  while (pos < len && _classify(text.codeUnitAt(pos)) == startClass) {
    pos++;
  }
  return pos;
}

(int, int) _findCJKRunBackward(String text, int pos) {
  int start = pos;
  while (start > 0 && _isCJK(text.codeUnitAt(start - 1))) {
    start--;
  }
  int end = pos;
  while (end < text.length && _isCJK(text.codeUnitAt(end))) {
    end++;
  }
  return (start, end);
}

(int, int) _findCJKRunForward(String text, int pos) {
  int start = pos;
  while (start > 0 && _isCJK(text.codeUnitAt(start - 1))) {
    start--;
  }
  int end = pos;
  while (end < text.length && _isCJK(text.codeUnitAt(end))) {
    end++;
  }
  return (start, end);
}

List<int> _jiebaBoundaries(String text, int start, int end) {
  final cjkText = text.substring(start, end);
  final words = _getJieba().cut(cjkText);
  final boundaries = <int>[start];
  int offset = start;
  for (final word in words) {
    offset += word.length;
    boundaries.add(offset);
  }
  return boundaries;
}

final WordBoundaryProvider cjkWordBoundaryProvider = (
  previousBoundary: _previousWordBoundary,
  nextBoundary: _nextWordBoundary,
);
