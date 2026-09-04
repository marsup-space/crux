import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/surface_host.dart';
import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/theme/crux_theme.dart';

import '../tool/genui_surface_samples.dart';

void main() {
  final expectedText = <String, String>{
    'dashboard': 'Migration plan',
    'form': 'Release request',
    'progress': 'Agent work queue',
    'data': 'Component coverage',
  };

  for (final name in sampleNames) {
    test('$name sample is catalog-valid', () {
      expect(createBasicCatalog().validate(sampleFor(name)), isEmpty);
    });

    test('$name sample renders in a terminal', () async {
      await testNocterm('sample $name', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 100,
            height: 30,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: SurfaceHost(
                declaration: sampleFor(name),
                catalog: createBasicCatalog(),
                instanceKey: 'test.$name',
                retainState: false,
                submitOnAction: false,
                onAction: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.terminalState, containsText(expectedText[name]!));
      }, size: const Size(100, 30));
    });
  }
}
