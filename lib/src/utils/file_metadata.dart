import 'dart:convert';

/// Result of reading a text file: the decoded content plus detected
/// encoding and line ending metadata. We surface this to the agent via the
/// read tool's output header so it can write back the same encoding/ending
/// instead of silently re-encoding the file on every edit (the source of
/// session 70's "LF will be replaced by CRLF" warning storm).
class FileReadResult {
  final String content;
  final String encoding;
  final String lineEnding;
  final int byteLength;

  const FileReadResult({
    required this.content,
    required this.encoding,
    required this.lineEnding,
    required this.byteLength,
  });
}

/// Decodes [bytes] as a text file, detecting UTF-8 vs UTF-8-with-BOM and
/// counting CRLF vs LF so the caller can report a stable header.
///
/// We deliberately do NOT support UTF-16 / GBK / etc. — the project is Dart
/// source which is always UTF-8. If we see non-UTF-8 bytes, [content] will
/// still decode (with replacement chars) but [encoding] stays 'utf-8' so
/// the agent's view matches what Dart itself would do.
FileReadResult readFileWithMetadata(List<int> bytes) {
  String content;
  String encoding;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    content = utf8.decode(bytes.sublist(3), allowMalformed: true);
    encoding = 'utf-8-bom';
  } else {
    content = utf8.decode(bytes, allowMalformed: true);
    encoding = 'utf-8';
  }

  var crlf = 0;
  var lfOnly = 0;
  for (var i = 0; i < content.length; i++) {
    if (content[i] != '\n') continue;
    if (i > 0 && content[i - 1] == '\r') {
      crlf++;
    } else {
      lfOnly++;
    }
  }
  final String lineEnding;
  if (crlf == 0 && lfOnly == 0) {
    lineEnding = 'none';
  } else if (crlf == 0) {
    lineEnding = 'lf';
  } else if (lfOnly == 0) {
    lineEnding = 'crlf';
  } else if (crlf >= lfOnly * 2) {
    lineEnding = 'crlf-mixed';
  } else if (lfOnly >= crlf * 2) {
    lineEnding = 'lf-mixed';
  } else {
    lineEnding = 'mixed';
  }

  return FileReadResult(
    content: content,
    encoding: encoding,
    lineEnding: lineEnding,
    byteLength: bytes.length,
  );
}

/// Apply the file's dominant line ending to [text]. Used by edit/write to
/// keep the file's line ending convention even if the agent's pattern
/// used a different one.
String normalizeToLineEnding(String text, String lineEnding) {
  if (lineEnding == 'crlf' || lineEnding == 'crlf-mixed') {
    return text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
  }
  return text.replaceAll('\r\n', '\n');
}
