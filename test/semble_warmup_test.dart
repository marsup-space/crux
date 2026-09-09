import 'dart:io';

import 'package:test/test.dart';
import 'package:crux/src/tools/semble_warmup.dart';

void main() {
  group('SembleWarmup', () {
    setUp(() {
      SembleWarmup.instance.debugReset();
    });

    test(
      'start() returns immediately — does NOT block on the warmup',
      () async {
        // Use a path that will make warmup do real work (a small repo),
        // but the assertion is that start() itself returns in well under
        // a second. We then await so the test cleans up.
        final repo = '${Directory.current.path}/.research/semble';

        final t0 = DateTime.now();
        final future = SembleWarmup.instance.start(repo);
        final startElapsed = DateTime.now().difference(t0);

        expect(
          startElapsed.inMilliseconds,
          lessThan(500),
          reason: 'start() must be fire-and-forget at the call site',
        );

        // Cleanup: don't leak the running warmup across tests.
        await future.timeout(const Duration(seconds: 30));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'start() is idempotent — second call returns the same future',
      () async {
        final future1 = SembleWarmup.instance.start('/tmp');
        final future2 = SembleWarmup.instance.start('/tmp');
        expect(
          identical(future1, future2),
          isTrue,
          reason: 'repeated start() must dedupe to the in-flight future',
        );

        // Reset state; don't await (warmup might take a while on /tmp).
        SembleWarmup.instance.debugReset();
      },
    );

    test('awaitReady() always completes, even when the underlying '
        'semble call fails (no exception leaks to the agent loop)', () async {
      final future = SembleWarmup.instance.awaitReady(
        '/nonexistent/path/xyzzy_no_such_dir',
      );
      // Must complete within a reasonable time, must NOT throw.
      await future.timeout(const Duration(seconds: 30));
    }, timeout: const Timeout(Duration(seconds: 35)));

    test('awaitReady() returns the same future as start() — second caller '
        'joins the first warmup instead of triggering a duplicate', () async {
      final startFuture = SembleWarmup.instance.start('/tmp');
      final awaitFuture = SembleWarmup.instance.awaitReady('/tmp');
      expect(identical(startFuture, awaitFuture), isTrue);

      SembleWarmup.instance.debugReset();
    });

    test(
      'debugReset clears state so the next start() kicks a fresh warmup',
      () async {
        // Use a bad path so the warmup fails quickly (and silently).
        final future1 = SembleWarmup.instance.start('/nonexistent/xyzzy1');
        await future1.timeout(const Duration(seconds: 30));
        expect(SembleWarmup.instance.isReady, isTrue);

        SembleWarmup.instance.debugReset();
        expect(SembleWarmup.instance.isReady, isFalse);
        expect(SembleWarmup.instance.isWarming, isFalse);

        final future2 = SembleWarmup.instance.start('/nonexistent/xyzzy2');
        expect(
          identical(future1, future2),
          isFalse,
          reason: 'debugReset must give us a fresh future on next start()',
        );

        await future2.timeout(const Duration(seconds: 30));
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'refresh() is fire-and-forget — returns immediately, spawns process',
      () async {
        // Use a real repo so refresh actually does work. The point is
        // that refresh() itself returns in <500ms.
        final repo = '${Directory.current.path}/.research/semble';

        final t0 = DateTime.now();
        SembleWarmup.instance.refresh(repo);
        final refreshElapsed = DateTime.now().difference(t0);

        expect(
          refreshElapsed.inMilliseconds,
          lessThan(500),
          reason: 'refresh() must be fire-and-forget, like start()',
        );

        // Cleanup: wait for the in-flight refresh to complete so we
        // don't leak state into the next test. Use a path that won't
        // hang.
        SembleWarmup.instance.debugReset();
      },
    );

    test(
      'refresh() is idempotent — concurrent calls collapse to one',
      () async {
        // Issue many refreshes back-to-back. Only one Process.run should
        // actually run at a time (the _refreshing guard coalesces them).
        SembleWarmup.instance.refresh('/nonexistent/xyzzy_r1');
        SembleWarmup.instance.refresh('/nonexistent/xyzzy_r2');
        SembleWarmup.instance.refresh('/nonexistent/xyzzy_r3');
        // The 2nd and 3rd calls are no-ops because _refreshing is true.
        expect(SembleWarmup.instance.isRefreshing, isTrue);

        // Wait for the in-flight refresh to finish (semble on a bad path
        // fails fast, ~1-2s).
        await Future.delayed(const Duration(seconds: 5));
        expect(SembleWarmup.instance.isRefreshing, isFalse);

        SembleWarmup.instance.debugReset();
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });
}
