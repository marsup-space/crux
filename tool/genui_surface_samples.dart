/// Standalone GenUI sample gallery — no Crux app/services required.
///
/// Run one sample in Ghostty, for example:
///   dart run tool/genui_surface_samples.dart form
/// Available names: dashboard, form, progress, data.
library;

import 'dart:io';

import 'package:crux/src/components/surface_host.dart';
import 'package:crux/src/services/a2ui/basic_catalog_items.dart';
import 'package:crux/src/services/a2ui/models.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:nocterm/nocterm.dart';

import 'genui_surface_sample.dart' show sampleSurface;

const sampleNames = ['dashboard', 'form', 'progress', 'data'];

CreateSurface sampleFor(String name) => switch (name) {
  'dashboard' => sampleSurface,
  'form' => _releaseForm,
  'progress' => _taskProgress,
  'data' => _reviewData,
  _ => throw ArgumentError.value(name, 'name', 'unknown GenUI sample'),
};

Future<void> main(List<String> args) async {
  if (args.firstOrNull == '--list') {
    stdout.writeln(sampleNames.join('\n'));
    return;
  }
  final name = args.firstOrNull ?? 'dashboard';
  if (!sampleNames.contains(name)) {
    stderr.writeln('Unknown sample "$name". Try: ${sampleNames.join(', ')}');
    exitCode = 64;
    return;
  }
  await runApp(
    CruxTheme(
      data: CruxThemeData.draculaFallback,
      child: Container(
        padding: const EdgeInsets.all(1),
        child: SurfaceHost(
          declaration: sampleFor(name),
          catalog: createBasicCatalog(),
          instanceKey: 'standalone.$name',
          retainState: false,
          submitOnAction: false,
          maxWidth: _sampleMaxWidth(name),
          onAction: (_) {},
        ),
      ),
    ),
  );
}

int _sampleMaxWidth(String name) => switch (name) {
  'form' => 92,
  'progress' => 132,
  'data' => 100,
  _ => 120,
};

final _releaseForm = CreateSurface(
  surfaceId: 'standalone.form',
  catalogId: 'crux/1.0/chat',
  dataModel: const {
    'title': 'Surface migration',
    'environment': ['staging'],
    'announce': true,
    'preview': false,
  },
  components: const [
    A2uiComponent(
      id: 'root',
      component: 'Column',
      properties: {
        'children': ['heading', 'card'],
      },
    ),
    A2uiComponent(
      id: 'heading',
      component: 'Text',
      properties: {'text': 'Release request'},
    ),
    A2uiComponent(
      id: 'card',
      component: 'Card',
      properties: {'title': 'Deploy', 'child': 'fields'},
    ),
    A2uiComponent(
      id: 'fields',
      component: 'Column',
      properties: {
        'children': ['title', 'environment', 'announce', 'preview', 'submit'],
        'align': 'start',
      },
    ),
    A2uiComponent(
      id: 'title',
      component: 'TextField',
      properties: {
        'label': 'Title',
        'value': {'path': '/title'},
      },
    ),
    A2uiComponent(
      id: 'environment',
      component: 'ChoicePicker',
      properties: {
        'label': 'Environment',
        'value': {'path': '/environment'},
        'variant': 'mutuallyExclusive',
        'displayStyle': 'inline',
        'options': [
          {'label': 'dev', 'value': 'dev'},
          {'label': 'staging', 'value': 'staging'},
          {'label': 'prod', 'value': 'prod'},
        ],
      },
    ),
    A2uiComponent(
      id: 'announce',
      component: 'CheckBox',
      properties: {
        'label': 'Post a release note',
        'value': {'path': '/announce'},
      },
    ),
    A2uiComponent(
      id: 'preview',
      component: 'Toggle',
      properties: {
        'label': 'Preview only',
        'value': {'path': '/preview'},
      },
    ),
    A2uiComponent(
      id: 'submit',
      component: 'Button',
      properties: {
        'child': 'submitLabel',
        'variant': 'primary',
        'action': {
          'event': {'name': 'submit_release'},
        },
      },
    ),
    A2uiComponent(
      id: 'submitLabel',
      component: 'Text',
      properties: {'text': 'Queue release'},
    ),
  ],
);

