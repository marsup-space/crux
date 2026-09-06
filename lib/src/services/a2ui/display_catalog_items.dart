/// A2UI display catalog items for Crux — data-driven components.
///
/// These are Crux extensions beyond the A2UI basic catalog, aimed at
/// terminal-native data display:
///
///   * `Table`       — column-aligned grid with header, `stringWidth()`
///                     driven column sizing (CJK = 2 columns)
///   * `ProgressBar` — numeric range indicator; a custom render object
///                     (mirroring ContextBar) that paints `width × 1`
///                     fixed-size cells directly on the canvas, so a
///                     CJK label can never blow the bar past its slot
///                     the way widget-composed cells could
///   * `List`        — scrollable list of row components, height-capped
///                     to keep chat bubbles compact
///
/// All three support `{"path": "/field"}` data binding — pair them with
/// the `surface_update` tool to push live progress/task data into a
/// mounted surface.
library;

import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';

import '../../theme/crux_theme.dart';
import '../../utils/text_width.dart';
import '../../i18n/strings.dart';
// For TerminalCanvas — the custom ProgressBar render object paints
// per-cell backgrounds directly, mirroring ContextBar.
// ignore_for_file: implementation_imports
import 'package:nocterm/src/framework/terminal_canvas.dart';
import 'basic_catalog_items.dart' show resolveString, resolveValue;
import 'interactive_list_item.dart' show ListItemCatalogItem;
import 'models.dart';
import 'surface_catalog.dart';

// ---------------------------------------------------------------------------
// KeyValue
// ---------------------------------------------------------------------------

/// A compact aligned label/value row for dashboards and inspectors.
///
/// This is deliberately a presentation primitive, not a form control. Hosts
/// own keyboard focus and action routing; `selected` merely mirrors their
/// current selection into the shared surface syntax.
class KeyValueCatalogItem extends CatalogItem {
  @override
  String get typeName => 'KeyValue';

  @override
  String get description =>
      'A compact label/value row for facts and settings. `selected` renders '
      'the host selection state; it does not create an action by itself.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'label': {'type': 'string', 'description': 'Left-hand label.'},
    'value': {
      'type': 'string',
      'description': 'Right-hand value. Supports {"path": "/field"}.',
    },
    'labelWidth': {
      'type': 'number',
      'description': 'Optional terminal-column width for aligned labels.',
    },
    'selected': {
      'type': 'boolean',
      'description': 'Whether the host currently selects this row.',
    },
    'action': {
      'type': 'object',
      'description':
          'Optional click action: {"event":{"name":"open","context":{}}}.',
    },
    'muted': {
      'type': 'boolean',
      'description': 'Render the value as read-only/muted.',
    },
    'tone': {
      'type': 'string',
      'enum': ['neutral', 'info', 'success', 'warning', 'error'],
      'description': 'Optional semantic color for the value.',
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
    final theme = CruxTheme.of(context);
    final label =
        resolveValue(component.properties['label'], dataModel)?.toString() ??
        '';
    final value =
        resolveValue(component.properties['value'], dataModel)?.toString() ??
        '';
    final selected = component.properties['selected'] == true;
    final action = _listItemAction(component.properties['action']);
    final muted = component.properties['muted'] == true;
    final tone = component.properties['tone'];
    final labelWidth = coerceIntProperty(
      component.properties['labelWidth'],
      stringWidth(label),
    );
    final labelColor = selected ? theme.selectedText : theme.onSurfaceDim;
    final valueColor = selected
        ? theme.selectedText
        : muted
        ? theme.onSurfaceDim
        : switch (tone) {
            'success' => theme.successColor,
            'warning' => theme.warningColor,
            'error' => theme.errorColor,
            'info' => theme.info,
            _ => theme.onSurfaceVariant,
          };

    final row = Container(
      color: selected ? theme.selection : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            padToWidth(label, labelWidth),
            style: TextStyle(color: labelColor),
          ),
          Text('  $value', style: TextStyle(color: valueColor)),
        ],
      ),
    );
    if (action == null || onAction == null || submitted) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onAction(
        A2uiAction(
          name: action.name,
          surfaceId: component.id,
          sourceComponentId: component.id,
          context: action.context,
        ),
      ),
      child: row,
    );
  }
}

