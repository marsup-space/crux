/// A2UI surface renderer for Crux.
///
/// The [SurfaceController] is a nocterm stateful component that receives a
/// [CreateSurface] declaration and renders it as a tree of nocterm
/// components. It resolves the A2UI adjacency-list model (flat list +
/// id references) into a widget tree, using the [SurfaceCatalog] to
/// look up component builders.
///
/// Phase 2: supports two-way data binding — input components (TextField,
/// CheckBox, ChoicePicker) write back to the local DataModel and trigger
/// re-render. Action components (Button) fire [onAction] callbacks.
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
///   onAction: (action) => handleAction(action),
/// )
/// ```
class SurfaceController extends StatefulComponent {
  /// The surface instance to render.
  final SurfaceInstance surface;

  /// The catalog to look up component builders from.
  final SurfaceCatalog catalog;

  /// Called when an interactive component triggers an action.
  /// Null for single-direction surfaces (Phase 1).
  final void Function(A2uiAction action)? onAction;

  /// Called when an interactive component mutates the data model.
  /// Null when data model updates don't need external notification.
  final void Function(String path, dynamic value)? onDataModelUpdate;

  const SurfaceController({
    super.key,
    required this.surface,
    required this.catalog,
    this.onAction,
    this.onDataModelUpdate,
  });

  @override
  State<SurfaceController> createState() => _SurfaceControllerState();
}

class _SurfaceControllerState extends State<SurfaceController> {
  /// Rebuild counter — incremented on every DataModel mutation so the
  /// component tree re-builds with the latest values.
  int _rebuildGeneration = 0;

  void _handleDataModelUpdate(String path, dynamic value) {
    component.surface.updateDataModel(path, value);
    component.onDataModelUpdate?.call(path, value);
    setState(() {
      _rebuildGeneration++;
    });
  }

  void _handleAction(A2uiAction action) {
    // Resolve any {"path": "/field"} references in the action context
    // against the current data model before sending.
    final resolvedContext = <String, dynamic>{};
    for (final entry in action.context.entries) {
      final binding = DataBinding.tryParse(entry.value);
      if (binding != null) {
        resolvedContext[entry.key] =
            binding.resolve(component.surface.dataModel);
      } else {
        resolvedContext[entry.key] = entry.value;
      }
    }

    final resolved = A2uiAction(
      name: action.name,
      surfaceId: action.surfaceId,
      sourceComponentId: action.sourceComponentId,
      context: resolvedContext,
    );

    // Mark the surface as submitted — disables further interaction and
    // freezes the data model so the surface shows exactly what was sent.
    component.surface.markSubmitted();

    component.onAction?.call(resolved);

    // Rebuild to reflect the submitted state (disabled components).
    setState(() {});
  }

  @override
  Component build(BuildContext context) {
    final root = component.surface.declaration.root;
    if (root == null) {
      return Text(
        'Surface "${component.surface.surfaceId}": no root component',
        style: TextStyle(color: CruxTheme.of(context).error),
      );
    }

    // The rebuild generation is intentionally unused in the build tree —
    // its sole purpose is to trigger setState so the build method re-runs
    // and data bindings re-resolve against the updated DataModel.
    final _ = _rebuildGeneration;

    return _buildComponent(context, root.id);
  }

  /// Recursively build a component by id, resolving children from the
  /// adjacency list.
  Component _buildComponent(BuildContext context, String componentId) {
    final comp = component.surface.declaration.componentById(componentId);
    if (comp == null) {
      return Text(
        '[unknown component: $componentId]',
        style: TextStyle(color: CruxTheme.of(context).error),
      );
    }

    final item = component.catalog.lookup(comp.component);
    if (item == null) {
      return Text(
        '[unregistered type: ${comp.component}]',
        style: TextStyle(color: CruxTheme.of(context).error),
      );
    }

    return item.build(
      context: context,
      component: comp,
      // Read from the frozen snapshot when submitted — the surface shows
      // exactly what was sent, not the (still-mutable) live model.
      dataModel: component.surface.renderDataModel,
      buildChild: (childId) => _buildComponent(context, childId),
      onAction: _handleAction,
      onDataModelUpdate: _handleDataModelUpdate,
      submitted: component.surface.submitted,
    );
  }
}
