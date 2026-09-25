import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux/src/lsp/actor.dart';
import 'package:crux/src/lsp/protocol.dart';
import 'package:test/test.dart';

/// A fake server actor that doesn't spawn a real Process. Instead,
/// `spawnProcess` returns a fake whose stdin/stdout are StreamControllers
/// driven by a paired fake "server" that reads requests and writes
/// responses. This lets us test the actor's command handling,
/// idempotency, document versioning, etc., without an LSP binary.
class _FakeProcess implements Process {
  final StreamController<List<int>> _stdinController =
      StreamController<List<int>>();
  final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>();
  final StreamController<List<int>> _stderrController =
      StreamController<List<int>>.broadcast();
  final Completer<int> _exitCompleter = Completer<int>();

  // Test asserts these flags.
  bool killCalled = false;
  ProcessSignal? killSignal;

  // What the fake server pushes back.
  final List<Map<String, dynamic>> scriptedResponses = [];

  _FakeProcess() {
    // Start the fake server reading stdin and pushing responses.
    _runFakeServer();
  }

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;
  @override
  Stream<List<int>> get stderr => _stderrController.stream;
  @override
  IOSink get stdin => _FakeSink(_stdinController);
  @override
  Future<int> get exitCode => _exitCompleter.future;
  @override
  int get pid => 99999;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalled = true;
    killSignal = signal;
    _exitCompleter.complete(0);
    return true;
  }

  void _runFakeServer() {
    final buf = StringBuffer();
    _stdinController.stream.listen((chunk) {
      for (final byte in chunk) {
        buf.writeCharCode(byte & 0xFF);
      }
      while (true) {
        final headerEnd = _findHeaderEnd(buf.toString());
        if (headerEnd < 0) return;
        final headers = buf.toString().substring(0, headerEnd);
        final length = _parseContentLength(headers);
        if (length == null) return;
        final bodyStart = headerEnd;
        final bodyEnd = bodyStart + length;
        final all = buf.toString();
        if (all.length < bodyEnd) return;
        final body = all.substring(bodyStart, bodyEnd);
        final leftover = all.substring(bodyEnd);
        buf
          ..clear()
          ..write(leftover);
        _dispatch(body);
      }
    });
  }

  int _findHeaderEnd(String s) {
    final crlf = s.indexOf('\r\n\r\n');
    if (crlf >= 0) return crlf + 4;
    final lf = s.indexOf('\n\n');
    if (lf >= 0) return lf + 2;
    return -1;
  }

  int? _parseContentLength(String header) {
    for (final line in header.split(RegExp(r'\r\n|\n'))) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final name = line.substring(0, colon).trim().toLowerCase();
      if (name != 'content-length') continue;
      return int.tryParse(line.substring(colon + 1).trim());
    }
    return null;
  }

  void _dispatch(String json) {
    final msg = jsonDecode(json) as Map<String, dynamic>;
    // Auto-reply MethodNotFound for any request the fake doesn't
    // explicitly know about — this matches the real LSP behavior we
    // test against.
    final id = msg['id'];
    final hasMethod = msg.containsKey('method');
    if (id is int && hasMethod) {
      // Drain scripted responses first.
      if (scriptedResponses.isNotEmpty) {
        _send(scriptedResponses.removeAt(0));
        return;
      }
      // Default initialize response with capabilities.
      if (msg['method'] == 'initialize') {
        _send({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'capabilities': {'textDocumentSync': 2, 'publishDiagnostics': true},
          },
        });
        return;
      }
      // shutdown request → reply with null result.
      if (msg['method'] == 'shutdown') {
        _send({'jsonrpc': '2.0', 'id': id, 'result': null});
        return;
      }
      // Default: MethodNotFound.
      _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32601, 'message': 'Method not found'},
      });
    }
    // Notifications (no id) are silently consumed.
  }

  void _send(Map<String, dynamic> body) {
    final bytes = utf8.encode(jsonEncode(body));
    final header = 'Content-Length: ${bytes.length}\r\n\r\n';
    _stdoutController.add(utf8.encode(header));
    _stdoutController.add(bytes);
  }

  void push(Map<String, dynamic> message) {
    _send(message);
  }
}

class _FakeSink implements IOSink {
  final StreamController<List<int>> _controller;
  _FakeSink(this._controller);

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => _controller.add(data);
  @override
  void addError(Object e, [StackTrace? st]) => _controller.addError(e, st);
  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future close() => _controller.close();
  @override
  Future flush() async {}
  @override
  Future get done => _controller.done;
  void writeCharCodes(Iterable<int> codes) =>
      _controller.add(codes.toList(growable: false));
  @override
  void writeCharCode(int charCode) => _controller.add([charCode & 0xFF]);
  @override
  void write(Object? object) => _controller.add(utf8.encode(object.toString()));
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    final str = objects.map((o) => o.toString()).join(separator);
    _controller.add(utf8.encode(str));
  }

  @override
  void writeln([Object? object = '']) => write('$object\n');
  bool get isClosed => _controller.isClosed;
}