({String name, Map<String, dynamic> context})? _listItemAction(dynamic raw) {
  if (raw is! Map<String, dynamic>) return null;
  final event = raw['event'];
  if (event is! Map<String, dynamic>) return null;
  final name = event['name'];
  if (name is! String || name.isEmpty) return null;
  final context = event['context'];
  return (
    name: name,
    context: context is Map<String, dynamic> ? context : const {},
  );
}

/// A compact status chip. `tone` is semantic, so the same declaration adapts
/// to every host theme rather than hard-coding terminal colors.
class BadgeCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Badge';

  @override
  String get description => 'A compact semantic status chip.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'text': {'type': 'string', 'description': 'Badge text.'},
    'tone': {
      'type': 'string',
      'enum': ['neutral', 'info', 'success', 'warning', 'error'],
      'description': 'Semantic color. Default neutral.',
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
    final theme = CruxTheme.of(context);
    final tone = component.properties['tone'];
    final color = switch (tone) {
      'success' => theme.success,
      'warning' => theme.warning,
      'error' => theme.error,
      'info' => theme.info,
      _ => theme.surfaceVariant,
    };
    final foreground = tone == 'neutral' || tone == null
        ? theme.onSurfaceVariant
        : theme.onColor(color);
    return Container(
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Text(
        resolveString(component.properties['text'], dataModel),
        style: TextStyle(color: foreground, fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// A prominent value with a small label, for token, count and quota metrics.
class StatCatalogItem extends CatalogItem {
  @override
  String get typeName => 'Stat';

  @override
  String get description => 'A prominent metric value with a small label.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'label': {'type': 'string', 'description': 'Metric label.'},
    'value': {'type': 'string', 'description': 'Metric value.'},
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
    final theme = CruxTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          resolveString(component.properties['value'], dataModel),
          style: TextStyle(color: theme.accent, fontWeight: FontWeight.bold),
        ),
        Text(
          resolveString(component.properties['label'], dataModel),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// BarList
// ---------------------------------------------------------------------------

/// A compact ranked list of labeled progress bars. Covers usage breakdowns,
/// provider quotas, and per-model token distributions without introducing a
/// charting dependency into terminal hosts.
class BarListCatalogItem extends CatalogItem {
  @override
  String get typeName => 'BarList';

  @override
  String get description =>
      'A responsive list of labeled 0..1 progress bars. Use for model token '
      'breakdowns, usage windows, or ranked work queues.';

  @override
  Map<String, dynamic> get propertiesSchema => {
    'rows': {
      'type': 'array',
      'description':
          'Rows: [{"label":"Claude","value":0.72,"detail":"72k",'
          '"tone":"success"}]. `value` is a 0..1 fraction.',
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
    final raw = unwrapListProperty(
      resolveValue(component.properties['rows'], dataModel),
    );
    final rows = <({String label, double value, String detail, String tone})>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map<String, dynamic>) continue;
        final value = item['value'];
        final fraction = value is num
            ? value.toDouble()
            : double.tryParse(value?.toString() ?? '') ?? 0;
        rows.add((
          label: item['label']?.toString() ?? '',
          value: fraction.clamp(0.0, 1.0),
          detail: item['detail']?.toString() ?? '',
          tone: item['tone']?.toString() ?? 'success',
        ));
      }
    }
    if (rows.isEmpty) return const Text('—');
    return _SurfaceBarList(rows: rows, theme: CruxTheme.of(context));
  }
}

class _SurfaceBarList extends StatelessComponent {
  final List<({String label, double value, String detail, String tone})> rows;
  final CruxThemeData theme;

  const _SurfaceBarList({required this.rows, required this.theme});

  @override
  Component build(BuildContext context) {
    final labelWidth = rows
        .fold<int>(0, (width, row) => math.max(width, stringWidth(row.label)))
        .clamp(1, 16);
    final detailWidth = rows
        .fold<int>(0, (width, row) => math.max(width, stringWidth(row.detail)))
        .clamp(0, 12);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth.floor()
            : 40;
        final trackWidth = math.max(
          6,
          available - labelWidth - detailWidth - 3,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final row in rows)
              _BarListRow(
                row: row,
                labelWidth: labelWidth,
                detailWidth: detailWidth,
                trackWidth: trackWidth,
                theme: theme,
              ),
          ],
        );
      },
    );
  }
}

