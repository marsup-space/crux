import 'package:test/test.dart';

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
  return codeUnit == 0x20 || codeUnit == 0x09 || codeUnit == 0x0A || codeUnit == 0x0D;
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

// Pure boundary logic without jieba — tests character-class transitions
// which are the core mechanism for CJK ↔ Latin boundaries

int _previousBoundaryNoJieba(String text, int offset) {
  if (offset <= 0) return 0;
  int pos = offset;

  while (pos > 0 && _isSpace(text.codeUnitAt(pos - 1))) {
    pos--;
  }
  if (pos == 0) return 0;

  final charClass = _classify(text.codeUnitAt(pos - 1));

  if (charClass == _CharClass.cjk) {
    while (pos > 0 && _classify(text.codeUnitAt(pos - 1)) == _CharClass.cjk) {
      pos--;
    }
    return pos;
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

int _nextBoundaryNoJieba(String text, int offset) {
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
    int pos = offset;
    while (pos < len && _classify(text.codeUnitAt(pos)) == _CharClass.cjk) {
      pos++;
    }
    return pos;
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

void main() {
  group('CJK-Latin word boundary transitions', () {
    test('CJK-Latin transition is a boundary (backward)', () {
      // "asdas我们dasdasd" — positions: a(0)s(1)d(2)a(3)s(4)我(5)们(6)d(7)a(8)s(9)d(10)a(11)s(12)d(13)
      final text = 'asdas我们dasdasd';
      // From end (14), backward should stop at CJK→Latin boundary
      expect(_previousBoundaryNoJieba(text, 14), equals(7)); // skip "dasdasd"
      // From 7, backward should stop at Latin→CJK boundary
      expect(_previousBoundaryNoJieba(text, 7), equals(5)); // skip "我们"
      // From 5, backward should stop at start
      expect(_previousBoundaryNoJieba(text, 5), equals(0)); // skip "asdas"
    });

    test('CJK-Latin transition is a boundary (forward)', () {
      final text = 'asdas我们dasdasd';
      // From 0, forward should stop at Latin→CJK boundary
      expect(_nextBoundaryNoJieba(text, 0), equals(5)); // skip "asdas"
      // From 5, forward should stop at CJK→Latin boundary
      expect(_nextBoundaryNoJieba(text, 5), equals(7)); // skip "我们"
      // From 7, forward should reach end
      expect(_nextBoundaryNoJieba(text, 7), equals(14)); // skip "dasdasd"
    });

    test('space-CJK transition is a boundary', () {
      // h(0)e(1)l(2)l(3)o(4) (5)我(6)们(7)都(8)好(9) (10)w(11)o(12)r(13)l(14)d(15)
      final text = 'hello 我们都好 world';
      // From end (16), backward: skip "world" → 11
      expect(_previousBoundaryNoJieba(text, 16), equals(11));
      // From 11 (on 'w'), but previous char is space at 10, so skip spaces → 10, then CJK → 6
      expect(_previousBoundaryNoJieba(text, 11), equals(6));
      // From 6, skip spaces → 5, then latin "hello" → 0
      expect(_previousBoundaryNoJieba(text, 6), equals(0));
    });

    test('pure CJK text: each char is boundary without jieba', () {
      final text = '我们都好';
      // Without jieba, the whole CJK run is one "word"
      expect(_previousBoundaryNoJieba(text, 4), equals(0));
      expect(_nextBoundaryNoJieba(text, 0), equals(4));
    });

    test('pure Latin text: word boundaries on char class transitions', () {
      final text = 'hello world';
      // h(0)e(1)l(2)l(3)o(4) (5)w(6)o(7)r(8)l(9)d(10)
      expect(_previousBoundaryNoJieba(text, 11), equals(6)); // skip "world"
      // From 6 ('w'), skip spaces first → 5, then "hello" → 0
      expect(_previousBoundaryNoJieba(text, 6), equals(0));
    });

    test('punctuation is its own boundary class', () {
      final text = 'hello,world';
      // "hello" is latin, "," is punct, "world" is latin
      expect(_previousBoundaryNoJieba(text, 11), equals(6)); // skip "world"
      expect(_previousBoundaryNoJieba(text, 6), equals(5)); // skip ","
      expect(_previousBoundaryNoJieba(text, 5), equals(0)); // skip "hello"
    });
  });
}
