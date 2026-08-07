import 'package:path/path.dart' as p;

import '../models/message.dart';
import 'tool_detail_utils.dart';

/// The reconstructed before→after state for one file in a vibe segment:
/// the unified line diff plus the full old/new snapshots it was computed
/// from.
///
/// The snapshots are returned alongside the lines so callers can
/// syntax-highlight the **whole** text once (preserving multi-line
/// constructs such as block comments and template strings) and slice the
/// resulting spans per line — highlighting each diff line in isolation
/// loses the parser's cross-line state and miscolors those constructs.
class VibeFileDiffResult {
  /// The unified line diff (context/removed/added/gap rows).
  final List<DiffLine> lines;

  /// The reconstructed old snapshot, as a list of lines.
  final List<String> oldLines;

  /// The reconstructed new snapshot, as a list of lines.
  final List<String> newLines;

  const VibeFileDiffResult({
    required this.lines,
    required this.oldLines,
    required this.newLines,
  });
}

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
VibeFileDiffResult? computeVibeFileDiff(VibeFileDiffInput input) {
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
  if (!hasChange) return null;

  return VibeFileDiffResult(
    lines: lines,
    oldLines: _splitLines(oldText),
    newLines: _splitLines(newText),
  );
}

/// Whether the segment's [allCalls] can reconstruct a meaningful diff for
/// the file at [path] — i.e. [computeVibeFileDiff] would NOT return null
/// for it.
///
/// The files box's per-file `diff` action uses this to disable itself when
/// the answer is known to be no: segments persisted before the walker
/// tracked mutating calls (empty `modCalls`), and rows whose persisted call
/// args lack reconstructable content (e.g. an old `edit` row that stored a
/// read-shaped payload — see the June-2026 `limit`/`offset` arg mixup that
/// prompted this helper). Gating the action up front is better than
/// opening the fullpane to its "(no reconstructable changes)" placeholder.
bool hasReconstructableVibeFileDiff(
  String path,
  List<ToolCallData> allCalls,
) {
  final calls = allCalls
      .where((c) => vibeToolCallTouchesPath(c, path))
      .toList();
  if (calls.isEmpty) return false;
  return computeVibeFileDiff(VibeFileDiffInput(path: path, calls: calls)) !=
      null;
}

/// Whether a `write`/`edit` call targets [path]. The LLM names the same
/// file with different path strings across calls (absolute vs relative,
/// `./`-prefixed), so we normalize both sides and compare, falling back to
/// a basename comparison — the files box's own dedup notion of "same
/// file". Shared by the diff fullpane's per-file filter and
/// [hasReconstructableVibeFileDiff] so the row's gate always agrees with
/// what the fullpane would show.
bool vibeToolCallTouchesPath(ToolCallData call, String path) {
  final callPath = call.input['filePath'] as String? ?? '';
  if (callPath.isEmpty) return false;
  final a = p.normalize(callPath);
  final b = p.normalize(path);
  if (a == b) return true;
  return p.basename(a) == p.basename(b);
}

/// Split [text] into lines the same way the diff does — a single trailing
/// newline (the conventional EOF marker) does not produce a phantom empty
/// line, and an empty string yields zero lines. Kept in sync with the
/// diff's own splitter so the snapshot line indices line up with the
/// per-line numbers the renderers assign.
List<String> _splitLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.length > 1 && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
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
