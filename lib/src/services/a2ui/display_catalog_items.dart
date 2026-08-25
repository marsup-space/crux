/// A2UI display catalog items for Crux — data-driven components.
///
/// These are Crux extensions beyond the A2UI basic catalog, aimed at
/// terminal-native data display:
///
///   * `Table`       — column-aligned grid with header, `stringWidth()`
///                     driven column sizing (CJK = 2 columns)
///   * `ProgressBar` — numeric range indicator, wraps nocterm's
///                     `ProgressBar` render object
///   * `List`        — scrollable list of row components, height-capped
///                     to keep chat bubbles compact
///
/// All three support `{"path": "/field"}` data binding — pair them with
/// the `surface_update` tool to push live progress/task data into a
/// mounted surface.
library;

import 'package:nocterm/nocterm.dart';

import '../../theme/crux_theme.dart';
import '../../utils/text_width.dart';
import 'basic_catalog_items.dart' show resolveValue;
import 'models.dart';
import 'surface_catalog.dart';

// ---------------------------------------------------------------------------
// Table
// ---------------------------------------------------------------------------

/// A2UI `Table` component (Crux extension) — column-aligned data grid.
///
/// Rows come from a single source of truth (a data binding or a literal)
/// so `surface_update` can push new rows without re-declaring components.
///
/// Properties:
/// - `columns` (array, required): `[{"header": "Name", "key": "name"}]`.
///   Optional `width` overrides natural (max-content) column width.
/// - `rows` (array | binding, required): list of row objects keyed by
///   column `key`. Supports `{"path": "/items"}` binding.
class TableCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Table';

  @override
  String get description =>
      'Column-aligned table with a header row. Values are padded to '
      'terminal-column width, so CJK text aligns correctly.';

  @override
  Map<String, dynamic> get propertiesSchema => {
        'columns': {
          'type': 'array',
          'description':
              'Column definitions: [{"header": "File", "key": "file", '
              '"width": 20}]. `width` is optional (natural width by '
              'default).',
          'items': {
            'type': 'object',
            'properties': {
              'header': {'type': 'string'},
              'key': {'type': 'string'},
              'width': {'type': 'number'},
            },
            'required': ['header', 'key'],
          },
        },
        'rows': {
          'type': 'array',
          'description':
              'Row objects keyed by column `key`. Can be a literal list '
              'or {"path": "/field"} — the latter lets surface_update '
              'push live rows.',
          'items': {'type': 'object'},
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
    final theme = CruxTheme.of(context);

    // Parse column definitions.
    final columnsRaw = component.properties['columns'];
    final columns = <({String header, String key, int? width})>[];
    if (columnsRaw is List) {
      for (final c in columnsRaw) {
        if (c is Map<String, dynamic>) {
          final header = c['header']?.toString() ?? '';
          final key = c['key']?.toString() ?? '';
          if (header.isEmpty || key.isEmpty) continue;
          final w = c['width'];
          columns.add((
            header: header,
            key: key,
            width: w is num ? w.toInt() : null,
          ));
        }
      }
    }

    // Resolve rows (literal or data-bound).
    final rowsRaw = resolveValue(component.properties['rows'], dataModel);
    final rows = <Map<String, dynamic>>[];
    if (rowsRaw is List) {
      for (final r in rowsRaw) {
        if (r is Map<String, dynamic>) rows.add(r);
      }
    }

    if (columns.isEmpty) {
      return Text(
        '[Table: no columns]',
        style: TextStyle(color: theme.error),
      );
    }

    // Compute column widths: natural = max(header, longest cell) with a
    // 20-col safety cap per column; explicit `width` wins.
    final widths = List<int>.filled(columns.length, 0);
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].width != null) {
        widths[i] = columns[i].width!;
        continue;
      }
      var w = stringWidth(columns[i].header);
      for (final row in rows) {
        final cell = row[columns[i].key]?.toString() ?? '';
        final cw = stringWidth(cell);
        if (cw > w) w = cw;
      }
      widths[i] = w > 20 ? 20 : w;
    }

    Component headerRow() => Row(
          children: [
            for (var i = 0; i < columns.length; i++)
              Text(
                _padCell(columns[i].header, widths[i]),
                style: TextStyle(
                  color: theme.secondary,
                  fontWeight: FontWeight.bold,
                ),
              ),
          ],
        );

    Component dataRow(Map<String, dynamic> row) => Row(
          children: [
            for (var i = 0; i < columns.length; i++)
              Text(
                _padCell(row[columns[i].key]?.toString() ?? '', widths[i]),
                style: TextStyle(color: theme.foreground),
              ),
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        headerRow(),
        for (final row in rows) dataRow(row),
      ],
    );
  }

  /// Pad a cell to [width] terminal columns, truncating with `…` when
  /// the content overflows. Uses `stringWidth`, so CJK padding is exact.
  static String _padCell(String text, int width) {
    final w = stringWidth(text);
    if (w > width) {
      // Truncate to width - 1 columns + ellipsis (1 col).
      var acc = 0;
      final buf = StringBuffer();
      for (final rune in text.runes) {
        final ch = String.fromCharCode(rune);
        final cw = stringWidth(ch);
        if (acc + cw > width - 1) break;
        buf.write(ch);
        acc += cw;
      }
      return '$buf…';
    }
    return padToWidth(text, width);
  }
}

