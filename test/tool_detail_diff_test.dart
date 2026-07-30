import 'package:crux/src/components/tool_detail_utils.dart';
import 'package:test/test.dart';

void main() {
  group('computeLineDiff', () {
    test('identical inputs collapse to a gap marker', () {
      final lines = computeLineDiff(
        'a\nb\nc\nd\ne\nf\ng',
        'a\nb\nc\nd\ne\nf\ng',
      );
      // 7 identical lines > 2*2+1 → 2 head + gap(3) + 2 tail.
      expect(lines.where((l) => l.kind == DiffLineKind.gap), hasLength(1));
      expect(
        lines.firstWhere((l) => l.kind == DiffLineKind.gap).elidedCount,
        3,
      );
      expect(lines.where((l) => l.kind == DiffLineKind.context), hasLength(4));
    });

    test('small identical input stays as context', () {
      final lines = computeLineDiff('a\nb', 'a\nb');
      expect(lines, hasLength(2));
      expect(lines.every((l) => l.kind == DiffLineKind.context), isTrue);
    });

    test('pure insertion renders added lines with context', () {
      final lines = computeLineDiff('a\nb', 'a\nx\nb');
      expect(lines.map((l) => l.kind), [
        DiffLineKind.context,
        DiffLineKind.added,
        DiffLineKind.context,
      ]);
      expect(lines[1].text, 'x');
    });

    test('pure deletion renders removed lines with context', () {
      final lines = computeLineDiff('a\nx\nb', 'a\nb');
      expect(lines.map((l) => l.kind), [
        DiffLineKind.context,
        DiffLineKind.removed,
        DiffLineKind.context,
      ]);
      expect(lines[1].text, 'x');
    });

    test('replacement renders removed before added', () {
      final lines = computeLineDiff('old', 'new');
      expect(lines.map((l) => l.kind), [
        DiffLineKind.removed,
        DiffLineKind.added,
      ]);
      expect(lines[0].text, 'old');
      expect(lines[1].text, 'new');
    });

    test('empty old string diffs as all-added', () {
      final lines = computeLineDiff('', 'a\nb');
      expect(lines, hasLength(2));
      expect(lines.every((l) => l.kind == DiffLineKind.added), isTrue);
    });

    test('empty new string diffs as all-removed', () {
      final lines = computeLineDiff('a\nb', '');
      expect(lines, hasLength(2));
      expect(lines.every((l) => l.kind == DiffLineKind.removed), isTrue);
    });

    test('both empty produces no rows', () {
      expect(computeLineDiff('', ''), isEmpty);
    });

    test('trailing newline does not create a phantom line', () {
      final lines = computeLineDiff('a\n', 'a\nb\n');
      expect(lines.map((l) => l.kind), [
        DiffLineKind.context,
        DiffLineKind.added,
      ]);
    });

    test('long unchanged run between hunks collapses to one gap', () {
      final oldText = [
        'change1',
        ...List.filled(20, 'same'),
        'change2',
      ].join('\n');
      final newText = [
        'CHANGED1',
        ...List.filled(20, 'same'),
        'CHANGED2',
      ].join('\n');
      final lines = computeLineDiff(oldText, newText);

      final gaps = lines.where((l) => l.kind == DiffLineKind.gap).toList();
      expect(gaps, hasLength(1));
      expect(gaps.single.elidedCount, 16); // 20 - 2*2 context lines

      // Both hunks survive around the collapsed middle.
      expect(
        lines.where((l) => l.kind == DiffLineKind.removed).map((l) => l.text),
        ['change1', 'change2'],
      );
      expect(
        lines.where((l) => l.kind == DiffLineKind.added).map((l) => l.text),
        ['CHANGED1', 'CHANGED2'],
      );
    });

    test('contextLines parameter controls the collapse threshold', () {
      final text = List.filled(6, 'x').join('\n');
      // 6 > 2*1+1 → collapse with contextLines: 1.
      final collapsed = computeLineDiff(text, text, contextLines: 1);
      expect(
        collapsed.where((l) => l.kind == DiffLineKind.gap).single.elidedCount,
        4,
      );
      // 6 <= 2*4+1 → no collapse with contextLines: 4.
      final expanded = computeLineDiff(text, text, contextLines: 4);
      expect(expanded.where((l) => l.kind == DiffLineKind.gap), isEmpty);
    });
  });
}
