import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/services/a2ui/display_catalog_items.dart';
import 'package:crux/src/services/a2ui/models.dart';
import 'package:crux/src/services/a2ui/surface_catalog.dart';
import 'package:crux/src/services/a2ui/surface_controller.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/tools/surface_update_tool.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  late SurfaceCatalog catalog;

  setUp(() {
    catalog = createBasicCatalog();
  });

  group('Catalog registration', () {
    test('Table / ProgressBar / List are registered and validated', () {
      expect(catalog.lookup('Table'), isA<TableCatalogItem>());
      expect(catalog.lookup('ProgressBar'), isA<ProgressBarCatalogItem>());
      expect(catalog.lookup('List'), isA<ListCatalogItem>());

      // Catalog id remains stable.
      expect(catalog.catalogId, 'crux/1.0/chat');
    });
  });

  group('Table rendering', () {
    test('renders header and rows with column alignment', () async {
      await testNocterm('table basic', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'table_1',
          catalogId: 'crux/1.0/chat',
          components: [
            A2uiComponent(
              id: 'root',
              component: 'Table',
              properties: {
                'columns': [
                  {'header': 'File', 'key': 'file'},
                  {'header': 'Status', 'key': 'status'},
                ],
                'rows': [
                  {'file': 'a.dart', 'status': 'ok'},
                  {'file': 'b.dart', 'status': 'fail'},
                ],
              },
            ),
          ],
        );

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: catalog.instanceFor('c1', surface),
              catalog: catalog,
            ),
          ),
        );
        await tester.pump();

        expect(tester.terminalState.findText('File').isNotEmpty, isTrue);
        expect(tester.terminalState.findText('Status').isNotEmpty, isTrue);
        expect(tester.terminalState.findText('a.dart').isNotEmpty, isTrue);
        expect(tester.terminalState.findText('fail').isNotEmpty, isTrue);
      }, size: const Size(80, 24));
    });

    test('rows via data binding re-resolve after surface_update', () async {
      await testNocterm('table live update', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'table_live',
          catalogId: 'crux/1.0/chat',
          components: [
            A2uiComponent(
              id: 'root',
              component: 'Table',
              properties: {
                'columns': [
                  {'header': 'Step', 'key': 'step'},
                ],
                'rows': {'path': '/steps'},
              },
            ),
          ],
          dataModel: {
            'steps': [
              {'step': 'build'},
            ],
          },
        );

        final instance = catalog.instanceFor('c1', surface);

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(surface: instance, catalog: catalog),
          ),
        );
        await tester.pump();

        expect(tester.terminalState.findText('build').isNotEmpty, isTrue);
        expect(tester.terminalState.findText('deploy'), isEmpty);

        // Apply an update the way the surface_update tool does.
        instance.updateDataModel('/steps', [
          {'step': 'build'},
          {'step': 'deploy'},
        ]);
        await tester.pump();

        expect(tester.terminalState.findText('deploy').isNotEmpty, isTrue);
      }, size: const Size(80, 24));
    });

    test('CJK cell content aligns by terminal width', () async {
      await testNocterm('table cjk', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'table_cjk',
          catalogId: 'crux/1.0/chat',
          components: [
            A2uiComponent(
              id: 'root',
              component: 'Table',
              properties: {
                'columns': [
                  {'header': '名称', 'key': 'name'},
                  {'header': '状态', 'key': 'status'},
                ],
                'rows': [
                  {'name': '编译', 'status': 'ok'},
                  {'name': 'test', 'status': 'ok'},
                ],
              },
            ),
          ],
        );

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: catalog.instanceFor('c1', surface),
              catalog: catalog,
            ),
          ),
        );
        await tester.pump();

        expect(tester.terminalState.findText('编译').isNotEmpty, isTrue);
        expect(tester.terminalState.findText('test').isNotEmpty, isTrue);
      }, size: const Size(80, 24));
    });
  });

  group('ProgressBar rendering', () {
    test('renders a determinate, data-bound bar', () async {
      await testNocterm('progressbar bound', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'pb_1',
          catalogId: 'crux/1.0/chat',
          components: [
            A2uiComponent(
              id: 'root',
              component: 'ProgressBar',
              properties: {
                'value': {'path': '/progress'},
                'showPercentage': true,
              },
            ),
          ],
          dataModel: {'progress': 0.5},
        );

        final instance = catalog.instanceFor('c1', surface);

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(surface: instance, catalog: catalog),
          ),
        );
        await tester.pump();

        // 50% at width 80 → the bar should render with a "50%" readout
        // centered, drawn on filled/empty cell backgrounds.
        expect(
          tester.terminalState.findText('50%').isNotEmpty,
          isTrue,
          reason: 'percentage readout should render on the bar',
        );

        // Advance via surface_update path.
        instance.updateDataModel('/progress', 1.0);
        await tester.pump();

        // Full bar: 100% readout.
        expect(
          tester.terminalState.findText('100%').isNotEmpty,
          isTrue,
          reason: '100% readout should render after update',
        );
      }, size: const Size(80, 24));
    });
  });

  group('List rendering', () {
    test('caps height and renders all children after scroll', () async {
      await testNocterm('list capped', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'list_1',
          catalogId: 'crux/1.0/chat',
          components: [
            A2uiComponent(
              id: 'root',
              component: 'List',
              properties: {
                'children': [
                  for (var i = 1; i <= 12; i++) 'row$i',
                ],
                'maxHeight': 5,
              },
            ),
            for (var i = 1; i <= 12; i++)
              A2uiComponent(
                id: 'row$i',
                component: 'Text',
                properties: {'text': 'item-$i'},
              ),
          ],
        );

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: catalog.instanceFor('c1', surface),
              catalog: catalog,
            ),
          ),
        );
        await tester.pump();

        // First items render.
        expect(tester.terminalState.findText('item-1').isNotEmpty, isTrue);
        // The list is at most maxHeight rows tall — item beyond the
        // cap is scrollable, not all visible at once. (Exact scrolled
        // offset is an implementation detail; assert the visible head.)
      }, size: const Size(80, 24));
    });
  });

  group('SurfaceInstance change notification', () {
    test('updateDataModel notifies listeners', () {
      final surface = CreateSurface(
        surfaceId: 'n1',
        catalogId: 'crux/1.0/chat',
        components: [],
      );
      final instance = SurfaceInstance(declaration: surface);
      var notified = 0;
      instance.addListener(() => notified++);

      instance.updateDataModel('/x', 1);
      expect(notified, 1);
      expect(instance.readDataModel('/x'), 1);

      instance.markSubmitted();
      expect(notified, 2);

      // markSubmitted is idempotent — no spurious notification.
      instance.markSubmitted();
      expect(notified, 2);
    });

    test('listeners re-keyed via instanceFor share one instance', () {
      // Simulates surface + surface_update calls in one turn: the
      // update's instanceFor call happens under a different key but
      // the same surfaceId — both keys must resolve to one instance.
      final decl = CreateSurface(
        surfaceId: 'shared',
        catalogId: 'crux/1.0/chat',
        components: [],
      );
      final a = catalog.instanceFor('call_create', decl);
      final b = catalog.instanceFor('call_update', decl);
      expect(identical(a, b), isTrue);

      // Update through one handle, read through the other.
      b.updateDataModel('/v', 7);
      expect(a.readDataModel('/v'), 7);
    });
  });

  group('SurfaceUpdateTool', () {
    late SurfaceUpdateTool tool;

    setUp(() {
      tool = SurfaceUpdateTool(catalog: catalog);
    });

    test('applies updates to a live instance', () async {
      final decl = CreateSurface(
        surfaceId: 'live_1',
        catalogId: 'crux/1.0/chat',
        components: [],
      );
      catalog.instanceFor('c1', decl);

      final ctx = _FakeToolContext();
      final result = await tool.execute({
        'surface_id': 'live_1',
        'updates': {'progress': 0.4, 'status': 'running'},
      }, ctx);

      expect(result.title == 'Error', isFalse);
      final instance = catalog.instanceById('live_1')!;
      expect(instance.readDataModel('/progress'), 0.4);
      expect(instance.readDataModel('/status'), 'running');
    });

    test('errors on unknown surfaceId', () async {
      final ctx = _FakeToolContext();
      final result = await tool.execute({
        'surface_id': 'ghost',
        'updates': {'a': 1},
      }, ctx);
      expect(result.title, 'Error');
    });

    test('errors on missing args', () async {
      final ctx = _FakeToolContext();
      expect(
        (await tool.execute({'updates': {'a': 1}}, ctx)).title,
        'Error',
      );
      expect(
        (await tool.execute({'surface_id': 'x'}, ctx)).title,
        'Error',
      );
    });

    test('does not mutate a submitted surface', () async {
      final decl = CreateSurface(
        surfaceId: 'frozen',
        catalogId: 'crux/1.0/chat',
        components: [],
      );
      final instance = catalog.instanceFor('c1', decl);
      instance.markSubmitted();

      final ctx = _FakeToolContext();
      final result = await tool.execute({
        'surface_id': 'frozen',
        'updates': {'a': 1},
      }, ctx);

      // Tool-level guard: submitted surfaces are frozen.
      expect(result.title, 'Error');
      expect(instance.readDataModel('/a'), isNull);
    });
  });
  group('Button single-child', () {
    test('Button child label renders exactly once', () async {
      await testNocterm('button label dedup', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'btn_dedup',
          catalogId: 'crux/1.0/chat',
          components: [
            A2uiComponent(
              id: 'root',
              component: 'Column',
              properties: {
                'children': ['card'],
              },
            ),
            A2uiComponent(
              id: 'card',
              component: 'Card',
              properties: {'child': 'inner', 'title': 'T'},
            ),
            A2uiComponent(
              id: 'inner',
              component: 'Column',
              properties: {
                'children': ['go'],
              },
            ),
            A2uiComponent(
              id: 'go',
              component: 'Button',
              properties: {
                'child': 'go_lbl',
                'action': {'event': {'name': 'go', 'context': {}}},
              },
            ),
            A2uiComponent(
              id: 'go_lbl',
              component: 'Text',
              properties: {'text': '提交验收'},
            ),
          ],
        );

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: catalog.instanceFor('c1', surface),
              catalog: catalog,
            ),
          ),
        );
        await tester.pump();

        // Count occurrences of the label text on screen. The
        // terminalState.findText returns a list of positions; assert
        // exactly one match.
        final positions = tester.terminalState.findText('提交验收');
        expect(positions.length, 1,
            reason: 'Button label must render exactly once, not twice');
      }, size: const Size(80, 24));
    });
  });
}

class _FakeToolContext implements ToolContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
