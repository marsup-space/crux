import 'package:crux/src/components/tool_guard_bubble.dart';
import 'package:test/test.dart';

void main() {
  group('ToolGuardBubble', () {
    test('autoRead body is "guard: auto-read: <path>"', () {
      const bubble = ToolGuardBubble(
        guardKind: ToolGuardKind.autoRead,
        filePath: 'foo.dart',
      );
      expect(bubble.body, 'guard: auto-read: foo.dart');
      expect(bubble.kind.name, 'warning');
    });

    test('readBeforeWrite body is "guard: read-before-write: <path>"', () {
      const bubble = ToolGuardBubble(
        guardKind: ToolGuardKind.readBeforeWrite,
        filePath: 'src/main.dart',
      );
      expect(bubble.body, 'guard: read-before-write: src/main.dart');
    });

    test('sizeMismatch body uses "refused" wording', () {
      const bubble = ToolGuardBubble(
        guardKind: ToolGuardKind.sizeMismatch,
        filePath: 'huge.dart',
      );
      expect(bubble.body, 'guard: refused: use edit or pass force: huge.dart');
    });

    test('streamingAbort body is a guard hint', () {
      const bubble = ToolGuardBubble(
        guardKind: ToolGuardKind.streamingAbort,
        filePath: 'lib/a.dart',
      );
      expect(bubble.body, 'guard: streaming abort: lib/a.dart');
    });

    test('omits the trailing ": <path>" when no path supplied', () {
      const bubble = ToolGuardBubble(guardKind: ToolGuardKind.autoRead);
      expect(bubble.body, 'guard: auto-read');
    });

    test('ToolGuardKind.values order matches parallelCount encoding', () {
      // The kind is encoded as parallelCount.index. Changing the
      // order would change every persisted message; this test
      // makes that drift obvious.
      expect(ToolGuardKind.values.length, 4);
      expect(ToolGuardKind.autoRead.index, 0);
      expect(ToolGuardKind.readBeforeWrite.index, 1);
      expect(ToolGuardKind.sizeMismatch.index, 2);
      expect(ToolGuardKind.streamingAbort.index, 3);
    });
  });
}
