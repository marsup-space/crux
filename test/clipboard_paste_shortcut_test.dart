import 'package:crux/src/components/input_keys.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  group('clipboard image paste shortcut', () {
    test('accepts Ctrl+V, Ctrl+Shift+V, and macOS-style Meta+V', () {
      expect(
        isClipboardPasteShortcut(
          const KeyboardEvent(
            logicalKey: LogicalKey.keyV,
            modifiers: ModifierKeys(ctrl: true),
          ),
        ),
        isTrue,
      );
      expect(
        isClipboardPasteShortcut(
          const KeyboardEvent(
            logicalKey: LogicalKey.keyV,
            modifiers: ModifierKeys(ctrl: true, shift: true),
          ),
        ),
        isTrue,
      );
      expect(
        isClipboardPasteShortcut(
          const KeyboardEvent(
            logicalKey: LogicalKey.keyV,
            modifiers: ModifierKeys(meta: true),
          ),
        ),
        isTrue,
      );
    });

    test('rejects Alt-modified or unrelated chords', () {
      expect(
        isClipboardPasteShortcut(
          const KeyboardEvent(
            logicalKey: LogicalKey.keyV,
            modifiers: ModifierKeys(ctrl: true, alt: true),
          ),
        ),
        isFalse,
      );
      expect(
        isClipboardPasteShortcut(
          const KeyboardEvent(
            logicalKey: LogicalKey.keyV,
            modifiers: ModifierKeys(ctrl: true, meta: true),
          ),
        ),
        isFalse,
      );
      expect(
        isClipboardPasteShortcut(
          const KeyboardEvent(
            logicalKey: LogicalKey.keyC,
            modifiers: ModifierKeys(ctrl: true),
          ),
        ),
        isFalse,
      );
    });
  });
}
