// Channel abstraction between LspManager (main isolate) and an
// LspServerActor (own isolate, or same isolate in the in-process
// case). Two implementations:
//
//   - [InProcessChannel]: actor and manager run in the same isolate.
//     Events are forwarded through a broadcast [StreamController].
//     Cheap, deterministic, ideal for tests.
//
//   - [IsolateChannel]: actor runs in its own [Isolate], communicating
//     with the manager via paired [SendPort] / [ReceivePort]s. A
//     handshake on startup establishes the actor's incoming port;
//     subsequent commands and events cross the boundary as Dart
//     sendable objects (sealed classes whose fields are primitives,
//     strings, or lists thereof).
//
// The actor's public surface is identical in both modes — it sees a
// `void Function(LspEvent)` callback via [LspServerActor.attach] and
// a stream of [LspCommand]s via [LspChannel.send]. The channel
// implementation decides how to deliver them.
//
// See `docs/design-lsp-actors.md` §2 for the full rationale.

import 'dart:async';
import 'dart:isolate';

import 'actor.dart';
import 'protocol.dart';

/// Map of `serverId` → factory that creates a fresh actor instance.
typedef LspActorFactory = LspServerActor Function();

/// A bidirectional conduit to one running [LspServerActor].
///
/// The manager sends commands via [send] and observes events via
/// [events]. Both implementations expose the same surface so
/// switching between in-process and per-server isolates is a
/// constructor-time decision and never leaks into the manager's
/// logic.
abstract class LspChannel {
  /// Hand [cmd] to the actor. Fire-and-forget; responses (if any)
  /// come back as events on [events].
  void send(LspCommand cmd);

  /// Live stream of events emitted by the actor. Broadcast — multiple
  /// listeners are supported. Closes when the actor has shut down.
  Stream<LspEvent> get events;

  /// Ask the actor to shut down and wait until it has exited (or
  /// the timeout elapses, whichever is first). Safe to call more
  /// than once.
  Future<void> shutdown();
}

// =========================================================================
// InProcessChannel — actor runs in the same isolate as the manager.
// =========================================================================

/// In-process channel: actor and manager share an isolate. Commands
/// are dispatched via direct method calls; events flow through a
/// broadcast [StreamController]. The simplest possible plumbing.
///
/// Used by:
///   - The manager's test path (deterministic, no isolate spawn cost)
///   - The "Option B" migration target if profiling shows per-actor
///     isolates are too expensive (see `design-lsp-actors.md` §10).
class InProcessChannel implements LspChannel {
  final LspServerActor _actor;
  final StreamController<LspEvent> _events =
      StreamController<LspEvent>.broadcast();

  /// Construct an in-process channel wrapping [actor]. The actor's
  /// outbound event callback is wired to the channel's stream on
  /// construction.
  InProcessChannel(this._actor) {
    _actor.attach(_events.add);
  }

  @override
  void send(LspCommand cmd) {
    // Fire-and-forget; the actor's `handle` is async but we don't
    // surface its completion to the caller — events arrive on
    // [events] when the actor has done its work.
    unawaited(_actor.handle(cmd));
  }

  @override
  Stream<LspEvent> get events => _events.stream;

  @override
  Future<void> shutdown() async {
    await _actor.handle(const LspCmdShutdown());
    await _events.close();
  }
}

// =========================================================================
// IsolateChannel — actor runs in its own isolate.
// =========================================================================

/// Cross-isolate channel: the actor lives in a dedicated [Isolate]
/// and communicates with the manager via [SendPort] / [ReceivePort].
///
/// On startup:
///   1. Manager spawns the isolate with [_entryPoint] as `main` and
///      a [_ActorSpawnArgs] containing the actor factory and a
///      [SendPort] pointing back at the manager.
///   2. The isolate sends an [_ActorHandshake] with its incoming
///      [SendPort]. Manager waits for it (5 s timeout).
///   3. Manager returns the channel; subsequent `send` calls
///      dispatch commands to the actor's [ReceivePort]; events
///      emitted by the actor arrive via the manager's
///      [ReceivePort] and are forwarded to subscribers.
///
/// On shutdown:
///   1. Manager sends [LspCmdShutdown].
///   2. Actor handles it (which awaits each server's graceful
///      exit), then closes its [ReceivePort] and sends an
///      [_ActorExited] marker.
///   3. Manager receives the marker, closes its event stream,
///      resolves the exit completer.
///
/// A misbehaving server (or a stalled `initialize` handshake) is
/// isolated to its own isolate — other servers and the TUI keep
/// running.
class IsolateChannel implements LspChannel {
  SendPort? _send;
  ReceivePort? _receive;
  final StreamController<LspEvent> _events =
      StreamController<LspEvent>.broadcast();
  final Completer<void> _exit = Completer<void>();
  bool _shutdownSent = false;

  /// Construct a channel that hasn't yet received the actor's
  /// handshake. The first message on [receive] will set the
  /// SendPort via [_setSendPort]. Used only by [spawn].
  IsolateChannel._pending(ReceivePort receive) : _receive = receive;