class _BarListRow extends StatelessComponent {
  final ({String label, double value, String detail, String tone}) row;
  final int labelWidth;
  final int detailWidth;
  final int trackWidth;
  final CruxThemeData theme;

  const _BarListRow({
    required this.row,
    required this.labelWidth,
    required this.detailWidth,
    required this.trackWidth,
    required this.theme,
  });

  @override
  Component build(BuildContext context) {
    final filled = (trackWidth * row.value).round().clamp(0, trackWidth);
    final color = switch (row.tone) {
      'warning' => theme.warning,
      'error' => theme.error,
      'info' => theme.info,
      _ => theme.success,
    };
    return Row(
      children: [
        Text(
          padToWidth(_truncateToWidth(row.label, labelWidth), labelWidth),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
        const Text(' '),
        Text('█' * filled, style: TextStyle(color: color)),
        Text(
          '░' * (trackWidth - filled),
          style: TextStyle(color: theme.borderSubtle),
        ),
        if (detailWidth > 0) ...[
          const Text(' '),
          Text(
            padToWidth(_truncateToWidth(row.detail, detailWidth), detailWidth),
            style: TextStyle(color: theme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

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
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
  }) {
    final theme = CruxTheme.of(context);

    // Parse column definitions. unwrapListProperty tolerates the
    // {"item": [...]} array wrapper some providers emit.
    final columnsRaw = unwrapListProperty(component.properties['columns']);
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

    // Resolve rows (literal or data-bound); unwrap provider-mangled arrays.
    final rowsRaw = unwrapListProperty(
      resolveValue(component.properties['rows'], dataModel),
    );
    final rows = <Map<String, dynamic>>[];
    if (rowsRaw is List) {
      for (final r in rowsRaw) {
        if (r is Map<String, dynamic>) rows.add(r);
      }
    }

    if (columns.isEmpty) {
      return Text('[Table: no columns]', style: TextStyle(color: theme.error));
    }

    // Compute natural column widths: max(header, longest cell) with a
    // 20-col safety cap per column; explicit `width` wins.
    final natural = List<int>.filled(columns.length, 0);
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].width != null) {
        natural[i] = columns[i].width!;
        continue;
      }
      var w = stringWidth(columns[i].header);
      for (final row in rows) {
        final cell = row[columns[i].key]?.toString() ?? '';
        final cw = stringWidth(cell);
        if (cw > w) w = cw;
      }
      natural[i] = w > 20 ? 20 : w;
    }

    // Fit the table to the available width. In a tight container (an
    // Expanded inside a side-by-side Card row, a narrow terminal) the
    // natural widths can overflow — shrink columns proportionally so
    // the table respects the constraint instead of blowing out the
    // Card border and pushing siblings off screen.
    return LayoutBuilder(
      builder: (context, constraints) {
        final widths = List<int>.from(natural);
        if (constraints.maxWidth.isFinite) {
          final avail = constraints.maxWidth.floor();
          // Keep a visible gutter between data columns. Without it, a cell
          // that exactly fills its natural width runs into the next value
          // (`Pluginsnext`), which is especially confusing in compact cards.
          const columnGap = 2;
          var total =
              widths.fold(0, (a, b) => a + b) +
              (columns.length - 1) * columnGap;
          if (total > avail && avail >= columns.length * 3) {
            // Shrink round-robin from the widest columns until we fit,
            // never below 3 cols (2 content + ellipsis stays readable).
            while (total > avail) {
              var widest = 0;
              for (var i = 1; i < widths.length; i++) {
                if (widths[i] > widths[widest]) widest = i;
              }
              if (widths[widest] <= 3) break;
              widths[widest]--;
              total--;
            }
          }
        }

        Component headerRow() => Row(
          children: [
            for (var i = 0; i < columns.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Text(
                _padCell(columns[i].header, widths[i]),
                style: TextStyle(
                  color: theme.secondary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        );

        Component dataRow(Map<String, dynamic> row) => Row(
          children: [
            for (var i = 0; i < columns.length; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Text(
                _padCell(row[columns[i].key]?.toString() ?? '', widths[i]),
                style: TextStyle(color: theme.foreground),
              ),
            ],
          ],
        );

        // Height autonomy: the host caps how many rows a table may
        // contribute to the chat flow, regardless of how many the agent
        // declared. A long table folds behind a toggle row instead of
        // pushing the conversation off screen — the agent declares
        // content, the host owns layout (vertically too).
        const foldBudget = 12;
        if (rows.length <= foldBudget) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [headerRow(), for (final row in rows) dataRow(row)],
          );
        }

        return _FoldableTable(
          header: headerRow(),
          rows: [for (final row in rows) dataRow(row)],
          hiddenCount: rows.length - foldBudget,
          strings: strings,
        );
      },
    );
  }

  /// Pad a cell to [width] terminal columns, truncating with `…` when
  /// the content overflows. Uses `stringWidth`, so CJK padding is exact.
  static String _padCell(String text, int width) =>
      padToWidth(_truncateToWidth(text, width), width);
}

/// Truncate [text] to at most [width] terminal columns, ending with `…`
/// when truncation occurred. A wide rune that straddles the limit is
/// dropped rather than half-drawn; the result can therefore end up a
/// column short, so callers still need to pad afterwards when the exact
/// width matters (see `_padCell`).
String _truncateToWidth(String text, int width) {
  if (stringWidth(text) <= width) return text;
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

/// A Table whose row count exceeds the host's fold budget. Shows the
/// first [budget] rows plus a toggle row; clicking it (or pressing
/// Enter when focused) expands to the full table, and the toggle row
/// becomes "show fewer".
///
/// The toggle row is a real focusable so keyboard users can reach it
/// via Tab — the surface keyboard story must cover host-added chrome
/// too, not just agent-declared components.
class _FoldableTable extends StatefulComponent {
  final Component header;
  final List<Component> rows;
  final int hiddenCount;
  final Strings strings;

  const _FoldableTable({
    required this.header,
    required this.rows,
    required this.hiddenCount,
    this.strings = kEnglishStrings,
  });

  @override
  State<_FoldableTable> createState() => _FoldableTableState();
}

class _FoldableTableState extends State<_FoldableTable> {
  bool _expanded = false;
  bool _hovered = false;

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final c = component;
    final focused = Focus.of(context);

    final visibleRows = _expanded ? c.rows : c.rows.take(12).toList();
    final toggleLabel = _expanded
        ? c.strings.t('surface.table.less')
        : c.strings.t('surface.table.more', {'n': '${c.hiddenCount}'});

    final toggle = Focusable(
      autofocus: false,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.enter ||
            event.logicalKey == LogicalKey.space) {
          setState(() => _expanded = !_expanded);
          return true;
        }
        return false;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          opaque: false,
          child: Container(
            color: _hovered ? theme.surfaceVariant : null,
            child: Text(
              toggleLabel,
              style: TextStyle(
                color: _hovered || focused ? theme.accent : theme.textMuted,
              ),
            ),
          ),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [c.header, ...visibleRows, toggle],
    );
  }
}

// ---------------------------------------------------------------------------
// ProgressBar
// ---------------------------------------------------------------------------

/// A2UI `ProgressBar` component (Crux extension) — numeric progress.
///
/// Renders like the ContextBar: every cell carries a background color
/// (filled/empty/boundary-blend), and the percentage/label text is drawn
/// directly on those cells with the appropriate fg — the number never
/// floats over a transparent background.
///
/// Properties:
/// - `value` (number | binding, optional): progress fraction 0..1.
/// - `label` (string | binding, optional): text drawn inside the bar
///   (overrides the percentage readout when set).
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
    String? Function(String childId)? childType,
    Strings strings = kEnglishStrings,
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

    // Label overrides percentage readout; neither shown when the bar is
    // indeterminate without a label.
    String? displayText = label;
    if (displayText == null && showPercentage && value != null) {
      displayText = '${(value * 100).toInt()}%';
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth.toInt()
            : 20;
        return _SurfaceProgressBar(
          width: width,
          value: indeterminate ? null : value,
          indeterminate: indeterminate,
          displayText: displayText,
          fillColor: theme.success,
          emptyColor: theme.borderSubtle,
          labelFillFg: theme.background,
          labelEmptyFg: theme.foreground,
        );
      },
    );
  }
}

