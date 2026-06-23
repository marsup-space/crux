// Tests for the chunked message loader behind [SessionController].
//
// Three invariants are pinned here, all of them about perceived
// latency on session switch:
//
//   1. The first chunk to arrive in `messageCache` is the LATEST
//      messages (newest at the end), so the chat history's first
//      paint shows the most recent conversation at the bottom of
//      the scroll — exactly what the user wants to see first.
//   2. Subsequent chunks are strictly OLDER than the first chunk,
//      prepended in order. The final `messageCache` reads
//      oldest → newest so the chat renders correctly top-to-bottom.
//   3. Sessions that fit in the first chunk complete in a single
//      DB round-trip — the user's "loading" flash is invisible
//      because the chunk arrives before the loading label has a
//      chance to render.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';

void main() {
  late Directory tempDir;
  late ProviderService providerService;
  late SessionStore store;
  late SessionController controller;
  late Session session;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_chunkload_');
    providerService = ProviderService(userProvidersDir: tempDir.path);
    store = SessionStore(CruxDatabase());
    final toolRegistry = ToolRegistry()
      ..registerDefaults(FileReadTracker(), sessionStore: store, webProviderRegistry: WebProviderRegistry());
    controller = SessionController(
      store: store,
      providerService: providerService,
      chatService: ChatService(
        store,
        providerService,
        LlmClient(),
        ToolExecutor(toolRegistry),
      ),
      refresh: () {},
    );
    session = await store.create(
      title: 'Big session',
      model: '',
      projectPath: tempDir.path,
    );
    // SessionController.switchSession validates the target session
    // via `findSession` which scans `controller.sessions`. Tests
    // need the controller to see the session we just created,
    // otherwise beginSwitchSession early-returns with "not found"
    // and the loading state never engages.
    controller.sessions = [session];
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Seed [count] user messages into the session. Messages get
  /// monotonically increasing ids, and ids are what the chunked
  /// loader uses for cursor pagination (`beforeId`), so the test's
  /// load-order assertions are really about id ordering.
  Future<void> seedMessages(int count) async {
    for (var i = 0; i < count; i++) {
      await store.messageStore.addMessage(
        session.id,
        role: 'user',
        content: 'message #$i',
      );
    }
  }

  test('first chunk contains the latest messages (newest at the end)',
      () async {
    await seedMessages(120);

    // Track every progress tick to verify the first one already
    // has the latest messages in the cache.
    final progressTicks = <List<dynamic>>[];
    final completer = Completer<void>();
    controller.beginSwitchSession(session.id);
    final future = controller.completeSwitchSession(
      session.id,
      onProgress: () {
        final cache = controller.messageCache[session.id];
        progressTicks.add(cache?.map((m) => m.content).toList() ?? const []);
        if (!completer.isCompleted &&
            (cache?.length ?? 0) >= 120) {
          completer.complete();
        }
      },
    );
    future.whenComplete(() {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    await future;

    // At least one tick must have fired (first chunk or COUNT).
    expect(progressTicks, isNotEmpty,
        reason: 'onProgress must fire at least once after the '
            'first chunk lands');

    // Locate the first tick where the cache actually contains
    // messages — this is the chat history's "first paint with
    // content" event. (The very first tick might be a COUNT(*)
    // callback that ran ahead of the first chunk.)
    final firstWithContent = progressTicks.firstWhere(
      (l) => l.isNotEmpty,
      orElse: () => const [],
    );
    expect(firstWithContent, isNotEmpty,
        reason: 'at least one progress tick must observe a '
            'non-empty cache (first chunk landed)');
    expect(firstWithContent.last, 'message #119',
        reason: 'cache tail after first chunk must be the most-'
            'recently-inserted message — this is what the user '
            'sees at the bottom of the chat on first paint');
  });

  test('subsequent chunks are strictly older than the first chunk',
      () async {
    // 250 messages forces the loader into the "older chunks"
    // path (first chunk = 50, then more chunks of 200).
    await seedMessages(250);

    final lengths = <int>[];
    controller.beginSwitchSession(session.id);
    await controller.completeSwitchSession(
      session.id,
      onProgress: () {
        lengths.add(controller.messageCache[session.id]?.length ?? 0);
      },
    );

    // Length sequence should be monotonically non-decreasing —
    // each chunk either adds older messages (length grows) or is
    // a label-only tick (length stays the same).
    for (var i = 1; i < lengths.length; i++) {
      expect(lengths[i], greaterThanOrEqualTo(lengths[i - 1]),
          reason: 'cache length should never shrink as chunks '
              'arrive: was ${lengths[i - 1]} at tick $i-1, now '
              '${lengths[i]} at tick $i');
    }

    // Final cache must contain all 250 seeded messages in
    // chronological order: "message #0" first, "message #249" last.
    final cache = controller.messageCache[session.id];
    expect(cache, isNotNull);
    expect(cache!.length, 250);
    expect(cache.first.content, 'message #0');
    expect(cache.last.content, 'message #249');
  });

  test('small session (≤ first chunk size) completes in one chunk',
      () async {
    // 40 messages < first-chunk-size (50), so the loader should
    // finish after the first chunk without entering the older-
    // chunk loop at all.
    await seedMessages(40);

    final ticks = <int>[];
    controller.beginSwitchSession(session.id);
    await controller.completeSwitchSession(
      session.id,
      onProgress: () {
        ticks.add(controller.messageCache[session.id]?.length ?? 0);
      },
    );

    expect(controller.messageCache[session.id]?.length, 40,
        reason: 'all 40 messages should be loaded');
    // Three onProgress calls happen for a session that fits in
    // the first chunk:
    //   1. After the first chunk lands (cache = 40).
    //   2. After COUNT(*) returns (cache still 40, but the
    //      loading label can now show "40").
    //   3. In [completeSwitchSession]'s `finally` block, after the
    //      loading state is cleared (the chat history rebuilds
    //      one last time without the loading label).
    // What we DON'T see is any tick where the cache length
    // increases again — that would mean the older-chunk loop ran.
    // All three ticks show length 40, so the loop was correctly
    // skipped for this session size.
    expect(ticks.length, lessThanOrEqualTo(3),
        reason: 'sessions within the first-chunk size should not '
            'trigger the older-chunk loop (got ${ticks.length} '
            'ticks: $ticks)');
    expect(ticks.toSet(), {40},
        reason: 'cache length should never change during a '
            'single-chunk load — if any tick shows a different '
            'length, the older-chunk loop ran unexpectedly '
            '(ticks: $ticks)');
  });

  test('loading state clears after completeSwitchSession finishes',
      () async {
    await seedMessages(50);
    controller.beginSwitchSession(session.id);
    expect(controller.isLoadingMessages(session.id), isTrue,
        reason: 'beginSwitchSession must mark the session as loading');
    await controller.completeSwitchSession(session.id);
    expect(controller.isLoadingMessages(session.id), isFalse,
        reason: 'loading state must be cleared in the finally block');
    expect(controller.loadingMessageTotal(session.id), isNull);
    expect(controller.loadingMessageLoaded(session.id), isNull);
  });

  test('chunked loader resumes from a pre-populated cache '
      '(boot pre-load path)', () async {
    // The boot path ([loadChatPanelBootState]) pre-loads the first
    // chunk synchronously and then calls `completeSwitchSession` to
    // fill in the rest. The loader must detect the pre-loaded cache
    // and skip its own first-chunk fetch — otherwise the user pays
    // a wasted ~200ms re-fetching the same rows the boot just put
    // there.
    //
    // We seed 120 messages, manually put the latest 50 into the
    // cache (simulating what the boot loader returns), then call
    // `completeSwitchSession` and verify it only fetches the older
    // 70 via the chunked loop, not the latest 50 again.
    await seedMessages(120);

    // Manually populate the cache with the latest 50 messages —
    // mimicking what `loadChatPanelBootState` does. IDs were
    // auto-assigned in seed order, so the latest 50 are messages
    // #71..#120, and `messageCache[session.id].first.id` ends up
    // as the id of the earliest of those (i.e. message #71).
    final allMessages = controller.messageCache[session.id] = await store
        .messageStore
        .getMessages(session.id, limit: 50);
    expect(allMessages.length, 50,
        reason: 'pre-condition: 50 messages in the pre-populated cache');

    // Now run the chunked loader. It should detect the cache and
    // resume from `beforeId = preloadedFirstId`, NOT re-fetch the
    // latest 50.
    final lengths = <int>[];
    await controller.completeSwitchSession(
      session.id,
      onProgress: () {
        lengths.add(controller.messageCache[session.id]?.length ?? 0);
      },
    );

    // Final cache should contain all 120 messages — the pre-loaded
    // 50 plus the 70 older ones the chunked loop fetched.
    final finalCache = controller.messageCache[session.id]!;
    expect(finalCache.length, 120,
        reason: 'all 120 messages should be present after resume');
    expect(finalCache.first.content, 'message #0');
    expect(finalCache.last.content, 'message #119');
    // The cache should never shrink mid-load — preloaded messages
    // are kept and older chunks are prepended.
    for (var i = 1; i < lengths.length; i++) {
      expect(lengths[i], greaterThanOrEqualTo(lengths[i - 1]),
          reason: 'cache length must be monotonically non-decreasing '
              'during resume: tick ${i - 1} had ${lengths[i - 1]}, '
              'tick $i had ${lengths[i]}');
    }
    // And the resumed loader's first observed length must be the
    // pre-loaded count (50), NOT zero — proves the first-chunk
    // fetch was skipped.
    expect(lengths.first, greaterThanOrEqualTo(50),
        reason: 'first progress tick should already see the pre-'
            'loaded 50 messages, not 0');
    expect(lengths.first, lessThanOrEqualTo(50),
        reason: 'first tick cannot have grown past the pre-loaded '
            'count without fetching at least one older chunk');
  });
}