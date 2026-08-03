import 'package:nocterm/nocterm.dart';

import '../../../models/session.dart';
import '../../../theme/crux_theme.dart';
import '../home_widgets.dart';

/// The `yesterday` box — a passive summary of what you were doing
/// yesterday.
///
/// Data source: the same in-memory session/chat lists as
/// `recent-sessions`, filtered to `updatedAt` falling within yesterday
/// (local midnight-to-midnight). Purely informational — `activate`
/// returns null.
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

  @override
  int heightFor(int span) => 4;

  @override
  void Function()? activate(HomeContext ctx) => null; // passive

  /// Sessions updated yesterday (local midnight-to-midnight before
  /// today), most-recent first.
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
    final theme = CruxTheme.of(context);
    final list = _yesterdays();

    if (list.isEmpty) {
      return Text(
        'nothing active yesterday',
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

    // Show a couple of the most recent titles as a memory jog.
    for (final s in list.take(2)) {
      children.add(
        Text(
          '· ${s.title.isEmpty ? s.displayId : s.title}',
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
