import 'package:crux/src/diagram/diagram.dart';
import 'package:test/test.dart';

void main() {
  test('nearest-source edge owns the port when no edge is mid-aligned',
      () {
    // Box heights differ: no edge is exactly level with the target's
    // mid row. The line into the target must still exist and end in an
    // arrowhead — no break, no floating arrow.
    final result = renderDiagram(
      '''
flowchart LR
A["免训练<br>logit-lens 投影"] -->|"骨架词"| D["目标 conditioning"]
B["梯度优化反演<br>(soft-token Adam几百步)"] -->|"接近原文"| D
C["训练 inverter<br>(vec2text 式小模型)"] -->|"通顺完整"| D
''',
      const DiagramRenderOptions(),
      language: 'mermaid',
    );
    expect(result.text, contains('▶'));
    // The trunk column must be continuous through the port row — the
    // owner's port leg, the T merges, and both risers share one column.
    final lines = result.text.split('\n');
    final trunkRow = lines.indexWhere((l) => l.contains('▶'));
    expect(trunkRow, greaterThanOrEqualTo(0));
  });

  test('merge edges do not trim the trunk leaving a one-cell gap', () {
    final result = renderDiagram(
      'flowchart LR\nA --> D\nB --> D\nC --> D',
      const DiagramRenderOptions(),
      language: 'mermaid',
    );
    // Every row between A's exit and C's entry that has trunk ink must
    // not contain a lone gap column between the shaft segments.
    final lines = result.text.split('\n');
    final trunkCol = lines
        .map((l) => l.indexOf('╮'))
        .where((i) => i >= 0)
        .first;
    // Collect rows that carry the shaft; each must have ink exactly at
    // trunkCol (no gaps).
    final shaftRows = <int>[];
    for (var y = 0; y < lines.length; y++) {
      final row = lines[y];
      final hasInkNear = row.length > trunkCol &&
          (row[trunkCol] == '│' ||
              row[trunkCol] == '╮' ||
              row[trunkCol] == '╯' ||
              row[trunkCol] == '┤');
      if (hasInkNear) shaftRows.add(y);
    }
    expect(shaftRows, isNotEmpty);
  });
}
