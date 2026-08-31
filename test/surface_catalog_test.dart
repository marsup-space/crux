import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/services/a2ui/models.dart';
import 'package:crux/src/services/a2ui/surface_controller.dart';
import 'package:crux/src/theme/crux_theme.dart';

void main() {
  final catalog = createBasicCatalog();

  group('A2UI model parsing', () {
    test('parses a minimal createSurface', () {
      final json = {
        'surfaceId': 'test_1',
        'catalogId': 'crux/1.0/chat',
        'components': [
          {'id': 'root', 'component': 'Text', 'text': 'Hello'},
        ],
      };
      final surface = CreateSurface.fromJson(json);
      expect(surface, isNotNull);
      expect(surface!.surfaceId, 'test_1');
      expect(surface.catalogId, 'crux/1.0/chat');
      expect(surface.components.length, 1);
      expect(surface.root!.id, 'root');
      expect(surface.root!.component, 'Text');
    });

    test('parses components with adjacency list children', () {
      final json = {
        'surfaceId': 'test_2',
        'catalogId': 'crux/1.0/chat',
        'components': [
          {
            'id': 'root',
            'component': 'Column',
            'children': ['title', 'body'],
          },
          {'id': 'title', 'component': 'Text', 'text': 'Title'},
          {'id': 'body', 'component': 'Text', 'text': 'Body'},
        ],
      };
      final surface = CreateSurface.fromJson(json);
      expect(surface, isNotNull);
      expect(surface!.components.length, 3);
      expect(surface.root!.properties['children'], ['title', 'body']);
      expect(surface.componentById('title')!.component, 'Text');
      expect(surface.componentById('body')!.component, 'Text');
    });

    test('parses data model', () {
      final json = {
        'surfaceId': 'test_3',
        'catalogId': 'crux/1.0/chat',
        'components': [
          {'id': 'root', 'component': 'Text', 'text': 'Hello'},
        ],
        'dataModel': {'name': 'World', 'count': 42},
      };
      final surface = CreateSurface.fromJson(json);
      expect(surface, isNotNull);
      expect(surface!.dataModel['name'], 'World');
      expect(surface.dataModel['count'], 42);
    });

    test('returns null for missing surfaceId', () {
      final json = {
        'catalogId': 'crux/1.0/chat',
        'components': [],
      };
      expect(CreateSurface.fromJson(json), isNull);
    });

    test('returns null for missing catalogId', () {
      final json = {
        'surfaceId': 'test',
        'components': [],
      };
      expect(CreateSurface.fromJson(json), isNull);
    });
  });

  group('DataBinding', () {
    test('resolves a simple path', () {
      final binding = DataBinding('/name');
      expect(binding.resolve({'name': 'Alice'}), 'Alice');
    });

    test('resolves a nested path', () {
      final binding = DataBinding('/user/name');
      expect(
        binding.resolve({
          'user': {'name': 'Bob'},
        }),
        'Bob',
      );
    });

    test('returns null for missing path', () {
      final binding = DataBinding('/missing');
      expect(binding.resolve({}), isNull);
    });

    test('tryParse returns null for non-binding values', () {
      expect(DataBinding.tryParse('hello'), isNull);
      expect(DataBinding.tryParse(42), isNull);
      expect(DataBinding.tryParse(null), isNull);
      expect(DataBinding.tryParse({'foo': 'bar'}), isNull);
    });

    test('tryParse returns binding for path map', () {
      final binding = DataBinding.tryParse({'path': '/field'});
      expect(binding, isNotNull);
      expect(binding!.path, '/field');
    });
  });

  group('SurfaceInstance', () {
    test('initializes with declaration data model', () {
      final surface = CreateSurface(
        surfaceId: 'test',
        catalogId: 'crux/1.0/chat',
        components: [],
        dataModel: {'x': 1},
      );
      final instance = SurfaceInstance(declaration: surface);
      expect(instance.readDataModel('/x'), 1);
      expect(instance.submitted, isFalse);
    });

    test('updateDataModel writes a value', () {
      final surface = CreateSurface(
        surfaceId: 'test',
        catalogId: 'crux/1.0/chat',
        components: [],
      );
      final instance = SurfaceInstance(declaration: surface);
      instance.updateDataModel('/name', 'Alice');
      expect(instance.readDataModel('/name'), 'Alice');
    });

    test('updateDataModel creates nested paths', () {
      final surface = CreateSurface(
        surfaceId: 'test',
        catalogId: 'crux/1.0/chat',
        components: [],
      );
      final instance = SurfaceInstance(declaration: surface);
      instance.updateDataModel('/user/name', 'Bob');
      expect(instance.readDataModel('/user/name'), 'Bob');
    });
  });

  group('SurfaceInstance.updateComponents', () {
    CreateSurface tree() => CreateSurface(
          surfaceId: 'dyn',
          catalogId: 'crux/1.0/chat',
          components: [
            const A2uiComponent(
              id: 'root',
              component: 'Column',
              properties: {
                'children': ['title'],
              },
            ),
            const A2uiComponent(
              id: 'title',
              component: 'Text',
              properties: {'text': 'Title'},
            ),
          ],
        );

    test('appends new components and extends a container', () {
      final instance = SurfaceInstance(declaration: tree());
      final ok = instance.updateComponents(
        components: [
          const A2uiComponent(
            id: 'row1',
            component: 'Text',
            properties: {'text': 'Row 1'},
          ),
        ],
        extendContainerId: 'root',
      );
      expect(ok, isTrue);
      // New component is registered and wired into root.children.
      expect(instance.declaration.componentById('row1'), isNotNull);
      expect(
        instance.declaration.componentById('root')!.properties['children'],
        contains('row1'),
      );
    });

    test('replaces an existing component in place (no double append)', () {
      final instance = SurfaceInstance(declaration: tree());
      final ok = instance.updateComponents(
        components: [
          const A2uiComponent(
            id: 'title',
            component: 'Text',
            properties: {'text': 'Replaced'},
          ),
        ],
        extendContainerId: 'root',
      );
      expect(ok, isTrue);
      // children must NOT gain a duplicate 'title'.
      final children =
          instance.declaration.componentById('root')!.properties['children']
              as List;
      expect(children.where((c) => c == 'title').length, 1);
      expect(
        instance.declaration.componentById('title')!.properties['text'],
        'Replaced',
      );
    });

    test('rejects structural updates on a submitted surface', () {
      final instance = SurfaceInstance(declaration: tree());
      instance.markSubmitted();
      final ok = instance.updateComponents(
        components: [
          const A2uiComponent(id: 'x', component: 'Text'),
        ],
      );
      expect(ok, isFalse);
      expect(instance.declaration.componentById('x'), isNull);
    });
  });

  group('SurfaceCatalog validation', () {
    test('accepts a valid surface', () {
      final surface = CreateSurface(
        surfaceId: 'test',
        catalogId: 'crux/1.0/chat',
        components: [
          const A2uiComponent(
            id: 'root',
            component: 'Column',
            properties: {
              'children': ['title'],
            },
          ),
          const A2uiComponent(
            id: 'title',
            component: 'Text',
            properties: {'text': 'Hello'},
          ),
        ],
      );
      final errors = catalog.validate(surface);
      expect(errors, isEmpty);
    });

    test('rejects unknown component type', () {
      final surface = CreateSurface(
        surfaceId: 'test',
        catalogId: 'crux/1.0/chat',
        components: [
          const A2uiComponent(
            id: 'root',
            component: 'UnknownWidget',
          ),
        ],
      );
      final errors = catalog.validate(surface);
      expect(errors, isNotEmpty);
      expect(errors.any((e) => e.contains('unknown component type')), isTrue);
    });

    test('rejects catalogId mismatch', () {
      final surface = CreateSurface(
        surfaceId: 'test',
        catalogId: 'wrong/1.0',
        components: [
          const A2uiComponent(id: 'root', component: 'Text'),
        ],
      );
      final errors = catalog.validate(surface);
      expect(errors.any((e) => e.contains('catalogId mismatch')), isTrue);
    });

    test('rejects duplicate component ids', () {
      final surface = CreateSurface(
        surfaceId: 'test',
        catalogId: 'crux/1.0/chat',
        components: [
          const A2uiComponent(id: 'root', component: 'Text'),
          const A2uiComponent(id: 'root', component: 'Text'),
        ],
      );
      final errors = catalog.validate(surface);
      expect(errors.any((e) => e.contains('duplicate component id')), isTrue);
    });

    test('rejects unknown child references', () {
      final surface = CreateSurface(
        surfaceId: 'test',
        catalogId: 'crux/1.0/chat',
        components: [
          const A2uiComponent(
            id: 'root',
            component: 'Column',
            properties: {
              'children': ['missing'],
            },
          ),
        ],
      );
      final errors = catalog.validate(surface);
      expect(
        errors.any((e) => e.contains('unknown child')),
        isTrue,
      );
    });

    test('rejects empty components list', () {
      final surface = CreateSurface(
        surfaceId: 'test',
        catalogId: 'crux/1.0/chat',
        components: [],
      );
      final errors = catalog.validate(surface);
      expect(errors.any((e) => e.contains('empty')), isTrue);
    });
  });

  group('Surface rendering', () {
    test('renders a simple Text surface', () async {
      await testNocterm('simple text surface', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'simple',
          catalogId: 'crux/1.0/chat',
          components: [
            const A2uiComponent(
              id: 'root',
              component: 'Text',
              properties: {'text': 'Hello, Surface!'},
            ),
          ],
        );

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: SurfaceInstance(declaration: surface),
              catalog: catalog,
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.terminalState.findText('Hello, Surface!').isNotEmpty,
          isTrue,
        );
      });
    });

    test('renders a Column with multiple Texts', () async {
      await testNocterm('column with texts', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'column_test',
          catalogId: 'crux/1.0/chat',
          components: [
            const A2uiComponent(
              id: 'root',
              component: 'Column',
              properties: {
                'children': ['line1', 'line2', 'line3'],
              },
            ),
            const A2uiComponent(
              id: 'line1',
              component: 'Text',
              properties: {'text': 'First'},
            ),
            const A2uiComponent(
              id: 'line2',
              component: 'Text',
              properties: {'text': 'Second'},
            ),
            const A2uiComponent(
              id: 'line3',
              component: 'Text',
              properties: {'text': 'Third'},
            ),
          ],
        );

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: SurfaceInstance(declaration: surface),
              catalog: catalog,
            ),
          ),
        );
        await tester.pump();

        expect(tester.terminalState.findText('First').isNotEmpty, isTrue);
        expect(tester.terminalState.findText('Second').isNotEmpty, isTrue);
        expect(tester.terminalState.findText('Third').isNotEmpty, isTrue);
      });
    });

    test('renders a Card with title and child', () async {
      await testNocterm('card with title', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'card_test',
          catalogId: 'crux/1.0/chat',
          components: [
            const A2uiComponent(
              id: 'root',
              component: 'Card',
              properties: {'child': 'content', 'title': 'My Card'},
            ),
            const A2uiComponent(
              id: 'content',
              component: 'Text',
              properties: {'text': 'Card body'},
            ),
          ],
        );

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: SurfaceInstance(declaration: surface),
              catalog: catalog,
            ),
          ),
        );
        await tester.pump();

        expect(tester.terminalState.findText('Card body').isNotEmpty, isTrue);
        // Card border should render — check for the title text which
        // only appears when the border decoration is active.
        expect(tester.terminalState.findText('My Card').isNotEmpty, isTrue);
      });
    });

    test('renders data-bound text', () async {
      await testNocterm('data bound text', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'binding_test',
          catalogId: 'crux/1.0/chat',
          components: [
            const A2uiComponent(
              id: 'root',
              component: 'Text',
              properties: {
                'text': {'path': '/greeting'},
              },
            ),
          ],
          dataModel: const {'greeting': 'Hello from DataModel'},
        );

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: SurfaceInstance(declaration: surface),
              catalog: catalog,
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.terminalState.findText('Hello from DataModel').isNotEmpty,
          isTrue,
        );
      });
    });

    test('renders error for unknown component type', () async {
      await testNocterm('unknown component error', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'error_test',
          catalogId: 'crux/1.0/chat',
          components: [
            const A2uiComponent(
              id: 'root',
              component: 'NonExistent',
            ),
          ],
        );

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: SurfaceInstance(declaration: surface),
              catalog: catalog,
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.terminalState.findText('unregistered type').isNotEmpty,
          isTrue,
        );
      });
    });

    test('renders error for missing root', () async {
      await testNocterm('missing root error', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'empty_test',
          catalogId: 'crux/1.0/chat',
          components: [],
        );

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: SurfaceInstance(declaration: surface),
              catalog: catalog,
            ),
          ),
        );
        await tester.pump();

        expect(
          tester.terminalState.findText('no root component').isNotEmpty,
          isTrue,
        );
      });
    });
  });
}
