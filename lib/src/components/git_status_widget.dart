import 'dart:math' as math;

import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import '../services/git_status_service.dart';
import '../theme/crux_theme.dart';
import '../utils/terminal_symbols.dart';
import '../utils/text_width.dart';
import '../utils/ticker_registry.dart';
import 'ui/hoverable.dart';

/// Compact git status panel that lives just above the project widget
/// in the right-hand side bar.
///
/// Visual layout (each row is only rendered when it carries
/// information — a clean tree shows just the branch line):
///
/// ```text
///   +124  −56                 ← only when there are line changes
///   3 staged      1 modified   ← stable two-column grid
///   2 untracked                ← single-column fallback when too narrow
/// ```
///
/// The widget is *reactive*: it subscribes to its
/// [GitStatusService] in [initState] and re-renders on every
/// notification. Repaints are cheap — the layout has only a few
/// short rows and the service only fires when the snapshot actually
/// changes (see [GitStatus] ==).
///
/// When [GitStatus.isRepo] is `false` (i.e. the project isn't
/// tracked by git, or git isn't installed) the widget collapses to
/// a zero-height box so the panel layout doesn't reserve a gap for
/// it. Callers can therefore always insert it without conditionals.
class GitStatusWidget extends StatefulComponent {
  /// Service that owns the polling timer and the current snapshot.
  /// Must outlive the widget — the caller (typically
  /// [ChatPanel]) is responsible for calling [GitStatusService.start]
  /// in `initState` and [GitStatusService.dispose] in `dispose`.
  final GitStatusService service;

  /// Optional tap handler. When non-null, the whole widget becomes
  /// hover-sensitive and a click triggers the callback. The
  /// canonical use is "click to force-refresh", but tests leave it
  /// null.
  final VoidCallback? onTap;

  /// When true, render the widget in a flat, no-border style that
  /// matches the project [MultiButton] below it. Default `true`
  /// because that's what the side panel wants.
  final bool compact;
  final Strings strings;

  const GitStatusWidget({
    super.key,
    required this.service,
    this.onTap,
    this.compact = true,
    this.strings = kEnglishStrings,
  });

  @override
  State<GitStatusWidget> createState() => _GitStatusWidgetState();
}

class _GitStatusWidgetState extends State<GitStatusWidget> {
  GitStatus? _targetStatus;
  GitStatus? _fromStatus;
  TickerToken? _animationTicker;
  int _animationStartMs = 0;

  /// A deliberately legible transition: Git changes feel like an event rather
  /// than a one-frame replacement.
  static const Duration _animationDuration = Duration(milliseconds: 2500);

  @override
  void initState() {
    super.initState();
    _targetStatus = component.service.current;
    component.service.addListener(_onStatusChanged);
  }

  @override
  void didUpdateComponent(GitStatusWidget old) {
    super.didUpdateComponent(old);
    if (!identical(old.service, component.service)) {
      old.service.removeListener(_onStatusChanged);
      _animationTicker?.cancel();
      _animationTicker = null;
      _fromStatus = null;
      _targetStatus = component.service.current;
      component.service.addListener(_onStatusChanged);
    }
  }

  @override
  void dispose() {
    component.service.removeListener(_onStatusChanged);
    _animationTicker?.cancel();
    _animationTicker = null;
    super.dispose();
  }

  void _onStatusChanged() {
    if (!mounted) return;
    final next = component.service.current;
    final previous = _targetStatus;
    if (previous == null || !_hasNumericChange(previous, next)) {
      _targetStatus = next;
      _fromStatus = null;
      _animationTicker?.cancel();
      _animationTicker = null;
      setState(() {});
      return;
    }

    // If another Git change lands before the previous animation finishes,
    // continue from the value currently on screen instead of snapping back.
    _fromStatus = _displayStatus();
    _targetStatus = next;
    _animationStartMs = DateTime.now().millisecondsSinceEpoch;
    _animationTicker ??= TickerRegistry.instance.subscribe(
      name: 'gitStatusLerp',
      interval: const Duration(milliseconds: 16),
      onTick: _tickAnimation,
    );
    setState(() {});
  }