/// Custom-rendered progress bar — draws per-cell backgrounds and writes
/// the label/percentage directly on those cells, mirroring ContextBar's
/// paint logic so the readout never sits on a bare background.
class _SurfaceProgressBar extends StatefulComponent {
  final int width;
  final double? value;
  final bool indeterminate;
  final String? displayText;
  final Color fillColor;
  final Color emptyColor;
  final Color labelFillFg;
  final Color labelEmptyFg;

  const _SurfaceProgressBar({
    required this.width,
    required this.value,
    required this.indeterminate,
    required this.displayText,
    required this.fillColor,
    required this.emptyColor,
    required this.labelFillFg,
    required this.labelEmptyFg,
  });

  @override
  State<_SurfaceProgressBar> createState() => _SurfaceProgressBarState();
}

class _SurfaceProgressBarState extends State<_SurfaceProgressBar> {
  int _frame = 0;

  // Determinate lerp animation state.
  double _displayValue = 0.0;
  double _targetValue = 0.0;
  bool _lerping = false;
  static const Duration _lerpTick = Duration(milliseconds: 16);
  static const double _lerpSpeed = 6.0; // per-second convergence rate
  DateTime _lastTick = DateTime.now();

  @override
  void initState() {
    super.initState();
    final v = component.value;
    _displayValue = v ?? 0.0;
    _targetValue = v ?? 0.0;
    if (component.indeterminate) _startTimer();
  }

