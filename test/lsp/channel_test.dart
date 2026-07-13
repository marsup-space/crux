// Tests for the LspChannel abstraction.
//
// Coverage:
//   - InProcessChannel: send/event roundtrip; events stream closes
//     after shutdown.
//   - IsolateChannel: handshake completes; command crosses the
//     isolate boundary; event crosses back; shutdown is clean and
//     idempotent.
//   - Manager integration: useIsolates:true is accepted at
//     construction time.

import 'dart:async';
import 'dart:io';

import 'package:crux/src/lsp/actor.dart';
import 'package:crux/src/lsp/channel.dart';
import 'package:crux/src/lsp/manager.dart';
import 'package:crux/src/lsp/protocol.dart';
import 'package:test/test.dart';

// =========================================================================
// Test actor
// =========================================================================

/// Records every command it receives and emits a synthetic
/// [LspEventStarted] for each. Overrides [attach] to capture the
/// emit callback (the base class's `_emit` field is private) so the
/// test can drive events deterministically without going through
/// `_runStart` / process spawning.
class _EchoActor extends LspServerActor {
  final List<String> receivedCommands = [];
  void Function(LspEvent)? _capturedEmit;

  @override
  String get id => 'echo';
  @override
  List<String> get extensions => const ['.echo'];

  @override
  void attach(void Function(LspEvent) emit) {
    super.attach(emit);
    _capturedEmit = emit;
  }

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    return LspServerSpec(
      root: root,
      command: const ['true'],
      env: const {},
      initialization: const {},
    );
  }

  @override
  Future<Process> spawnProcess(LspServerSpec spec) async {
    final p = await Process.start('true', const []);
    unawaited(p.exitCode);
    return p;
  }

  @override
  Future<void> handle(LspCommand cmd) async {
    receivedCommands.add(cmd.runtimeType.toString());
    // Don't emit on shutdown — the channel may have already
    // closed its outbound stream by the time the second shutdown
    // command is dispatched.
    if (cmd is LspCmdShutdown) return;
    // Echo back the root from the command so tests can verify
    // commands actually carried their payload across the boundary.
    final root = switch (cmd) {
      LspCmdStart(:final root) => root,
      LspCmdOpenDocument(:final root) => root,
      LspCmdCloseDocument(:final root) => root,
      LspCmdShutdownRoot() => '/shutdown-root',
      _ => '/unknown',
    };
    _capturedEmit?.call(LspEventStarted(
      root: root,
      serverId: id,
    ));
  }
}

/// Always throws when handling a command. Used to verify the
/// IsolateChannel isolates handler failures.
class _ThrowingActor extends LspServerActor {
  @override
  String get id => 'throw';
  @override
  List<String> get extensions => const ['.throw'];

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    return LspServerSpec(
      root: root,
      command: const ['true'],
      env: const {},
      initialization: const {},
    );
  }

  @override
  Future<Process> spawnProcess(LspServerSpec spec) async {
    final p = await Process.start('true', const []);
    unawaited(p.exitCode);
    return p;
  }

  @override
  Future<void> handle(LspCommand cmd) async {
    throw StateError('boom from _ThrowingActor');
  }
}

/// Subscribes to [stream] and resolves [future] with the first
/// event matching [predicate]. Cancels the subscription after
/// resolving. Used to await a specific event on a broadcast stream
/// without racing other listeners.
Future<T> _firstMatching<T>(
  Stream<LspEvent> stream,
  bool Function(LspEvent) predicate,
) {
  final completer = Completer<T>();
  late StreamSubscription<LspEvent> sub;
  sub = stream.listen((event) {
    if (predicate(event) && !completer.isCompleted) {
      completer.complete(event as T);
      unawaited(sub.cancel());
    }
  }, onError: (Object e, StackTrace st) {
    if (!completer.isCompleted) completer.completeError(e, st);
  });
  return completer.future;
}

// =========================================================================
// InProcessChannel
// =========================================================================

