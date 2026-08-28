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

  @override
  void initState() {
    super.initState();
    // External mutations (surface_update tool calls writing into the
    // DataModel) notify here so mounted surfaces re-render live.
    component.surface.addListener(_onSurfaceChanged);
  }

  @override
  void didUpdateComponent(SurfaceController oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.surface != component.surface) {
      oldComponent.surface.removeListener(_onSurfaceChanged);
      component.surface.addListener(_onSurfaceChanged);
    }
  }

  @override
  void dispose() {
    component.surface.removeListener(_onSurfaceChanged);
    super.dispose();
  }

  void _onSurfaceChanged() {
    if (mounted) setState(() {});
  }

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

    // Components cannot know the surface id — CatalogItem.build has no
    // surfaceId parameter, so interactive items fill it with their own
    // component id (e.g. "submitBtn"). Override it here, at the single
    // exit point every action passes through, with the real surface id.
    // Without this, the persisted action message records the component
    // id in its "surface:" field and state restoration after a restart
    // (instanceById) never finds the surface.
    final resolved = A2uiAction(
      name: action.name,
      surfaceId: component.surface.surfaceId,
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

    final submitted = component.surface.submitted;

    return item.build(
      context: context,
      component: comp,
      dataModel: component.surface.renderDataModel,
      buildChild: (childId) => _buildComponent(context, childId),
      // Submitted surfaces are read-only: cut the interaction callbacks
      // so buttons/checkboxes/fields render disabled and ignore input.
      onAction: submitted ? null : _handleAction,
      onDataModelUpdate: submitted ? null : _handleDataModelUpdate,
      submitted: submitted,
      // Lets layout containers make type-aware decisions (Column
      // auto-flowing sibling Cards into a row on wide terminals).
      childType: (childId) =>
          component.surface.declaration.componentById(childId)?.component,
    );
  }
}
