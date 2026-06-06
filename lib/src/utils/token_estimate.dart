const _cjkRanges = [
  (0x4E00, 0x9FFF),
  (0x3400, 0x4DBF),
  (0xF900, 0xFAFF),
];

bool _isCJK(int codeUnit) {
  for (final range in _cjkRanges) {
    if (codeUnit >= range.$1 && codeUnit <= range.$2) return true;
  }
  return false;
}

int estimateTokens(String content) {
  int cjkChars = 0;
  int otherChars = 0;
  for (final codeUnit in content.runes) {
    if (_isCJK(codeUnit)) {
      cjkChars++;
    } else {
      otherChars++;
    }
  }
  final cjkTokens = (cjkChars / 1.25).ceil();
  final otherTokens = (otherChars / 4).ceil();
  return cjkTokens + otherTokens;
}
