import 'package:nocterm/nocterm.dart';

import '../../../models/session.dart';
import '../../../theme/crux_theme.dart';
import '../home_widgets.dart';

/// The `yesterday` box — an auxiliary-model summary of what you worked
/// on yesterday.
///
/// When [HomeContext.summarizeYesterday] is wired (the real panel), the
/// box kicks off one single-round LLM call (no tools) on first build and
/// shows the returned bullets. While the call is in flight it shows a
/// "Summarizing…" line; if the call returns null (no auxiliary model,
/// failure, or no yesterday activity) it falls back to the static
/// yesterday-session list so the box is never empty. When the callback
/// is null (tests / previews) only the static list renders.
///
/// The summary is cached by the service (keyed on the yesterday-session
/// fingerprint), so re-opening home the same day doesn't re-call the
/// model — the widget's own `_summary` field is just the local copy.
///
/// Passive box — `activate` returns null; there's no primary action.
class YesterdayHomeWidget extends HomeWidget {
  /// Sessions + chats, merged by the caller.
  final List<Session> Function() sessions;

  /// Injectable clock for tests.
  final DateTime Function() _now;

  YesterdayHomeWidget({
    required this.sessions,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  @override
  String get id => 'yesterday';

  @override
  String get title => 'Yesterday';

  @override
  Set<int> get supportedSpans => const {1, 2};

  /// Taller than the other boxes — the summary wraps to several lines
  /// and the box scrolls, so it wants the room. 8 content rows (+2
  /// border) is enough to show a multi-line summary with scroll afford.
  @override
  int heightFor(int span) => 8;

  /// The summary scrolls — centering it would break the scrollview's
  /// height constraint and mis-place wrapped lines.
  @override
  bool get verticallyCenter => false;

  @override
  void Function()? activate(HomeContext ctx) => null; // passive

  /// Sessions updated yesterday (local midnight-to-midnight before
  /// today), most-recent first. Used by the static fallback list.
  List<Session> _yesterdays() {
    final now = _now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final list = sessions().where((s) {
      final u = s.updatedAt;
      return !u.isBefore(yesterdayStart) && u.isBefore(todayStart);
    }).toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    return _YesterdayView(
      sessions: _yesterdays,
      summarize: ctx.summarizeYesterday == null
          ? null
          : () => ctx.summarizeYesterday!(sessions()),
    );
  }
}

/// Stateful view so the async summary can land after first build.
class _YesterdayView extends StatefulComponent {
  final List<Session> Function() sessions;

  /// Null when no summarizer is wired (tests) — only the fallback list
  /// shows. Otherwise the single-round summary call.
  final Future<String?> Function()? summarize;

  const _YesterdayView({required this.sessions, this.summarize});

  @override
  State<_YesterdayView> createState() => _YesterdayViewState();
}

class _YesterdayViewState extends State<_YesterdayView> {
  /// The fetched summary, or null while pending / after a null result.
  String? _summary;

  /// True once the summary call has settled (success or null), so the
  /// view stops showing "Summarizing…" and either shows the bullets or
  /// drops to the fallback list.
  bool _settled = false;

  /// Guards against kicking the call twice across rebuilds.
  bool _requested = false;

  /// Scrolls the summary when it wraps past the box's content height.
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _maybeRequest();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeRequest() {
    final summarize = component.summarize;
    if (summarize == null || _requested) {
      _settled = true; // no summarizer → straight to the fallback list
      return;
    }
    _requested = true;
    summarize().then((result) {
      if (!mounted) return;
      setState(() {
        _summary = result;
        _settled = true;
      });
    });
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);

    // 1. Summary available → the bullets, wrapped and scrollable.
    final summary = _summary;
    if (summary != null) {
      final lines = summary
          .split(RegExp(r'\r\n|\r|\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      // softWrap: true lets each bullet wrap to the box width (no
      // ellipsis — the full text is the point). The Scrollbar +
      // SingleChildScrollView give the wrapped block a bounded height
      // (the box's fixed content area) so it scrolls on the mouse wheel
      // when it outgrows the box instead of overflowing the border.
      return Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        thumbColor: theme.onSurfaceDim.withOpacity(0.4),
        trackColor: theme.surfaceVariant.withOpacity(0.3),
        child: SingleChildScrollView(
          controller: _scrollController,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in lines)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        line,
                        softWrap: true,
                        style: TextStyle(color: theme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      );
    }

    // 2. Call still in flight → a one-line pending hint.
    if (!_settled) {
      return Text(
        'summarizing yesterday…',
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    // 3. Settled with no summary → the static fallback list.
    return _buildFallback(theme);
  }

  Component _buildFallback(CruxThemeData theme) {
    final list = component.sessions();

    if (list.isEmpty) {
      return Text(
        'nothing yesterday',
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    final children = <Component>[
      Text(
        '${list.length} session${list.length == 1 ? '' : 's'} active',
        style: TextStyle(
          color: theme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    ];

    // Show a couple of the most recent titles as a memory jog. Same
    // width-bound need as the summary bullets — a bare Text here would
    // overflow the border on a long title.
    for (final s in list.take(2)) {
      children.add(
        Row(
          children: [
            Expanded(
              child: Text(
                '· ${s.title.isEmpty ? s.displayId : s.title}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.onSurfaceDim),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
