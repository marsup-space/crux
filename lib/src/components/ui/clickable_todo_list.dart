import 'dart:async';

import 'package:nocterm/nocterm.dart';
// TextLayoutEngine / UnicodeWidth are nocterm internals not re-exported
// through the public barrel; used here to word-wrap long todo rows with a
// hanging indent.
// ignore_for_file: implementation_imports
import 'package:nocterm/src/text/text_layout_engine.dart';
import 'package:nocterm/src/utils/unicode_width.dart';

import '../../theme/crux_theme.dart';
import 'button.dart';

/// One open todo rendered as a clickable row.
typedef TodoRowData = ({String text, int line});

/// Shared interactive todo-list rendering for the "my notes" feature —
/// used by both the spec sidebar widget and the home dashboard box so
/// the interaction is identical everywhere.
///
/// Each open row renders as a flush-left `☐` marker followed by an
/// indented ` text` [Button]; clicking it marks the todo done: the row
/// flips to `☑ text` (struck-through, success color)
/// *locally and immediately*, fires [onToggle] with `done: true`, and
/// stays visible for [undoWindow] (default 10 s) so an accidental click
/// can be reversed. Clicking a checked row inside the window restores
/// it (`done: false`). After the window the checked row disappears from
/// the list (it still exists in the backing document, now checked).
///
/// When [onToggle] is null the rows render as plain non-clickable text
/// (tests / contexts with no host).
class ClickableTodoList extends StatefulComponent {
  /// The open todos to show, in display order.
  final List<TodoRowData> todos;

  /// Callback fired on every row click: `done: true` marks it done,
  /// `done: false` restores it (the undo click). Null → plain text rows.
  final void Function(String text, int line, bool done)? onToggle;

  /// How long a checked row stays visible before disappearing.
  final Duration undoWindow;

  /// Base text color for open rows (checked rows use the success color).
  final Color? color;

  const ClickableTodoList({
    super.key,
    required this.todos,
    this.onToggle,
    this.undoWindow = const Duration(seconds: 10),
    this.color,
  });

  @override
  State<ClickableTodoList> createState() => _ClickableTodoListState();
}

class _ClickableTodoListState extends State<ClickableTodoList> {
  /// Line → text of rows the user just checked, still inside their undo
  /// window. Rendered as checked rows even after the host drops them
  /// from the projection, so an accidental click is visible/reversible.
  final Map<int, String> _checked = {};

  /// Per-checked-line timers that expire the row after [undoWindow].
  final Map<int, Timer> _checkedTimers = {};

  @override
  void dispose() {
    for (final t in _checkedTimers.values) {
      t.cancel();
    }
    _checkedTimers.clear();
    super.dispose();
  }

  void _markDone(String text, int line) {
    setState(() {
      _checked[line] = text;
    });
    _checkedTimers[line]?.cancel();
    _checkedTimers[line] = Timer(component.undoWindow, () {
      if (!mounted) return;
      setState(() {
        _checked.remove(line);
        _checkedTimers.remove(line);
      });
    });
    component.onToggle?.call(text, line, true);
  }

  void _undo(String text, int line) {
    _checkedTimers.remove(line)?.cancel();
    setState(() {
      _checked.remove(line);
    });
    component.onToggle?.call(text, line, false);
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final baseColor = component.color ?? theme.onSurfaceVariant;

    // Merge the open todos with any rows still in the undo window (which
    // the host has already dropped from its projection), preserving
    // order by line: first the projection rows, then any undo-window
    // rows the projection no longer lists.
    final rows = <({String text, int line})>[];
    final seenLines = <int>{};
    for (final todo in component.todos) {
      rows.add(todo);
      seenLines.add(todo.line);
    }
    for (final line in _checked.keys) {
      if (seenLines.contains(line)) continue;
      final text = _checked[line] ?? '';
      if (text.isEmpty) continue;
      rows.add((text: text, line: line));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++)
          _row(theme, baseColor, rows[i].text, rows[i].line, i),
      ],
    );
  }

  Component _row(
    CruxThemeData theme,
    Color baseColor,
    String text,
    int line,
    int index,
  ) {
    final checked = _checked.containsKey(line);
    final onToggle = component.onToggle;

    // Alternating row background, matching the markdown table's zebra
    // striping: even rows keep the box surface, odd rows tint with
    // surfaceVariant. `withOpacity(0.5)` keeps it a subtle tint rather
    // than a solid band (same treatment as the table cells).
    final rowBackground = (index.isEven ? theme.surface : theme.surfaceVariant)
        .withOpacity(0.5);

    // Checkbox flush-left, then a single-space gutter. Wrapped continuation
    // lines are indented to the same column so long todos stay aligned.
    final marker = checked ? '☑' : '☐';
    const gutter = ' ';
    final prefix = '$marker$gutter';

    return Container(
      width: double.infinity,
      color: rowBackground,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth.toInt()
              : null;
          final label = _hangingIndentLabel(prefix, text, maxWidth);

          if (onToggle == null) {
            return Text(
              label,
              softWrap: false,
              style: TextStyle(
                color: checked ? theme.successColor : baseColor,
                decoration: checked
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
              ),
            );
          }

          return Button(
            label: label,
            onPressed: () =>
                checked ? _undo(text, line) : _markDone(text, line),
            color: checked ? theme.successColor : baseColor,
            hoverColor: theme.accent,
            // Transparent idle background so the row's alternating tint
            // shows through; hover still paints the usual highlight.
            bgColor: theme.surface.withAlpha(0),
            hoverBgColor: theme.buttonBackgroundHover,
            padding: EdgeInsets.zero,
          );
        },
      ),
    );
  }

  /// Wraps [text] to [maxWidth] display columns with a hanging indent: the
  /// first line carries [prefix] (`☐ ` / `☑ `), and every wrapped
  /// continuation line is indented by the same width so it lines up under
  /// the content column.
  String _hangingIndentLabel(String prefix, String text, int? maxWidth) {
    if (maxWidth == null) return '$prefix$text';

    final prefixWidth = UnicodeWidth.stringWidth(prefix);
    final contentWidth = maxWidth - prefixWidth;
    if (contentWidth < 1) return '$prefix$text';

    final layout = TextLayoutEngine.layout(
      text,
      TextLayoutConfig(softWrap: true, maxWidth: contentWidth),
    );
    final lines = layout.lines;
    if (lines.length <= 1) return '$prefix$text';

    final indent = ' ' * prefixWidth;
    final buffer = StringBuffer('$prefix${lines.first}');
    for (var i = 1; i < lines.length; i++) {
      buffer.write('\n$indent${lines[i]}');
    }
    return buffer.toString();
  }
}
