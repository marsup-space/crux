import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../models/message.dart';
import '../theme/crux_theme.dart';
import '../utils/terminal_symbols.dart';
import 'tool_detail_utils.dart';
import 'ui/fullpane.dart';
import 'ui/highlight_service.dart';
import 'ui/layout_metrics.dart';
import 'vibe_box_data.dart';
import 'vibe_file_diff.dart';

/// A request to open the vibe diff fullpane for one segment's files box.
///
/// Carries everything the fullpane needs to render without touching the
/// live filesystem or git: the per-file entries (display path + segment
/// line counts), the segment's mutating `write`/`edit` calls (from which
/// each file's before/after is rebuilt by [computeVibeFileDiff]), and the
/// index of the file the user clicked `diff` on so the fullpane opens
/// focused on it.
class VibeDiffRequest {
  /// The segment's per-file entries (same order as the files box rows).
  final List<ModFileEntry> files;

  /// The segment's `write`/`edit` calls across all files, in order.
  final List<ToolCallData> calls;

  /// Index into [files] of the file whose `diff` action was activated.
  final int initialIndex;

  const VibeDiffRequest({
    required this.files,
    required this.calls,
    this.initialIndex = 0,
  });
}

/// Content width (in cells) at or above which a file's diff renders
/// side-by-side (old | new); below it the diff falls back to unified.
/// Mirrors the opencode diff viewer's `MIN_SPLIT_WIDTH = 100` gate —
/// the same "only split when there's room for two readable columns"
/// rule, applied per the fullpane's measured width.
const double kMinSplitWidth = 100;

/// Full-screen diff view for a vibe segment's `files` box.
///
/// Shows **one file at a time** (the user asked for a file picker rather
/// than a stacked all-files list): a header row with the full file list,
/// and the selected file's diff below. `←`/`→` (or `h`/`l`) move between
/// files; `j`/`k` and the arrow/page keys scroll.
///
/// The selected file's diff renders **side-by-side when the pane is wide
/// enough** (≥ [kMinSplitWidth]) and unified otherwise — the opencode
/// viewer's split/unified-by-width behaviour. Code is syntax-highlighted
/// from the file's extension and every row carries old/new line numbers
/// in a gutter. Each file's before/after is rebuilt from the segment's
/// own persisted `write`/`edit` args (see [computeVibeFileDiff]) — no
/// git, no live re-read — so the view stays anchored to what the agent
/// changed in this segment.
class VibeDiffFullpane extends StatefulComponent {
  final VibeDiffRequest request;
  final VoidCallback onClose;

  const VibeDiffFullpane({
    required this.request,
    required this.onClose,
    super.key,
  });

  @override
  State<VibeDiffFullpane> createState() => _VibeDiffFullpaneState();
}

class _VibeDiffFullpaneState extends State<VibeDiffFullpane> {
  late int _index = component.request.initialIndex.clamp(
    0,
    math.max(0, component.request.files.length - 1),
  );
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _selectFile(int index) {
    if (index == _index) return;
    setState(() {
      _index = index;
      // Jump back to the top so the newly selected file's diff starts at
      // its first line rather than inheriting the previous file's scroll
      // offset.
      _scroll.jumpTo(0);
    });
  }

  bool _handleKey(KeyboardEvent event) {
    final files = component.request.files;
    if (files.isEmpty) return false;
    final key = event.logicalKey;
    if (key == LogicalKey.arrowRight || key == LogicalKey.keyL) {
      _selectFile((_index + 1).clamp(0, files.length - 1));
      return true;
    }
    if (key == LogicalKey.arrowLeft || key == LogicalKey.keyH) {
      _selectFile((_index - 1).clamp(0, files.length - 1));
      return true;
    }
    // Let scroll keys fall through to the SingleChildScrollView's
    // keyboardScrollable handling (and the Fullpane's own escape).
    return false;
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final files = component.request.files;
    return Fullpane(
      title: 'Diff — ${files.isEmpty ? 0 : _index + 1}/${files.length}',
      onClose: component.onClose,
      onKeyEvent: _handleKey,
      shortcuts: [
        FullpaneShortcut(
          label: 'prev file',
          keyHint: '←',
          matches: (e) => e.logicalKey == LogicalKey.arrowLeft,
          onActivate: () => _selectFile((_index - 1).clamp(0, files.length - 1)),
        ),
        FullpaneShortcut(
          label: 'next file',
          keyHint: '→',
          matches: (e) => e.logicalKey == LogicalKey.arrowRight,
          onActivate: () => _selectFile((_index + 1).clamp(0, files.length - 1)),
        ),
      ],
      contentBuilder: (context) => LayoutBuilder(
        builder: (context, constraints) => _buildBody(theme, constraints),
      ),
    );
  }

