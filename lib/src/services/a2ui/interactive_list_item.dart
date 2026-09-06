/// Interactive A2UI ListItem catalog item for Crux.
///
/// List rows are also used by app-owned hosts such as the home dashboard.
/// Keeping interaction here, separate from display_catalog_items.dart, lets
/// the display catalog remain focused on non-interactive visual primitives.
library;

import 'package:nocterm/nocterm.dart';

import '../../i18n/strings.dart';
import '../../theme/crux_theme.dart';
import 'basic_catalog_items.dart' show resolveString;
import 'models.dart';
import 'surface_catalog.dart';

class ListItemCatalogItem extends CatalogItem {
  @override
  String get typeName => 'ListItem';

  @override
  String get description =>
      'A selectable list row with optional leading marker, detail and badge.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'title': {'type': 'string', 'description': 'Primary row text.'},
    'leading': {
      'type': 'string',
      'description':
          'Optional compact leading marker, such as an icon or state.',
    },
    'detail': {'type': 'string', 'description': 'Optional secondary text.'},
    'inline': {
      'type': 'boolean',
      'description':
          'Keep title and detail on one row. Useful for compact action lists.',
    },
    'badge': {'type': 'string', 'description': 'Optional trailing status.'},
    'selected': {
      'type': 'boolean',
      'description': 'Whether the host currently selects this row.',
    },
    'action': {
      'type': 'object',
      'description':
          'Optional click action: {"event":{"name":"open","context":{}}}.',
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
    final action = _parseAction(component.properties['action']);
    return _SurfaceListItem(
      title: resolveString(component.properties['title'], dataModel),
      leading: resolveString(component.properties['leading'], dataModel),
      detail: resolveString(component.properties['detail'], dataModel),
      badge: resolveString(component.properties['badge'], dataModel),
      inline: component.properties['inline'] == true,
      selected: component.properties['selected'] == true,
      sourceComponentId: component.id,
      action: action,
      onAction: submitted ? null : onAction,
      theme: CruxTheme.of(context),
    );
  }

  _ListItemAction? _parseAction(dynamic raw) {
    if (raw is! Map<String, dynamic>) return null;
    final event = raw['event'];
    if (event is! Map<String, dynamic>) return null;
    final name = event['name'];
    if (name is! String || name.isEmpty) return null;
    final context = event['context'];
    return _ListItemAction(
      name: name,
      context: context is Map<String, dynamic> ? context : const {},
    );
  }
}

class _ListItemAction {
  final String name;
  final Map<String, dynamic> context;

  const _ListItemAction({required this.name, required this.context});
}

class _SurfaceListItem extends StatefulComponent {
  final String title;
  final String leading;
  final String detail;
  final String badge;
  final bool inline;
  final bool selected;
  final String sourceComponentId;
  final _ListItemAction? action;
  final void Function(A2uiAction action)? onAction;
  final CruxThemeData theme;

  const _SurfaceListItem({
    required this.title,
    required this.leading,
    required this.detail,
    required this.badge,
    required this.inline,
    required this.selected,
    required this.sourceComponentId,
    required this.action,
    required this.onAction,
    required this.theme,
  });

  @override
  State<_SurfaceListItem> createState() => _SurfaceListItemState();
}

class _SurfaceListItemState extends State<_SurfaceListItem> {
  bool _hovered = false;

  bool get _isActive => component.action != null && component.onAction != null;

  void _activate() {
    final action = component.action;
    final onAction = component.onAction;
    if (action == null || onAction == null) return;
    onAction(
      A2uiAction(
        name: action.name,
        surfaceId: component.sourceComponentId,
        sourceComponentId: component.sourceComponentId,
        context: action.context,
      ),
    );
  }

  @override
  Component build(BuildContext context) {
    final theme = component.theme;
    final highlighted = component.selected || _hovered;
    final titleColor = highlighted ? theme.selectedText : theme.onSurface;
    final secondaryColor = highlighted
        ? theme.selectedText
        : theme.onSurfaceDim;

    final row = Container(
      color: highlighted ? theme.selection : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (component.leading.isNotEmpty) ...[
            Text(component.leading, style: TextStyle(color: secondaryColor)),
            const SizedBox(width: 1),
          ],
          Expanded(
            child: component.inline
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        component.title,
                        style: TextStyle(color: titleColor),
                      ),
                      if (component.detail.isNotEmpty)
                        Expanded(
                          child: Text(
                            '  ${component.detail}',
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: secondaryColor),
                          ),
                        ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        component.title,
                        style: TextStyle(color: titleColor),
                      ),
                      if (component.detail.isNotEmpty)
                        Text(
                          component.detail,
                          style: TextStyle(color: secondaryColor),
                        ),
                    ],
                  ),
          ),
          if (component.badge.isNotEmpty) ...[
            const SizedBox(width: 1),
            Text(
              component.badge,
              style: TextStyle(
                color: highlighted ? theme.selectedText : theme.secondary,
              ),
            ),
          ],
        ],
      ),
    );

    if (!_isActive) return row;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      opaque: false,
      child: GestureDetector(
        onTap: _activate,
        behavior: HitTestBehavior.opaque,
        child: row,
      ),
    );
  }
}
