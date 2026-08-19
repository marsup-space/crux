/// A2UI surface renderer for Crux.
///
/// The [SurfaceController] is a nocterm component that receives a
/// [CreateSurface] declaration and renders it as a tree of nocterm
/// components. It resolves the A2UI adjacency-list model (flat list +
/// id references) into a widget tree, using the [SurfaceCatalog] to
/// look up component builders.
///
/// Phase 1: single-direction rendering only — no action handling,
/// no data model updates, no interactivity. Just render the tree.
library;

import 'package:nocterm/nocterm.dart';

import '../../theme/crux_theme.dart';
import 'models.dart';
import 'surface_catalog.dart';

/// Renders an A2UI surface as a nocterm component tree.
///
/// Usage:
/// ```dart
/// SurfaceController(
///   surface: createSurfaceInstance,
///   catalog: catalog,
/// )
/// ```
class SurfaceController extends StatelessComponent {
  /// The surface instance to render.
  final SurfaceInstance surface;

  /// The catalog to look up component builders from.
  final SurfaceCatalog catalog;

  /// Called when an interactive component triggers an action.
  /// Null for Phase 1 (single-direction surfaces).
  final void Function(A2uiAction action)? onAction;

  /// Called when an interactive component mutates the data model.
  /// Null for Phase 1.
  final void Function(String path, dynamic value)? onDataModelUpdate;

  const SurfaceController({
    super.key,
    required this.surface,
    required this.catalog,
    this.onAction,
    this.onDataModelUpdate,
  });

  @override
  Component build(BuildContext context) {
    final root = surface.declaration.root;
    if (root == null) {
      return Text(
        'Surface "${surface.surfaceId}": no root component',
        style: TextStyle(color: CruxTheme.of(context).error),
      );
    }

    return _buildComponent(context, root.id);
  }

  /// Recursively build a component by id, resolving children from the
  /// adjacency list.
  Component _buildComponent(BuildContext context, String componentId) {
    final component = surface.declaration.componentById(componentId);
    if (component == null) {
      return Text(
        '[unknown component: $componentId]',
        style: TextStyle(color: CruxTheme.of(context).error),
      );
    }

    final item = catalog.lookup(component.component);
    if (item == null) {
      return Text(
        '[unregistered type: ${component.component}]',
        style: TextStyle(color: CruxTheme.of(context).error),
      );
    }

    return item.build(
      context: context,
      component: component,
      dataModel: surface.dataModel,
      buildChild: (childId) => _buildComponent(context, childId),
      onAction: onAction,
      onDataModelUpdate: onDataModelUpdate,
      submitted: surface.submitted,
    );
  }
}