final _taskProgress = CreateSurface(
  surfaceId: 'standalone.progress',
  catalogId: 'crux/1.0/chat',
  components: const [
    A2uiComponent(
      id: 'root',
      component: 'Column',
      properties: {
        'children': ['heading', 'summary', 'active', 'queue'],
      },
    ),
    A2uiComponent(
      id: 'heading',
      component: 'Text',
      properties: {'text': 'Agent work queue'},
    ),
    A2uiComponent(
      id: 'summary',
      component: 'Card',
      properties: {'title': 'Today', 'child': 'metrics'},
    ),
    A2uiComponent(
      id: 'metrics',
      component: 'Row',
      properties: {
        'gap': 3,
        'children': ['runs', 'tests', 'ready'],
      },
    ),
    A2uiComponent(
      id: 'runs',
      component: 'Stat',
      properties: {'value': '4', 'label': 'runs'},
    ),
    A2uiComponent(
      id: 'tests',
      component: 'Stat',
      properties: {'value': '2871', 'label': 'tests'},
    ),
    A2uiComponent(
      id: 'ready',
      component: 'Badge',
      properties: {'text': 'green', 'tone': 'success'},
    ),
    A2uiComponent(
      id: 'active',
      component: 'Card',
      properties: {'title': 'Active', 'child': 'activeBody'},
    ),
    A2uiComponent(
      id: 'activeBody',
      component: 'Column',
      properties: {
        'children': ['activeName', 'runtime'],
      },
    ),
    A2uiComponent(
      id: 'activeName',
      component: 'Text',
      properties: {'text': 'Migrate home boxes'},
    ),
    A2uiComponent(
      id: 'runtime',
      component: 'Section',
      properties: {'title': 'Runtime', 'child': 'runtimeRows'},
    ),
    A2uiComponent(
      id: 'runtimeRows',
      component: 'Column',
      properties: {
        'children': ['activeBar', 'activeState'],
      },
    ),
    A2uiComponent(
      id: 'activeBar',
      component: 'ProgressBar',
      properties: {'value': 0.58, 'showPercentage': true},
    ),
    A2uiComponent(
      id: 'activeState',
      component: 'KeyValue',
      properties: {'label': 'status', 'value': 'testing'},
    ),
    A2uiComponent(
      id: 'queue',
      component: 'Card',
      properties: {'title': 'Next', 'child': 'queueList'},
    ),
    A2uiComponent(
      id: 'queueList',
      component: 'List',
      properties: {
        'maxHeight': 4,
        'children': ['q1', 'q2', 'q3'],
      },
    ),
    A2uiComponent(
      id: 'q1',
      component: 'ListItem',
      properties: {'title': 'Plugin adapter', 'badge': 'next'},
    ),
    A2uiComponent(
      id: 'q2',
      component: 'ListItem',
      properties: {'title': 'Prompt trim', 'detail': 'shorten catalog rules'},
    ),
    A2uiComponent(
      id: 'q3',
      component: 'ListItem',
      properties: {'title': 'Restore coverage', 'badge': 'test'},
    ),
  ],
);

final _reviewData = CreateSurface(
  surfaceId: 'standalone.data',
  catalogId: 'crux/1.0/chat',
  components: const [
    A2uiComponent(
      id: 'root',
      component: 'Column',
      properties: {
        'children': ['heading', 'review'],
      },
    ),
    A2uiComponent(
      id: 'heading',
      component: 'Text',
      properties: {'text': 'Surface migration review'},
    ),
    A2uiComponent(
      id: 'review',
      component: 'Card',
      properties: {'title': 'Component coverage', 'child': 'table'},
    ),
    A2uiComponent(
      id: 'table',
      component: 'Table',
      properties: {
        'columns': [
          {'header': 'Area', 'key': 'area'},
          {'header': 'Surface', 'key': 'surface'},
          {'header': 'Owner', 'key': 'owner'},
        ],
        'rows': [
          {'area': 'Workspace', 'surface': 'KeyValue', 'owner': 'home'},
          {'area': 'Settings', 'surface': 'KeyValue', 'owner': 'home'},
          {'area': 'Plugins', 'surface': 'adapter', 'owner': 'next'},
          {'area': 'Chat forms', 'surface': 'interactive', 'owner': 'done'},
          {'area': 'Progress', 'surface': 'ProgressBar', 'owner': 'done'},
        ],
      },
    ),
  ],
);
