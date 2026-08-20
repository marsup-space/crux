import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/services/a2ui/interactive_catalog_items.dart';
import 'package:crux/src/services/a2ui/models.dart';
import 'package:crux/src/services/a2ui/surface_catalog.dart';
import 'package:crux/src/services/a2ui/surface_controller.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:crux/src/tools/surface_tool.dart';

void main() {
  late SurfaceCatalog catalog;

  setUp(() {
    catalog = createBasicCatalog();
    registerInteractiveCatalogItems(catalog);
  });

  group('Surface restore from chat history', () {
    test('restoreSubmitted fills DataModel and marks submitted', () {
      final surface = CreateSurface(
        surfaceId: 'test_form',
        catalogId: 'crux/1.0/chat',
        components: [
          A2uiComponent(
            id: 'root',
            component: 'Column',
            properties: {
              'children': ['name_field', 'sub_check', 'submit_btn'],
            },
          ),
          A2uiComponent(
            id: 'name_field',
            component: 'TextField',
            properties: {
              'value': {'path': '/name'},
            },
          ),
          A2uiComponent(
            id: 'sub_check',
            component: 'CheckBox',
            properties: {
              'label': 'Subscribe',
              'value': {'path': '/subscribe'},
            },
          ),
          A2uiComponent(
            id: 'submit_btn',
            component: 'Button',
            properties: {
              'child': 'submit_label',
              'action': {
                'event': {
                  'name': 'submit',
                  'context': {
                    'name': {'path': '/name'},
                    'subscribe': {'path': '/subscribe'},
                  },
                },
              },
            },
          ),
          A2uiComponent(
            id: 'submit_label',
            component: 'Text',
            properties: {'text': 'Submit'},
          ),
        ],
      );

      // Register the instance (simulating pass 1).
      final instance = catalog.instanceFor('call_1', surface);
      expect(instance.submitted, isFalse);
      expect(instance.dataModel, isEmpty);

      // Simulate: user submitted, action message in history.
      final action = A2uiAction.tryParseDisplayString(
        'action: submit\n'
        'surface: test_form\n'
        'context: {"name": "Alice", "subscribe": true}',
      );
      expect(action, isNotNull);
      expect(action!.name, 'submit');
      expect(action.surfaceId, 'test_form');
      expect(action.context['name'], 'Alice');
      expect(action.context['subscribe'], true);

      // Restore (simulating pass 2).
      final found = catalog.instanceById('test_form');
      expect(found, isNotNull);
      expect(found!.submitted, isFalse);
      found.restoreSubmitted(action);
      expect(found.submitted, isTrue);
      expect(found.dataModel['name'], 'Alice');
      expect(found.dataModel['subscribe'], true);
    });

    test('surfaceFromToolCall parses surface arg', () {
      // The tool schema expects {"surface": {...}} — the surface
      // declaration is nested under the "surface" key.
      final input = {
        'surface': {
          'surfaceId': 'nested_test',
          'catalogId': 'crux/1.0/chat',
          'components': [
            {'id': 'root', 'component': 'Text', 'text': 'Hello'},
          ],
        },
      };
      final surface = surfaceFromToolCall(input);
      expect(surface, isNotNull);
      expect(surface!.surfaceId, 'nested_test');
    });

    test('restored surface renders submitted values read-only', () async {
      await testNocterm('restored surface', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'restore_test',
          catalogId: 'crux/1.0/chat',
          components: [
            A2uiComponent(
              id: 'root',
              component: 'Column',
              properties: {
                'children': ['name_field', 'sub_check'],
              },
            ),
            A2uiComponent(
              id: 'name_field',
              component: 'TextField',
              properties: {
                'value': {'path': '/name'},
              },
            ),
            A2uiComponent(
              id: 'sub_check',
              component: 'CheckBox',
              properties: {
                'label': 'Subscribe',
                'value': {'path': '/subscribe'},
              },
            ),
          ],
        );

        final instance = catalog.instanceFor('call_1', surface);

        // Simulate restore from chat history.
        final action = A2uiAction.tryParseDisplayString(
          'action: submit\n'
          'surface: restore_test\n'
          'context: {"name": "Alice", "subscribe": true}',
        );
        instance.restoreSubmitted(action!);

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(surface: instance, catalog: catalog),
          ),
        );
        await tester.pump();

        // TextField should show the restored value.
        expect(
          tester.terminalState.findText('Alice').isNotEmpty,
          isTrue,
          reason: 'TextField should show restored value "Alice"',
        );
        // CheckBox should show checked state.
        expect(
          tester.terminalState.findText('☑').isNotEmpty,
          isTrue,
          reason: 'CheckBox should show checked ☑',
        );
      }, size: const Size(80, 24));
    });
  });

  group('Submitted surface interaction', () {
    test('submitted surface does not respond to interaction', () async {
      await testNocterm('submitted surface read-only', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'readonly_test',
          catalogId: 'crux/1.0/chat',
          components: [
            A2uiComponent(
              id: 'root',
              component: 'Column',
              properties: {
                'children': ['sub_check', 'submit_btn'],
              },
            ),
            A2uiComponent(
              id: 'sub_check',
              component: 'CheckBox',
              properties: {
                'label': 'Subscribe',
                'value': {'path': '/subscribe'},
              },
            ),
            A2uiComponent(
              id: 'submit_btn',
              component: 'Button',
              properties: {
                'child': 'submit_label',
                'action': {
                  'event': {'name': 'submit', 'context': {}},
                },
              },
            ),
            A2uiComponent(
              id: 'submit_label',
              component: 'Text',
              properties: {'text': 'Submit'},
            ),
          ],
        );

        final instance = catalog.instanceFor('call_1', surface);

        var actionFired = false;
        var dataModelUpdated = false;

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: instance,
              catalog: catalog,
              onAction: (_) => actionFired = true,
              onDataModelUpdate: (_, __) => dataModelUpdated = true,
            ),
          ),
        );
        await tester.pump();

        // Before submit: checkbox should be unchecked.
        expect(
          tester.terminalState.findText('☐').isNotEmpty,
          isTrue,
          reason: 'CheckBox should start unchecked',
        );

        // Tap the checkbox — should toggle.
        final checkPos = tester.terminalState.findText('☐');
        expect(checkPos.isNotEmpty, isTrue);
        await tester.tap(checkPos.first.x, checkPos.first.y);
        await tester.pump();
        expect(dataModelUpdated, isTrue);

        // Tap submit — should fire action.
        final submitPos = tester.terminalState.findText('Submit');
        expect(submitPos.isNotEmpty, isTrue);
        await tester.tap(submitPos.first.x, submitPos.first.y);
        await tester.pump();
        expect(actionFired, isTrue);
        expect(instance.submitted, isTrue);

        // After submit: reset flags and try to interact again.
        dataModelUpdated = false;
        actionFired = false;

        // Checkbox should now show checked state (from DataModel).
        final checkedPos = tester.terminalState.findText('☑');
        expect(checkedPos.isNotEmpty, isTrue);
        await tester.tap(checkedPos.first.x, checkedPos.first.y);
        await tester.pump();
        expect(dataModelUpdated, isFalse,
            reason: 'submitted surface should not update DataModel');

        // Submit button should be disabled — tapping should not fire.
        await tester.tap(submitPos.first.x, submitPos.first.y);
        await tester.pump();
        expect(actionFired, isFalse,
            reason: 'submitted surface should not fire action');
      }, size: const Size(80, 24));
    });

    test('action carries the surface id, not the component id', () async {
      await testNocterm('action surfaceId fix', (tester) async {
        final surface = CreateSurface(
          surfaceId: 'real_surface_id',
          catalogId: 'crux/1.0/chat',
          components: [
            A2uiComponent(
              id: 'root',
              component: 'Column',
              properties: {
                'children': ['submit_btn'],
              },
            ),
            A2uiComponent(
              id: 'submit_btn',
              component: 'Button',
              properties: {
                'child': 'submit_label',
                'action': {
                  'event': {'name': 'submit', 'context': {}},
                },
              },
            ),
            A2uiComponent(
              id: 'submit_label',
              component: 'Text',
              properties: {'text': 'Submit'},
            ),
          ],
        );

        final instance = catalog.instanceFor('call_1', surface);
        String? capturedSurfaceId;

        await tester.pumpComponent(
          CruxTheme(
            data: CruxThemeData.draculaFallback,
            child: SurfaceController(
              surface: instance,
              catalog: catalog,
              onAction: (a) => capturedSurfaceId = a.surfaceId,
            ),
          ),
        );
        await tester.pump();

        await tester.tap(
          tester.terminalState.findText('Submit').first.x,
          tester.terminalState.findText('Submit').first.y,
        );
        await tester.pump();

        // The action's surfaceId must be the surface's declared id —
        // not the Button component's own id ("submit_btn"). Regression
        // guard for restart-state restoration (instanceById lookup).
        expect(capturedSurfaceId, 'real_surface_id');
      }, size: const Size(80, 24));
    });
  });

  group('Legacy action message formats', () {
    test('parses legacy multi-line kv context', () {
      final action = A2uiAction.tryParseDisplayString(
        'action: submit_form\n'
        'surface: submitBtn\n'
        'context:\n'
        '  form: subscription\n'
        '  interests: [food, anime]\n'
        '  name: 123\n'
        '  subscribe: true',
      );
      expect(action, isNotNull);
      expect(action!.context['form'], 'subscription');
      expect(action.context['interests'], isA<List<dynamic>>());
      expect((action.context['interests'] as List)[0], 'food');
      expect(action.context['name'], 123);
      expect(action.context['subscribe'], true);
    });

    test('legacy surfaceId falls back to nearest surface (simulate pass 2)', () {
      // Old actions recorded a component id in the "surface:" field.
      // Pass 2's fallback picks the most recent un-submitted surface.
      final registry = createBasicCatalog();
      registerInteractiveCatalogItems(registry);

      final decl = CreateSurface(
        surfaceId: 'subscription_form',
        catalogId: 'crux/1.0/chat',
        components: [
          A2uiComponent(
            id: 'root',
            component: 'Text',
            properties: {'text': 'form'},
          ),
        ],
      );
      final instance = registry.instanceFor('call_1', decl);

      final action = A2uiAction.tryParseDisplayString(
        'action: submit_form\n'
        'surface: submitBtn\n'
        'context: {"name": "Alice"}',
      )!;

      // instanceById misses (component id), fallback applies.
      final found = registry.instanceById(action.surfaceId);
      expect(found, isNull, reason: 'component id should not match');
      instance.restoreSubmitted(action);
      expect(instance.submitted, isTrue);
      expect(instance.dataModel['name'], 'Alice');
    });
  });
}
