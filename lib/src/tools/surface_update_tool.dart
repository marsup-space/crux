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
      'Update the data model of an existing UI surface (created by the '
      '`surface` tool) so it re-renders with fresh values. Use this to '
      'push live progress, results, or status into a surface the user '
      'can already see — e.g. advance a ProgressBar, append rows to a '
      'Table, update a status Text.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'required': ['surface_id', 'updates'],
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
                'maps. Example: {"progress": 0.7, "status": "running"}.',
          },
        },
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> args,
    ToolContext ctx,
  ) async {
    final surfaceId = args['surface_id']?.toString();
    if (surfaceId == null || surfaceId.isEmpty) {
      return ToolResult.error('Missing required argument: surface_id');
    }
    final updates = args['updates'];
    if (updates is! Map<String, dynamic>) {
      return ToolResult.error(
        'Missing or invalid required argument: updates (object of '
        'path → value)',
      );
    }
    if (updates.isEmpty) {
      return ToolResult.error('updates is empty — nothing to do');
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
    for (final entry in updates.entries) {
      instance.updateDataModel(entry.key, entry.value);
      applied++;
    }

    return ToolResult(
      title: 'Surface update',
      output: 'Updated "$surfaceId": $applied field(s) applied.',
    );
  }

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final surfaceId = args['surface_id']?.toString() ?? '?';
    final updates = args['updates'];
    final count = updates is Map ? updates.length : 0;
    return CollapsedSummary(
      text: 'surface update "$surfaceId" ($count fields)',
      argsTokens: 0,
      totalTokens: 0,
    );
  }
}
