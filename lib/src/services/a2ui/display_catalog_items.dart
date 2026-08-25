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
    final dt = (now.difference(_lastTick).inMicroseconds) /
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
  double? get _renderedValue => component.value != null
      ? _displayValue.clamp(0.0, 1.0)
      : component.value;

  @override
  Component build(BuildContext context) {
    final width = component.width;
    // Render the lerped display value (not the target) so the bar and
    // the percentage readout animate smoothly toward the new value.
    final value = _renderedValue;
    final text = component.displayText ?? '';

    final cells = <Component>[];

    if (component.indeterminate) {
      // Pulse: a moving 30% highlight band sweeping left→right→left.
      final pos = _frame % (width * 2);
      final center = pos <= width ? pos : width * 2 - pos;
      final bandHalf = (width * 0.3 / 2).ceil().clamp(1, width ~/ 2);
      for (var i = 0; i < width; i++) {
        final inBand = (i - center).abs() <= bandHalf;
        cells.add(
          Container(
            decoration: BoxDecoration(
              color: inBand ? component.fillColor : component.emptyColor,
            ),
            child: const Text(' '),
          ),
        );
      }
    } else if (value != null) {
      // Determinate: filled prefix with a boundary-blend cell for the
      // fractional remainder, then empty suffix.  Uses the lerped
      // display value so the bar animates smoothly.
      final rawFill = value * width;
      final filledCount = rawFill.floor();
      final partial = rawFill - filledCount;
      final boundaryIdx = (partial > 0.0 && filledCount < width)
          ? filledCount
          : -1;
      for (var i = 0; i < width; i++) {
        final Color bg;
        if (i < filledCount) {
          bg = component.fillColor;
        } else if (i == boundaryIdx) {
          bg = Color.lerp(component.emptyColor, component.fillColor, partial)!;
        } else {
          bg = component.emptyColor;
        }
        cells.add(
          Container(
            decoration: BoxDecoration(color: bg),
            child: const Text(' '),
          ),
        );
      }
    } else {
      // Empty bar.
      for (var i = 0; i < width; i++) {
        cells.add(
          Container(
            decoration: BoxDecoration(color: component.emptyColor),
            child: const Text(' '),
          ),
        );
      }
    }

    // Overlay the label/percentage centered on the bar. Each character
    // is drawn with the fg appropriate to the cell underneath. The
    // percentage is computed from the lerped display value so the readout
    // animates in lock-step with the bar.
    if (text.isNotEmpty && text.length <= width) {
      final start = (width - text.length) ~/ 2;
      final value = _renderedValue;
      final rawFill = value != null ? value * width : 0.0;
      final filledCount = rawFill.floor();
      final partial = rawFill - filledCount;
      final boundaryIdx = (partial > 0.0 && filledCount < width)
          ? filledCount
          : -1;

      for (var i = 0; i < text.length; i++) {
        final cellIdx = start + i;
        if (cellIdx < 0 || cellIdx >= width) continue;

        final Color bg;
        final Color fg;
        if (component.indeterminate) {
          // Pulse: label fg flips per band membership.
          final pos = _frame % (width * 2);
          final center = pos <= width ? pos : width * 2 - pos;
          final bandHalf = (width * 0.3 / 2).ceil().clamp(1, width ~/ 2);
          final inBand = (cellIdx - center).abs() <= bandHalf;
          bg = inBand ? component.fillColor : component.emptyColor;
          fg = inBand ? component.labelFillFg : component.labelEmptyFg;
        } else if (value != null) {
          if (cellIdx < filledCount) {
            bg = component.fillColor;
            fg = component.labelFillFg;
          } else if (cellIdx == boundaryIdx && partial >= 0.5) {
            bg = Color.lerp(
              component.emptyColor,
              component.fillColor,
              partial,
            )!;
            fg = component.labelFillFg;
          } else if (cellIdx == boundaryIdx) {
            bg = Color.lerp(
              component.emptyColor,
              component.fillColor,
              partial,
            )!;
            fg = component.labelEmptyFg;
          } else {
            bg = component.emptyColor;
            fg = component.labelEmptyFg;
          }
        } else {
          bg = component.emptyColor;
          fg = component.labelEmptyFg;
        }

        cells[cellIdx] = Container(
          decoration: BoxDecoration(color: bg),
          child: Text(
            text[i],
            style: TextStyle(color: fg),
          ),
        );
      }
    }

    return Row(children: cells);
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

    // The SizedBox height must ALWAYS be bounded: `height: null` lets the
    // internal ListView keep an infinite intrinsic height, which bubbles up
    // to the chat scroll area's scrollbar math (RenderScrollbar computes
    // thumb height from viewport dimensions) and crashes with
    // "Infinity or NaN toInt". Cap at maxHeight so the ListView scrolls
    // inside a fixed viewport.
    //
    // Wrap in a Scrollbar so the user sees a visible handle on the right
    // edge when content overflows — the thumb tracks the scroll offset
    // and is draggable.
    return SizedBox(
      height: maxHeight.toDouble(),
      child: Scrollbar(
        thumbVisibility: true,
        child: ListView(
          keyboardScrollable: true,
          lazy: false,
          children: children,
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
  catalog.register(TableCatalogItem());
  catalog.register(ProgressBarCatalogItem());
  catalog.register(ListCatalogItem());
}