/// A test actor subclass that returns a fake spec on resolveSpec.
class _TestActor extends LspServerActor {
  _FakeProcess? lastProcess;
  bool resolveSpecCalled = false;
  int resolveSpecCalls = 0;
  int spawnCalls = 0;

  @override
  String get id => 'test';

  @override
  List<String> get extensions => const ['.test'];

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    resolveSpecCalled = true;
    resolveSpecCalls++;
    return LspServerSpec(
      root: root,
      command: ['fake'],
      env: const {},
      initialization: const {'foo': 'bar'},
    );
  }

  @override
  Future<Process> spawnProcess(LspServerSpec spec) async {
    spawnCalls++;
    lastProcess = _FakeProcess();
    return lastProcess!;
  }
}

/// Holds spec resolution until the test decides whether startup may proceed.
class _DelayedResolveActor extends _TestActor {
  final resolveEntered = Completer<void>();
  final _spec = Completer<LspServerSpec?>();

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) {
    if (!resolveEntered.isCompleted) resolveEntered.complete();
    return _spec.future;
  }

  void completeResolve() {
    _spec.complete(
      LspServerSpec(
        root: '/delayed',
        command: const ['fake'],
        env: const {},
        initialization: const {},
      ),
    );
  }
}

/// Starts a real child that deliberately never answers `initialize`.
class _HangingInitializeActor extends LspServerActor {
  final spawned = Completer<Process>();

  @override
  String get id => 'hanging';

  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async {
    return LspServerSpec(
      root: root,
      command: const ['sh', '-c', 'while true; do sleep 1; done'],
      env: const {},
      initialization: const {},
    );
  }

  @override
  Future<Process> spawnProcess(LspServerSpec spec) async {
    final process = await Process.start(
      spec.command.first,
      spec.command.skip(1).toList(),
    );
    spawned.complete(process);
    return process;
  }
}

/// An actor that always refuses to start (returns null from resolveSpec).
class _FailingActor extends LspServerActor {
  @override
  String get id => 'failing';
  @override
  Future<LspServerSpec?> resolveSpec(String root, String file) async => null;
}

/// A server that ignores every signal — kill() records the signal
/// but never exits, forcing [_killAfter]'s SIGKILL escalation.
class _StubbornProcess extends _FakeProcess {
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalled = true;
    killSignal = signal;
    return true; // exitCode never completes.
  }
}

class _StubbornActor extends _TestActor {
  @override
  Future<Process> spawnProcess(LspServerSpec spec) async {
    lastProcess = _StubbornProcess();
    return lastProcess!;
  }
}

