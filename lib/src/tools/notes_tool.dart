import '../storage/session_store.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'tool_def.dart';

/// Read-only access to the user's "my notes" scratchpad for the
/// current project.
///
/// The note's source of truth is the `project_notes` table (one row
/// per project, keyed on the workspace root), edited by the user in
/// the `notes` fullpane. This tool reads that row live on every call,
/// so it never goes stale the way a prompt-injected snapshot would.
///
/// It is intentionally NOT the `.dart_tool/my_notes.json` file the
/// sidebar widget polls — that projection only carries the open-todo
/// list (no done items, no prose), not the full markdown. Reading it
/// would show the agent an incomplete view of the note.
///
/// Read-only, mirroring [SessionTool]: the note belongs to the user,
/// and editing it stays user-driven (the fullpane). We deliberately
/// do NOT override `skipInPrune` — unlike a `grep` / `glob`
/// discovery whose result is implied by downstream reads, the note
/// content is a durable, unique artifact the agent should keep across
/// compaction.
class NotesTool extends ToolDef {
  final SessionStore _store;

  NotesTool({required this._store});

  @override
  String get name => 'notes';

  @override
  String get description =>
      'Read the user\'s "my notes" scratchpad for the current project. '
      'This is the per-project markdown note the user edits in the `notes` '
      'fullpane — NOT the AGENTS.md / CLAUDE.md project-instruction files '
      'that are already in your system prompt. '
      'Returns the full note content verbatim, or a "no notes yet" message '
      'when the user hasn\'t written one. '
      'Read-only: this tool never writes, appends, or deletes — note '
      'editing stays user-driven. '
      'ONLY call this when the user explicitly asks you to read their notes '
      '(e.g. "看看我的笔记" / "what\'s in my notes"). Do NOT read them '
      'proactively — the notes are the user\'s private scratchpad, not part '
      'of your working context. '
      'Do NOT read the `.dart_tool/my_notes.json` projection file instead — '
      'it only carries the open-todo list, not the full note.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': <String, dynamic>{},
  };

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final chars = (result.metadata['charCount'] as int?) ?? 0;
    final label = chars == 0 ? 'no notes' : 'notes — $chars chars';
    final total = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    return CollapsedSummary(text: label, argsTokens: total, totalTokens: total);
  }

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final note = await _store.notesStore.load(ctx.workingDirectory);

    if (note == null || note.content.isEmpty) {
      return ToolResult(
        title: 'my notes',
        output:
            'No notes yet for this project (${ctx.workingDirectory}). '
            'Open the `notes` fullpane to start one.',
        metadata: {'exists': false, 'charCount': 0},
      );
    }

    final updated = DateTime.fromMillisecondsSinceEpoch(note.updatedAt)
        .toLocal();
    final header = 'my notes — updated ${_formatTimestamp(updated)}';

    return ToolResult(
      title: 'my notes',
      output: '$header\n\n${note.content}',
      metadata: {'updatedAt': note.updatedAt, 'charCount': note.content.length},
    );
  }

  static String _formatTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}
