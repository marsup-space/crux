import 'package:crux/src/components/annotated_scrollbar.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  test('thumb is at least two lines tall for long content', () async {
    await testNocterm('annotated scrollbar minimum thumb height', (
      tester,
    ) async {
      final controller = ScrollController();

      await tester.pumpComponent(
        Container(
          width: 20,
          height: 10,
          child: AnnotatedScrollbar(
            controller: controller,
            thumbVisibility: true,
            child: ListView.builder(
              controller: controller,
              itemCount: 100,
              itemBuilder: (context, index) => Text('Line $index'),
            ),
          ),
        ),
      );

      final thumbCells = [
        for (var y = 0; y < 10; y++)
          if (tester.terminalState.getCellAt(19, y)?.char == '█') y,
      ];

      expect(thumbCells, hasLength(2));
    }, size: const Size(20, 10));
  });
}