  Component _buildBody(CruxThemeData theme, BoxConstraints constraints) {
    final files = component.request.files;
    if (files.isEmpty) {
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

    final entry = files[_index];
    // The content area is inside the fullpane's 1-cell horizontal padding,
    // so `constraints.maxWidth` is already the usable width for the diff.
    final useSplit = constraints.maxWidth >= kMinSplitWidth;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _filePicker(theme),
        Divider(color: theme.outline, height: 1),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            keyboardScrollable: true,
            child: _fileDiff(entry, theme, constraints.maxWidth, useSplit),
          ),
        ),
      ],
    );
  }

  /// The file picker header: every file's basename on one row, the
  /// selected one highlighted. Clicking a name selects that file.
  Component _filePicker(CruxThemeData theme) {
    final files = component.request.files;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < files.length; i++) ...[
            if (i > 0) Text('  ', style: TextStyle(color: theme.onSurfaceDim)),
            _pickerItem(files[i], i, theme),
          ],
        ],
      ),
    );
  }

  Component _pickerItem(ModFileEntry entry, int index, CruxThemeData theme) {
    final selected = index == _index;
    final name = p.basename(entry.path);
    return GestureDetector(
      onTap: () => _selectFile(index),
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: selected
            ? BoxDecoration(color: theme.wizardRowBgSelected)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Text(
          name.isEmpty ? entry.path : name,
          style: TextStyle(
            color: selected ? theme.foreground : theme.onSurfaceDim,
            fontWeight: selected ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }

  /// The selected file's diff: a header (path + segment `+N -M`), then the
  /// diff body in split or unified form by [useSplit].
  Component _fileDiff(
    ModFileEntry entry,
    CruxThemeData theme,
    double maxWidth,
    bool useSplit,
  ) {
    final calls = component.request.calls
        .where((c) => _callTouchesPath(c, entry.path))
        .toList();
    final lines = computeVibeFileDiff(
      VibeFileDiffInput(path: entry.path, calls: calls),
    );
    final language = languageFromPath(entry.path);

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
        else if (useSplit)
          _SplitDiff(
            lines: lines,
            theme: theme,
            language: language,
            totalWidth: maxWidth,
          )
        else
          _UnifiedDiff(lines: lines, theme: theme, language: language),
      ],
    );
  }
}

// ── shared helpers ───────────────────────────────────────────────────

/// Highlight [text] as [language], blending the diff foreground/background
/// onto each token. Returns a single plain span when the highlighter isn't
/// available (grammar not loaded) or the line is empty.
List<TextSpan> _highlightLine(
  String text,
  String language,
  CruxThemeData theme,
  Color fg,
  Color? bg,
) {
  if (text.isEmpty) {
    return [TextSpan(text: '', style: TextStyle(color: fg, backgroundColor: bg))];
  }
  if (language.isEmpty) {
    return [
      TextSpan(text: text, style: TextStyle(color: fg, backgroundColor: bg)),
    ];
  }
  final spans = highlightCode(text, language, theme);
  return [
    for (final span in spans)
      if (span is TextSpan)
        TextSpan(
          text: span.text,
          style: (span.style ?? const TextStyle()).copyWith(
            color: fg,
            backgroundColor: bg,
          ),
        ),
  ];
}

/// Whether every rendered line number fits in two cells, which lets the
/// gutter use a compact fixed width instead of measuring the file.
bool _allLineNumbersFit(int oldLines, int newLines) =>
    oldLines <= 99 && newLines <= 99;

/// Format a gutter cell: right-align the present side's number to [width],
/// blank when that side has no line. [width] is the number of digit cells.
String _gutterCell(int? number, int width) =>
    number == null ? ' ' * width : number.toString().padLeft(width);

/// Count the old/new lines a diff spans, for sizing the line-number gutter.
(int, int) _diffExtent(List<DiffLine> lines) {
  var old = 0;
  var newLines = 0;
  for (final line in lines) {
    switch (line.kind) {
      case DiffLineKind.context:
        old++;
        newLines++;
      case DiffLineKind.removed:
        old++;
      case DiffLineKind.added:
        newLines++;
      case DiffLineKind.gap:
        old += line.elidedCount;
        newLines += line.elidedCount;
    }
  }
  return (old, newLines);
}

/// Unified (single-column) diff — the same visual language as the edit
/// tool's inline diff: `-` rows tinted removed, `+` rows added, context
/// dimmed, long unchanged runs collapsed to a gap marker. Every row is
/// prefixed with its old/new line numbers and the code is highlighted.
class _UnifiedDiff extends StatelessComponent {
  final List<DiffLine> lines;
  final CruxThemeData theme;
  final String language;

