import 'package:crux/src/components/version_badge.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  group('VersionBadge', () {
    test('renders top-right with jit suffix without shifting layout', () async {
      await testNocterm('badge', (tester) async {
        // `dart test` runs on the JIT VM, so the badge must carry the
        // ` jit` suffix here.
        expect(kIsJit, isTrue);

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: VersionBadge(
                child: const Text('CHILD', textAlign: TextAlign.left),
              ),
            ),
          ),
        );

        print(tester.renderToString());

        // Badge is visible, with jit suffix under the test runner.
        expect(tester.terminalState, containsText('v0.22.0 jit'));

        // Right-aligned on the top row.
        final matches = tester.terminalState.findText('v0.22.0 jit');
        expect(matches, hasLength(1));
        expect(matches.first.y, 0);

        // Child still gets row 0 at the left edge — layout unaffected.
        final childMatch = tester.terminalState.findText('CHILD');
        expect(childMatch, hasLength(1));
        expect(childMatch.first.y, 0);
        expect(childMatch.first.x, 0);
      });
    });
  });
}
