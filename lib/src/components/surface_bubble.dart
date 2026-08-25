/// Inline surface renderer for chat message bubbles.
///
/// When a tool call is a `surface` tool invocation, this component
/// renders the A2UI surface inline below the collapsed tool-call row.
/// It parses the surface declaration from the tool call's input args
/// and delegates rendering to [SurfaceController].
library;

import 'package:nocterm/nocterm.dart';

import '../models/message.dart';
import '../services/a2ui/models.dart';
import '../services/a2ui/surface_catalog.dart';
import '../services/a2ui/surface_controller.dart';
import '../theme/crux_theme.dart';
import '../tools/surface_tool.dart';

/// Renders an A2UI surface inline in the chat flow.
///
/// Parses the surface declaration from [toolCall]'s input and renders
/// it via [SurfaceController]. Returns an error message if the surface
/// data is invalid or missing.
class SurfaceBubble extends StatelessComponent {
  /// The tool call data containing the surface declaration.
  final ToolCallData toolCall;

  /// The catalog to resolve component types from.
  final SurfaceCatalog catalog;

  /// Called when an interactive component triggers an action.
  final void Function(A2uiAction action)? onAction;

  /// Called when an interactive component mutates the data model.
  final void Function(String path, dynamic value)? onDataModelUpdate;

  const SurfaceBubble({
    super.key,
    required this.toolCall,
    required this.catalog,
    this.onAction,
    this.onDataModelUpdate,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final surface = surfaceFromToolCall(toolCall.input);

    if (surface == null) {
      return Padding(
        padding: const EdgeInsets.only(left: 2),
        child: Text(
          'surface: invalid declaration',
          style: TextStyle(color: theme.error),
        ),
      );
    }

    // Validate against the catalog.
    final errors = catalog.validate(surface);
    if (errors.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(left: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'surface "${surface.surfaceId}": validation errors',
              style: TextStyle(color: theme.error),
            ),
            for (final e in errors)
              Text(
                '  $e',
                style: TextStyle(color: theme.textMuted),
              ),
          ],
        ),
      );
    }

    // Use the catalog's instance registry so interactive state (DataModel
    // edits, submitted flag) survives chat-list rebuilds. The tool call's
    // callId is a stable key — the same logical surface always maps to the
    // same instance.
    final instance = catalog.instanceFor(toolCall.callId, surface);

    // Wrap in a subtle background tint so surfaces visually lift from the
    // plain message flow — a surface is an interactive artifact, not prose.
    // Horizontal padding keeps the Card border inset from the tint edge;
    // vertical padding (1 line above/below) separates the surface from
    // surrounding message prose. An extra blank line below the tinted box
    // (outside the background) acts as a margin, so the next message or
    // tool call doesn't sit flush against the tinted edge.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(color: theme.surface),
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
          child: Padding(
            padding: const EdgeInsets.only(left: 1, top: 0),
            child: SurfaceController(
              surface: instance,
              catalog: catalog,
              onAction: onAction,
              onDataModelUpdate: onDataModelUpdate,
            ),
          ),
        ),
        const SizedBox(height: 1),
      ],
    );
  }
}
