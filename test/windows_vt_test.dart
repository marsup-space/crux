import 'package:crux/src/utils/windows_vt.dart';
import 'package:test/test.dart';

void main() {
  test('Windows VT output mode enables delayed full-width row wrapping', () {
    expect(windowsVtOutputMode(0), equals(0x0001 | 0x0004 | 0x0008));
  });

  test('Windows VT output mode preserves existing console flags', () {
    const existingMode = 0x0010 | 0x0020;
    expect(
      windowsVtOutputMode(existingMode),
      equals(existingMode | 0x0001 | 0x0004 | 0x0008),
    );
  });
}
