/// The `surface_update` tool — agent's live-update channel for mounted
/// A2UI surfaces.
///
/// A companion to the `surface` tool: `surface` declares the component
/// tree once; `surface_update` pushes fresh data into an existing
/// surface's DataModel so mounted surfaces re-render live. The classic
/// pairing: declare a ProgressBar bound to `{"path": "/progress"}` up
/// front, then call `surface_update` as long-running work advances.
///
/// The update applies to the surface's live [SurfaceInstance] via the
/// catalog's registry (id-keyed, shared across tool calls in the same
/// turn), so the bubble mounted from the original `surface` call sees
/// the new values on its next build. Persisted messages replay through
/// the same path in chat-history restore.
library;

import '../services/a2ui/models.dart';
import '../services/a2ui/surface_catalog.dart';
import 'tool_def.dart';

/// Tool name constant.
const String kSurfaceUpdateToolName = 'surface_update';

/// The `surface_update` tool. Applies a JSON-Patcher-style updates map
/// to an existing surface's DataModel.
class SurfaceUpdateTool extends ToolDef {
  final SurfaceCatalog catalog;

  SurfaceUpdateTool({required this.catalog});

  @override
  String get name => kSurfaceUpdateToolName;

  @override
  String get description =>
      'Update an existing UI surface (created by the `surface` tool) so it '
      're-renders live. Two channels, usable together in one call: '
      '`updates` writes data-model values ({"path": "/field"} bindings '
      're-resolve); `components` adds or REPLACES components in the tree '
      '(new ids are appended — pair with `extend_container_id` to append '
      'them to a container, e.g. add rows to a Column). Use this to push '
      'live progress, results, status, or new UI blocks into a surface '
      'the user can already see.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'required': ['surface_id'],
    'properties': {
      'surface_id': {
        'type': 'string',
        'description': 'The surfaceId of the surface to update.',
      },
      'updates': {
        'type': 'object',
        'description':
            'Map of data-model path (without leading slash, or with — '
            'both accepted) to new value. Nested keys create nested '
            'maps. Example: {"progress": 0.7, "status": "running"}. '
            'Omit when only updating components.',
      },
      'components': {
        'type': 'array',
        'description':
            'Components to add or replace (same flat schema as '
            'createSurface.components). An id that already exists is '
            'replaced in place; a new id is appended to the surface. '
            'Example: a new Table row Text component.',
        'items': {'type': 'object'},
      },
      'extend_container_id': {
        'type': 'string',
        'description':
            'Optional container component id (e.g. the root Column). '
            'New (not-yet-referenced) component ids from `components` '
            'are appended to its `children` — one call adds visible '
            'blocks without touching the tree by hand.',
      },
    },
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final surfaceId = args['surface_id']?.toString();
    if (surfaceId == null || surfaceId.isEmpty) {
      return ToolResult.error('Missing required argument: surface_id');
    }
    final updates = args['updates'];
    if (updates != null && updates is! Map<String, dynamic>) {
      return ToolResult.error(
        'Invalid argument: updates must be an object of path → value',
      );
    }
    final componentsRaw = args['components'];
    if (componentsRaw != null && componentsRaw is! List) {
      return ToolResult.error(
        'Invalid argument: components must be an array of component objects',
      );
    }
    if ((updates == null || (updates as Map).isEmpty) &&
        (componentsRaw == null || (componentsRaw as List).isEmpty)) {
      return ToolResult.error(
        'Nothing to do — pass `updates` (data) and/or `components` '
        '(structure)',
      );
    }

    final instance = catalog.instanceById(surfaceId);
    if (instance == null) {
      return ToolResult.error(
        'No surface found with surfaceId "$surfaceId". Create it first '
        'with the `surface` tool.',
      );
    }
    if (instance.submitted) {
      return ToolResult.error(
        'Surface "$surfaceId" has been submitted by the user and is '
        'frozen read-only — updates are no longer accepted.',
      );
    }

    var applied = 0;
    if (updates != null && (updates as Map<String, dynamic>).isNotEmpty) {
      for (final entry in updates.entries) {
        instance.updateDataModel(entry.key, entry.value);
        applied++;
      }
    }

    var componentCount = 0;
    if (componentsRaw is List && componentsRaw.isNotEmpty) {
      final parsed = <A2uiComponent>[];
      for (final c in componentsRaw) {
        if (c is Map<String, dynamic>) {
          final comp = A2uiComponent.fromJson(c);
          if (comp != null) parsed.add(comp);
        }
      }
      if (parsed.length != componentsRaw.length) {
        return ToolResult.error(
          'Invalid components: every entry must contain a non-empty "id" '
          'and "component" string.',
        );
      }
      if (parsed.isNotEmpty) {
        final extendId = args['extend_container_id']?.toString();
        final ok = instance.updateComponents(
          components: parsed,
          extendContainerId: (extendId == null || extendId.isEmpty)
              ? null
              : extendId,
        );
        if (!ok) {
          return ToolResult.error(
            'Component update rejected: the surface is submitted or '
            'extend_container_id does not exist.',
          );
        }
        componentCount = parsed.length;
      }
    }

    return ToolResult(
      title: 'Surface update',
      output:
          'Updated "$surfaceId": $applied field(s), '
          '$componentCount component(s) applied.',
    );
  }

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final surfaceId = args['surface_id']?.toString() ?? '?';
    final updates = args['updates'];
    final components = args['components'];
    final fields = updates is Map ? updates.length : 0;
    final comps = components is List ? components.length : 0;
    return CollapsedSummary(
      text:
          'surface update "$surfaceId" '
          '($fields fields, $comps components)',
      argsTokens: 0,
      totalTokens: 0,
    );
  }
}
