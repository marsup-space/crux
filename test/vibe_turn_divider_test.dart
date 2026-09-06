import 'package:crux/src/components/compaction_divider.dart';
import 'package:crux/src/components/vibe_turn_divider.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  test('turn divider uses a continuous box-drawing rule', () async {
    await testNocterm('continuous turn divider', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 5,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: const VibeTurnDivider(sinceLastTurn: Duration(minutes: 3)),
          ),
        ),
      );

      expect(tester.terminalState, containsText('3 minutes ago'));
      expect(tester.terminalState, containsText('────'));
      expect(tester.terminalState.containsText('----'), isFalse);
    }, size: const Size(80, 5));
  });

  test('compaction divider matches the continuous time-divider rule', () async {
    await testNocterm('continuous compaction divider', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 5,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: const CompactionDivider(),
          ),
        ),
      );

      expect(tester.terminalState, containsText('Compaction'));
      expect(tester.terminalState, containsText('────'));
      expect(tester.terminalState.containsText('----'), isFalse);
    }, size: const Size(80, 5));
  });
}