// ---------------------------------------------------------------------------
// ProgressBar
// ---------------------------------------------------------------------------

/// A2UI `ProgressBar` component (Crux extension) — numeric progress.
///
/// Unlike the agent-side convention of hand-rolling `####----` character
/// art in Text, this component sizes to available width and follows the
/// host theme.
///
/// Properties:
/// - `value` (number | binding, optional): progress fraction 0..1.
/// - `label` (string | binding, optional): text drawn inside the bar.
/// - `indeterminate` (bool, optional): animated pulse (no value needed).
/// - `showPercentage` (bool, optional, default false).
class ProgressBarCatalogItem extends CatalogItem {
  @override
  String get typeName => 'ProgressBar';

  @override
  String get description =>
      'Horizontal progress bar. `value` is a 0..1 fraction or '
      '{"path": "/field"} — pair with surface_update to show live '
      'progress of long-running work.';

  @override
  Map<String, dynamic> get propertiesSchema => {
        'value': {
          'type': 'number',
          'description':
              'Progress fraction 0..1. Can be {"path": "/field"}. '
              'Omit for an indeterminate bar.',
        },
        'label': {
          'type': 'string',
          'description':
              'Optional text drawn inside the bar '
              '(overrides the percentage readout).',
        },
        'indeterminate': {
          'type': 'boolean',
          'description': 'Animated "work in progress" pulse.',
        },
        'showPercentage': {
          'type': 'boolean',
          'description': 'Show "42%" centered in the bar. Default false.',
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
    final theme = CruxTheme.of(context);
    final valueRaw = resolveValue(component.properties['value'], dataModel);
    final labelRaw = component.properties['label'];
    final label = labelRaw == null
        ? null
        : resolveValue(labelRaw, dataModel)?.toString();
    final indeterminate = component.properties['indeterminate'] == true;
    final showPercentage = component.properties['showPercentage'] == true;

    double? value;
    if (valueRaw is num) {
      value = (valueRaw.toDouble()).clamp(0.0, 1.0);
    } else if (valueRaw is String) {
      value = double.tryParse(valueRaw)?.clamp(0.0, 1.0);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth.toInt()
            : 20;
        return SizedBox(
          width: width.toDouble(),
          child: ProgressBar(
            value: indeterminate ? null : value,
            indeterminate: indeterminate,
            label: label,
            showPercentage: showPercentage,
            valueColor: theme.success,
            backgroundColor: theme.borderSubtle,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

/// A2UI `List` component — scrollable list of row components.
///
/// Unlike Column (the full-height layout container), List caps its
/// height ([maxHeight], default 8) and scrolls, keeping chat bubbles
/// compact per the TUI height constraint. Keyboard navigation via
/// arrow keys when focused.
class ListCatalogItem extends CatalogItem {
  @override
  String get typeName => 'List';

  @override
  String get description =>
      'Scrollable list of row components, capped at maxHeight rows '
      '(default 8). Use instead of a tall Column when the row count is '
      'unbounded or large. Children scroll; keyboard arrows work.';

  @override
  Map<String, dynamic> get propertiesSchema => {
        'children': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Row component ids, in order.',
        },
        'maxHeight': {
          'type': 'number',
          'description':
              'Maximum visible rows before scrolling. Default 8.',
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
    final maxHeightRaw = component.properties['maxHeight'];
    final maxHeight =
        maxHeightRaw is num ? maxHeightRaw.toInt().clamp(1, 100) : 8;

    final children = <Component>[];
    if (childrenRaw is List) {
      for (final childId in childrenRaw) {
        if (childId is String) children.add(buildChild(childId));
      }
    }

    // Hard cap without a scroll view: a plain Column inside a SizedBox
    // clips silently on overflow, which is worse than scrolling. Use
    // ListView with lazy: false so children keep their state.
    return SizedBox(
      height: children.length < maxHeight
          ? maxHeight.toDouble()
          : null,
      child: children.length <= maxHeight
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            )
          : ListView(
              keyboardScrollable: true,
              lazy: false,
              children: children,
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Register the Crux display-extension catalog items into a
/// [SurfaceCatalog]: Table, ProgressBar, List.
void registerDisplayCatalogItems(SurfaceCatalog catalog) {
  catalog.register(TableCatalogItem());
  catalog.register(ProgressBarCatalogItem());
  catalog.register(ListCatalogItem());
}
