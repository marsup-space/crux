import 'package:dart_jieba/dart_jieba.dart';
import 'package:nocterm/nocterm.dart';

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
  _jieba = JiebaSegmenter()..initializeSync();
  return _jieba!;
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
