import '../models/message.dart';
import 'tool_detail_utils.dart';

/// Reconstructs a segment-scoped before→after diff for one file from the
/// segment's persisted `write`/`edit` tool-call args.
///
/// The vibe files box's `diff` button opens a fullpane whose content is
/// derived entirely from data already on disk — no git, no re-read of the
/// live file. That keeps the view anchored to **this segment's** changes
/// (the tool-call diff the user asked for), independent of whatever else
/// has touched the file since.
///
/// ## Reconstruction model
///
/// We never persisted a file snapshot, so we rebuild an approximate
/// before/after pair by folding the segment's own mutating calls:
///
///   * `write(filePath, content)` — the full post-write body. Seeds the
///     "after" content (and resets the fold; a write overwrites the file).
///   * `edit(filePath, oldString, newString)` — contributes its
///     old/new pair. `oldString` joins the "before" snapshot, `newString`
///     the "after" snapshot, in call order.
///
/// The two snapshots are concatenations of the segment's fragments, not
/// byte-exact file states (we can't recover content the edit didn't
/// touch, and an edit's `oldString` may match fuzzily). That is the right
/// fidelity for a glance-level "what changed here" view and matches the
/// edit tool's own inline diff, which renders `computeLineDiff(oldString,
/// newString)` — the same building block, just chained across the segment.
///
/// Returns `null` when the file has no reconstructable content in this
/// segment (e.g. it was only `read`, or its calls were guard-aborted
/// before any mutation). The fullpane shows a placeholder in that case.
List<DiffLine>? computeVibeFileDiff(VibeFileDiffInput input) {
  final oldParts = <String>[];
  final newParts = <String>[];
  var sawMutation = false;

  for (final call in input.calls) {
    final args = call.input;
    switch (call.name) {
      case 'write':
        final content = args['content'] as String? ?? '';
        // A write replaces the file body — restart the fold from the
        // written content so a later edit applies on top of it rather
        // than on a pre-write fragment.
        oldParts
          ..clear()
          ..add(content);
        newParts
          ..clear()
          ..add(content);
        sawMutation = true;
      case 'edit':
        final oldString = args['oldString'] as String? ?? '';
        final newString = args['newString'] as String? ?? '';
        // An edit with an empty oldString is a create/append — nothing
        // on the "before" side. Skip pairs that are identical (the tool
        // rejects them, but be defensive against hand-built rows).
        if (oldString == newString && oldString.isEmpty) continue;
        oldParts.add(oldString);
        newParts.add(newString);
        sawMutation = true;
      default:
        // read / bash / grep / etc. don't mutate file content.
        continue;
    }
  }

  if (!sawMutation) return null;

  final oldText = oldParts.join('\n');
  final newText = newParts.join('\n');
  final lines = computeLineDiff(oldText, newText, contextLines: 3);
  // Identical snapshots (no-op write, or edits whose old==new) produce
  // only context rows — nothing meaningful to show.
  final hasChange = lines.any(
    (l) => l.kind == DiffLineKind.added || l.kind == DiffLineKind.removed,
  );
  return hasChange ? lines : null;
}

/// Input to [computeVibeFileDiff]: the ordered mutating calls that touched
/// one file within the segment.
class VibeFileDiffInput {
  /// The display path of the file (as shown in the files box).
  final String path;

  /// The segment's `write`/`edit` calls against [path], in emission
  /// order. Callers filter the segment's tool calls down to this file
  /// (matching by resolved path) before constructing this input.
  final List<ToolCallData> calls;

  const VibeFileDiffInput({required this.path, required this.calls});
}
