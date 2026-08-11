import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../storage/notes_store.dart';
import '../utils/todo_parser.dart';

/// Owns the "my notes" feature for one project: the markdown content
/// (persisted in the crux DB via [NotesStore]) plus the small status
/// JSON file the spec-widget reads.
///
/// This mirrors the dev-harness architecture ("same architecture as
/// crux dev"): a process-side feature keeps its source of truth
/// somewhere durable and writes a tiny *projection* to a well-known
/// file that the generic, TOML-driven sidebar widget polls. Here the
/// source of truth is the `project_notes` table and the projection is
/// `.dart_tool/my_notes.json`:
///
///   {
///     "updatedAt": "2026-08-11T12:00:00.000",
///     "openCount": 3,
///     "totalCount": 5,
///     "todos": [
///       {"text": "fix the bug", "line": 4},
///       {"text": "write tests", "line": 7},
///       {"text": "ship it", "line": 9}
///     ],
///     "display": "3 todos\n… +2 more"
///   }
///
/// The widget label template is a single `{display}` — spec templates
/// can't loop over arrays, so the service pre-renders the *count* and
/// overflow lines into `display`, while the individual open items live
/// in the structured `todos` array (`{text, line}`) so the renderer can
/// draw each as a clickable row. Clicking a row marks that todo done in
/// the DB ([markTodoDone]); the projection is rewritten, and the row
/// disappears at the widget's next poll (~2 s) — the note still holds
/// the item, now checked.
///
/// The widget (`my-notes.toml`) has no `heartbeat_field`, so file
/// presence = alive. The service rewrites the projection on every save
/// and once on [init], so the widget always reflects the DB.
///
/// The projection write is atomic (temp file + rename) so a widget
/// polling mid-write never reads a torn file.
class NotesService {
  final NotesStore _store;

  /// The project (workspace root) this service is bound to. Both the
  /// DB row key and the projection file location derive from it.
  final String projectPath;

  NotesService(this._store, {required this.projectPath});

  /// Path of the status projection the widget polls, relative to
  /// [projectPath]. Kept in sync with `.crux/widgets/my-notes.toml`.
  static const statusPath = '.dart_tool/my_notes.json';

  /// How many open todo items the projection (and therefore the
  /// widget) lists inline before collapsing the rest into "+N more".
  static const maxListedOpenTodos = 3;

  /// Load the note content from the DB (empty string when none yet)
  /// and refresh the projection so the widget is correct even before
  /// the first edit. Call once when the feature first activates.
  Future<String> init() async {
    final content = await _store.loadContent(projectPath);
    await _writeProjection(content);
    return content;
  }

  /// Load the current note content (no projection write).
  Future<String> load() => _store.loadContent(projectPath);

  /// Render the multi-line widget label body for [summary]. Line 1 is
  /// the open count (just "N todo(s)" — the items themselves are the
  /// widget's clickable rows, not part of the label); a "+N more" line
  /// collapses any overflow beyond [maxListedOpenTodos]. Pure and
  /// top-level so it's unit-testable and reusable by the fullpane.
  static String renderDisplay(TodoSummary summary) {
    if (summary.isEmpty) return 'no todos';
    final open = summary.open;
    final lines = <String>[
      '${summary.openCount} todo${summary.openCount == 1 ? '' : 's'}',
    ];
    final overflow = open.length - maxListedOpenTodos;
    if (overflow > 0) lines.add('… +$overflow more');
    return lines.join('\n');
  }

  /// Persist [content] to the DB and rewrite the widget projection.
  /// Returns the todo summary derived from the saved content so the
  /// caller (the fullpane) can update its own footer without
  /// re-parsing.
  Future<TodoSummary> save(String content) async {
    await _store.save(projectPath, content);
    await _writeProjection(content);
    return parseTodos(content);
  }

  /// Mark the todo on source [lineIndex] (0-based) done by flipping its
  /// checkbox marker to `[x]`, persist, and refresh the projection so
  /// the widget's todo row disappears on the next poll. Returns the new
  /// summary. No-op (returns the current summary) when [lineIndex] is
  /// out of range or the line isn't an unchecked todo.
  ///
  /// The parser accepts both `- [ ]` (space) and `- []` (empty) as
  /// unchecked markers, so the flip rebuilds the marker from the regex
  /// groups rather than string-searching for `[ ]` — which would miss
  /// the empty-bracket form and silently do nothing.
  Future<TodoSummary> markTodoDone(int lineIndex) =>
      _setTodoChecked(lineIndex, done: true);

  /// Undo a done todo: flip its `[x]` marker back to `[ ]` (the undo
  /// counterpart of [markTodoDone], used by the widget's 10-second
  /// undo window). No-op when the line isn't a checked todo.
  Future<TodoSummary> markTodoOpen(int lineIndex) =>
      _setTodoChecked(lineIndex, done: false);

  Future<TodoSummary> _setTodoChecked(int lineIndex,
      {required bool done}) async {
    final content = await _store.loadContent(projectPath);
    final lines = content.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) {
      return parseTodos(content);
    }
    final rewritten = _rewriteTodoMarker(lines[lineIndex], done: done);
    if (rewritten == null) return parseTodos(content);
    lines[lineIndex] = rewritten;
    return save(lines.join('\n'));
  }

  /// Rebuild [line] with its checkbox marker set to `x` (when [done])
  /// or ` ` (when undoing), or return null when the line isn't a
  /// task-list item in the requested state. Captures the prefix, marker,
  /// and trailing text so `- [ ]`, `- []`, `- [x]` all round-trip
  /// without losing anything (the marker may be a space, an `x`/`X`, or
  /// empty).
  static String? _rewriteTodoMarker(String line, {required bool done}) {
    final m = RegExp(
      r'^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX]?)(\])(.*)$',
    ).firstMatch(line);
    if (m == null) return null;
    final marker = m.group(2) ?? '';
    final isChecked = marker.toLowerCase() == 'x';
    if (done == isChecked) return null; // already in the requested state
    // The unchecked form is `[ ]` (a space) — the canonical open marker
    // the parser emits; `[x]` is the checked one.
    return '${m.group(1)}${done ? 'x' : ' '}${m.group(3)}${m.group(4)}';
  }

  /// Recompute todos from [content] and write the projection file.
  /// Best-effort: a read-only or full disk must never break note
  /// editing, so filesystem errors are swallowed.
  Future<void> _writeProjection(String content) async {
    final todos = parseTodos(content);
    final open = todos.open;
    final payload = <String, dynamic>{
      'updatedAt': DateTime.now().toIso8601String(),
      'openCount': todos.openCount,
      'totalCount': todos.totalCount,
      'todos': [
        for (final item in open.take(maxListedOpenTodos))
          {'text': item.text, 'line': item.lineIndex},
      ],
      'display': NotesService.renderDisplay(todos),
    };
    try {
      final file = File(p.join(projectPath, statusPath));
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(payload));
      await tmp.rename(file.path);
    } catch (_) {
      // Projection is a convenience for the widget; the DB row is the
      // source of truth. Never let a filesystem hiccup break editing.
    }
  }
}
