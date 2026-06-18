/// Project notes discovery for the Crux system prompt.
///
/// Walks up from `cwd` to `worktree` and picks the canonical
/// project-instructions file: `AGENTS.md` (preferred) or `CLAUDE.md`
/// (fallback). If both exist in the same directory, the one with the
/// newer mtime wins. The first directory that contains either file
/// stops the walk — `path > mtime`.
///
/// Separately, finds the closest `crux-addition.md` walking up from
/// `cwd` and appends it after the canonical project file (if any).
/// The addendum is Crux-specific, so it lives in a separate file
/// to avoid polluting `AGENTS.md` (which is read by other tools
/// like Cursor, Aider, Continue.dev, …).
///
/// Returns a single rendered block with the structure:
///
///     Instructions from: <abs path>
///     <file content>
///
///     ---
///
///     Instructions from: <abs path>
///     <file content>
///
/// Either section may be absent. If both are absent, returns `null`
/// (caller should omit the project-notes layer entirely).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Discovers and renders project notes for the current working
/// directory, walking up to (but not including) [worktree].
///
/// Returns `null` if no `AGENTS.md`, `CLAUDE.md`, or `crux-addition.md`
/// is found anywhere in the walk. Returns the rendered block
/// otherwise.
///
/// Unreadable files (permission errors, broken symlinks) are
/// silently skipped with no warning — Crux does not fail the
/// session over a misconfigured `AGENTS.md`.
String? discoverProjectNotes({
  required String cwd,
  required String worktree,
}) {
  if (!Directory(worktree).existsSync()) {
    // Worktree must exist; if not, the caller passed a bad path.
    // Treat the walk as a no-op rather than throwing — the system
    // prompt can still be built without project notes.
    return null;
  }

  // Walk up from cwd to (but not including) worktree. We stop at
  // worktree, not at the filesystem root, so a stale `AGENTS.md`
  // somewhere above the repo can't leak into every project.
  final directories = _walkUp(cwd, stopAt: worktree);
  if (directories.isEmpty) return null;

  // --- Canonical project file (AGENTS.md or CLAUDE.md) ---
  String? canonicalPath;
  String? canonicalContent;

  for (final dir in directories) {
    final agentsPath = p.join(dir, 'AGENTS.md');
    final claudePath = p.join(dir, 'CLAUDE.md');

    final agents = _safeFile(agentsPath);
    final claude = _safeFile(claudePath);

    if (agents != null && claude != null) {
      // Both present in the same dir — mtime wins.
      final agentsMtime = agents.statSync().modified;
      final claudeMtime = claude.statSync().modified;
      if (agentsMtime.isAfter(claudeMtime)) {
        canonicalPath = agents.path;
        canonicalContent = agents.readAsStringSync();
      } else {
        canonicalPath = claude.path;
        canonicalContent = claude.readAsStringSync();
      }
      break; // first match wins; don't keep walking
    }
    if (agents != null) {
      canonicalPath = agents.path;
      canonicalContent = agents.readAsStringSync();
      break;
    }
    if (claude != null) {
      canonicalPath = claude.path;
      canonicalContent = claude.readAsStringSync();
      break;
    }
    // Neither file in this dir — keep walking up.
  }

  // --- Crux-specific addendum (crux-addition.md) ---
  // First match up the tree wins (closest to cwd). This is the
  // OpenCode-style "closest ancestor" rule.
  String? addendumPath;
  String? addendumContent;
  for (final dir in directories) {
    final cruxPath = p.join(dir, 'crux-addition.md');
    final crux = _safeFile(cruxPath);
    if (crux != null) {
      addendumPath = crux.path;
      addendumContent = crux.readAsStringSync();
      break;
    }
  }

  if (canonicalPath == null && addendumPath == null) return null;

  // Skip rendering for empty files. An empty canonical file is
  // equivalent to "no project notes" — an empty addendum is just
  // noise.
  if ((canonicalContent == null || canonicalContent.trim().isEmpty) &&
      (addendumContent == null || addendumContent.trim().isEmpty)) {
    return null;
  }

  // Compose the rendered block. The canonical file (if any) comes
  // first; the addendum (if any) is appended with a `---`
  // separator so the model can pattern-match the section break.
  final blocks = <String>[];
  if (canonicalContent != null && canonicalContent.trim().isNotEmpty) {
    blocks.add('Instructions from: $canonicalPath\n$canonicalContent');
  }
  if (addendumContent != null && addendumContent.trim().isNotEmpty) {
    if (blocks.isNotEmpty) blocks.add('\n---\n');
    blocks.add('Instructions from: $addendumPath\n$addendumContent');
  }
  return blocks.join('\n');
}

/// Walk from [start] up to (and including) [stopAt]. Returns the
/// directories in walk-up order: [start], [start.parent], …, up
/// to and including the worktree itself. The first entry is
/// always [start]; the last entry is either [stopAt] (when
/// [start] is [stopAt] or below it) or the deepest directory
/// that was still under [stopAt] (when [start] is not under
/// [stopAt]).
///
/// If [start] is not under [stopAt], returns just [start] — the
/// walker doesn't try to escape an unrelated directory tree.
List<String> _walkUp(String start, {required String stopAt}) {
  final canonicalStart = p.canonicalize(start);
  final canonicalStop = p.canonicalize(stopAt);
  final result = <String>[];

  String? current = canonicalStart;
  while (current != null) {
    result.add(current);
    if (p.equals(current, canonicalStop)) {
      // We've reached the stop boundary — include it and stop.
      break;
    }
    final parent = p.dirname(current);
    if (parent == current) break; // filesystem root
    if (!_isUnder(parent, canonicalStop)) {
      // The next step up would cross the worktree boundary.
      // Don't include it. The current directory (which is just
      // below the worktree) is already in the result.
      break;
    }
    current = parent;
  }
  return result;
}

/// True if [child] is the same as [parent] or strictly below it.
bool _isUnder(String child, String parent) {
  if (p.equals(child, parent)) return true;
  final rel = p.relative(child, from: parent);
  return !rel.startsWith('..') && !p.isAbsolute(rel);
}

/// Returns the [File] for [path] if it exists and is readable, else
/// `null`. Does not throw on permission errors or broken symlinks.
File? _safeFile(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    // Touching the file with a stat() forces the OS to surface
    // permission errors here (rather than later in readAsStringSync).
    f.statSync();
    return f;
  } on FileSystemException {
    return null;
  } catch (_) {
    return null;
  }
}
