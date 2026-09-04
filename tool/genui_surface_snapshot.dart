/// Print the standalone GenUI sample as a deterministic terminal snapshot.
///
/// Run: dart test tool/genui_surface_snapshot.dart
library;

import 'package:crux/src/components/surface_host.dart';
import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

import 'genui_surface_sample.dart' show sampleSurface;

void main() {
  test('standalone GenUI sample snapshot', () async {
    await testNocterm('standalone GenUI sample', (tester) async {
      await tester.pumpComponent(
        Container(
          width: 100,
          height: 24,
          padding: const EdgeInsets.all(1),
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceHost(
              declaration: sampleSurface,
              catalog: createBasicCatalog(),
              instanceKey: 'snapshot',
              retainState: false,
              submitOnAction: false,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.terminalState, containsText('Migration plan'));
      expect(tester.terminalState, containsText('Plugins  next'));
      expect(tester.terminalState, containsText('Open settings'));
      // This is intentionally printable: it is the exact layout artifact
      // attached to a review when native terminal screenshot access is absent.
      print(tester.renderToString(showBorders: true));
    }, size: const Size(100, 24));
  });
}