  void _tickAnimation(Duration _) {
    if (!mounted || _targetStatus == null || _fromStatus == null) return;
    final elapsed = DateTime.now().millisecondsSinceEpoch - _animationStartMs;
    if (elapsed >= _animationDuration.inMilliseconds) {
      _animationTicker?.cancel();
      _animationTicker = null;
      _fromStatus = null;
    }
    setState(() {});
  }

  GitStatus _displayStatus() {
    final target = _targetStatus ?? component.service.current;
    final from = _fromStatus;
    if (from == null) return target;
    final elapsed = DateTime.now().millisecondsSinceEpoch - _animationStartMs;
    final progress = (elapsed / _animationDuration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    final t = 1.0 - math.pow(1.0 - progress, 3).toDouble();
    return _lerpStatus(from, target, t);
  }

  bool _hasNumericChange(GitStatus a, GitStatus b) =>
      a.ahead != b.ahead ||
      a.behind != b.behind ||
      a.stagedFiles != b.stagedFiles ||
      a.modifiedFiles != b.modifiedFiles ||
      a.deletedFiles != b.deletedFiles ||
      a.untrackedFiles != b.untrackedFiles ||
      a.conflictedFiles != b.conflictedFiles ||
      a.addedLines != b.addedLines ||
      a.deletedLines != b.deletedLines;

  GitStatus _lerpStatus(GitStatus from, GitStatus to, double t) {
    int value(int a, int b) => (a + (b - a) * t).round().clamp(0, 1 << 31);
    return GitStatus(
      isRepo: to.isRepo,
      fetchedAt: to.fetchedAt,
      branch: to.branch,
      ahead: value(from.ahead, to.ahead),
      behind: value(from.behind, to.behind),
      stagedFiles: value(from.stagedFiles, to.stagedFiles),
      modifiedFiles: value(from.modifiedFiles, to.modifiedFiles),
      deletedFiles: value(from.deletedFiles, to.deletedFiles),
      untrackedFiles: value(from.untrackedFiles, to.untrackedFiles),
      conflictedFiles: value(from.conflictedFiles, to.conflictedFiles),
      addedLines: value(from.addedLines, to.addedLines),
      deletedLines: value(from.deletedLines, to.deletedLines),
    );
  }

  @override
  Component build(BuildContext context) {
    final status = _displayStatus();
    if (!status.isRepo) {
      // Outside a repo (or git missing): collapse to zero height so
      // the panel layout above/below stays tight.
      return const SizedBox.shrink();
    }
    return _GitStatusView(
      status: status,
      visibilityStatus: _targetStatus ?? status,
      onTap: component.onTap,
      compact: component.compact,
      strings: component.strings,
    );
  }
}

/// Stateless renderer for a [GitStatus] snapshot. Split out from
/// [GitStatusWidget] so the layout code is reusable in tests
/// (without a service) and so the rebuild path doesn't have to
/// chase the StatefulComponent's bookkeeping.
class _GitStatusView extends StatelessComponent {
  /// Animated numbers shown to the user.
  final GitStatus status;

  /// Latest Git snapshot, used to decide which rows are visible while an
  /// animated value is still briefly rounding through zero.
  final GitStatus visibilityStatus;
  final VoidCallback? onTap;
  final bool compact;
  final Strings strings;

  const _GitStatusView({
    required this.status,
    required this.visibilityStatus,
    required this.onTap,
    required this.compact,
    required this.strings,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final body = LayoutBuilder(
      builder: (context, constraints) {
        // The panel contributes one column of padding on either side. Use the
        // remaining terminal columns as a hard line budget so CJK labels wrap
        // before nocterm has a chance to paint through the right border.
        final contentWidth = constraints.maxWidth.isFinite
            ? (constraints.maxWidth.floor() - 2).clamp(1, 1 << 20)
            : 1 << 20;
        final rows = <Component>[];

        if (visibilityStatus.addedLines > 0 ||
            visibilityStatus.deletedLines > 0) {
          rows.add(_buildDiffRow(theme));
        }

        rows.addAll(_buildCountRows(theme, contentWidth));

        if (rows.isEmpty) rows.add(_buildCleanRow(theme));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        );
      },
    );

    // Wrap in a hoverable, tappable region only when the caller
    // supplied a click handler. The project widget below uses the
    // same `HitTestBehavior.opaque` trick to keep clicks
    // predictable across the whole panel.
    if (onTap == null) return body;
    return Hoverable(
      onTap: onTap,
      builder: (context, hovered) => Container(
        decoration: BoxDecoration(
          color: hovered ? theme.buttonBackgroundHover : null,
        ),
        child: body,
      ),
    );
  }