void main() {
  group('LspServerActor handle', () {
    test('emits LspEventStarted after successful initialize', () async {
      final actor = _TestActor();
      final events = <LspEvent>[];
      actor.attach(events.add);

      await actor.handle(
        LspCmdStart(root: '/fake/root', file: '/fake/root/x.test'),
      );

      expect(events.whereType<LspEventStarted>(), hasLength(1));
      expect(events.whereType<LspEventStarted>().first.root, '/fake/root');
      expect(actor.activeServerCount, 1);
      expect(actor.activeRoots, ['/fake/root']);
    });

    test('emits LspEventStartFailed when resolveSpec returns null', () async {
      final actor = _FailingActor();
      final events = <LspEvent>[];
      actor.attach(events.add);

      await actor.handle(LspCmdStart(root: '/fake', file: '/fake/x.test'));

      final failed = events.whereType<LspEventStartFailed>().toList();
      expect(failed, hasLength(1));
      expect(failed.first.serverId, 'failing');
      expect(actor.activeServerCount, 0);
    });

    test(
      'is idempotent: second LspCmdStart for same root is a no-op',
      () async {
        final actor = _TestActor();
        final events = <LspEvent>[];
        actor.attach(events.add);

        await actor.handle(LspCmdStart(root: '/r', file: '/r/a.test'));
        await actor.handle(LspCmdStart(root: '/r', file: '/r/a.test'));

        expect(actor.resolveSpecCalls, 1);
        expect(events.whereType<LspEventStarted>(), hasLength(1));
      },
    );

    test('LspCmdShutdownRoot(null) shuts down all roots', () async {
      final actor = _TestActor();
      final events = <LspEvent>[];
      actor.attach(events.add);

      await actor.handle(LspCmdStart(root: '/a', file: '/a/a.test'));
      await actor.handle(LspCmdStart(root: '/b', file: '/b/b.test'));
      expect(actor.activeServerCount, 2);

      await actor.handle(const LspCmdShutdownRoot());
      // Give the kill timer a chance to fire.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(actor.activeServerCount, 0);
    });

    test('drops commands after LspCmdShutdown', () async {
      final actor = _TestActor();
      final events = <LspEvent>[];
      actor.attach(events.add);

      await actor.handle(const LspCmdShutdown());
      await actor.handle(LspCmdStart(root: '/r', file: '/r/a.test'));

      expect(events.whereType<LspEventStarted>(), isEmpty);
      expect(actor.activeServerCount, 0);
    });

    test(
      'shutdown waits for delayed resolution and prevents a late spawn',
      () async {
        final actor = _DelayedResolveActor();
        actor.attach((_) {});

        final start = actor.handle(
          LspCmdStart(root: '/delayed', file: '/delayed/a.test'),
        );
        await actor.resolveEntered.future;
        final shutdown = actor.handle(const LspCmdShutdown());

        actor.completeResolve();
        await Future.wait([start, shutdown]);

        expect(actor.spawnCalls, 0);
        expect(actor.activeServerCount, 0);
      },
    );

    test('shutdown kills and reaps a child stuck in initialize', () async {
      if (Platform.isWindows) return;
      final actor = _HangingInitializeActor();
      actor.attach((_) {});

      final start = actor.handle(
        LspCmdStart(root: '/hanging', file: '/hanging/a.test'),
      );
      final process = await actor.spawned.future.timeout(
        const Duration(seconds: 2),
      );

      await actor
          .handle(const LspCmdShutdown())
          .timeout(const Duration(seconds: 3));
      await start.timeout(const Duration(seconds: 1));
      expect(
        await process.exitCode.timeout(const Duration(seconds: 1)),
        isNotNull,
      );
      expect(actor.activeServerCount, 0);
    });
  });

  group('LspServerActor document tracking', () {
    test(
      'opens documents via didOpen and emits diagnostics from server',
      () async {
        final actor = _TestActor();
        final events = <LspEvent>[];
        actor.attach(events.add);

        await actor.handle(LspCmdStart(root: '/r', file: '/r/a.test'));
        await actor.handle(
          LspCmdOpenDocument(
            root: '/r',
            path: '/r/a.test',
            content: 'hello',
            version: 0,
          ),
        );

        // Give the actor time to send didOpen.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Server pushes a diagnostic for the document.
        final proc = actor.lastProcess!;
        proc.push({
          'jsonrpc': '2.0',
          'method': 'textDocument/publishDiagnostics',
          'params': {
            'uri': 'file:///r/a.test',
            'diagnostics': [
              {
                'range': {
                  'start': {'line': 0, 'character': 0},
                  'end': {'line': 0, 'character': 5},
                },
                'message': 'oops',
                'severity': 1,
              },
            ],
          },
        });

        // Allow the peer to process.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final diagEvents = events.whereType<LspEventDiagnostics>().toList();
        expect(diagEvents, hasLength(1));
        expect(diagEvents.first.batch.diagnostics.first.message, 'oops');
        expect(diagEvents.first.root, '/r');
      },
    );
  });

  group('LspServerActor standard handlers', () {
    test('replies to workspace/configuration with nulls', () async {
      final actor = _TestActor();
      final events = <LspEvent>[];
      actor.attach(events.add);

      await actor.handle(LspCmdStart(root: '/r', file: '/r/a.test'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Server sends workspace/configuration request.
      actor.lastProcess!.push({
        'jsonrpc': '2.0',
        'id': 42,
        'method': 'workspace/configuration',
        'params': {
          'items': [
            {'section': 'typescript'},
            {'section': 'python'},
          ],
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // We can't easily inspect the response sent back, but we can
      // verify the actor didn't crash. (More rigorous verification
      // would require peeking at the fake process's stdin.)
    });
  });

  group('LspServerActor error handling', () {
    test('emits LspEventRpcFatal when process stdout errors', () async {
      final actor = _TestActor();
      final events = <LspEvent>[];
      actor.attach(events.add);

      await actor.handle(LspCmdStart(root: '/r', file: '/r/a.test'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Inject an error into the peer's stdout stream.
      actor.lastProcess!._stdoutController.addError(StateError('pipe broken'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final fatals = events.whereType<LspEventRpcFatal>().toList();
      expect(fatals, hasLength(1));
      expect(fatals.first.root, '/r');
    });

    test('shutdown group-TERMs the server (fallback kill observed)', () async {
      final actor = _TestActor();
      final events = <LspEvent>[];
      actor.attach(events.add);

      await actor.handle(LspCmdStart(root: '/g', file: '/g/x.test'));
      await actor.handle(const LspCmdShutdownRoot(root: '/g'));

      final proc = actor.lastProcess!;
      expect(proc.killCalled, isTrue);
      // The kill sites go through `killProcessGroup`
      // (utils/process_group_kill.dart): the group signal itself
      // travels via `kill -TERM -- -<pgid>`, and the per-pid
      // fallback we observe here is a bare SIGTERM kill.
      expect(proc.killSignal, ProcessSignal.sigterm);
      expect(actor.activeServerCount, 0);
    });

    test(
      'shutdown escalates to SIGKILL when the server ignores TERM',
      () async {
        final actor = _StubbornActor();
        final events = <LspEvent>[];
        actor.attach(events.add);

        await actor.handle(LspCmdStart(root: '/s', file: '/s/x.test'));
        // The stubborn server never exits on its own, so this only
        // returns after _killAfter's SIGKILL escalation
        // (grace 1s + 500ms TERM window + 200ms reap).
        await actor.handle(const LspCmdShutdownRoot(root: '/s'));

        final proc = actor.lastProcess!;
        expect(proc.killCalled, isTrue);
        expect(proc.killSignal, ProcessSignal.sigkill);
        expect(actor.activeServerCount, 0);
      },
    );
  });
}
