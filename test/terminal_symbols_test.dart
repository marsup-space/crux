import 'package:crux/src/utils/terminal_symbols.dart';
import 'package:test/test.dart';

void main() {
  test('non-Windows platforms keep rich symbols', () {
    expect(
      supportsRichTerminalSymbols(environment: const {}, isWindows: false),
      isTrue,
    );
  });

  test('bare Windows console uses ASCII-safe symbols', () {
    expect(
      supportsRichTerminalSymbols(environment: const {}, isWindows: true),
      isFalse,
    );
  });

  test('Windows Terminal keeps rich symbols', () {
    expect(
      supportsRichTerminalSymbols(
        environment: const {'WT_SESSION': 'session-id'},
        isWindows: true,
      ),
      isTrue,
    );
  });

  test('xterm-like Windows hosts such as Tabby keep rich symbols', () {
    expect(
      supportsRichTerminalSymbols(
        environment: const {'TERM': 'xterm-256color'},
        isWindows: true,
      ),
      isTrue,
    );
  });

  test('ConEmu and ANSICON keep rich symbols', () {
    expect(
      supportsRichTerminalSymbols(
        environment: const {'ConEmuANSI': 'ON'},
        isWindows: true,
      ),
      isTrue,
    );
    expect(
      supportsRichTerminalSymbols(
        environment: const {'ANSICON': '189x1000'},
        isWindows: true,
      ),
      isTrue,
    );
  });
}