  /// `+124 −56` — sum of staged and unstaged line changes.
  ///
  /// The leading indent matches the counts row's padding so the
  /// numbers align vertically across the two rows.
  Component _buildDiffRow(CruxThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '+${status.addedLines}',
            style: TextStyle(
              color: theme.successColor,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text('  ', style: TextStyle(color: theme.onSurfaceDim)),
          Text(
            '−${status.deletedLines}',
            style: TextStyle(
              color: theme.errorColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// File states rendered as calm `count label` pairs. Cryptic porcelain
  /// glyphs are intentionally omitted: colour and wording carry the meaning,
  /// while the number is bold for fast scanning.
  ///
  /// Pairs use a stable two-column grid whenever both columns can contain the
  /// widest label. At extreme widths the grid collapses to one column. This
  /// avoids horizontal jitter as counts change and remains safe for CJK text.
  List<Component> _buildCountRows(CruxThemeData theme, int maxWidth) {
    final items = <_GitCountItem>[
      if (visibilityStatus.conflictedFiles > 0)
        _GitCountItem(
          status.conflictedFiles,
          strings.t('home.git.conflict'),
          theme.errorColor,
        ),
      if (visibilityStatus.stagedFiles > 0)
        _GitCountItem(
          status.stagedFiles,
          strings.t('home.git.staged'),
          theme.successColor,
        ),
      if (visibilityStatus.modifiedFiles > 0)
        _GitCountItem(
          status.modifiedFiles,
          strings.t('home.git.modified'),
          theme.warningColor,
        ),
      if (visibilityStatus.deletedFiles > 0)
        _GitCountItem(
          status.deletedFiles,
          strings.t('home.git.deleted'),
          theme.errorColor,
        ),
      if (visibilityStatus.untrackedFiles > 0)
        _GitCountItem(
          status.untrackedFiles,
          strings.t('home.git.untracked'),
          theme.hintText,
        ),
    ];
    if (items.isEmpty) return const [];

    const gap = 3;
    final widestItem = items
        .map((item) => item.width)
        .reduce((a, b) => a > b ? a : b);
    final useTwoColumns = maxWidth >= widestItem * 2 + gap;
    final columnWidth = useTwoColumns ? (maxWidth - gap) ~/ 2 : maxWidth;
    final rows = <Component>[];

    for (var index = 0; index < items.length; index += useTwoColumns ? 2 : 1) {
      final hasSecond = useTwoColumns && index + 1 < items.length;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (useTwoColumns)
                SizedBox(
                  width: columnWidth.toDouble(),
                  child: _buildCountItem(items[index]),
                )
              else
                _buildCountItem(items[index]),
              if (hasSecond) ...[
                Text(' ' * gap, style: TextStyle(color: theme.onSurfaceDim)),
                _buildCountItem(items[index + 1]),
              ],
            ],
          ),
        ),
      );
    }
    return rows;
  }

  Component _buildCountItem(_GitCountItem item) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${item.count}',
          style: TextStyle(color: item.color, fontWeight: FontWeight.bold),
        ),
        Text(' ${item.label}', style: TextStyle(color: item.color)),
      ],
    );
  }

  /// Single-glyph "all clean" indicator. Muted (hint colour,
  /// no bold) because nothing here needs the user's attention.
  /// The label `clean` removes the previous ambiguity where an
  /// empty widget was indistinguishable from "not a git repo".
  Component _buildCleanRow(CruxThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Text(
        '${terminalSymbol('✓', '+')} ${strings.t('home.git.clean')}',
        style: TextStyle(color: theme.hintText),
      ),
    );
  }
}

class _GitCountItem {
  final int count;
  final String label;
  final Color color;

  const _GitCountItem(this.count, this.label, this.color);

  int get width => stringWidth('$count $label');
}