  @override
  void didUpdateComponent(_SurfaceProgressBar oldComponent) {
    super.didUpdateComponent(oldComponent);
    if (oldComponent.indeterminate != component.indeterminate) {
      if (component.indeterminate) {
        _startTimer();
      } else {
        _stopTimer();
      }
    }

    // Value changed → lerp the displayed value toward the new target.
    final oldTarget = oldComponent.value;
    final newTarget = component.value;
    if (oldTarget != newTarget) {
      _targetValue = newTarget ?? 0.0;
      if (!_lerping && !component.indeterminate) {
        _lerping = true;
        _lastTick = DateTime.now();
        _tickLerp();
      }
    }
  }

  void _startTimer() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted || !component.indeterminate) return false;
      setState(() => _frame++);
      return true;
    });
  }

  void _stopTimer() {
    // The doWhile loop exits on next check when indeterminate is false.
  }

  void _tickLerp() {
    if (!mounted || component.indeterminate) {
      _lerping = false;
      return;
    }
    final now = DateTime.now();
    final dt =
        (now.difference(_lastTick).inMicroseconds) /
        Duration.microsecondsPerSecond;
    _lastTick = now;
    final diff = _targetValue - _displayValue;
    if (diff.abs() < 0.005) {
      // Close enough — snap and stop.
      setState(() {
        _displayValue = _targetValue;
        _lerping = false;
      });
      return;
    }
    setState(() {
      _displayValue += diff * (dt * _lerpSpeed).clamp(0.0, 1.0);
    });
    Future.delayed(_lerpTick, _tickLerp);
  }

  /// The value the bar should visually present — the lerped display
  /// value while animating, the target value when at rest.
  double? get _renderedValue =>
      component.value != null ? _displayValue.clamp(0.0, 1.0) : component.value;

  @override
  Component build(BuildContext context) {
    return _SurfaceProgressBarComponent(
      width: component.width,
      renderValue: _renderedValue,
      indeterminateFrame: component.indeterminate ? _frame : null,
      displayText: component.displayText,
      fillColor: component.fillColor,
      emptyColor: component.emptyColor,
      labelFillFg: component.labelFillFg,
      labelEmptyFg: component.labelEmptyFg,
    );
  }
}

