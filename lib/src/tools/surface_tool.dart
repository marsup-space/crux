/// The `surface` tool — agent's entry point for creating A2UI surfaces.
///
/// The agent calls this tool with an A2UI `createSurface` message (JSON).
/// The tool validates the declaration against the catalog and returns
/// a confirmation. The surface data lives in the tool call's input args —
/// the message bubble parses it at render time and builds a
/// [SurfaceController] inline.
///
/// Phase 1: single-direction surfaces only — no action handling.
library;

import '../services/a2ui/models.dart';
import '../services/a2ui/surface_catalog.dart';
import 'tool_def.dart';

/// Tool name constant.
const String kSurfaceToolName = 'surface';

/// The `surface` tool. Accepts an A2UI `createSurface` message as JSON,
/// validates it against the catalog, and makes it available for rendering.
class SurfaceTool extends ToolDef {
  final SurfaceCatalog catalog;

  SurfaceTool({required this.catalog});

  @override
  String get name => kSurfaceToolName;

  @override
  String get description =>
      'Create an interactive UI surface in the chat flow. '
      'The surface is rendered inline using the registered component catalog. '
      'Pass the A2UI createSurface payload directly as the "surface" '
      'argument value — do NOT wrap it in another object. '
      'The payload must have "surfaceId", "catalogId", and "components" '
      'at the top level. '
      'The surface appears in the chat bubble — the user can see it '
      'immediately. For interactive surfaces (with buttons, inputs), '
      'the user\'s actions are sent back as tool results.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'required': ['surface'],
    'properties': {
      'surface': {
        'type': 'object',
        'description':
            'The A2UI createSurface payload. Must contain '
            '"surfaceId", "catalogId", and "components".',
        'properties': {
          'surfaceId': {
            'type': 'string',
            'description': 'Unique identifier for this surface.',
          },
          'catalogId': {
            'type': 'string',
            'description':
                'Catalog version identifier. Must be '
                '"${catalog.catalogId}".',
          },
          'components': {
            'type': 'array',
            'description':
                'Flat list of components (adjacency list). '
                'Must include a component with id "root".',
            'items': {'type': 'object'},
          },
          'dataModel': {
            'type': 'object',
            'description':
                'Initial data model values, keyed by field name.',
          },
        },
      },
    },
  };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> args,
    ToolContext ctx,
  ) async {
    var surfaceArg = args['surface'];
    if (surfaceArg is! Map<String, dynamic>) {
      return ToolResult.error(
        'Invalid surface: expected an object with "surfaceId", '
        '"catalogId", and "components".',
      );
    }

    // Defensive unwrap: some models double-wrap the parameter,
    // producing {"surface": {"surface": {...}}}. Peel one layer
    // when the inner value is also a Map with surface-like keys.
    if (surfaceArg['surface'] is Map<String, dynamic> &&
        surfaceArg['surfaceId'] == null) {
      surfaceArg = surfaceArg['surface'] as Map<String, dynamic>;
    }

    final surface = CreateSurface.fromJson(surfaceArg);
    if (surface == null) {
      return ToolResult.error(
        'Invalid surface: could not parse. Required fields: '
        '"surfaceId" (string), "catalogId" (string), '
        '"components" (array of {"id": ..., "component": ...}).',
      );
    }

    // Validate against the catalog.
    final errors = catalog.validate(surface);
    if (errors.isNotEmpty) {
      final errorList = errors.map((e) => '  - $e').join('\n');
      return ToolResult.error(
        'Surface validation failed:\n$errorList\n\n'
        'Available component types: ${catalog.typeNames.join(', ')}',
      );
    }

    return ToolResult(
      title: 'Surface',
      output:
          'Surface "${surface.surfaceId}" created '
          '(${surface.components.length} components).',
    );
  }

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final surfaceArg = args['surface'];
    String surfaceId = '?';
    int componentCount = 0;

    if (surfaceArg is Map<String, dynamic>) {
      surfaceId = surfaceArg['surfaceId']?.toString() ?? '?';
      final components = surfaceArg['components'];
      if (components is List) componentCount = components.length;
    }

    return CollapsedSummary(
      text: 'surface "$surfaceId" ($componentCount components)',
      argsTokens: 0,
      totalTokens: 0,
    );
  }
}

/// Try to parse a [CreateSurface] from a tool call's input args.
///
/// This is the primary way the UI layer extracts surface data for
/// rendering — the tool call's `input` map persists with the message,
/// so the surface can be reconstructed at render time.
CreateSurface? surfaceFromToolCall(Map<String, dynamic> toolCallInput) {
  var surfaceArg = toolCallInput['surface'];
  if (surfaceArg is! Map<String, dynamic>) return null;

  // Same defensive unwrap as in execute().
  if (surfaceArg['surface'] is Map<String, dynamic> &&
      surfaceArg['surfaceId'] == null) {
    surfaceArg = surfaceArg['surface'] as Map<String, dynamic>;
  }

  return CreateSurface.fromJson(surfaceArg);
}
