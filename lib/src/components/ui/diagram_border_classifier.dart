import 'package:characters/characters.dart';
import 'package:nocterm/src/utils/unicode_width.dart';

/// Classifies diagram node and subgraph outlines in rendered character-grid art.
///
/// The renderer deliberately emits plain text, so the viewport cannot receive
/// draw provenance directly. This classifier recovers only outlines with a
/// complete multi-row shape: a horizontal cap plus its matching base and
/// paired walls. It intentionally does not classify isolated edge trunks or
/// elbows as borders, leaving those glyphs in the brighter edge color.
class DiagramBorderClassifier {
  const DiagramBorderClassifier._();

  /// Returns the grapheme indexes that belong to a diagram border for every
  /// line in [lines].
  static List<Set<int>> infer(List<String> lines) {
    final rows = [_forLines(lines)];
    final borders = List<Set<int>>.generate(lines.length, (_) => <int>{});
    final classifier = _BorderClassifier(rows.single, borders);
    classifier.markRectangles();
    classifier.markDiamonds();
    return borders;
  }

  static List<_GlyphRow> _forLines(List<String> lines) =>
      lines.map(_GlyphRow.new).toList(growable: false);
}

class _BorderClassifier {
  _BorderClassifier(this.rows, this.borders);

  final List<_GlyphRow> rows;
  final List<Set<int>> borders;

  /// Standard / rounded box outlines have matching horizontal caps and bases,
  /// with a wall at both cap coordinates on every interior row. An edge elbow
  /// such as `╭──╮` has no matching base and is therefore never classified.
  void markRectangles() {
    for (var topY = 0; topY < rows.length; topY++) {
      final top = rows[topY];
      for (final cap in top.caps(left: '┌', right: '┐')) {
        _markRectangle(topY, cap, '└', '┘');
      }
      for (final cap in top.caps(left: '╭', right: '╮')) {
        _markRectangle(topY, cap, '╰', '╯');
      }
    }
  }

  void _markRectangle(int topY, _Cap top, String bottomLeft, String bottomRight) {
    for (var bottomY = topY + 2; bottomY < rows.length; bottomY++) {
      final bottom = rows[bottomY];
      if (!bottom.hasAt(top.left, bottomLeft) ||
          !bottom.hasAt(top.right, bottomRight) ||
          !bottom.isHorizontalLine(top.left, top.right)) {
        continue;
      }
      if (!_hasWalls(topY, bottomY, top.left, top.right)) continue;
      _markHorizontal(topY, top.left, top.right);
      _markHorizontal(bottomY, top.left, top.right);
      for (var y = topY + 1; y < bottomY; y++) {
        _markAt(y, top.left);
        _markAt(y, top.right);
      }
      return;
    }
  }

  bool _hasWalls(int topY, int bottomY, int left, int right) {
    for (var y = topY + 1; y < bottomY; y++) {
      if (!rows[y].hasAt(left, '│') || !rows[y].hasAt(right, '│')) {
        return false;
      }
    }
    return true;
  }

  /// Decision boxes have inset `╭──╮` caps, sloped shoulder rows, and walls
  /// two columns outside the cap. Require the complete structure so a rounded
  /// edge elbow remains an edge stroke.
  void markDiamonds() {
    for (var topY = 0; topY + 4 < rows.length; topY++) {
      final top = rows[topY];
      for (final cap in top.caps(left: '╭', right: '╮')) {
        final leftWall = cap.left - 2;
        final rightWall = cap.right + 2;
        if (leftWall < 0 || !rows[topY + 1].hasAt(leftWall + 1, '╱') ||
            !rows[topY + 1].hasAt(rightWall - 1, '╲')) {
          continue;
        }
        for (var bottomY = topY + 4; bottomY < rows.length; bottomY++) {
          final bottom = rows[bottomY];
          if (!bottom.hasAt(cap.left, '╰') || !bottom.hasAt(cap.right, '╯') ||
              !bottom.isHorizontalLine(cap.left, cap.right) ||
              !rows[bottomY - 1].hasAt(leftWall + 1, '╲') ||
              !rows[bottomY - 1].hasAt(rightWall - 1, '╱') ||
              !_hasWalls(topY + 2, bottomY - 2, leftWall, rightWall)) {
            continue;
          }
          _markHorizontal(topY, cap.left, cap.right);
          _markHorizontal(bottomY, cap.left, cap.right);
          _markAt(topY + 1, leftWall + 1);
          _markAt(topY + 1, rightWall - 1);
          _markAt(bottomY - 1, leftWall + 1);
          _markAt(bottomY - 1, rightWall - 1);
          for (var y = topY + 2; y < bottomY - 1; y++) {
            _markAt(y, leftWall);
            _markAt(y, rightWall);
          }
          break;
        }
      }
    }
  }

  void _markHorizontal(int y, int left, int right) {
    for (final glyph in rows[y].glyphs) {
      if (glyph.column >= left && glyph.column <= right && glyph.text != ' ') {
        borders[y].add(glyph.index);
      }
    }
  }

  void _markAt(int y, int column) {
    final index = rows[y].indexAt(column);
    if (index != null) borders[y].add(index);
  }
}

class _GlyphRow {
  _GlyphRow(String line) : glyphs = _glyphs(line);

  final List<_PositionedGlyph> glyphs;

  bool hasAt(int column, String text) =>
      glyphs.any((glyph) => glyph.column == column && glyph.text == text);

  int? indexAt(int column) {
    for (final glyph in glyphs) {
      if (glyph.column == column) return glyph.index;
    }
    return null;
  }

  bool isHorizontalLine(int left, int right) {
    for (var column = left + 1; column < right; column++) {
      if (!hasAt(column, '─')) return false;
    }
    return true;
  }

  Iterable<_Cap> caps({required String left, required String right}) sync* {
    for (final start in glyphs.where((glyph) => glyph.text == left)) {
      for (final end in glyphs) {
        if (end.column <= start.column || end.text != right) continue;
        if (isHorizontalLine(start.column, end.column)) {
          yield _Cap(start.column, end.column);
          break;
        }
      }
    }
  }

  static List<_PositionedGlyph> _glyphs(String line) {
    var column = 0;
    var index = 0;
    final result = <_PositionedGlyph>[];
    for (final text in line.characters) {
      result.add(_PositionedGlyph(index++, column, text));
      column += UnicodeWidth.graphemeWidth(text);
    }
    return result;
  }
}

class _PositionedGlyph {
  const _PositionedGlyph(this.index, this.column, this.text);

  final int index;
  final int column;
  final String text;
}

class _Cap {
  const _Cap(this.left, this.right);

  final int left;
  final int right;
}
