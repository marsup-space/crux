/// A2UI basic catalog items for Crux.
///
/// Each item maps an A2UI component type to a nocterm component.
/// Aligned with the A2UI basic catalog semantics — type names, property
/// names, and data binding patterns follow the A2UI specification.
library;

import 'package:nocterm/nocterm.dart';

import '../../theme/crux_theme.dart';
import 'display_catalog_items.dart' show registerDisplayCatalogItems;
import 'interactive_catalog_items.dart';
import 'models.dart';
import 'surface_catalog.dart';

/// Resolve a property value, following data bindings if present.
///
/// If the value is a `{"path": "/field"}` map, resolve it from the
/// data model. Otherwise return the value as-is.
dynamic resolveValue(dynamic value, Map<String, dynamic> dataModel) {
  final binding = DataBinding.tryParse(value);
  if (binding != null) {
    return binding.resolve(dataModel);
  }
  return value;
}

/// Resolve a property value as a string, following data bindings.
String resolveString(dynamic value, Map<String, dynamic> dataModel) {
  final resolved = resolveValue(value, dataModel);
  if (resolved == null) return '';
  return resolved.toString();
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

/// A2UI `Text` component — renders text content.
///
/// In Crux, maps to nocterm's `Text` component. The text content can
/// be a literal string or a data-bound value.
class TextCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Text';

  @override
  String get description =>
      'Renders text content. Supports data binding via {"path": "/field"}.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'text': {
      'type': 'string',
      'description':
          'The text content. Can be a literal string or '
          '{"path": "/field"} for data binding.',
    },
  };

  @override
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted = false,
  }) {
    final text = resolveString(component.properties['text'], dataModel);
    return Text(text);
  }
}

// ---------------------------------------------------------------------------
// Column
// ---------------------------------------------------------------------------

/// A2UI `Column` component — vertical layout container.
///
/// Children are referenced by id in the `children` array.
class ColumnCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Column';

  @override
  String get description =>
      'Vertical layout container. Children are stacked top-to-bottom.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'children': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': 'List of child component ids, in order.',
    },
  };

  @override
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted = false,
  }) {
    final childrenRaw = component.properties['children'];
    final children = <Component>[];

    if (childrenRaw is List) {
      for (final childId in childrenRaw) {
        if (childId is String) {
          children.add(buildChild(childId));
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

// ---------------------------------------------------------------------------
// Row
// ---------------------------------------------------------------------------

/// A2UI `Row` component — horizontal layout container.
class RowCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Row';

  @override
  String get description =>
      'Horizontal layout container. Children are placed left-to-right.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'children': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': 'List of child component ids, in order.',
    },
  };

  @override
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted = false,
  }) {
    final childrenRaw = component.properties['children'];
    final children = <Component>[];

    if (childrenRaw is List) {
      for (final childId in childrenRaw) {
        if (childId is String) {
          children.add(buildChild(childId));
        }
      }
    }

    return Row(children: children);
  }
}

// ---------------------------------------------------------------------------
// Card
// ---------------------------------------------------------------------------

/// A2UI `Card` component — bordered container for grouping related content.
///
/// In Crux, maps to `DecoratedBox` with a border. Has a single child.
class CardCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Card';

  @override
  String get description =>
      'Bordered container for grouping related content. Has a single child.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'child': {
      'type': 'string',
      'description': 'The child component id.',
    },
    'title': {
      'type': 'string',
      'description':
          'Optional title shown in the card border. '
          'Can be a literal string or {"path": "/field"} for data binding.',
    },
  };

  @override
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted = false,
  }) {
    final childId = component.properties['child'];
    final title = resolveString(component.properties['title'], dataModel);

    Component child = const SizedBox();
    if (childId is String && childId.isNotEmpty) {
      child = buildChild(childId);
    }

    final theme = CruxTheme.of(context);
    final isInteractive = onAction != null;

    return _SurfaceCard(
      title: title,
      isInteractive: isInteractive,
      isSubmitted: submitted,
      theme: theme,
      child: child,
    );
  }
}

/// Internal stateful card that brightens its border on hover when
/// the surface is interactive (has action handlers). Submitted
/// surfaces fade to a subtle border — visually archival.
class _SurfaceCard extends StatefulComponent {
  final String title;
  final bool isInteractive;

  /// True when the owning surface has been submitted — the card
  /// renders with a subdued border and muted title.
  final bool isSubmitted;
  final CruxThemeData theme;
  final Component child;

  const _SurfaceCard({
    required this.title,
    required this.isInteractive,
    required this.isSubmitted,
    required this.theme,
    required this.child,
  });

  @override
  State<_SurfaceCard> createState() => _SurfaceCardState();
}

class _SurfaceCardState extends State<_SurfaceCard> {
  bool _hovered = false;

  @override
  Component build(BuildContext context) {
    final theme = component.theme;
    final borderColor = _hovered && component.isInteractive
        ? theme.accent
        : component.isSubmitted
        ? theme.borderSubtle
        : theme.borderActive;
    final titleColor =
        component.isSubmitted ? theme.textMuted : theme.secondary;

    return MouseRegion(
      onEnter: component.isInteractive
          ? (_) => setState(() => _hovered = true)
          : null,
      onExit: component.isInteractive
          ? (_) => setState(() => _hovered = false)
          : null,
      opaque: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: BoxBorder.all(
            color: borderColor,
            style: BoxBorderStyle.double,
          ),
          title: component.title.isNotEmpty
              ? BorderTitle(
                  text: component.title,
                  style: TextStyle(
                    color: titleColor,
                    fontWeight: FontWeight.bold,
                  ),
                )
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: component.child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Divider
// ---------------------------------------------------------------------------

/// A2UI `Divider` component — horizontal separator line.
class DividerCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Divider';

  @override
  String get description => 'Horizontal separator line.';

  @override
  Map<String, dynamic> get propertiesSchema => {};

  @override
  Component build({
    required BuildContext context,
    required A2uiComponent component,
    required Map<String, dynamic> dataModel,
    required Component Function(String childId) buildChild,
    void Function(A2uiAction action)? onAction,
    void Function(String path, dynamic value)? onDataModelUpdate,
    bool submitted = false,
  }) {
    return const Divider();
  }
}

// ---------------------------------------------------------------------------
// Registration helper
// ---------------------------------------------------------------------------

/// Register all basic catalog items into a [SurfaceCatalog].
///
/// Includes both display components (Text, Column, Row, Card, Divider)
/// and interactive components (Button, CheckBox, TextField, ChoicePicker).
SurfaceCatalog createBasicCatalog() {
  final catalog = SurfaceCatalog();
  catalog.register(TextCatalogItem());
  catalog.register(ColumnCatalogItem());
  catalog.register(RowCatalogItem());
  catalog.register(CardCatalogItem());
  catalog.register(DividerCatalogItem());
  registerInteractiveCatalogItems(catalog);
  registerDisplayCatalogItems(catalog);
  return catalog;
}