  /// Record the actor's incoming [SendPort] from the handshake.
  /// Must be called exactly once. After this, [send] works.
  void _setSendPort(SendPort send) {
    _send = send;
  }

  /// Spawn an isolate running [factory]() as the actor and return
  /// a channel bound to it. Throws [TimeoutException] if the
  /// handshake doesn't complete within 5 seconds (the isolate
  /// crashed or never started).
  static Future<IsolateChannel> spawn(LspActorFactory factory) async {
    final mainReceive = ReceivePort();
    final channel = IsolateChannel._pending(mainReceive);
    final handshake = Completer<SendPort>();

    // Single listener: dispatches the handshake (first message)
    // and continues forwarding events / exit markers for the life
    // of the channel. ReceivePort is single-subscription, so we
    // can't have two listeners — handshake + events share one.
    mainReceive.listen((msg) {
      if (!handshake.isCompleted && msg is _ActorHandshake) {
        handshake.complete(msg.peerPort);
        // Don't return — keep listening for events.
      }
      channel._onMessage(msg);
    }, onError: channel._onReceiveError);

    await Isolate.spawn(
      _entryPoint,
      _ActorSpawnArgs(
        actorFactory: factory,
        mainPort: mainReceive.sendPort,
      ),
      debugName: 'lsp-actor',
    );

    final peerPort = await handshake.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        mainReceive.close();
        throw TimeoutException('LSP actor handshake timed out');
      },
    );
    channel._setSendPort(peerPort);
    return channel;
  }

  /// Entry point for the actor isolate. Sets up the [ReceivePort],
  /// sends the handshake, wires the actor's outbound events to the
  /// manager, and processes commands until shutdown.
  static void _entryPoint(_ActorSpawnArgs args) {
    final actor = args.actorFactory();
    final receivePort = ReceivePort();
    final handshake = _ActorHandshake(receivePort.sendPort);
    args.mainPort.send(handshake);

    final sink = _OutboundSink(args.mainPort);
    actor.attach(sink.add);

    receivePort.listen((msg) async {
      if (msg is! LspCommand) return;
      try {
        await actor.handle(msg);
      } catch (_) {
        // A thrown handler shouldn't tear down the isolate. The
        // manager will see the actor go silent and surface its own
        // timeout / error. Stack traces are logged by the actor
        // internally; we don't ship them across the boundary.
      }
      if (msg is LspCmdShutdown) {
        try {
          receivePort.close();
          args.mainPort.send(const _ActorExited(0));
        } catch (_) {
          // Manager side already gone; nothing to do.
        }
      }
    });
  }

  @override
  void send(LspCommand cmd) {
    if (_shutdownSent) return;
    final send = _send;
    if (send == null) return;       // handshake not yet complete
    send.send(cmd);
  }

  @override
  Stream<LspEvent> get events => _events.stream;

  @override
  Future<void> shutdown() async {
    if (_shutdownSent) return;
    _shutdownSent = true;
    final send = _send;
    if (send != null) {
      send.send(const LspCmdShutdown());
    }
    // Wait for the actor to ack its own shutdown (via _ActorExited)
    // or for the timeout. If the actor has already crashed, the
    // stream error listener completes _exit early.
    try {
      await _exit.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    } finally {
      // Close the receive port so the listener stops firing and
      // the channel can be GC'd. Idempotent — close() is safe to
      // call multiple times.
      _receive?.close();
      _receive = null;
    }
  }

  void _onMessage(dynamic msg) {
    if (msg is LspEvent) {
      if (!_events.isClosed) _events.add(msg);
    } else if (msg is _ActorExited) {
      if (!_exit.isCompleted) _exit.complete();
      if (!_events.isClosed) _events.close();
    }
    // Anything else (notably _ActorHandshake, already handled in
    // the spawn listener) is silently dropped — protocol violation
    // by the actor, but we don't want to crash the manager.
  }

  void _onReceiveError(Object e, StackTrace st) {
    if (!_events.isClosed) _events.addError(e, st);
    if (!_exit.isCompleted) _exit.complete();
  }
}

// =========================================================================
// Internal protocol types — never escape the channel layer.
// =========================================================================

/// First message sent by a freshly-spawned actor isolate. Carries
/// the [SendPort] the manager should use to send commands.
class _ActorHandshake {
  final SendPort peerPort;
  const _ActorHandshake(this.peerPort);
}

/// Final message sent by a shutting-down actor isolate. Resolves the
/// channel's exit completer.
class _ActorExited {
  final int? code;
  const _ActorExited(this.code);
}

/// Arguments passed to [Isolate.spawn] for the actor isolate.
class _ActorSpawnArgs {
  final LspActorFactory actorFactory;
  final SendPort mainPort;
  _ActorSpawnArgs({
    required this.actorFactory,
    required this.mainPort,
  });
}

/// Adapts the actor's `void Function(LspEvent)` callback to a
/// [SendPort]. Lives in the actor isolate.
class _OutboundSink {
  final SendPort _mainPort;
  _OutboundSink(this._mainPort);

  void add(LspEvent event) {
    try {
      _mainPort.send(event);
    } catch (_) {
      // Manager side closed the receive port; swallow.
    }
  }
}