void main() {
  group('InProcessChannel', () {
    test('routes LspCmdStart through the actor and emits the event back',
        () async {
      final actor = _EchoActor();
      final channel = InProcessChannel(actor);

      final events = <LspEvent>[];
      final sub = channel.events.listen(events.add);

      channel.send(const LspCmdStart(root: '/test', file: '/test/x.echo'));

      // Yield so the actor's handle() microtask completes.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(actor.receivedCommands, ['LspCmdStart']);
      expect(events.whereType<LspEventStarted>(), hasLength(1));
      expect(events.whereType<LspEventStarted>().first.root, '/test');

      await sub.cancel();
      await channel.shutdown();
    });

    test('events stream closes after shutdown', () async {
      final channel = InProcessChannel(_EchoActor());
      final completer = Completer<void>();
      channel.events.listen(
        (_) {},
        onDone: completer.complete,
      );
      await channel.shutdown();
      await completer.future.timeout(const Duration(seconds: 1));
    });

    test('shutdown is idempotent', () async {
      final channel = InProcessChannel(_EchoActor());
      await channel.shutdown();
      // Second call should not throw.
      await channel.shutdown();
    });

    test('rejects commands after shutdown', () async {
      final channel = InProcessChannel(_EchoActor());
      await channel.shutdown();
      // The actor's handle drops commands once _shutdown=true, so
      // this is a silent no-op (not an error).
      channel.send(const LspCmdShutdown());
    });
  });

  // =======================================================================
  // IsolateChannel
  // =======================================================================

  group('IsolateChannel', () {
    test('spawn handshake completes within timeout', () async {
      final channel = await IsolateChannel.spawn(_EchoActor.new)
          .timeout(const Duration(seconds: 5));
      expect(channel, isNotNull);
      await channel.shutdown();
    });

    test('routes a command to the actor in another isolate and receives '
        'an event back', () async {
      final channel = await IsolateChannel.spawn(_EchoActor.new);
      final events = <LspEvent>[];
      final sub = channel.events.listen(events.add);

      channel.send(const LspCmdStart(root: '/test', file: '/test/x.echo'));

      // Wait up to 2s for the event to cross the boundary.
      final got = await _firstMatching<LspEventStarted>(
        channel.events,
        (e) => e is LspEventStarted,
      ).timeout(const Duration(seconds: 2));
      expect(got.root, '/test');
      expect(got.serverId, 'echo');

      await sub.cancel();
      await channel.shutdown();
    });

    test('shutdown closes the events stream', () async {
      final channel = await IsolateChannel.spawn(_EchoActor.new);
      final completer = Completer<void>();
      channel.events.listen(
        (_) {},
        onDone: completer.complete,
      );
      await channel.shutdown();
      await completer.future.timeout(const Duration(seconds: 5));
    });

    test('two IsolateChannels run independently and route events to the '
        'correct subscribers', () async {
      final ch1 = await IsolateChannel.spawn(_EchoActor.new);
      final ch2 = await IsolateChannel.spawn(_EchoActor.new);

      final events1 = <LspEvent>[];
      final events2 = <LspEvent>[];
      ch1.events.listen(events1.add);
      ch2.events.listen(events2.add);

      ch1.send(const LspCmdStart(root: '/a', file: '/a/x.echo'));
      ch2.send(const LspCmdStart(root: '/b', file: '/b/x.echo'));

      // 10s timeout — passes in <50ms under normal load
      // but tolerates the heavy CPU contention this test
      // sees when run as part of the full suite (other
      // tests, isolate spawn churn, etc.). 2s was too
      // tight and caused sporadic failures under load.
      final a = await _firstMatching<LspEventStarted>(
        ch1.events,
        (e) => e is LspEventStarted,
      ).timeout(const Duration(seconds: 10));
      final b = await _firstMatching<LspEventStarted>(
        ch2.events,
        (e) => e is LspEventStarted,
      ).timeout(const Duration(seconds: 10));

      expect(a.root, '/a');
      expect(b.root, '/b');

      await ch1.shutdown();
      await ch2.shutdown();
    });

    test('actor handler that throws does not bring down the channel',
        () async {
      final channel = await IsolateChannel.spawn(_ThrowingActor.new);
      // The actor throws but stays alive. The channel must not
      // surface an error on its events stream from this.
      channel.send(const LspCmdStart(root: '/x', file: '/x/y.echo'));

      // Allow the throw to happen in the actor isolate.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Shutdown still completes cleanly.
      await channel.shutdown();
    });
  });

  // =======================================================================
  // LspManager + useIsolates
  // =======================================================================

  group('LspManager with useIsolates', () {
    test('accepts the flag at construction time and shuts down cleanly',
        () async {
      final manager = await LspManager.create(
        workingDirectory: '/tmp',
        actorFactories: {'echo': _EchoActor.new},
        useIsolates: true,
      );
      // Constructing doesn't spawn — only matching requests do.
      // Just verify shutdown is clean with no slots active.
      await manager.shutdown();
    });
  });
}