  const _UnifiedDiff({
    required this.lines,
    required this.theme,
    required this.language,
  });

  @override
  Component build(BuildContext context) {
    final gapGlyph = terminalSymbol('⋮', '|');
    final (oldTotal, newTotal) = _diffExtent(lines);
    final width = _allLineNumbersFit(oldTotal, newTotal)
        ? 2
        : math.max(
            oldTotal.toString().length,
            newTotal.toString().length,
          );

    var oldLine = 1;
    var newLine = 1;
    final gutterStyle = TextStyle(color: theme.codeBlockGutter);

    final rows = <Component>[];
    for (final line in lines) {
      switch (line.kind) {
        case DiffLineKind.gap:
          rows.add(_gap(gapGlyph, line.elidedCount, width));
          oldLine += line.elidedCount;
          newLine += line.elidedCount;
        case DiffLineKind.removed:
          rows.add(
            _row(
              gutter: '${_gutterCell(oldLine, width)} ${_gutterCell(null, width)}',
              prefix: '-',
              text: line.text,
              fg: theme.diffRemoved,
              bg: theme.diffRemovedBackground,
              gutterStyle: gutterStyle,
            ),
          );
          oldLine++;
        case DiffLineKind.added:
          rows.add(
            _row(
              gutter: '${_gutterCell(null, width)} ${_gutterCell(newLine, width)}',
              prefix: '+',
              text: line.text,
              fg: theme.diffAdded,
              bg: theme.diffAddedBackground,
              gutterStyle: gutterStyle,
            ),
          );
          newLine++;
        case DiffLineKind.context:
          rows.add(
            _row(
              gutter: '${_gutterCell(oldLine, width)} ${_gutterCell(newLine, width)}',
              prefix: ' ',
              text: line.text,
              fg: theme.onSurfaceDim,
              bg: null,
              gutterStyle: gutterStyle,
            ),
          );
          oldLine++;
          newLine++;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  Component _gap(String glyph, int count, int width) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kContentHorizontalPadding,
      ),
      child: Text(
        '${' ' * (width * 2 + 2)} $glyph $count unchanged lines',
        style: TextStyle(
          color: theme.onSurfaceDim,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  Component _row({
    required String gutter,
    required String prefix,
    required String text,
    required Color fg,
    required Color? bg,
    required TextStyle gutterStyle,
  }) {
    return SizedBox(
      width: double.infinity,
      child: Container(
        decoration: bg != null ? BoxDecoration(color: bg) : null,
        padding: const EdgeInsets.symmetric(
          horizontal: kContentHorizontalPadding,
        ),
        child: RichText(
          softWrap: false,
          overflow: TextOverflow.clip,
          text: TextSpan(
            children: [
              TextSpan(text: gutter, style: gutterStyle),
              TextSpan(text: ' $prefix ', style: TextStyle(color: fg, backgroundColor: bg)),
              ..._highlightLine(text, language, theme, fg, bg),
            ],
          ),
        ),
      ),
    );
  }
}

/// Side-by-side (two-column) diff, shown when the pane is wide enough.
///
/// Rows are paired old|new: a context line appears on both sides, a run of
/// removals pairs with the following run of additions (a replaced hunk),
/// and unpaired removals/additions sit against an empty placeholder on the
/// other side. Each column has its own line-number gutter and clips its
/// highlighted code to its own width.
class _SplitDiff extends StatelessComponent {
  final List<DiffLine> lines;
  final CruxThemeData theme;
  final String language;

  /// The full usable width of the diff area; each column gets half minus
  /// the separator.
  final double totalWidth;

  const _SplitDiff({
    required this.lines,
    required this.theme,
    required this.language,
    required this.totalWidth,
  });

  @override
  Component build(BuildContext context) {
    final gapGlyph = terminalSymbol('⋮', '|');
    final (oldTotal, newTotal) = _diffExtent(lines);
    final width = _allLineNumbersFit(oldTotal, newTotal)
        ? 2
        : math.max(
            oldTotal.toString().length,
            newTotal.toString().length,
          );

    final rows = _pairRows(width);
    // 1 cell for the separator between the two columns.
    final colWidth = ((totalWidth - 1) / 2).floorToDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          row.isGap
              ? _gapRow(gapGlyph, row.gapCount, width)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: colWidth,
                      child: _cell(row.left, width, isLeft: true),
                    ),
                    SizedBox(
                      width: 1,
                      child: Text(
                        '│',
                        style: TextStyle(color: theme.outline),
                      ),
                    ),
                    SizedBox(
                      width: colWidth,
                      child: _cell(row.right, width, isLeft: false),
                    ),
                  ],
                ),
      ],
    );
  }

  Component _gapRow(String glyph, int count, int width) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kContentHorizontalPadding,
      ),
      child: Text(
        '$glyph $count unchanged lines',
        style: TextStyle(
          color: theme.onSurfaceDim,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }

  /// One side of a split row. Null [side] is an empty placeholder (the
  /// other half of an unpaired add/remove). Text is clipped, not wrapped,
  /// so a long line doesn't push the two columns out of alignment.
  Component _cell(_Side? side, int width, {required bool isLeft}) {
    if (side == null) {
      return const SizedBox();
    }
    final (fg, bg) = switch (side.kind) {
      DiffLineKind.removed => (theme.diffRemoved, theme.diffRemovedBackground),
      DiffLineKind.added => (theme.diffAdded, theme.diffAddedBackground),
      _ => (theme.onSurfaceDim, null),
    };
    final gutterStyle = TextStyle(color: theme.codeBlockGutter);
    return Container(
      decoration: bg != null ? BoxDecoration(color: bg) : null,
      padding: const EdgeInsets.symmetric(
        horizontal: kContentHorizontalPadding,
      ),
      child: RichText(
        softWrap: false,
        overflow: TextOverflow.clip,
        text: TextSpan(
          children: [
            TextSpan(text: _gutterCell(side.lineNumber, width), style: gutterStyle),
            TextSpan(text: ' ', style: TextStyle(color: fg, backgroundColor: bg)),
            ..._highlightLine(side.text, language, theme, fg, bg),
          ],
        ),
      ),
    );
  }

  /// Pair the linear diff into old|new rows, assigning old/new line
  /// numbers in a single forward pass. Consecutive removals followed by
  /// consecutive additions are zipped line-by-line (a replaced hunk);
  /// leftover removals/additions pair with an empty placeholder. Context
  /// lines occupy both columns.
  List<_SplitRow> _pairRows(int width) {
    final rows = <_SplitRow>[];
    var oldLine = 1;
    var newLine = 1;
    var i = 0;
    while (i < lines.length) {
      final line = lines[i];
      if (line.kind == DiffLineKind.context) {
        rows.add(
          _SplitRow(
            left: _Side(DiffLineKind.context, line.text, oldLine),
            right: _Side(DiffLineKind.context, line.text, newLine),
          ),
        );
        oldLine++;
        newLine++;
        i++;
      } else if (line.kind == DiffLineKind.gap) {
        rows.add(_SplitRow.gap(line.elidedCount));
        oldLine += line.elidedCount;
        newLine += line.elidedCount;
        i++;
      } else {
        // Collect the run of removals and the run of additions that make
        // up this change hunk, then zip them.
        final removed = <_Side>[];
        while (i < lines.length && lines[i].kind == DiffLineKind.removed) {
          removed.add(_Side(DiffLineKind.removed, lines[i].text, oldLine));
          oldLine++;
          i++;
        }
        final added = <_Side>[];
        while (i < lines.length && lines[i].kind == DiffLineKind.added) {
          added.add(_Side(DiffLineKind.added, lines[i].text, newLine));
          newLine++;
          i++;
        }
        final n = math.max(removed.length, added.length);
        for (var k = 0; k < n; k++) {
          rows.add(
            _SplitRow(
              left: k < removed.length ? removed[k] : null,
              right: k < added.length ? added[k] : null,
            ),
          );
        }
      }
    }
    return rows;
  }
}

/// One side of a split diff row: the code text plus its line number on
/// this side (old on the left, new on the right).
class _Side {
  final DiffLineKind kind;
  final String text;
  final int lineNumber;
  const _Side(this.kind, this.text, this.lineNumber);
}

/// A paired old|new row, or a full-width gap marker.
class _SplitRow {
  final _Side? left;
  final _Side? right;
  final bool isGap;
  final int gapCount;

  const _SplitRow({this.left, this.right})
    : isGap = false,
      gapCount = 0;

  const _SplitRow.gap(this.gapCount)
    : left = null,
      right = null,
      isGap = true;
}

/// Whether a `write`/`edit` call targets [path]. The LLM names the same
/// file with different path strings across calls (absolute vs relative,
/// `./`-prefixed), so we normalize both sides and compare, falling back to
/// a basename comparison — the files box's own dedup notion of "same
/// file".
bool _callTouchesPath(ToolCallData call, String path) {
  final callPath = call.input['filePath'] as String? ?? '';
  if (callPath.isEmpty) return false;
  final a = p.normalize(callPath);
  final b = p.normalize(path);
  if (a == b) return true;
  return p.basename(a) == p.basename(b);
}
