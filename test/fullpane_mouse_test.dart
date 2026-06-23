import 'package:crux/src/components/ui/fullpane.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

void main() {
  test(
    'closing fullpane restores mouse events to underlying content',
    () async {
      await testNocterm('fullpane close releases mouse state', (tester) async {
        var hovers = 0;
        var taps = 0;

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: _FullpaneMouseHarness(
              onHover: () => hovers++,
              onTap: () => taps++,
            ),
          ),
        );

        final close = tester.terminalState.findText('close').single;
        await tester.tap(close.x, close.y);
        expect(tester.terminalState.containsText('close'), isFalse);

        final target = tester.terminalState.findText('target').single;
        await tester.hover(target.x, target.y);
        await tester.tap(target.x, target.y);

        expect(hovers, greaterThan(0));
        expect(taps, 1);
      }, size: const Size(80, 20));
    },
  );
}

class _FullpaneMouseHarness extends StatefulComponent {
  const _FullpaneMouseHarness({required this.onHover, required this.onTap});

  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  State<_FullpaneMouseHarness> createState() => _FullpaneMouseHarnessState();
}

class _FullpaneMouseHarnessState extends State<_FullpaneMouseHarness> {
  bool _showFullpane = true;

  @override
  Component build(BuildContext context) {
    final body = MouseRegion(
      onHover: (_) => component.onHover(),
      child: GestureDetector(
        onTap: component.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(width: 20, height: 3, child: const Text('target')),
      ),
    );

    if (!_showFullpane) return body;

    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned.fill(
          child: Fullpane(
            title: 'Details',
            onClose: () => setState(() => _showFullpane = false),
            contentBuilder: (_) => const Text('modal content'),
          ),
        ),
      ],
    );
  }
}
