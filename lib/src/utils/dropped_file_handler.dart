import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Maximum size (in bytes) of a text file that will be inlined into
/// the chat input when the user drags-and-drops it. Files larger
/// than this fall back to being inserted as a path reference; the
/// AI agent can still read them on demand with its file tools.
///
/// 64 KiB is large enough for most source files and small enough
/// to keep the chat input responsive. Tuned for the typical
/// single-file drop case (drag one source file, get the content);
/// a multi-file drop with several of these would still fit in a
/// normal LLM context.
const int kMaxInlineTextBytes = 64 * 1024;

/// How a single dropped path should be handled. The caller
/// (`ChatInput._handlePaste`) maps each kind to a UI action:
///   • [image]            → attach as image attachment (existing path)
///   • [inlineableText]   → read content and inline into the input
///   • [largeOrBinary]    → insert path as a labeled reference
///   • [directory]        → list a few entries and insert as reference
///   • [missing]          → show an error toast, do not insert
enum DroppedFileKind {
  image,
  inlineableText,
  largeOrBinary,
  directory,
  missing,
}

/// One classified entry from a drop. [content] is only populated
/// for [DroppedFileKind.inlineableText].
class DroppedFile {
  /// The raw token from the paste, as the user (or their file
  /// manager) emitted it — may be quoted, URL-encoded, or relative.
  final String originalPath;

  /// The resolved absolute path. Falls back to [originalPath] if
  /// canonicalization fails (e.g. the file doesn't exist yet).
  final String absolutePath;

  final DroppedFileKind kind;
  final int sizeBytes;

  /// Inlined text content (only set when [kind] is
  /// [DroppedFileKind.inlineableText]).
  final String? content;

  const DroppedFile({
    required this.originalPath,
    required this.absolutePath,
    required this.kind,
    required this.sizeBytes,
    this.content,
  });
}

/// Tokenize a raw paste payload into a list of candidate file paths.
///
/// Most terminal emulators wrap file drops in bracketed-paste mode
/// (`ESC[200~ ... ESC[201~`), so the payload arrives as a single
/// string. Different sources format it differently:
///
///   * macOS Terminal / Finder → single line, sometimes quoted:
///       '/Users/me/notes.md'
///   * iTerm2                  → space-separated, may be quoted:
///       '/Users/me/a.md' '/Users/me/b.md'
///   * Kitty / WezTerm / Ghostty → newline-separated:
///       /Users/me/a.md
///       /Users/me/b.md
///   * Drag from a web browser  → `file://` URL with %-encoding:
///       file:///Users/me/My%20Doc.md
///
/// This function handles all of the above. The caller is expected
/// to verify each token actually resolves to a real file via
/// [classifyDroppedPaths] — that step is deliberately separated so
/// the parser can be unit-tested without touching the filesystem.
List<String> extractDroppedPaths(String raw) {
  // Split on any whitespace; preserves paths with spaces only when
  // they're surrounded by quotes (handled below).
  final tokens = raw.split(RegExp(r'\s+'));
  final paths = <String>[];
  for (final token in tokens) {
    if (token.isEmpty) continue;
    var s = token;
    // Strip a matched pair of surrounding single or double quotes.
    if (s.length >= 2) {
      final first = s.codeUnitAt(0);
      final last = s.codeUnitAt(s.length - 1);
      if ((first == 0x22 || first == 0x27) && first == last) {
        s = s.substring(1, s.length - 1);
      }
    }
    // Strip a `file://` prefix and percent-decode the rest.
    if (s.startsWith('file://')) {
      s = _urlDecode(s.substring('file://'.length));
    }
    if (s.isNotEmpty) paths.add(s);
  }
  return paths;
}