/// Bridge component — creates the render object and hands fresh visual
/// state (lerped value, pulse frame) to it on every rebuild.
class _SurfaceProgressBarComponent extends SingleChildRenderObjectComponent {
  final int width;
  final double? renderValue;
  final int? indeterminateFrame;
  final String? displayText;
  final Color fillColor;
  final Color emptyColor;
  final Color labelFillFg;
  final Color labelEmptyFg;

  const _SurfaceProgressBarComponent({
    required this.width,
    required this.renderValue,
    required this.indeterminateFrame,
    required this.displayText,
    required this.fillColor,
    required this.emptyColor,
    required this.labelFillFg,
    required this.labelEmptyFg,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderSurfaceProgressBar(
      width: width,
      value: renderValue,
      indeterminateFrame: indeterminateFrame,
      label: displayText,
      fillColor: fillColor,
      emptyColor: emptyColor,
      labelFillFg: labelFillFg,
      labelEmptyFg: labelEmptyFg,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSurfaceProgressBar renderObject,
  ) {
    renderObject
      ..width = width
      ..setVisualState(
        value: renderValue,
        indeterminateFrame: indeterminateFrame,
        label: displayText,
      )
      ..fillColor = fillColor
      ..emptyColor = emptyColor
      ..labelFillFg = labelFillFg
      ..labelEmptyFg = labelEmptyFg;
  }
}

/// Custom render object for the surface ProgressBar. Paints `width × 1`
/// fixed-size cells DIRECTLY on the canvas (mirroring ContextBar) so the
/// bar can never exceed its layout slot — a CJK label character advances
/// two columns on screen but is pre-coloured here per-cell in grid
/// space, so wide glyphs cannot push the row past the Card border the
/// way widget-composed cells could (their natural width made the Row
/// overflow by one column per wide char, erasing the Card's right
/// border).
///
/// Layout is trivially `Size(width, 1)`; every visual change goes
/// through `markNeedsPaint`.
class RenderSurfaceProgressBar extends RenderObject {
  int _width;
  double? _value;
  int? _indeterminateFrame;
  String _label;
  Color _fillColor;
  Color _emptyColor;
  Color _labelFillFg;
  Color _labelEmptyFg;

  RenderSurfaceProgressBar({
    required int width,
    required double? value,
    required int? indeterminateFrame,
    String? label,
    required Color fillColor,
    required Color emptyColor,
    required Color labelFillFg,
    required Color labelEmptyFg,
  }) : // Width/value/frame are transformed (frame is nullable in the
       // param, non-null usage inside), so explicit assignment reads
       // clearest; the lint is informational.
       // ignore: prefer_initializing_formals
       _width = width,
       // ignore: prefer_initializing_formals
       _value = value,
       // ignore: prefer_initializing_formals
       _indeterminateFrame = indeterminateFrame,
       _label = label ?? '',
       // Style infos trigger `prefer_initializing_formals` noise when
       // assigned in the initializer list; ContextBar's render object
       // lays these out the same way, and the lint is informational —
       // keep explicit assignment for readability.
       // ignore: prefer_initializing_formals
       _fillColor = fillColor,
       // ignore: prefer_initializing_formals
       _emptyColor = emptyColor,
       // ignore: prefer_initializing_formals
       _labelFillFg = labelFillFg,
       // ignore: prefer_initializing_formals
       _labelEmptyFg = labelEmptyFg;

  /// Width change re-lays-out (size depends on it); visual-only changes
  /// just repaint.
  set width(int value) {
    if (_width == value) return;
    _width = value;
    markNeedsLayout();
  }

  /// Bulk visual-state update from the bridge component. Repaints only
  /// when something actually changed (the lerp timer ticks at 60 fps
  /// while animating).
  void setVisualState({
    required double? value,
    required int? indeterminateFrame,
    required String? label,
  }) {
    var dirty = false;
    if (_value != value) {
      _value = value;
      dirty = true;
    }
    if (_indeterminateFrame != indeterminateFrame) {
      _indeterminateFrame = indeterminateFrame;
      dirty = true;
    }
    if (_label != label) {
      _label = label ?? '';
      dirty = true;
    }
    if (dirty) markNeedsPaint();
  }

  set fillColor(Color value) {
    if (_fillColor == value) return;
    _fillColor = value;
    markNeedsPaint();
  }

  set emptyColor(Color value) {
    if (_emptyColor == value) return;
    _emptyColor = value;
    markNeedsPaint();
  }

  set labelFillFg(Color value) {
    if (_labelFillFg == value) return;
    _labelFillFg = value;
    markNeedsPaint();
  }

  set labelEmptyFg(Color value) {
    if (_labelEmptyFg == value) return;
    _labelEmptyFg = value;
    markNeedsPaint();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! BoxParentData) {
      child.parentData = BoxParentData();
    }
  }

  @override
  void performLayout() {
    // Fixed size: exactly [_width] cells wide, 1 row tall. The parent's
    // constraints have already been measured by the catalog's
    // LayoutBuilder, so the slot can always hold this size.
    size = Size(_width.toDouble(), 1.0);
  }

  @override
  void paint(TerminalCanvas canvas, Offset offset) {
    super.paint(canvas, offset);

    final width = _width;
    final value = _value;
    final label = _label;

    final frame = _indeterminateFrame;
    final pos = frame == null ? 0 : frame % (width * 2);
    final center = pos <= width ? pos : width * 2 - pos;
    final bandHalf = (width * 0.3 / 2).ceil().clamp(1, width ~/ 2);

    final rawFill = (value ?? 0.0) * width;
    final filledCount = rawFill.floor();
    final partial = rawFill - filledCount;
    final boundaryIdx = (partial > 0.0 && filledCount < width)
        ? filledCount
        : -1;

    // Label centred in grid space; truncated to the bar's own width
    // with `…` when it would overflow.
    final fitted = _truncateToWidth(label, width);
    final labelWidth = stringWidth(fitted);
    final labelStart = (width - labelWidth) ~/ 2;

    // Walk label runes with their grid widths, building a per-cell
    // char/fg map so wide glyphs occupy their true column counts.
    final labelChars = <String?>[for (var i = 0; i < width; i++) null];
    final labelFgs = <Color?>[for (var i = 0; i < width; i++) null];
    var cellX = labelStart;
    for (final rune in fitted.runes) {
      final ch = String.fromCharCode(rune);
      final gw = stringWidth(ch);
      if (gw > 0 && cellX >= 0 && cellX + gw <= width) {
        final fg = _labelFgFor(
          cellX: cellX,
          filledCount: filledCount,
          boundaryIdx: boundaryIdx,
          partial: partial,
          center: center,
          bandHalf: bandHalf,
        );
        labelChars[cellX] = ch;
        labelFgs[cellX] = fg;
        if (gw == 2 && cellX + 1 < width) labelFgs[cellX + 1] = fg;
      }
      cellX += gw;
    }

    for (var i = 0; i < width; i++) {
      final Color bg;
      if (_indeterminateFrame != null) {
        // Pulse: a moving 30% band sweeping left→right→left.
        final inBand = (i - center).abs() <= bandHalf;
        bg = inBand ? _fillColor : _emptyColor;
      } else if (i < filledCount) {
        bg = _fillColor;
      } else if (i == boundaryIdx) {
        bg = Color.lerp(_emptyColor, _fillColor, partial)!;
      } else {
        bg = _emptyColor;
      }

      final ch = labelChars[i];
      final fg = labelFgs[i];
      final style = TextStyle(color: fg, backgroundColor: bg);
      // Always draw exactly one column per iteration: bg fill for
      // every cell, label char where mapped, space elsewhere.
      canvas.drawText(
        offset + Offset(i.toDouble(), 0),
        ch ?? ' ',
        style: style,
      );
    }
  }

  /// Per-cell label foreground for each fill/band state, mirroring the
  /// previous widget-composed logic:
  /// - filled: dedicated fill fg
  /// - boundary cell: fill fg when the blend is fill-dominant (≥ 0.5)
  /// - empty / pulse-outside: dedicated empty fg
  Color _labelFgFor({
    required int cellX,
    required int filledCount,
    required int boundaryIdx,
    required double partial,
    required int center,
    required int bandHalf,
  }) {
    if (_indeterminateFrame != null) {
      final inBand = (cellX - center).abs() <= bandHalf;
      return inBand ? _labelFillFg : _labelEmptyFg;
    }
    if (cellX < filledCount) return _labelFillFg;
    if (cellX == boundaryIdx && partial >= 0.5) return _labelFillFg;
    return _labelEmptyFg;
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
      'description': 'Maximum visible rows before scrolling. Default 8.',
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
    final childrenRaw = unwrapListProperty(component.properties['children']);
    final maxHeight = coerceIntProperty(
      component.properties['maxHeight'],
      8,
    ).clamp(1, 100);

    final children = <Component>[];
    if (childrenRaw is List) {
      for (final childId in childrenRaw) {
        if (childId is String) children.add(buildChild(childId));
      }
    }

    // The SizedBox height must ALWAYS be bounded: `height: null` lets the
    // internal ListView keep an infinite intrinsic height, which bubbles up
    // to the chat scroll area's scrollbar math (RenderScrollbar computes
    // thumb height from viewport dimensions) and crashes with
    // "Infinity or NaN toInt". Cap at maxHeight so the ListView scrolls
    // inside a fixed viewport.
    //
    // A ScrollController is shared between the ListView and the Scrollbar
    // so the scrollbar can read maxScrollExtent and paint its thumb —
    // without it, Scrollbar renders nothing.
    return _SurfaceList(maxHeight: maxHeight, children: children);
  }
}

/// Internal scrollable list with a shared [ScrollController] so the
/// [Scrollbar] can read the ListView's scroll metrics and paint its
/// thumb on the right edge.
class _SurfaceList extends StatefulComponent {
  final int maxHeight;
  final List<Component> children;

  const _SurfaceList({required this.maxHeight, required this.children});

  @override
  State<_SurfaceList> createState() => _SurfaceListState();
}

class _SurfaceListState extends State<_SurfaceList> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    return SizedBox(
      height: component.maxHeight.toDouble(),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: ListView(
          controller: _controller,
          keyboardScrollable: true,
          lazy: false,
          children: component.children,
        ),
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
  catalog.register(KeyValueCatalogItem());
  catalog.register(BadgeCatalogItem());
  catalog.register(StatCatalogItem());
  catalog.register(ListItemCatalogItem());
  catalog.register(BarListCatalogItem());
  catalog.register(TableCatalogItem());
  catalog.register(ProgressBarCatalogItem());
  catalog.register(ListCatalogItem());
}
