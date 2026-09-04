import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/surface_host.dart';
import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/services/a2ui/surface_builder.dart';
import 'package:crux/src/services/a2ui/models.dart';
import 'package:crux/src/theme/crux_theme.dart';

void main() {
  group('SurfaceBuilder', () {
    test('builds the same valid adjacency-list declaration as tool JSON', () {
      final surface = SurfaceBuilder(surfaceId: 'home.workspace')
        ..column('root', ['dir', 'branch'])
        ..keyValue('dir', label: 'dir', value: 'crux')
        ..keyValue('branch', label: 'branch', value: 'feature/genui');

      final declaration = surface.build();
      expect(declaration.root!.id, 'root');
      expect(declaration.components, hasLength(3));
      expect(createBasicCatalog().validate(declaration), isEmpty);
    });
  });

  group('SurfaceHost', () {
    test('centers a bounded standalone surface', () async {
      await testNocterm('surface host max width', (tester) async {
        final declaration =
            (SurfaceBuilder(surfaceId: 'sample.bounded')
                  ..column('root', ['fact'])
                  ..keyValue('fact', label: 'project', value: 'crux'))
                .build();
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: SurfaceHost(
                declaration: declaration,
                catalog: createBasicCatalog(),
                instanceKey: 'sample.bounded',
                retainState: false,
                maxWidth: 40,
              ),
            ),
          ),
        );
        final project = tester.terminalState.findText('project');
        expect(project, isNotEmpty);
        expect(project.first.x, greaterThanOrEqualTo(20));
      }, size: const Size(80, 8));
    });

    test('renders an app-owned KeyValue surface', () async {
      await testNocterm('surface host facts', (tester) async {
        final declaration =
            (SurfaceBuilder(surfaceId: 'sample.facts')
                  ..column('root', ['project', 'branch'])
                  ..keyValue('project', label: 'project', value: 'crux')
                  ..keyValue('branch', label: 'branch', value: 'feature/genui'))
                .build();
        await tester.pumpComponent(
          Container(
            width: 60,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: SurfaceHost(
                declaration: declaration,
                catalog: createBasicCatalog(),
                instanceKey: 'sample.facts',
                retainState: false,
                submitOnAction: false,
              ),
            ),
          ),
        );

        expect(tester.terminalState, containsText('project  crux'));
        expect(tester.terminalState, containsText('branch  feature/genui'));
      });
    });

    test('dashboard actions do not submit or freeze the surface', () async {
      await testNocterm('surface host repeat action', (tester) async {
        final declaration = CreateSurface(
          surfaceId: 'sample.action',
          catalogId: 'crux/1.0/chat',
          components: const [
            A2uiComponent(
              id: 'root',
              component: 'Button',
              properties: {
                'child': 'label',
                'action': {
                  'event': {'name': 'open_settings'},
                },
              },
            ),
            A2uiComponent(
              id: 'label',
              component: 'Text',
              properties: {'text': 'Open settings'},
            ),
          ],
        );
        var actions = 0;
        final catalog = createBasicCatalog();
        await tester.pumpComponent(
          Container(
            width: 60,
            height: 8,
            child: CruxTheme(
              data: CruxThemeData.draculaFallback,
              child: SurfaceHost(
                declaration: declaration,
                catalog: catalog,
                instanceKey: 'sample.action',
                submitOnAction: false,
                onAction: (_) => actions++,
              ),
            ),
          ),
        );

        await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.tab));
        await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.enter));
        await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.enter));

        expect(actions, 2);
        expect(catalog.instanceById('sample.action')!.submitted, isFalse);
      });
    });
  });
}