/// Walk [paths] on disk and classify each entry. Relative paths
/// are resolved against [projectRoot] (defaults to CWD).
///
/// Each output entry preserves the caller's [originalPath] so the
/// UI can show the user exactly what they dropped, while
/// [absolutePath] is used for actual file I/O.
List<DroppedFile> classifyDroppedPaths(
  List<String> paths, {
  String projectRoot = '.',
}) {
  final results = <DroppedFile>[];
  for (final original in paths) {
    // First resolve to an absolute path (joins projectRoot for
    // relative inputs). Then canonicalize to normalize `..`,
    // follow symlinks, and resolve macOS `/private/var` ↔ `/var`
    // style aliases. We do this in two steps because `canonicalize`
    // throws when the target doesn't exist.
    final joined = p.isAbsolute(original)
        ? original
        : p.absolute(p.normalize(p.join(projectRoot, original)));
    String resolved;
    try {
      resolved = p.canonicalize(joined);
    } on FileSystemException {
      resolved = joined;
    }

    final entityType = FileSystemEntity.typeSync(resolved);
    if (entityType == FileSystemEntityType.notFound) {
      results.add(DroppedFile(
        originalPath: original,
        absolutePath: resolved,
        kind: DroppedFileKind.missing,
        sizeBytes: 0,
      ));
      continue;
    }
    if (entityType == FileSystemEntityType.directory) {
      results.add(DroppedFile(
        originalPath: original,
        absolutePath: resolved,
        kind: DroppedFileKind.directory,
        sizeBytes: 0,
      ));
      continue;
    }

    // It's a file.
    final file = File(resolved);
    final size = _safeLength(file);
    final ext = p.extension(resolved).toLowerCase();
    if (_isImageExtension(ext)) {
      results.add(DroppedFile(
        originalPath: original,
        absolutePath: resolved,
        kind: DroppedFileKind.image,
        sizeBytes: size,
      ));
      continue;
    }
    if (size > kMaxInlineTextBytes) {
      results.add(DroppedFile(
        originalPath: original,
        absolutePath: resolved,
        kind: DroppedFileKind.largeOrBinary,
        sizeBytes: size,
      ));
      continue;
    }
    // Small file: try to read as text. We treat a NUL byte in the
    // first 8 KiB as a "definitely binary" signal (matches the
    // `file` command's heuristic). If decoding fails for any
    // reason we fall back to [largeOrBinary] so the user still
    // gets a useful path reference.
    try {
      final bytes = file.readAsBytesSync();
      if (_looksBinary(bytes)) {
        results.add(DroppedFile(
          originalPath: original,
          absolutePath: resolved,
          kind: DroppedFileKind.largeOrBinary,
          sizeBytes: size,
        ));
        continue;
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      results.add(DroppedFile(
        originalPath: original,
        absolutePath: resolved,
        kind: DroppedFileKind.inlineableText,
        sizeBytes: size,
        content: text,
      ));
    } on FileSystemException {
      results.add(DroppedFile(
        originalPath: original,
        absolutePath: resolved,
        kind: DroppedFileKind.largeOrBinary,
        sizeBytes: size,
      ));
    }
  }
  return results;
}

/// Build the text to insert into the chat input for the
/// non-image, non-missing entries in [files].
///
/// The format is deliberately simple and grep-friendly: each file
/// gets a `---` header line that contains the absolute path and
/// the byte count, followed by its content, followed by an `end`
/// marker. This is what tools like `aider`, `cursor`, and
/// `claude-code` do internally — the AI can clearly see file
/// boundaries and the user can see what was attached.
///
/// Image and missing entries are skipped here; the caller handles
/// them separately (attach / toast).
String formatDroppedFilesForInput(List<DroppedFile> files) {
  final buf = StringBuffer();
  for (final f in files) {
    switch (f.kind) {
      case DroppedFileKind.image:
      case DroppedFileKind.missing:
        // Caller handles these.
        break;
      case DroppedFileKind.inlineableText:
        final name = p.basename(f.absolutePath);
        buf.writeln('--- $name (${f.absolutePath}, ${f.sizeBytes} B) ---');
        buf.writeln(f.content ?? '');
        if (buf.isNotEmpty && !buf.toString().endsWith('\n')) {
          buf.writeln();
        }
        buf.writeln('--- end $name ---');
        buf.writeln();
        break;
      case DroppedFileKind.largeOrBinary:
        buf.writeln(
          '[file: ${f.absolutePath} '
          '(${_humanSize(f.sizeBytes)}, not inlined)]',
        );
        buf.writeln();
        break;
      case DroppedFileKind.directory:
        buf.writeln('[directory: ${f.absolutePath}]');
        try {
          final entries = Directory(f.absolutePath)
              .listSync(followLinks: false)
              .take(20)
              .map((e) => p.basename(e.path))
              .toList();
          if (entries.isEmpty) {
            buf.writeln('(empty directory)');
          } else {
            for (final name in entries) {
              buf.writeln('  - $name');
            }
            // Only show the "more" hint when we actually hit the
            // cap — otherwise the user gets a misleading "..." in
            // a directory that genuinely has 20 entries.
            final total = Directory(f.absolutePath)
                .listSync(followLinks: false)
                .length;
            if (total > entries.length) {
              buf.writeln('  ... and ${total - entries.length} more');
            }
          }
        } on FileSystemException catch (e) {
          buf.writeln('(could not list: ${e.message})');
        }
        buf.writeln();
        break;
    }
  }
  return buf.toString();
}

// ─── helpers ────────────────────────────────────────────────────────

const _imageExtensions = <String>{
  '.png', '.jpg', '.jpeg', '.gif', '.webp',
  '.bmp', '.svg', '.tiff', '.tif', '.ico',
};

bool _isImageExtension(String ext) => _imageExtensions.contains(ext);

bool _looksBinary(List<int> bytes) {
  // Sample the first 8 KiB. Any NUL byte is a strong binary
  // signal (no common text encoding uses 0x00 outside of UTF-16
  // surrogates, and a real UTF-16 file would still decode fine
  // through our UTF-8 fallback).
  final n = bytes.length < 8192 ? bytes.length : 8192;
  for (var i = 0; i < n; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

int _safeLength(File f) {
  try {
    return f.lengthSync();
  } on FileSystemException {
    return 0;
  }
}

String _humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

String _urlDecode(String s) {
  // Minimal %-decoder. Handles %XX hex escapes; leaves everything
  // else as-is. We don't decode the path-segment form (e.g.
  // `+` → space) because terminal `file://` URIs don't use it.
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final ch = s[i];
    if (ch == '%' && i + 2 < s.length) {
      final hex = s.substring(i + 1, i + 3);
      final byte = int.tryParse(hex, radix: 16);
      if (byte != null) {
        out.writeCharCode(byte);
        i += 3;
        continue;
      }
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}
