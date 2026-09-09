import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart' show NativeDatabase;
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:nocterm/nocterm.dart' as nocterm show isNotEmpty;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/components/home/widgets/activity_widget.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/storage/session_store.dart';
import 'package:crux/src/theme/crux_theme.dart';

/// Pumps the activity grid (bypassing the async loader) at a fixed
/// width so the heatmap cells are assertable.
Future<void> _pumpGrid(NoctermTester tester, Map<String, int> totals) async {
  await tester.pumpComponent(
    Container(
      width: 80,
      height: 14,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: Builder(
          builder: (context) =>
              ActivityHomeWidget(loader: (_) async => totals)
                  .build(context, _ctx(), 2),
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
    test('renders weekday header, week-number gutter and the legend', () async {
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

    test('ceiling tracks the busiest day in the window', () async {
      await testNocterm('activity ceiling', (tester) async {
        final today = DateTime.now();
        String key(DateTime d) =>
            '${d.year}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        // Peak day of 6M (below the old 100M floor): the legend's
        // ceiling endpoint must be 6M, not 100M.
        await _pumpGrid(tester, {key(today): 6000000});
        expect(tester.terminalState.findText('0→6M'), nocterm.isNotEmpty);
      });
    });

    test('empty window falls back to the 100M default ceiling', () async {
      await testNocterm('activity ceiling empty', (tester) async {
        await _pumpGrid(tester, const {});
        expect(tester.terminalState.findText('0→100M'), nocterm.isNotEmpty);
      });
    });

    test(
      'days older than the rendered window do not raise the ceiling',
      () async {
        await testNocterm('activity ceiling window', (tester) async {
          final today = DateTime.now();
          String key(DateTime d) =>
              '${d.year}-'
              '${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}';
          // A 90M monster day five weeks back (fetched as headroom but
          // scrolled off the 4-week grid) must not become the ceiling;
          // the visible peak (today, 6M) defines it instead.
          await _pumpGrid(tester, {
            key(today.subtract(const Duration(days: 35))): 90000000,
            key(today): 6000000,
          });
          expect(tester.terminalState.findText('0→6M'), nocterm.isNotEmpty);
        });
      },
    );

    test('week totals render with adaptive precision (<= 5 chars)', () async {
      await testNocterm('activity week totals', (tester) async {
        final today = DateTime.now();
        final monday = today.subtract(Duration(days: today.weekday - 1));
        String key(DateTime d) =>
            '${d.year}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        // Current week Mon+Tue = 4510000 -> `4.51M`; last week Mon =
        // 13100000 -> `13.1M`; two weeks back Mon = 130000000 ->
        // `130M` (130.0M would be 6 chars); three weeks back Mon =
        // 10000 -> `0.01M` (never a misleading `0M`).
        await _pumpGrid(tester, {
          key(monday): 4000000,
          key(monday.add(const Duration(days: 1))): 510000,
          key(monday.subtract(const Duration(days: 7))): 13100000,
          key(monday.subtract(const Duration(days: 14))): 130000000,
          key(monday.subtract(const Duration(days: 21))): 10000,
        });
        expect(tester.terminalState.findText('4.51M'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('13.1M'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('130M'), nocterm.isNotEmpty);
        expect(tester.terminalState.findText('0.01M'), nocterm.isNotEmpty);
      });
    });
  });

  group('dailyTokenTotals', () {
    late SessionStore store;

    setUp(() {
      store = SessionStore(CruxDatabase.forTesting(NativeDatabase.memory()));
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
      final session = await store.create(title: 't', projectPath: projectPath);
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

      final all = await store.messageStore.dailyTokenTotals(sinceDaysAgo: 7);
      expect(all.values.fold(0, (s, v) => s + v), 55);
    });

    test('excludes messages older than the window', () async {
      final old = DateTime.now().subtract(const Duration(days: 400));
      await sessionWithMessage(when: old, tokensIn: 999, tokensOut: 999);

      final totals = await store.messageStore.dailyTokenTotals(
        sinceDaysAgo: 7,
        projectPath: '/p',
      );
      expect(totals, isEmpty);
    });
  });

  test(
    'daily aggregates work through the production background isolate',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'crux_daily_background_',
      );
      final backgroundStore = SessionStore(
        CruxDatabase.forTesting(
          NativeDatabase.createInBackground(File(p.join(dir.path, 'stats.db'))),
        ),
      );
      addTearDown(() async {
        await backgroundStore.database.close();
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final session = await backgroundStore.create(
        title: 'background',
        projectPath: '/p',
      );
      await backgroundStore.messageStore.addMessage(
        session.id,
        role: 'ai',
        content: 'done',
        model: 'provider/model',
        tokensIn: 120,
        tokensOut: 30,
      );

      final totals = await backgroundStore.messageStore.dailyTokenTotals(
        sinceDaysAgo: 1,
        projectPath: '/p',
      );
      final usage = await backgroundStore.messageStore.dailyUsageStats(
        sinceDaysAgo: 1,
        projectPath: '/p',
      );

      expect(totals.values.single, 150);
      expect(usage.values.single.tokens, 150);
      expect(usage.values.single.byModel['provider/model'], 150);
    },
  );

  group('dailyUsageStats', () {
    late SessionStore store;

    setUp(() {
      store = SessionStore(CruxDatabase.forTesting(NativeDatabase.memory()));
    });

    tearDown(() async {
      await store.database.close();
    });

    Future<void> addMessage({
      required int sessionId,
      required String role,
      required DateTime when,
      int tokensIn = 0,
      int tokensOut = 0,
      String model = '',
    }) async {
      await store.database
          .into(store.database.messages)
          .insert(
            MessagesCompanion.insert(
              sessionId: sessionId,
              role: role,
              createdAt: when.millisecondsSinceEpoch,
              tokensIn: Value(tokensIn),
              tokensOut: Value(tokensOut),
              model: Value(model),
            ),
          );
    }

    test('counts tokens, turns, and distinct sessions per day', () async {
      final today = DateTime.now();
      final todayStart = DateTime(today.year, today.month, today.day);

      final s1 = await store.create(title: 'a', projectPath: '/p');
      final s2 = await store.create(title: 'b', projectPath: '/p');

      // Session 1: a user turn followed by the assistant reply.
      await addMessage(
        sessionId: s1.id,
        role: 'user',
        when: todayStart.add(const Duration(hours: 9)),
        tokensIn: 10,
      );
      await addMessage(
        sessionId: s1.id,
        role: 'ai',
        when: todayStart.add(const Duration(hours: 9, minutes: 1)),
        tokensIn: 20,
        tokensOut: 15,
      );
      // Session 2: a second user turn, still today.
      await addMessage(
        sessionId: s2.id,
        role: 'user',
        when: todayStart.add(const Duration(hours: 10)),
        tokensIn: 5,
      );

      final stats = await store.messageStore.dailyUsageStats(
        sinceDaysAgo: 7,
        projectPath: '/p',
      );

      String key(DateTime d) =>
          '${d.year}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';

      final todayStats = stats[key(todayStart)]!;
      // (10 + 0) + (20 + 15) + (5 + 0) = 50.
      expect(todayStats.tokens, 50);
      // Two `role: 'user'` messages.
      expect(todayStats.turns, 2);
      // Two distinct sessions.
      expect(todayStats.sessions, 2);
    });

    test('aggregates per-model token totals per day', () async {
      final today = DateTime.now();
      final todayStart = DateTime(today.year, today.month, today.day);

      final s1 = await store.create(title: 'a', projectPath: '/p');

      // Two models, several messages each.
      await addMessage(
        sessionId: s1.id,
        role: 'ai',
        when: todayStart.add(const Duration(hours: 9)),
        tokensIn: 100,
        tokensOut: 50,
        model: 'claude-opus-4',
      );
      await addMessage(
        sessionId: s1.id,
        role: 'ai',
        when: todayStart.add(const Duration(hours: 10)),
        tokensIn: 200,
        model: 'gpt-5.2',
      );
      await addMessage(
        sessionId: s1.id,
        role: 'user',
        when: todayStart.add(const Duration(hours: 11)),
        tokensIn: 5,
        model: 'claude-opus-4', // user tokens count toward the model too
      );

      final stats = await store.messageStore.dailyUsageStats(
        sinceDaysAgo: 7,
        projectPath: '/p',
      );
      final byModel = stats.values.fold<Map<String, int>>(
        {},
        (acc, s) => acc..addAll(s.byModel),
      );
      // claude-opus-4: (100 + 50) from the ai row + 5 from the user
      // row = 155. The aggregate sums every row's tokens under its
      // persisted model — roles don't filter the by-model breakdown.
      expect(byModel['claude-opus-4'], 155);
      expect(byModel['gpt-5.2'], 200);
      // Only models with usage appear — no zero/empty-model entries.
      expect(byModel.length, 2);
    });
  });
}
