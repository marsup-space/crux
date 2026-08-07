import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:nocterm/nocterm.dart' as nocterm show isNotEmpty;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/home/widgets/activity_widget.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/storage/session_store.dart';
import 'package:crux/src/theme/crux_theme.dart';

/// Pumps the activity grid (bypassing the async loader) at a fixed
/// width so the heatmap cells are assertable.
Future<void> _pumpGrid(
  NoctermTester tester,
  Map<String, int> totals,
) async {
  await tester.pumpComponent(
    Container(
      width: 80,
      height: 14,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: Builder(
          builder: (context) => ActivityHomeWidget(
            loader: (_) async => totals,
          ).build(context, _ctx(), 2),
        ),
      ),
    ),
  );
  await tester.pump();
  // Let the async loader settle, then pump the rebuild.
  await tester.pump();
}

HomeContext _ctx() => HomeContext.minimal(close: () {});

void main() {
  group('activity widget', () {
    test('renders weekday header, week-number gutter and the legend',
        () async {
      await testNocterm('activity grid', (tester) async {
        await _pumpGrid(tester, const {});
        expect(tester.terminalState.findText('Mon'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('Sun'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('less'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('more'), nocterm.isNotEmpty);
        // Ceiling label present.
        expect(tester.terminalState.findText('100M'), nocterm.isNotEmpty);
      });
    });

    test('is passive (activate returns null)', () {
      expect(ActivityHomeWidget().activate(_ctx()), isNull);
    });

    test('null loader (no store) renders an empty grid', () async {
      await testNocterm('activity empty', (tester) async {
        await _pumpGrid(tester, const {});
        // The grid still renders the legend — the box is never blank.
        expect(tester.terminalState.findText('less'), nocterm.isNotEmpty);
      });
    });
  });

  group('dailyTokenTotals', () {
    late SessionStore store;

    setUp(() {
      store = SessionStore(
        CruxDatabase.forTesting(NativeDatabase.memory()),
      );
    });

    tearDown(() async {
      await store.database.close();
    });

    Future<int> sessionWithMessage({
      required DateTime when,
      required int tokensIn,
      required int tokensOut,
      String projectPath = '/p',
    }) async {
      final session = await store.create(
        title: 't',
        projectPath: projectPath,
      );
      // addMessage stamps createdAt as now; to place a message on a
      // past day we write directly through the database.
      await store.database
          .into(store.database.messages)
          .insert(
            MessagesCompanion.insert(
              sessionId: session.id,
              role: 'ai',
              createdAt: when.millisecondsSinceEpoch,
              tokensIn: Value(tokensIn),
              tokensOut: Value(tokensOut),
            ),
          );
      return session.id;
    }

    test('sums tokens per local calendar day', () async {
      final today = DateTime.now();
      final todayStart = DateTime(today.year, today.month, today.day);
      final yesterday = todayStart.subtract(const Duration(days: 1));

      await sessionWithMessage(
        when: todayStart.add(const Duration(hours: 9)),
        tokensIn: 100,
        tokensOut: 50,
      );
      await sessionWithMessage(
        when: todayStart.add(const Duration(hours: 18)),
        tokensIn: 200,
        tokensOut: 25,
      );
      await sessionWithMessage(
        when: yesterday.add(const Duration(hours: 12)),
        tokensIn: 1000,
        tokensOut: 500,
      );

      final totals = await store.messageStore.dailyTokenTotals(
        sinceDaysAgo: 7,
        projectPath: '/p',
      );

      String key(DateTime d) =>
          '${d.year}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

      expect(totals[key(todayStart)], 375); // 150 + 225
      expect(totals[key(yesterday)], 1500);
    });

    test('filters by project path', () async {
      final today = DateTime.now();
      await sessionWithMessage(
        when: today,
        tokensIn: 10,
        tokensOut: 5,
        projectPath: '/a',
      );
      await sessionWithMessage(
        when: today,
        tokensIn: 20,
        tokensOut: 20,
        projectPath: '/b',
      );

      final a = await store.messageStore.dailyTokenTotals(
        sinceDaysAgo: 7,
        projectPath: '/a',
      );
      expect(a.values.fold(0, (s, v) => s + v), 15);

      final all = await store.messageStore.dailyTokenTotals(
        sinceDaysAgo: 7,
      );
      expect(all.values.fold(0, (s, v) => s + v), 55);
    });

    test('excludes messages older than the window', () async {
      final old = DateTime.now().subtract(const Duration(days: 400));
      await sessionWithMessage(
        when: old,
        tokensIn: 999,
        tokensOut: 999,
      );

      final totals = await store.messageStore.dailyTokenTotals(
        sinceDaysAgo: 7,
        projectPath: '/p',
      );
      expect(totals, isEmpty);
    });
  });
}
