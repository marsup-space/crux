import 'dart:convert';

import 'gitattributes.dart';

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

/// Process-wide shared `.gitattributes` lookup. The edit and write
/// tools consult this to decide the *target* line ending for a
/// file (instead of always defaulting to whatever the file
/// currently uses on disk). The lookup caches the parsed
/// .gitattributes per absolute path, so the steady-state cost
/// of consulting it on every edit is one `stat()` per
/// directory up the tree — and only the first time.
final GitAttributesLookup gitAttributesLookup = GitAttributesLookup();

/// Decide the line ending the file *should* be in, given the
/// file's detected line ending and the project's `.gitattributes`.
///
///   - If a matching rule in `.gitattributes` says `eol=crlf`
///     or `eol=lf`, return that.
///   - If a rule says `text` (with no `=`), return `lf` — git's
///     own convention is to normalize to LF on commit for
///     text-marked files.
///   - If the file is declared `binary` / `-text` / `text=false`,
///     return `null` (the caller should leave the bytes alone;
///     no normalization is the right behavior for binary).
///   - Otherwise, fall back to [detectedLineEnding].
///
/// The result is one of the strings that `normalizeToLineEnding`
/// understands: `'crlf'`, `'lf'`, or `null`.
String? targetLineEndingFor(
  String resolvedFilePath,
  String detectedLineEnding,
) {
  final eol = gitAttributesLookup.eolFor(resolvedFilePath);
  if (eol == null) return detectedLineEnding;
  if (eol.isPassthrough) return null;
  return eol.value ?? detectedLineEnding;
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
///
/// Any line-ending variant is normalized — `\r\n` (Windows), `\n` (Unix),
/// and standalone `\r` (classic-Mac) all collapse to the target. The
/// two-pass approach is:
///   1. Reduce to LF (handle both `\r\n` and lone `\r`).
///   2. If the target is CRLF, expand LF to `\r\n`.
String normalizeToLineEnding(String text, String lineEnding) {
  // First reduce everything to LF. Order matters: handle `\r\n`
  // before standalone `\r` so we don't accidentally double-convert
  // (e.g. \r\n → \n → \n if the standalone step ran first would
  // leave it as a single \n, but doing \r\n → \n first means the
  // standalone \r step only sees the truly-lone \r bytes).
  var lf = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (lineEnding == 'crlf' || lineEnding == 'crlf-mixed') {
    return lf.replaceAll('\n', '\r\n');
  }
  return lf;
}
