import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/surface_host.dart';
import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/services/a2ui/models.dart';
import 'package:crux/src/theme/crux_theme.dart';

void main() {
  final declaration = CreateSurface(
    surfaceId: 'primitives',
    catalogId: 'crux/1.0/chat',
    dataModel: const {'enabled': false},
    components: const [
      A2uiComponent(
        id: 'root',
        component: 'Column',
        properties: {
          'children': ['section', 'item', 'bars', 'toggle'],
        },
      ),
      A2uiComponent(
        id: 'section',
        component: 'Section',
        properties: {'title': 'Summary', 'child': 'row'},
      ),
      A2uiComponent(
        id: 'row',
        component: 'Row',
        properties: {
          'gap': 2,
          'children': ['stat', 'badge'],
        },
      ),
      A2uiComponent(
        id: 'stat',
        component: 'Stat',
        properties: {'value': '2871', 'label': 'tests'},
      ),
      A2uiComponent(
        id: 'badge',
        component: 'Badge',
        properties: {'text': 'passing', 'tone': 'success'},
      ),
      A2uiComponent(
        id: 'item',
        component: 'ListItem',
        properties: {
          'title': 'Plugin adapter',
          'leading': '›',
          'detail': 'next slice',
          'badge': 'next',
          'selected': true,
        },
      ),
      A2uiComponent(
        id: 'bars',
        component: 'BarList',
        properties: {
          'rows': [
            {'label': 'gpt-5.6', 'value': 0.72, 'detail': '72k'},
            {'label': 'luna', 'value': 0.34, 'detail': '34k'},
          ],
        },
      ),
      A2uiComponent(
        id: 'toggle',
        component: 'Toggle',
        properties: {
          'label': 'Enable previews',
          'value': {'path': '/enabled'},
        },
      ),
    ],
  );

  test('new primitives are registered and validate together', () {
    final catalog = createBasicCatalog();
    for (final type in [
      'Section',
      'Badge',
      'Stat',
      'ListItem',
      'BarList',
      'Toggle',
    ]) {
      expect(catalog.lookup(type), isNotNull);
    }
    expect(catalog.validate(declaration), isEmpty);
  });

  test('ListItem dispatches its declared action on mouse click', () async {
    final actions = <A2uiAction>[];
    final clickable = CreateSurface(
      surfaceId: 'clickable-list-item',
      catalogId: 'crux/1.0/chat',
      components: const [
        A2uiComponent(
          id: 'root',
          component: 'ListItem',
          properties: {
            'title': 'Open session',
            'inline': true,
            'action': {
              'event': {
                'name': 'open_session',
                'context': {'sessionId': 7},
              },
            },
          },
        ),
      ],
    );

    await testNocterm('clickable list item', (tester) async {
      final catalog = createBasicCatalog();
      await tester.pumpComponent(
        Container(
          width: 40,
          height: 4,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceHost(
              declaration: clickable,
              catalog: catalog,
              instanceKey: 'clickable-list-item',
              submitOnAction: false,
              onAction: actions.add,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(2, 0);
      await tester.pump();

      expect(actions, hasLength(1));
      expect(actions.single.name, 'open_session');
      expect(actions.single.context, {'sessionId': 7});
    }, size: const Size(40, 4));
  });

  test('Toggle updates the data model through keyboard activation', () async {
    await testNocterm('surface primitive toggle', (tester) async {
      final catalog = createBasicCatalog();
      await tester.pumpComponent(
        Container(
          width: 80,
          height: 24,
          child: CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceHost(
              declaration: declaration,
              catalog: catalog,
              instanceKey: 'primitives',
              submitOnAction: false,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.terminalState, containsText('passing'));
      expect(tester.terminalState, containsText('Plugin adapter'));
      expect(tester.terminalState, containsText('›'));
      expect(tester.terminalState, containsText('gpt-5.6'));

      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.tab));
      await tester.sendKeyEvent(KeyboardEvent(logicalKey: LogicalKey.enter));
      expect(
        catalog.instanceById('primitives')!.readDataModel('/enabled'),
        isTrue,
      );
      expect(tester.terminalState, containsText(' ON '));
    }, size: const Size(80, 24));
  });
}
