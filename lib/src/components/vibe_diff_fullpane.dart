import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../models/message.dart';
import '../theme/crux_theme.dart';
import '../i18n/strings.dart';
import '../utils/terminal_symbols.dart';
import 'tool_detail_utils.dart';
import 'ui/fullpane.dart';
import 'ui/highlight_service.dart';
import 'ui/hoverable.dart';
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
/// and the selected file's diff below. With several files `←`/`→` (or
/// `h`/`l`) move between them; `j`/`k` and the arrow/page keys scroll.
///
/// The selected file's diff renders **side-by-side when the pane is wide
/// enough** (≥ [kMinSplitWidth]) and unified otherwise — the opencode
/// viewer's split/unified-by-width behaviour. Code is syntax-highlighted
/// from the file's extension and every row carries old/new line numbers
/// in a gutter. The highlight runs over the **whole** old/new snapshot
/// once, then slices per line, so multi-line constructs (block comments,
/// template strings) keep their color — highlighting each diff line in
/// isolation would lose the parser's cross-line state and mis-color the
/// continuation lines. Each file's before/after is rebuilt from the
/// segment's own persisted `write`/`edit` args (see [computeVibeFileDiff])
/// — no git, no live re-read — so the view stays anchored to what the
/// agent changed in this segment.
///
/// Long lines **soft-wrap** to fit the pane width, so the full line is
/// always visible without any horizontal scrolling. The diff scrolls
/// vertically only. `←`/`→` (or `h`/`l`) switch files when a segment has
/// several.
class VibeDiffFullpane extends StatefulComponent {
  final VibeDiffRequest request;
  final VoidCallback onClose;
  final Strings strings;

