/// GitHub-style task-list parser for the "my notes" feature.
///
/// Extracts `- [ ]` / `- [x]` checkbox items from a markdown document
/// so the sidebar widget can show how many open todos remain (and the
/// first few of them) without rendering the whole note.
///
/// This is intentionally a small, pure, line-based scanner rather than
/// a full markdown AST walk: the note is user-authored prose, and the
/// checkbox syntax we care about is line-oriented. Recognised forms
/// (matching GitHub's task lists):
///
///   - [ ] open item
///   - [x] done item        (any of x / X)
///   * [ ] also open
///   + [ ] also open
///     - [ ] indented open  (any leading whitespace)
///   1. [ ] ordered open
///
/// The check is case-insensitive on the marker (`x`/`X`) and tolerant
/// of extra spaces inside the brackets. Items inside fenced code
/// blocks are NOT treated as todos — a ``` fence toggles "in code"
/// mode and lines there are skipped, so documentation / examples in
/// the note don't inflate the count.
library;

/// One parsed task-list item.
class TodoItem {
  /// The item text after the `- [ ]` marker, trimmed.
  final String text;

  /// Whether the checkbox is checked (`- [x]`).
  final bool done;

  /// 0-based source line index, for stable ordering / debugging.
  final int lineIndex;

  const TodoItem({
    required this.text,
    required this.done,
    required this.lineIndex,
  });

  @override
  String toString() =>
      'TodoItem(${done ? 'x' : ' '}, line $lineIndex: $text)';
}

/// Summary of the todos in a markdown document.
class TodoSummary {
  /// All parsed items, in document order (open + done).
  final List<TodoItem> items;

  const TodoSummary(this.items);

  /// Items still to do (`- [ ]`), in document order.
  List<TodoItem> get open =>
      items.where((i) => !i.done).toList(growable: false);

  /// Items already done (`- [x]`), in document order.
  List<TodoItem> get done =>
      items.where((i) => i.done).toList(growable: false);

  int get openCount => open.length;
  int get totalCount => items.length;
  bool get isEmpty => items.isEmpty;
}

/// Matches a task-list marker at the start of a (possibly indented)
/// list item. Captures the checkbox state and the trailing text.
///
///   group 1 → the checkbox contents (` `, `x`, `X`, …)
///   group 2 → the item text after `]`
final RegExp _todoLine = RegExp(
  r'^\s*(?:[-*+]|\d+[.)])\s+\[([ xX]?)\]\s+(.*)$',
);

/// Matches a fenced-code-block delimiter (``` or ~~~, optionally with
/// an info string) and captures the fence marker so open/close pairs of
/// the SAME style toggle correctly (a `~~~` line must not close a
/// ``` fence — CommonMark requires matching markers).
final RegExp _fence = RegExp(r'^\s*(```+|~~~+)');

/// Parse [markdown] into a [TodoSummary]. Never throws — malformed
/// lines are simply not todos.
TodoSummary parseTodos(String markdown) {
  final items = <TodoItem>[];
  // The marker (` ``` ` or `~~~`) of the fence currently open, or null
  // when outside a code block. A fence closes only on the same marker.
  String? openFence;
  final lines = markdown.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final fenceMatch = _fence.firstMatch(line);
    if (openFence != null) {
      // Inside a fence: only a matching marker closes it.
      if (fenceMatch != null && fenceMatch.group(1)![0] == openFence) {
        openFence = null;
      }
      continue;
    }
    if (fenceMatch != null) {
      openFence = fenceMatch.group(1)![0]; // '`' or '~'
      continue;
    }
    final m = _todoLine.firstMatch(line);
    if (m == null) continue;
    final marker = m.group(1) ?? ' ';
    final text = (m.group(2) ?? '').trim();
    items.add(
      TodoItem(
        text: text,
        done: marker.toLowerCase() == 'x',
        lineIndex: i,
      ),
    );
  }
  return TodoSummary(items);
}
