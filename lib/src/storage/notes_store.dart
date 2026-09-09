import 'package:drift/drift.dart';

import 'database.dart' as db;

/// Data-access layer for `project_notes` — the per-project "my notes"
/// markdown backing the notes sidebar widget and fullpane.
///
/// One row per project path; the note belongs to the *project*, not to
/// any session, so it is shared by every Crux session opened on the
/// same workspace and survives session deletion. A single instance is
/// shared app-wide (constructed lazily off [SessionStore], same
/// lifetime and DB connection — see [SessionStore.notesStore]).
class NotesStore {
  final db.CruxDatabase _db;

  NotesStore(this._db);

  /// Load the note for [projectPath], or `null` when none exists yet
  /// (the user has never written a note for this project).
  Future<db.ProjectNote?> load(String projectPath) {
    final query = _db.select(_db.projectNotes)
      ..where((n) => n.projectPath.equals(projectPath));
    return query.getSingleOrNull();
  }

  /// Load just the note's markdown content for [projectPath], or the
  /// empty string when no row exists. Convenience for callers that
  /// don't care about the timestamp.
  Future<String> loadContent(String projectPath) async =>
      (await load(projectPath))?.content ?? '';

  /// Insert or replace the note for [projectPath], stamping
  /// `updated_at` with the current time. Returns the stored row.
  Future<db.ProjectNote> save(String projectPath, String content) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final companion = db.ProjectNotesCompanion.insert(
      projectPath: projectPath,
      content: Value(content),
      updatedAt: now,
    );
    await _db.into(_db.projectNotes).insertOnConflictUpdate(companion);
    return db.ProjectNote(
      projectPath: projectPath,
      content: content,
      updatedAt: now,
    );
  }

  /// Delete the note for [projectPath] (no-op when none exists). Not
  /// wired into the UI today — here for completeness / tests.
  Future<void> delete(String projectPath) {
    final query = _db.delete(_db.projectNotes)
      ..where((n) => n.projectPath.equals(projectPath));
    return query.go();
  }
}
