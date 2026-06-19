class PartialJsonFieldExtractor {
  /// Extract a string field from a possibly-partial JSON
  /// document. By default this returns `null` when the field
  /// value's closing quote hasn't arrived yet — the strong
  /// guarantee callers (e.g. the streaming guard in
  /// `chat_service.dart`) want when they're deciding whether
  /// a value is trustworthy.
  ///
  /// Pass [lenient] `true` to return whatever has been
  /// accumulated so far when the closing quote is missing.
  /// This is what the streaming tool-call preview wants: it
  /// would rather show an under-counted `+5 lines` than no
  /// count at all while the LLM is still emitting the field.
  /// The lenient path still handles `\n`, `\t`, `\"`, etc.
  /// but falls back to the raw character when an unrecognised
  /// escape sequence is encountered (instead of returning
  /// null), so a streaming `"one\ntwo` decodes as `one\ntwo`
  /// rather than as a parse error.
  static String? extractStringField(
    String partial,
    String fieldName, {
    bool lenient = false,
  }) {
    final keyIndex = partial.indexOf('"$fieldName"');
    if (keyIndex < 0) return null;
    final colonIndex = partial.indexOf(':', keyIndex + fieldName.length + 2);
    if (colonIndex < 0) return null;

    var quoteIndex = colonIndex + 1;
    while (quoteIndex < partial.length &&
        RegExp(r'\s').hasMatch(partial[quoteIndex])) {
      quoteIndex++;
    }
    if (quoteIndex >= partial.length || partial[quoteIndex] != '"') {
      return null;
    }

    final buffer = StringBuffer();
    var escaping = false;
    for (var i = quoteIndex + 1; i < partial.length; i++) {
      final ch = partial[i];
      if (escaping) {
        switch (ch) {
          case '"':
            buffer.write('"');
            break;
          case r'\':
            buffer.write(r'\');
            break;
          case '/':
            buffer.write('/');
            break;
          case 'b':
            buffer.write('\b');
            break;
          case 'f':
            buffer.write('\f');
            break;
          case 'n':
            buffer.write('\n');
            break;
          case 'r':
            buffer.write('\r');
            break;
          case 't':
            buffer.write('\t');
            break;
          case 'u':
            if (i + 4 >= partial.length) {
              if (lenient) return buffer.toString();
              return null;
            }
            final hex = partial.substring(i + 1, i + 5);
            final codeUnit = int.tryParse(hex, radix: 16);
            if (codeUnit == null) {
              if (lenient) return buffer.toString();
              return null;
            }
            buffer.writeCharCode(codeUnit);
            i += 4;
            break;
          default:
            if (lenient) return buffer.toString();
            return null;
        }
        escaping = false;
        continue;
      }
      if (ch == r'\') {
        escaping = true;
        continue;
      }
      if (ch == '"') return buffer.toString();
      buffer.write(ch);
    }
    // End of input reached without a closing quote. Strict
    // callers want null; lenient callers (the streaming
    // tool-call preview) want whatever we accumulated.
    if (lenient) return buffer.toString();
    return null;
  }
}
