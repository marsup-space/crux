import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import '../services/git_status_service.dart';
import '../theme/crux_theme.dart';
import '../utils/terminal_symbols.dart';

/// Compact git status panel that lives just above the project widget
/// in the right-hand side bar.
///
/// Visual layout (each row is only rendered when it carries
/// information — a clean tree shows just the branch line):
///
/// ```text
///   ⎇ main ↑3 ↓2            ← always when isRepo
///   +124 -56                 ← only when there are working changes
///   ● 3 · ◐ 1 · ? 2          ← inline counts, only the non-zero buckets
/// ```
///
/// The widget is *reactive*: it subscribes to its
/// [GitStatusService] in [initState] and re-renders on every
/// notification. Repaints are cheap — the layout has at most four
/// rows and the service only fires when the snapshot actually
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
  @override
  void initState() {
    super.initState();
    // `addListener` is safe even if the service has already fired
    // its first refresh before the widget mounted: the cached
    // snapshot is still in [GitStatusService.current] and we'll
    // pick it up on the next build tick.
    component.service.addListener(_onStatusChanged);
  }

  @override
  void didUpdateComponent(GitStatusWidget old) {
    super.didUpdateComponent(old);
    if (!identical(old.service, component.service)) {
      old.service.removeListener(_onStatusChanged);
      component.service.addListener(_onStatusChanged);
    }
  }

  @override
  void dispose() {
    component.service.removeListener(_onStatusChanged);
    super.dispose();
  }

  void _onStatusChanged() {
    if (mounted) setState(() {});
  }

  @override
  Component build(BuildContext context) {
    final status = component.service.current;
    if (!status.isRepo) {
      // Outside a repo (or git missing): collapse to zero height so
      // the panel layout above/below stays tight.
      return const SizedBox.shrink();
    }
    return _GitStatusView(
      status: status,
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
  final GitStatus status;
  final VoidCallback? onTap;
  final bool compact;
  final Strings strings;

  const _GitStatusView({
    required this.status,
    required this.onTap,
    required this.compact,
    required this.strings,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final rows = <Component>[];

    // Row 1: line diff stats. Hidden when there's nothing to
    // commit — "+0 -0" is pure noise.
    if (status.addedLines > 0 || status.deletedLines > 0) {
      rows.add(_buildDiffRow(theme));
    }

    // Row 2: file counts — staged / modified / deleted /
    // untracked / conflicted. Only non-zero buckets render, and
    // every bucket now carries an explicit label so a single
    // glyph can't be misread (the old `?` for untracked in
    // particular looked like a literal question mark at a
    // glance).
    final countsRow = _buildCountsRow(theme);
    if (countsRow != null) rows.add(countsRow);

    // Fall-through: a clean tree inside a repo gets a single
    // muted `✓` so the panel doesn't silently collapse — that
    // collapse used to be indistinguishable from "not a git
    // repo" at a glance, which was confusing.
    if (rows.isEmpty) {
      rows.add(_buildCleanRow(theme));
    }

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );

    // Wrap in a hoverable, tappable region only when the caller
    // supplied a click handler. The project widget below uses the
    // same `HitTestBehavior.opaque` trick to keep clicks
    // predictable across the whole panel.
    if (onTap == null) return body;
    return MouseRegion(
      opaque: false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
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

  /// `● 3 staged   ~ 1 modified   ? 2 untracked   ! 1 conflict`
  ///
  /// Every bucket now carries an explicit English label so the
  /// glyph is decorative rather than load-bearing. The previous
  /// icon-only design (`● 0 · ◐ 21 · ? 10`) was unreadable at a
  /// glance — `?` for untracked looked like a literal question
  /// mark, and three single-glyph clusters in a row fought each
  /// other for attention.
  ///
  /// Returns `null` when there's nothing meaningful to render,
  /// which lets [build] fall back to the `✓` clean row.
  Component? _buildCountsRow(CruxThemeData theme) {
    final parts = <Component>[];

    /// Add a single bucket of the form `glyph count label`,
    /// skipping buckets whose count is zero so a clean tree
    /// doesn't show `● 0 staged` next to real entries.
    void add(
      String glyph,
      String ascii,
      int count,
      String label,
      Color color, {
      bool bold = false,
    }) {
      if (count <= 0) return;
      parts.add(
        Text(
          '${terminalSymbol(glyph, ascii)} $count $label',
          style: TextStyle(
            color: color,
            fontWeight: bold ? FontWeight.bold : null,
          ),
        ),
      );
      // Triple-space separator gives the eye a place to breathe
      // between buckets. The previous single `·` separator was
      // so faint it read as accidental whitespace.
      parts.add(Text('   ', style: TextStyle(color: theme.onSurfaceDim)));
    }

    // Conflict first — most urgent. Bold so it pops even at a
    // glance.
    add(
      '!',
      '!',
      status.conflictedFiles,
      strings.t('home.git.conflict'),
      theme.errorColor,
      bold: true,
    );
    add('●', '+', status.stagedFiles, strings.t('home.git.staged'), theme.successColor);
    add('~', '~', status.modifiedFiles, strings.t('home.git.modified'), theme.warningColor);
    add('D', 'D', status.deletedFiles, strings.t('home.git.deleted'), theme.errorColor);
    add('?', '?', status.untrackedFiles, strings.t('home.git.untracked'), theme.hintText);

    if (parts.isEmpty) return null;

    // Trim the trailing separator. Otherwise every row ends with
    // a lonely three-space gap.
    if (parts.length >= 2) parts.removeLast();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Row(mainAxisSize: MainAxisSize.min, children: parts),
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
