import 'dart:io';

import 'package:path/path.dart' as p;

/// How a single dropped path should be handled. The caller
/// (`ChatInput._handlePaste`) maps each kind to a UI action:
///   • [image]         → attach as image attachment (existing path)
///   • [file]          → insert path as a labeled reference
///   • [directory]     → insert just the directory path as a reference
///   • [missing]       → show an error toast, do not insert
enum DroppedFileKind {
  image,
  file,
  directory,
  missing,
}

/// One classified entry from a drop. Only the path is stored;
/// file content is never inlined — the AI agent reads files on
/// demand with its own tools.
class DroppedFile {
  /// The raw token from the paste, as the user (or their file
  /// manager) emitted it — may be quoted, URL-encoded, or relative.
  final String originalPath;

  /// The resolved absolute path. Falls back to [originalPath] if
  /// canonicalization fails (e.g. the file doesn't exist yet).
  final String absolutePath;

  final DroppedFileKind kind;
  final int sizeBytes;

  const DroppedFile({
    required this.originalPath,
    required this.absolutePath,
    required this.kind,
    required this.sizeBytes,
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

    // It's a file — just record the path; the AI agent reads
    // file content on demand with its own tools.
    final size = _safeLength(resolved);
    final ext = p.extension(resolved).toLowerCase();
    if (_isImageExtension(ext)) {
      results.add(DroppedFile(
        originalPath: original,
        absolutePath: resolved,
        kind: DroppedFileKind.image,
        sizeBytes: size,
      ));
    } else {
      results.add(DroppedFile(
        originalPath: original,
        absolutePath: resolved,
        kind: DroppedFileKind.file,
        sizeBytes: size,
      ));
    }
  }
  return results;
}

/// Build the text to insert into the chat input for the
/// non-image, non-missing entries in [files].
///
/// Each entry is inserted as a path reference — the AI agent
/// reads file content on demand with its own tools. Directories
/// get a bare path reference (no inlined listing): the chat
/// input is not the right place for a directory tree, and the
/// agent can list it itself with its tools.
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
      case DroppedFileKind.file:
        buf.writeln(
          '[file: ${f.absolutePath} '
          '(${_humanSize(f.sizeBytes)})]',
        );
        buf.writeln();
        break;
      case DroppedFileKind.directory:
        // Just the path reference — no inlined listing. The agent
        // can explore the directory with its own tools when it
        // needs to, and the chat input stays a clean prompt
        // instead of a one-shot directory dump.
        buf.writeln('[directory: ${f.absolutePath}]');
        buf.writeln();
        break;
    }
  }
  return buf.toString();
}

// ─── decision helpers ───────────────────────────────────────────────

/// Decide whether a paste payload, once tokenized and classified,
/// should be treated as a file drop.
///
/// Real file drops from terminal emulators (iTerm2, Kitty, WezTerm,
/// Ghostty, Finder) have a characteristic shape: every token in the
/// payload is a path, and each path is either absolute
/// (`/Users/me/notes.md`), home-relative (`~/notes.md`), or
/// explicitly relative (`./notes.md`, `../notes.md`). Requiring the
/// same here keeps us from misreading a sentence that merely
/// *mentions* a path as a drop (e.g. pasting "see /tmp/photo.png
/// for context" used to be mis-routed as a single-image attach,
/// with the surrounding words surfaced as "File(s) not found"
/// toasts).
///
/// Returns `true` only when:
///
///   * [classified] is non-empty,
///   * every token resolved to a real file or directory on disk
///     (the prose-with-path guard), AND
///   * for a single-token payload, the original token itself looks
///     like a path (see [_looksLikePath]).
///
/// The single-token guard is the macOS / IME-composition fix. On
/// macOS, Chinese / Japanese / Korean IMEs commit candidate text by
/// wrapping it in bracketed-paste markers (`ESC[200~ ... ESC[201~`),
/// so a confirmed candidate like "tool" or "你好" arrives here as a
/// single-token paste. Without this guard, [classifyDroppedPaths]
/// joins that token against the project root and resolves it as a
/// real path whenever the project happens to contain a matching
/// entry (e.g. a `tool/` subdirectory), at which point the input
/// gets replaced with `[directory: .../tool]` and a "Dropped: 1
/// path(s) inserted" toast fires. Real file drops from terminal
/// emulators are always path-shaped, so a bare word is a strong
/// signal that the paste is user input, not a file drop.
///
/// The caller is expected to fall through to the legacy single-image
/// path (and from there to plain-text insertion) when this returns
/// `false`.
bool looksLikeFileDrop(List<DroppedFile> classified) {
  if (classified.isEmpty) return false;

  // Single-token guard: a bare word (e.g. "tool", "你好") joined
  // against the project root is almost always IME-committed text,
  // not a file drop. See the docstring for the full context. The
  // multi-token case is unchanged — the prose-with-path guard
  // (the every-token-resolves check below) already rejects e.g.
  // "see /tmp/a.md for context" because the surrounding words
  // don't resolve.
  if (classified.length == 1 && !_looksLikePath(classified.first.originalPath)) {
    return false;
  }

  for (final f in classified) {
    if (f.kind == DroppedFileKind.missing) return false;
  }
  return true;
}

/// True when [s] has the shape of a real filesystem path —
/// absolute (`/foo`), home-relative (`~` / `~/foo`), or explicitly
/// relative (`./foo` / `../foo`).
///
/// A bare word like "tool" or a CJK token like "你好" returns
/// `false`. Those are exactly the inputs that get misclassified
/// as file drops on macOS when an IME commits them through
/// bracketed-paste mode.
bool _looksLikePath(String s) {
  return s.startsWith('/') ||
      s.startsWith('./') ||
      s.startsWith('../') ||
      s.startsWith('~');
}

// ─── helpers ────────────────────────────────────────────────────────

const _imageExtensions = <String>{
  '.png', '.jpg', '.jpeg', '.gif', '.webp',
  '.bmp', '.svg', '.tiff', '.tif', '.ico',
};

bool _isImageExtension(String ext) => _imageExtensions.contains(ext);

int _safeLength(String path) {
  try {
    return File(path).lengthSync();
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
