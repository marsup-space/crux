import 'package:crux/src/components/codex_login_fullpane.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/nocterm_test.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Codex login fullpane keeps the device code and steps visible',
    () async {
      var closed = false;
      await testNocterm('codex login fullpane', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 100,
            height: 30,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: CodexLoginFullpane(
                userCode: 'ABC123',
                verificationUrl: 'https://auth.openai.com/codex/device',
                onOpenBrowser: () {},
                onClose: () => closed = true,
              ),
            ),
          ),
        );

        expect(tester.terminalState, containsText('ABC123'));
        expect(
          tester.terminalState,
          containsText('Waiting for ChatGPT approval'),
        );
        expect(tester.terminalState, containsText('Open browser again'));

        await tester.sendEscape();
        expect(closed, isTrue);
      });
    },
  );
}
