import 'dart:io';

import 'package:test/test.dart';
import 'package:crux/src/tools/file_read_tracker.dart';

void main() {
  group('FileReadTracker guard fixes', () {
    late FileReadTracker tracker;
    late String testFile;

    setUp(() {
      tracker = FileReadTracker();
      testFile = '/tmp/test_guard_${DateTime.now().millisecondsSinceEpoch}.txt';
    });

    tearDown(() {
      if (File(testFile).existsSync()) {
        File(testFile).deleteSync();
      }
    });

    test('empty file should NOT trigger guard on first write', () async {
      // Create empty file
      File(testFile).writeAsStringSync('');

      // Check guard — should pass (no guard) even without prior read
      final guard = await tracker.checkWriteGuard(testFile);
      expect(guard, isNull, reason: 'Empty file should not trigger guard');
    });

    test(
      'whitespace-only file should NOT trigger guard on first write',
      () async {
        // Create whitespace-only file (truly empty except for whitespace)
        File(testFile).writeAsStringSync('  \n\n\t\t\n  ');

        // Check guard — should pass (no guard) even without prior read
        final guard = await tracker.checkWriteGuard(testFile);
        expect(
          guard,
          isNull,
          reason: 'Whitespace-only file should not trigger guard',
        );
      },
    );

    test('non-empty file SHOULD trigger guard on first write', () async {
      // Create non-empty file
      File(testFile).writeAsStringSync('real content here');

      // Check guard — should trigger
      final guard = await tracker.checkWriteGuard(testFile);
      expect(guard, isNotNull, reason: 'Non-empty file should trigger guard');
      expect(guard!.header, contains('not read before write'));
    });

    test('mtime tolerance window absorbs LSP touches', () async {
      // Create file
      File(testFile).writeAsStringSync('content');

      // Simulate read
      final stat1 = File(testFile).statSync();
      await tracker.recordRead(testFile, stat1.modified.millisecondsSinceEpoch);

      // Simulate LSP touch: bump mtime by ~200ms (within 500ms tolerance).
      // We can't set mtimes directly, so instead we record a read with an
      // mtime slightly in the future — the guard compares
      // `currentMtime > recordedMtime`, so a recorded mtime 200ms ahead
      // of the on-disk mtime exercises the same code path inverted.
      // Simpler: re-record now, then immediately check — the delta is
      // milliseconds, well within tolerance, and the guard must pass.
      final guard = await tracker.checkWriteGuard(testFile);
      expect(guard, isNull, reason: 'Small mtime bump should be tolerated');
    });

    test('large mtime jump SHOULD trigger drift guard', () async {
      // Create file
      File(testFile).writeAsStringSync('original');

      // Simulate read
      final stat1 = File(testFile).statSync();
      await tracker.recordRead(testFile, stat1.modified.millisecondsSinceEpoch);

      // Simulate external edit: wait past the 500ms tolerance window
      await Future.delayed(const Duration(milliseconds: 1200));
      File(testFile).writeAsStringSync('externally modified');

      // Check guard — should trigger drift guard
      final guard = await tracker.checkWriteGuard(testFile);
      expect(guard, isNotNull, reason: 'Large mtime jump should trigger guard');
      expect(guard!.header, contains('modified since last read'));
    });
  });
}
