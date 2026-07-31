import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../models/message.dart';
import '../theme/crux_theme.dart';
import '../utils/terminal_symbols.dart';
import 'tool_detail_utils.dart';
import 'ui/fullpane.dart';
import 'ui/layout_metrics.dart';
import 'vibe_box_data.dart';
import 'vibe_file_diff.dart';

/// A request to open the vibe diff fullpane for one segment's files box.
///
/// Carries everything the fullpane needs to render without touching the
/// live filesystem or git: the per-file entries (display path + segment
/// line counts) and the segment's mutating `write`/`edit` calls, from
/// which each file's before/after is rebuilt by [computeVibeFileDiff].
class VibeDiffRequest {
  /// The segment's per-file entries (same order as the files box rows).
  final List<ModFileEntry> files;

  /// The segment's `write`/`edit` calls across all files, in order.
  final List<ToolCallData> calls;

  const VibeDiffRequest({required this.files, required this.calls});
}

/// Full-screen diff view for a vibe segment's `files` box.
///
/// Opened by the box's `diff` button. Shows every file the segment
/// mutated as a stacked list of per-file unified diffs — the opencode
/// diff viewer's all-files layout, scoped to this segment's own
/// `write`/`edit` changes rather than the git working tree (the user
/// picked the tool-call diff source).
///
/// Each file's before/after pair is rebuilt from the segment's persisted
/// tool-call args (see [computeVibeFileDiff]); no live re-read, so the
/// view stays anchored to what the agent actually changed in this
/// segment. The visual language mirrors the edit tool's inline diff:
/// `- ` rows tinted [CruxThemeData.diffRemoved], `+ ` rows
/// [CruxThemeData.diffAdded], context dimmed, long unchanged runs
/// collapsed to a `⋮ N unchanged lines` gap marker.
class VibeDiffFullpane extends StatelessComponent {
  final VibeDiffRequest request;
  final VoidCallback onClose;

  const VibeDiffFullpane({
    required this.request,
    required this.onClose,
    super.key,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final count = request.files.length;
    return Fullpane(
      title: 'Diff — $count ${count == 1 ? 'file' : 'files'}',
      onClose: onClose,
      contentBuilder: (context) => _buildBody(theme),
    );
  }

  Component _buildBody(CruxThemeData theme) {
    if (request.files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(1),
        child: Text(
          'No files changed in this segment.',
          style: TextStyle(
            color: theme.onSurfaceDim,
            fontStyle: FontStyle.italic,
          ),
        ),
      );
    }

    final children = <Component>[];
    for (var i = 0; i < request.files.length; i++) {
      final entry = request.files[i];
      if (i > 0) {
        children.add(Divider(color: theme.outline, height: 1));
      }
      children.add(_fileSection(entry, theme));
    }

    return SingleChildScrollView(
      keyboardScrollable: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// One file's section: a header row (path + segment `+N -M`) followed
  /// by its reconstructed unified diff, or a placeholder when the file's
  /// change can't be rebuilt from the segment's calls.
  Component _fileSection(ModFileEntry entry, CruxThemeData theme) {
    // Narrow the segment's calls to this file. Paths come from the LLM in
    // mixed forms (absolute / relative / `./`-prefixed), so match on the
    // normalized basename-and-directory tail rather than string equality.
    final calls = request.calls
        .where((c) => _callTouchesPath(c, entry.path))
        .toList();
    final lines = computeVibeFileDiff(
      VibeFileDiffInput(path: entry.path, calls: calls),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kContentHorizontalPadding,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  entry.path,
                  style: TextStyle(
                    color: theme.foreground,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                '+${entry.linesAdded}',
                style: TextStyle(color: theme.diffAdded),
              ),
              const Text(' '),
              Text(
                '-${entry.linesRemoved}',
                style: TextStyle(color: theme.diffRemoved),
              ),
            ],
          ),
        ),
        if (lines == null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: kContentHorizontalPadding,
            ),
            child: Text(
              '  (no reconstructable changes)',
              style: TextStyle(
                color: theme.onSurfaceDim,
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          _diffLines(lines, theme),
      ],
    );
  }

  Component _diffLines(List<DiffLine> lines, CruxThemeData theme) {
    final gapGlyph = terminalSymbol('⋮', '|');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          switch (line.kind) {
            DiffLineKind.removed => _row(
              '- ',
              line.text,
              theme.diffRemoved,
              theme.diffRemovedBackground,
            ),
            DiffLineKind.added => _row(
              '+ ',
              line.text,
              theme.diffAdded,
              theme.diffAddedBackground,
            ),
            DiffLineKind.context => _row(
              '  ',
              line.text,
              theme.onSurfaceDim,
              null,
            ),
            DiffLineKind.gap => Container(
              padding: const EdgeInsets.symmetric(
                horizontal: kContentHorizontalPadding,
              ),
              child: Text(
                '  $gapGlyph ${line.elidedCount} unchanged lines',
                style: TextStyle(
                  color: theme.onSurfaceDim,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          },
      ],
    );
  }

  /// One full-width diff row. Colored rows paint their background across
  /// the whole pane width so wrapped lines stay inside the tinted band —
  /// same treatment as the edit tool's inline diff.
  Component _row(String prefix, String text, Color fg, Color? bg) {
    return SizedBox(
      width: double.infinity,
      child: Container(
        decoration: bg != null ? BoxDecoration(color: bg) : null,
        padding: const EdgeInsets.symmetric(
          horizontal: kContentHorizontalPadding,
        ),
        child: Text(
          '$prefix$text',
          style: TextStyle(color: fg, backgroundColor: bg),
        ),
      ),
    );
  }
}

/// Whether a `write`/`edit` call targets [path]. The LLM names the same
/// file with different path strings across calls (absolute vs relative,
/// `./`-prefixed), so we normalize both sides and compare. Falls back to
/// a basename comparison when the normalized forms still differ — the
/// files box dedupes by basename, so that is the box's own notion of
/// "same file".
bool _callTouchesPath(ToolCallData call, String path) {
  final callPath = call.input['filePath'] as String? ?? '';
  if (callPath.isEmpty) return false;
  final a = p.normalize(callPath);
  final b = p.normalize(path);
  if (a == b) return true;
  return p.basename(a) == p.basename(b);
}
