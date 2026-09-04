/// Standalone GenUI sample — no Crux app/services required.
///
/// Run locally: dart run tool/genui_surface_sample.dart
/// Quit with Ctrl-C. It renders the shared A2UI catalog in a plain Nocterm
/// process, which makes it useful for visual catalog work in Ghostty.
library;

import 'package:crux/src/components/surface_host.dart';
import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/services/a2ui/models.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart';

Future<void> main() => runApp(
  CruxTheme(
    data: CruxThemeData.draculaFallback,
    child: Container(
      padding: const EdgeInsets.all(1),
      child: SurfaceHost(
        declaration: sampleSurface,
        catalog: createBasicCatalog(),
        instanceKey: 'standalone.sample',
        retainState: false,
        submitOnAction: false,
        onAction: (action) {},
      ),
    ),
  ),
);

/// A small gallery covering the shared dashboard primitives.
final sampleSurface = CreateSurface(
  surfaceId: 'standalone.sample',
  catalogId: 'crux/1.0/chat',
  components: const [
    A2uiComponent(
      id: 'root',
      component: 'Column',
      properties: {
        'children': ['title', 'facts', 'release', 'divider', 'status', 'go'],
      },
    ),
    A2uiComponent(
      id: 'title',
      component: 'Text',
      properties: {'text': 'GenUI standalone catalog sample'},
    ),
    A2uiComponent(
      id: 'facts',
      component: 'Card',
      properties: {'title': 'Workspace', 'child': 'factRows'},
    ),
    A2uiComponent(
      id: 'factRows',
      component: 'Column',
      properties: {
        'children': ['project', 'branch', 'model'],
      },
    ),
    A2uiComponent(
      id: 'project',
      component: 'KeyValue',
      properties: {'label': 'project', 'value': 'crux'},
    ),
    A2uiComponent(
      id: 'branch',
      component: 'KeyValue',
      properties: {'label': 'branch', 'value': 'feature/genui'},
    ),
    A2uiComponent(
      id: 'model',
      component: 'KeyValue',
      properties: {'label': 'model', 'value': 'gpt-5.6'},
    ),
    A2uiComponent(
      id: 'release',
      component: 'Card',
      properties: {'title': 'Migration plan', 'child': 'planTable'},
    ),
    A2uiComponent(
      id: 'planTable',
      component: 'Table',
      properties: {
        'columns': [
          {'header': 'Slice', 'key': 'slice'},
          {'header': 'State', 'key': 'state'},
        ],
        'rows': [
          {'slice': 'Host', 'state': 'done'},
          {'slice': 'Home', 'state': 'active'},
          {'slice': 'Plugins', 'state': 'next'},
        ],
      },
    ),
    A2uiComponent(id: 'divider', component: 'Divider'),
    A2uiComponent(
      id: 'status',
      component: 'ProgressBar',
      properties: {'label': 'Migration', 'value': 2, 'max': 6},
    ),
    A2uiComponent(
      id: 'go',
      component: 'Button',
      properties: {
        'child': 'goLabel',
        'variant': 'primary',
        'action': {
          'event': {'name': 'open_settings'},
        },
      },
    ),
    A2uiComponent(
      id: 'goLabel',
      component: 'Text',
      properties: {'text': 'Open settings'},
    ),
  ],
);
