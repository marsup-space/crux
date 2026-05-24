/// A cell in a keyboard-focus navigation grid.
///
/// Each cell maps a focus-area enum value to its visual (row, col) position.
/// Together, cells define a 2D layout that [FocusGrid] uses to translate
/// arrow keys into focus movements between interactive elements.
class FocusCell<T extends Enum> {
  final T id;
  final int row;
  final int col;

  const FocusCell(this.id, {required this.row, required this.col});
}

/// A 2D grid-based keyboard focus navigator.
///
/// Maps focusable areas to (row, col) positions, enabling independent
/// arrow-key navigation:
///
/// - **Up/Down**: moves between rows, preferring the same column.
///   Falls back to the nearest column in an adjacent row if the exact
///   column is empty at the target row.
/// - **Left/Right**: moves between columns within the same row.
///   Wraps around when reaching the edge of the row.
/// - **Tab/Shift+Tab**: linearly forward/backward through all cells
///   in their definition order.
///
/// Usage:
/// ```dart
/// final grid = FocusGrid<_MyArea>(
///   cells: const [
///     FocusCell(_MyArea.urlInput, row: 0, col: 0),
///     FocusCell(_MyArea.resetBtn, row: 0, col: 1),
///     FocusCell(_MyArea.apiKeyInput, row: 1, col: 0),
///     FocusCell(_MyArea.showKeyBtn, row: 1, col: 1),
///     FocusCell(_MyArea.nameInput, row: 2, col: 0),
///   ],
///   initial: _MyArea.urlInput,
/// );
///
/// grid.moveDown();  // urlInput → apiKeyInput
/// grid.moveRight(); // apiKeyInput → showKeyBtn (currently at apiKeyInput)
/// ```
///
/// Footer buttons (Back, Next, Cancel) are NOT part of the grid —
/// they live in a separate [Focusable] managed by [WizardOverlay].
/// Tab traverses from the last grid cell into the footer; Shift+Tab
/// returns from the footer to the first grid cell.
class FocusGrid<T extends Enum> {
  final List<FocusCell<T>> _cells;
  T _current;

  FocusGrid({
    required List<FocusCell<T>> cells,
    required T initial,
  }) : _cells = List.unmodifiable(cells),
       _current = initial;

  T get current => _current;

  FocusCell<T> _cellFor(T id) =>
      _cells.firstWhere((c) => c.id == id);

  void moveTo(T id) => _current = id;

  /// Move up: prefer same column, else nearest column in a row above.
  void moveUp() {
    final cur = _cellFor(_current);
    FocusCell<T>? best;
    int bestScore = 99999;
    for (final cell in _cells) {
      if (cell.id == _current) continue;
      if (cell.row >= cur.row) continue;
      final colDist = (cell.col - cur.col).abs();
      final rowDist = cur.row - cell.row;
      final score = rowDist * 100 + colDist * 10 + (cell.col == cur.col ? 0 : 1);
      if (best == null || score < bestScore) {
        best = cell;
        bestScore = score;
      }
    }
    if (best != null) _current = best.id;
  }

  /// Move down: prefer same column, else nearest column in a row below.
  void moveDown() {
    final cur = _cellFor(_current);
    FocusCell<T>? best;
    int bestScore = 99999;
    for (final cell in _cells) {
      if (cell.id == _current) continue;
      if (cell.row <= cur.row) continue;
      final colDist = (cell.col - cur.col).abs();
      final rowDist = cell.row - cur.row;
      final score = rowDist * 100 + colDist * 10 + (cell.col == cur.col ? 0 : 1);
      if (best == null || score < bestScore) {
        best = cell;
        bestScore = score;
      }
    }
    if (best != null) _current = best.id;
  }

  /// Move left: previous column in same row, wraps to rightmost.
  void moveLeft() {
    final cur = _cellFor(_current);
    FocusCell<T>? best;
    // Find the nearest cell to the left
    int bestDist = 99999;
    for (final cell in _cells) {
      if (cell.id == _current) continue;
      if (cell.row != cur.row) continue;
      if (cell.col < cur.col) {
        final dist = cur.col - cell.col;
        if (dist < bestDist) {
          best = cell;
          bestDist = dist;
        }
      }
    }
    if (best == null) {
      // Wrap: find rightmost cell in the same row
      for (final cell in _cells) {
        if (cell.id == _current) continue;
        if (cell.row != cur.row) continue;
        if (cell.col > cur.col) {
          if (best == null || cell.col > best.col) best = cell;
        }
      }
    }
    if (best != null) _current = best.id;
  }

  /// Move right: next column in same row, wraps to leftmost.
  void moveRight() {
    final cur = _cellFor(_current);
    FocusCell<T>? best;
    int bestDist = 99999;
    for (final cell in _cells) {
      if (cell.id == _current) continue;
      if (cell.row != cur.row) continue;
      if (cell.col > cur.col) {
        final dist = cell.col - cur.col;
        if (dist < bestDist) {
          best = cell;
          bestDist = dist;
        }
      }
    }
    if (best == null) {
      // Wrap: find leftmost cell in the same row
      for (final cell in _cells) {
        if (cell.id == _current) continue;
        if (cell.row != cur.row) continue;
        if (cell.col < cur.col) {
          if (best == null || cell.col < best.col) best = cell;
        }
      }
    }
    if (best != null) _current = best.id;
  }
}
