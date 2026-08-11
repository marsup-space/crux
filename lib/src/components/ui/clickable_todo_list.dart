import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../../theme/crux_theme.dart';
import 'button.dart';

/// One open todo rendered as a clickable row.
typedef TodoRowData = ({String text, int line});

/// Shared interactive todo-list rendering for the "my notes" feature —
/// used by both the spec sidebar widget and the home dashboard box so
/// the interaction is identical everywhere.
///
/// Each open row renders as a `☐ text` [Button]; clicking it marks the
/// todo done: the row flips to `☑ text` (struck-through, success color)
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
        for (final todo in rows)
          _row(theme, baseColor, todo.text, todo.line),
      ],
    );
  }

  Component _row(
    CruxThemeData theme,
    Color baseColor,
    String text,
    int line,
  ) {
    final checked = _checked.containsKey(line);
    final onToggle = component.onToggle;
    if (onToggle == null) {
      return Text(
        '${checked ? '☑' : '☐'} $text',
        style: TextStyle(
          color: checked ? theme.successColor : baseColor,
          decoration:
              checked ? TextDecoration.lineThrough : TextDecoration.none,
        ),
      );
    }
    return Button(
      label: '${checked ? '☑' : '☐'} $text',
      onPressed: () => checked ? _undo(text, line) : _markDone(text, line),
      color: checked ? theme.successColor : baseColor,
      hoverColor: theme.accent,
      bgColor: theme.surface,
      hoverBgColor: theme.buttonBackgroundHover,
      padding: const EdgeInsets.symmetric(horizontal: 1),
    );
  }
}