  const VibeDiffFullpane({
    required this.request,
    required this.onClose,
    this.strings = kEnglishStrings,
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
    // Arrows (or h/l) switch files; only relevant with several files.
    if (key == LogicalKey.arrowRight || key == LogicalKey.keyL) {
      _selectFile((_index + 1).clamp(0, files.length - 1));
      return true;
    }
    if (key == LogicalKey.arrowLeft || key == LogicalKey.keyH) {
      _selectFile((_index - 1).clamp(0, files.length - 1));
      return true;
    }
    // Vertical scroll keys fall through to the SingleChildScrollView's
    // keyboardScrollable handling (and the Fullpane's own escape).
    return false;
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final files = component.request.files;
    final multiple = files.length > 1;
    // The title is the current file's full path. For a multi-file segment
    // we also show the position (n/N) so the prev/next shortcuts have a
    // visible anchor; for a single file the path alone is the title.
    final title = files.isEmpty
        ? component.strings.t('chat.vibe.diffTitle')
        : multiple
        ? '${files[_index].path}  ${_index + 1}/${files.length}'
        : files[_index].path;
    return Fullpane(
      title: title,
      onClose: component.onClose,
      strings: component.strings,
      onKeyEvent: _handleKey,
      shortcuts: [
        if (multiple) ...[
          FullpaneShortcut(
            label: component.strings.t('chat.vibe.prevFile'),
            keyHint: '←',
            matches: (e) => e.logicalKey == LogicalKey.arrowLeft,
            onActivate: () =>
                _selectFile((_index - 1).clamp(0, files.length - 1)),
          ),
          FullpaneShortcut(
            label: component.strings.t('chat.vibe.nextFile'),
            keyHint: '→',
            matches: (e) => e.logicalKey == LogicalKey.arrowRight,
            onActivate: () =>
                _selectFile((_index + 1).clamp(0, files.length - 1)),
          ),
        ],
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
    // The file picker (and its divider) is only useful when there's more
    // than one file to switch between — with a single file the title
    // already names it, so we go straight to the diff.
    final multiple = files.length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (multiple) ...[
          _filePicker(theme),
          Divider(color: theme.outline, height: 1),
        ],
        Expanded(
          // Vertical scrolling only — the diff soft-wraps to the pane
          // width, so there's nothing to pan horizontally.
          child: SingleChildScrollView(
            controller: _scroll,
            keyboardScrollable: true,
            child: _fileDiff(
              entry,
              theme,
              constraints.maxWidth,
              useSplit,
              // With a single file the fullpath is already the fullpane
              // title, so the body header shows only the +N -M counts;
              // with several files the picker shows basenames, so the
              // body header keeps the full path for clarity.
              showPath: multiple,
            ),
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
    return Hoverable(
      onTap: () => _selectFile(index),
      builder: (context, hovered) => Container(
        decoration: BoxDecoration(
          color: selected
              ? theme.wizardRowBgSelected
              : hovered
              ? theme.wizardRowBgHover
              : theme.buttonBackground,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Text(
          name.isEmpty ? entry.path : name,
          style: TextStyle(
            color: selected || hovered ? theme.foreground : theme.onSurfaceDim,
            fontWeight: selected ? FontWeight.bold : null,
          ),
        ),
      ),
    );
  }

  /// The selected file's diff: a header (path + segment `+N -M`), then the
  /// diff body in split or unified form by [useSplit]. When [showPath] is
  /// false (a single-file segment, where the fullpath is already the
  /// fullpane title) the header collapses to just the right-aligned
  /// `+N -M` counts.
  Component _fileDiff(
    ModFileEntry entry,
    CruxThemeData theme,
    double maxWidth,
    bool useSplit, {
    bool showPath = true,
  }) {
    final calls = component.request.calls
        .where((c) => vibeToolCallTouchesPath(c, entry.path))
        .toList();
    final result = computeVibeFileDiff(
      VibeFileDiffInput(path: entry.path, calls: calls),
    );
    final language = languageFromPath(entry.path);

    final body = result == null ? null : _highlighted(result, language, theme);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kContentHorizontalPadding,
          ),
          // No Expanded/Spacer: this header sits inside the inner
          // horizontal scroll view, which gives it an unbounded width —
          // a flex child would throw. Shrink-wrap instead.
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showPath) ...[
                Text(
                  entry.path,
                  softWrap: false,
                  style: TextStyle(
                    color: theme.foreground,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text('  '),
              ],
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
        if (result == null || body == null)
          // Normally unreachable from the files box: the segment
          // bubble disables the `diff` action when
          // hasReconstructableVibeFileDiff says no. This remains as
          // the fallback for a file that turns unreconstructable
          // after the fullpane is already open.
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: kContentHorizontalPadding,
            ),
            child: Text(
              '  ${component.strings.t('chat.vibe.noReconstructable')}',
              style: TextStyle(
                color: theme.onSurfaceDim,
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else if (useSplit)
          _SplitDiff(
            lines: result.lines,
            theme: theme,
            totalWidth: maxWidth,
            gutterWidth: _gutterWidth(result),
            leftSpans: body.left,
            rightSpans: body.right,
          )
        else
          _UnifiedDiff(
            lines: result.lines,
            theme: theme,
            gutterWidth: _gutterWidth(result),
            leftSpans: body.left,
            rightSpans: body.right,
          ),
      ],
    );
  }

  /// The digit width of the line-number gutter: 2 cells when every number
  /// fits, else the widest number's width.
  int _gutterWidth(VibeFileDiffResult result) {
    final old = result.oldLines.length;
    final newLines = result.newLines.length;
    if (old <= 99 && newLines <= 99) return 2;
    return math.max(old.toString().length, newLines.toString().length);
  }

  /// Highlight the whole old/new snapshot once and slice into per-line
  /// span lists (0-indexed by line number − 1). Highlighting per line
  /// would reset the TextMate state at every boundary and miscolor
  /// multi-line block comments / strings; highlighting whole and slicing
  /// keeps it.
  _Highlighted _highlighted(
    VibeFileDiffResult result,
    String language,
    CruxThemeData theme,
  ) {
    return _Highlighted(
      left: _highlightLines(result.oldLines, language, theme),
      right: _highlightLines(result.newLines, language, theme),
    );
  }
}

/// The per-line syntax spans for both sides of a file's diff.
class _Highlighted {
  /// Spans for the old snapshot, one entry per line (0-indexed).
  final List<List<TextSpan>> left;

  /// Spans for the new snapshot, one entry per line (0-indexed).
  final List<List<TextSpan>> right;

  const _Highlighted({required this.left, required this.right});
}

/// Highlight each line of [lines] as [language] by running the
/// highlighter over the whole joined text and slicing the resulting spans
/// at the line boundaries. Returns one span list per line (0-indexed).
///
/// Highlighting the whole text once (rather than line-by-line) preserves
/// the TextMate parser's cross-line state, so multi-line constructs —
/// block comments, template strings, raw strings — keep their color on
/// every continuation line instead of being re-tokenized as plain code.
List<List<TextSpan>> _highlightLines(
  List<String> lines,
  String language,
  CruxThemeData theme,
) {
  if (lines.isEmpty) return const [];
  if (language.isEmpty) {
    return [
      for (final l in lines) [TextSpan(text: l)],
    ];
  }
  final joined = lines.join('\n');
  final spans = highlightCode(joined, language, theme);

  // Slice the flat span list at each '\n'. A span may straddle a line
  // boundary (a multi-line token such as a block-comment run), so split
  // it and carry its style across the boundary.
  final perLine = <List<TextSpan>>[];
  var current = <TextSpan>[];
  for (final span in spans) {
    if (span is! TextSpan) continue;
    var remaining = span.text ?? '';
    while (remaining.isNotEmpty) {
      final nl = remaining.indexOf('\n');
      if (nl < 0) {
        current.add(TextSpan(text: remaining, style: span.style));
        remaining = '';
      } else {
        final piece = remaining.substring(0, nl);
        if (piece.isNotEmpty) {
          current.add(TextSpan(text: piece, style: span.style));
        }
        perLine.add(current);
        current = <TextSpan>[];
        remaining = remaining.substring(nl + 1);
      }
    }
  }
  // The joined text does not end with '\n', so the trailing line's spans
  // are still in `current` — flush them.
  perLine.add(current);

  // Defensive: if the highlighter dropped a line, pad with plain text so
  // the per-line index still lines up with the diff's line numbers.
  while (perLine.length < lines.length) {
    perLine.add([TextSpan(text: lines[perLine.length])]);
  }
  return perLine;
}

/// Format a gutter cell: right-align the present side's number to [width],
/// blank when that side has no line. [width] is the number of digit cells.
String _gutterCell(int? number, int width) =>
    number == null ? ' ' * width : number.toString().padLeft(width);

/// Unified (single-column) diff — the same visual language as the edit
/// tool's inline diff: `-` rows tinted removed, `+` rows added, context
/// dimmed, long unchanged runs collapsed to a gap marker. Every row is
/// prefixed with its old/new line numbers and the code is highlighted.
class _UnifiedDiff extends StatelessComponent {
  final List<DiffLine> lines;
  final CruxThemeData theme;

  /// Digit width of the line-number gutter.
  final int gutterWidth;

  /// Per-line syntax spans for the old (removed/context) side.
  final List<List<TextSpan>> leftSpans;

  /// Per-line syntax spans for the new (added/context) side.
  final List<List<TextSpan>> rightSpans;

  const _UnifiedDiff({
    required this.lines,
    required this.theme,
    required this.gutterWidth,
    required this.leftSpans,
    required this.rightSpans,
  });

  @override
  Component build(BuildContext context) {
    final gapGlyph = terminalSymbol('⋮', '|');
    final gutterStyle = TextStyle(color: theme.codeBlockGutter);

    var oldLine = 1;
    var newLine = 1;
    final rows = <Component>[];
    for (final line in lines) {
      switch (line.kind) {
        case DiffLineKind.gap:
          rows.add(_gap(gapGlyph, line.elidedCount));
          oldLine += line.elidedCount;
          newLine += line.elidedCount;
        case DiffLineKind.removed:
          rows.add(
            _row(
              gutter:
                  '${_gutterCell(oldLine, gutterWidth)} ${_gutterCell(null, gutterWidth)}',
              prefix: '-',
              spans: _spansFor(leftSpans, oldLine, line.text),
              fg: theme.diffRemoved,
              bg: theme.diffRemovedBackground,
              gutterStyle: gutterStyle,
            ),
          );
          oldLine++;
        case DiffLineKind.added:
          rows.add(
            _row(
              gutter:
                  '${_gutterCell(null, gutterWidth)} ${_gutterCell(newLine, gutterWidth)}',
              prefix: '+',
              spans: _spansFor(rightSpans, newLine, line.text),
              fg: theme.diffAdded,
              bg: theme.diffAddedBackground,
              gutterStyle: gutterStyle,
            ),
          );
          newLine++;
        case DiffLineKind.context:
          rows.add(
            _row(
              gutter:
                  '${_gutterCell(oldLine, gutterWidth)} ${_gutterCell(newLine, gutterWidth)}',
              prefix: ' ',
              spans: _spansFor(leftSpans, oldLine, line.text),
              fg: theme.onSurfaceDim,
              bg: null,
              gutterStyle: gutterStyle,
            ),
          );
          oldLine++;
          newLine++;
      }
    }

    // The inner horizontal scroll view already gives this column unbounded
    // width, so it shrink-wraps to its longest row and the viewport pans
    // over it; in wrap mode each row wraps to the viewport width instead.
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  Component _gap(String glyph, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kContentHorizontalPadding,
      ),
      child: Text(
        '${' ' * (gutterWidth * 2 + 2)} $glyph $count unchanged lines',
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
    required List<TextSpan> spans,
    required Color fg,
    required Color? bg,
    required TextStyle gutterStyle,
  }) {
    return Container(
      decoration: bg != null ? BoxDecoration(color: bg) : null,
      padding: const EdgeInsets.symmetric(
        horizontal: kContentHorizontalPadding,
      ),
      child: RichText(
        softWrap: true,
        overflow: TextOverflow.clip,
        text: TextSpan(
          children: [
            TextSpan(text: gutter, style: gutterStyle),
            TextSpan(
              text: ' $prefix ',
              style: TextStyle(color: fg, backgroundColor: bg),
            ),
            ..._applyBackground(spans, fg, bg),
          ],
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
/// other side. Each column has its own line-number gutter, and long code
/// soft-wraps within its column width.
class _SplitDiff extends StatelessComponent {
  final List<DiffLine> lines;
  final CruxThemeData theme;

  /// Digit width of the line-number gutter.
  final int gutterWidth;

  /// Per-line syntax spans for the old (left) side.
  final List<List<TextSpan>> leftSpans;

  /// Per-line syntax spans for the new (right) side.
  final List<List<TextSpan>> rightSpans;

  /// The full usable width of the diff area; each column gets half minus
  /// the separator.
  final double totalWidth;

  const _SplitDiff({
    required this.lines,
    required this.theme,
    required this.gutterWidth,
    required this.leftSpans,
    required this.rightSpans,
    required this.totalWidth,
  });

  @override
  Component build(BuildContext context) {
    final gapGlyph = terminalSymbol('⋮', '|');
    final rows = _pairRows();
    // 1 cell for the separator between the two columns.
    final colWidth = ((totalWidth - 1) / 2).floorToDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          row.isGap
              ? _gapRow(gapGlyph, row.gapCount)
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: colWidth,
                      child: _cell(row.left, isLeft: true),
                    ),
                    SizedBox(
                      width: 1,
                      child: Text('│', style: TextStyle(color: theme.outline)),
                    ),
                    SizedBox(
                      width: colWidth,
                      child: _cell(row.right, isLeft: false),
                    ),
                  ],
                ),
      ],
    );
  }

  Component _gapRow(String glyph, int count) {
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
  Component _cell(_Side? side, {required bool isLeft}) {
    if (side == null) {
      return const SizedBox();
    }
    final (fg, bg) = switch (side.kind) {
      DiffLineKind.removed => (theme.diffRemoved, theme.diffRemovedBackground),
      DiffLineKind.added => (theme.diffAdded, theme.diffAddedBackground),
      _ => (theme.onSurfaceDim, null),
    };
    final spans = _spansFor(
      isLeft ? leftSpans : rightSpans,
      side.lineNumber,
      side.text,
    );
    final gutterStyle = TextStyle(color: theme.codeBlockGutter);
    return Container(
      decoration: bg != null ? BoxDecoration(color: bg) : null,
      padding: const EdgeInsets.symmetric(
        horizontal: kContentHorizontalPadding,
      ),
      child: RichText(
        softWrap: true,
        overflow: TextOverflow.clip,
        text: TextSpan(
          children: [
            TextSpan(
              text: _gutterCell(side.lineNumber, gutterWidth),
              style: gutterStyle,
            ),
            TextSpan(
              text: ' ',
              style: TextStyle(color: fg, backgroundColor: bg),
            ),
            ..._applyBackground(spans, fg, bg),
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
  List<_SplitRow> _pairRows() {
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

/// Fetch the syntax spans for [lineNumber] (1-based) from [perLine],
/// falling back to a single plain span of [text] when the index is out of
/// range (a gap/padding mismatch) so a row never renders empty.
List<TextSpan> _spansFor(
  List<List<TextSpan>> perLine,
  int lineNumber,
  String text,
) {
  final i = lineNumber - 1;
  if (i < 0 || i >= perLine.length) return [TextSpan(text: text)];
  final spans = perLine[i];
  return spans.isEmpty ? [TextSpan(text: text)] : spans;
}

/// Blend the diff row's background onto each syntax span, keeping the
/// token's syntax color as the foreground. The diff's add/remove/context
/// identity is carried by the row background and the `-`/`+` marker, NOT
/// by flattening every token to one foreground — that would erase the
/// highlight. [fgFallback] covers tokens the highlighter left uncolored.
List<TextSpan> _applyBackground(
  List<TextSpan> spans,
  Color fgFallback,
  Color? bg,
) {
  return [
    for (final span in spans)
      TextSpan(
        text: span.text,
        style: (span.style ?? const TextStyle()).copyWith(
          color: span.style?.color ?? fgFallback,
          backgroundColor: bg,
        ),
      ),
  ];
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

  const _SplitRow({this.left, this.right}) : isGap = false, gapCount = 0;

  const _SplitRow.gap(this.gapCount) : left = null, right = null, isGap = true;
}
