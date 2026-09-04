/// A2UI basic catalog items for Crux.
///
/// Each item maps an A2UI component type to a nocterm component.
/// Aligned with the A2UI basic catalog semantics — type names, property
/// names, and data binding patterns follow the A2UI specification.
library;

import 'package:nocterm/nocterm.dart';

import '../../i18n/strings.dart';
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
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
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
      'Vertical layout container. Children are stacked top-to-bottom. '
      'Responsive: when ≥2 consecutive children are Cards and the '
      'terminal is wide enough, the host automatically flows them '
      'side-by-side into a row (equal widths) — the agent should just '
      'stack Cards in a Column and NOT wrap them in a Row manually.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'children': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': 'List of child component ids, in order.',
    },
    'align': {
      'type': 'string',
      'enum': ['stretch', 'start'],
      'description':
          'Cross-axis alignment. Default stretch; use start for compact forms.',
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
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
  }) {
    // unwrapListProperty: some providers wrap arrays as {"item": [...]}
    // or JSON-encode them as strings — normalize before the is List check.
    final childrenRaw = unwrapListProperty(component.properties['children']);
    final childIds = <String>[
      if (childrenRaw is List)
        for (final id in childrenRaw)
          if (id is String) id,
    ];

    // Host-side responsive layout: when the agent stacks several Cards
    // vertically, flow each run of ≥2 consecutive Cards into a
    // side-by-side Row whenever the terminal is wide enough. The agent
    // only declares content; the host owns presentation. Widths are
    // shared equally via Expanded; non-Card children break a run and
    // render stacked as before.
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 0.0;

        final children = <Component>[];
        var i = 0;
        while (i < childIds.length) {
          final id = childIds[i];
          if (childType?.call(id) == 'Card') {
            // Collect the run of consecutive Card ids.
            var j = i;
            while (j < childIds.length &&
                childType?.call(childIds[j]) == 'Card') {
              j++;
            }
            final runLength = j - i;
            // Each card needs ~36 columns to stay readable (border +
            // padding + a couple of table columns). Only flow when the
            // run fits and there are at least two cards to place.
            final fits =
                runLength >= 2 && maxWidth > 0 && maxWidth / runLength >= 36;
            if (fits) {
              children.add(
                Row(
                  children: [
                    for (var k = i; k < j; k++) ...[
                      if (k > i) const SizedBox(width: 2),
                      Expanded(child: buildChild(childIds[k])),
                    ],
                  ],
                ),
              );
            } else {
              for (var k = i; k < j; k++) {
                children.add(buildChild(childIds[k]));
              }
            }
            i = j;
          } else {
            children.add(buildChild(id));
            i++;
          }
        }

        return Column(
          crossAxisAlignment: component.properties['align'] == 'start'
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.stretch,
          children: children,
        );
      },
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
      'Horizontal layout container. Children are placed left-to-right. '
      'Use `gap` to control spacing between children.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'children': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': 'List of child component ids, in order.',
    },
    'gap': {
      'type': 'number',
      'description':
          'Horizontal spacing (columns) between children. Default 1.',
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
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
  }) {
    // unwrapListProperty: tolerate provider-mangled array wrappers.
    final childrenRaw = unwrapListProperty(component.properties['children']);
    final gap = coerceIntProperty(component.properties['gap'], 1).clamp(0, 20);

    final children = <Component>[];

    if (childrenRaw is List) {
      for (var i = 0; i < childrenRaw.length; i++) {
        final childId = childrenRaw[i];
        if (childId is String) {
          if (i > 0 && gap > 0) {
            children.add(SizedBox(width: gap.toDouble()));
          }
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
    'child': {'type': 'string', 'description': 'The child component id.'},
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
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
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

// ---------------------------------------------------------------------------
// Section
// ---------------------------------------------------------------------------

/// A titled grouping without Card chrome. Useful inside cards and compact
/// dashboard boxes where a second border would be visual noise.
class SectionCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Section';

  @override
  String get description =>
      'A lightweight titled group with one child and no border. Use inside a '
      'Card to divide related controls or facts.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'title': {'type': 'string', 'description': 'Section heading.'},
    'child': {'type': 'string', 'description': 'The single child id.'},
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
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
  }) {
    final title = resolveString(component.properties['title'], dataModel);
    final childId = component.properties['child'];
    final theme = CruxTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Text(
            title,
            style: TextStyle(
              color: theme.secondary,
              fontWeight: FontWeight.bold,
            ),
          ),
        if (title.isNotEmpty) const SizedBox(height: 1),
        if (childId is String && childId.isNotEmpty) buildChild(childId),
      ],
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
    // Submitted cards fade to the same muted grey-blue the vibe tool
    // boxes use (theme.toolPrefix). borderSubtle — the previous choice —
    // is near-black in most themes, which reads as "the card turned
    // off" rather than "archived"; textMuted stays visible while still
    // receding next to the accent border of live cards.
    final borderColor = _hovered && component.isInteractive
        ? theme.accent
        : component.isSubmitted
        ? theme.toolPrefix
        : theme.borderActive;
    final titleColor = component.isSubmitted
        ? theme.textMuted
        : theme.secondary;

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
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
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
  catalog.register(SectionCatalogItem());
  catalog.register(DividerCatalogItem());
  registerInteractiveCatalogItems(catalog);
  registerDisplayCatalogItems(catalog);
  return catalog;
}
