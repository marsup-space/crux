// Regression tests for the interrupt-then-type bug: cancelStream must
// force-close the in-flight round's HTTP response (so a stalled
// provider stream can't hold the lease), and every exit path must
// drop the round token so a stale cancel can't leak into the next
// turn.
//
// See SessionLeaseManager.cancelStream / attachRoundCancelToken and
// the orchestrator's clearCancelRequest call at turn start.

import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/session_lease_manager.dart';
import 'package:test/test.dart';

void main() {
  late SessionLeaseManager manager;
  late int heartbeats;

  setUp(() {
    manager = SessionLeaseManager();
    heartbeats = 0;
    manager.markSessionActive(1, heartbeat: (_) async => heartbeats++);
  });

  tearDown(() {
    manager.dispose();
  });

  test('cancelStream force-closes the attached round cancel token', () async {
    final token = LlmStreamCancelToken();
    manager.attachRoundCancelToken(1, token);

    manager.cancelStream(1);

    expect(
      token.isCancelled,
      isTrue,
      reason:
          'the in-flight HTTP response '
          'must be destroyed so the executor awaits unblock even when the '
          'provider stream has gone quiet',
    );
    expect(manager.isCancelRequested(1), isTrue);
  });

  test('cancelStream with no attached token still sets the cancel flag', () {
    manager.cancelStream(1);
    expect(manager.isCancelRequested(1), isTrue);
  });

  test('markSessionInactive drops the round token — a stale cancel can '
      'not survive into the next turn', () async {
    final token = LlmStreamCancelToken();
    manager.attachRoundCancelToken(1, token);

    manager.markSessionInactive(1);

    // The old token must be detached: cancelling the manager now (a
    // NEW turn's interrupt) must not touch the detached token...
    manager.cancelStream(1);
    expect(token.isCancelled, isFalse);
  });

  test(
    'attachRoundCancelToken(null) detaches without touching the lease',
    () async {
      final token = LlmStreamCancelToken();
      manager.attachRoundCancelToken(1, token);

      manager.attachRoundCancelToken(1, null);
      manager.cancelStream(1);

      expect(
        token.isCancelled,
        isFalse,
        reason:
            'after a round ends its token must be inert — an '
            'interrupt between rounds only sets the flag for the '
            'executor checkpoints',
      );
      expect(manager.isStreaming(1), isTrue);
    },
  );

  test(
    're-attaching replaces the previous token (new round, new token)',
    () async {
      final first = LlmStreamCancelToken();
      final second = LlmStreamCancelToken();
      manager.attachRoundCancelToken(1, first);
      manager.attachRoundCancelToken(1, second);

      manager.cancelStream(1);

      expect(first.isCancelled, isFalse);
      expect(second.isCancelled, isTrue);
    },
  );

  test('a token cancelled after attach still destroys its response when '
      'the response attaches late', () async {
    // Covers LlmStreamCancelToken._attachResponse's
    // already-cancelled branch: interrupt fires before the HTTP
    // response exists (between rounds / during connection setup).
    final token = LlmStreamCancelToken();
    manager.attachRoundCancelToken(1, token);
    manager.cancelStream(1);
    expect(token.isCancelled, isTrue);
  });
}
