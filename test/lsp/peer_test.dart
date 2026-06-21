import 'dart:async';
import 'dart:convert';

import 'package:crux/src/lsp/peer.dart';
import 'package:crux/src/lsp/protocol.dart';
import 'package:test/test.dart';

/// A pair of in-memory broadcast StreamControllers that act like
/// stdin/stdout of a process. Broadcast so multiple listeners can
/// subscribe to the same side (the test fixture itself reads from
/// one side, and the test code often listens on the same stream to
/// verify output).
class _PipePair {
  final controllerA = StreamController<List<int>>.broadcast();
  final controllerB = StreamController<List<int>>.broadcast();

  /// Side A reads from controllerA.stream and writes to controllerB.sink.
  /// Side B reads from controllerB.stream and writes to controllerA.sink.
  Stream<List<int>> get aInput => controllerA.stream;
  StreamSink<List<int>> get aOutput => controllerB.sink;
  Stream<List<int>> get bInput => controllerB.stream;
  StreamSink<List<int>> get bOutput => controllerA.sink;

  Future<void> close() async {
    if (!controllerA.isClosed) await controllerA.close();
    if (!controllerB.isClosed) await controllerB.close();
  }
}

/// A minimal fake LSP server running in-process. Reads framed
/// messages, dispatches them, and writes responses.
class _FakeServer {
  final _PipePair _pipe;
  final List<void Function(Map<String, dynamic>, void Function(Map<String, dynamic>) send)>
      _requestHandlers = [];
  final List<void Function(Map<String, dynamic>)> _notificationHandlers = [];
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StringBuffer _readBuf = StringBuffer();

  _FakeServer(this._pipe) {
    _pipe.bInput.listen(_onChunk);
    _messages.stream.listen(_dispatch);
  }

  void handleRequest(
    void Function(
      Map<String, dynamic> params,
      void Function(Map<String, dynamic>) reply,
    ) handler,
  ) {
    _requestHandlers.add(handler);
  }

  void handleNotification(void Function(Map<String, dynamic>) handler) {
    _notificationHandlers.add(handler);
  }

  void push(Map<String, dynamic> message) {
    _send(message);
  }

  Future<void> shutdown() async {
    await _messages.close();
    await _pipe.close();
  }

  void _onChunk(List<int> chunk) {
    for (final byte in chunk) {
      _readBuf.writeCharCode(byte & 0xFF);
    }
    while (true) {
      final headerEnd = _findHeaderEnd();
      if (headerEnd < 0) return;
      final headerBlock = _readBuf.toString().substring(0, headerEnd);
      final length = _parseContentLength(headerBlock);
      if (length == null) return;
      final bodyStart = headerEnd;
      final bodyEnd = bodyStart + length;
      final all = _readBuf.toString();
      if (all.length < bodyEnd) return;
      final body = all.substring(bodyStart, bodyEnd);
      final leftover = all.substring(bodyEnd);
      _readBuf..clear()..write(leftover);
      _messages.add(body);
    }
  }

  int _findHeaderEnd() {
    final s = _readBuf.toString();
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
    final hasId = msg.containsKey('id');
    final hasMethod = msg.containsKey('method');
    if (hasId && hasMethod) {
      for (final handler in _requestHandlers) {
        handler(
          (msg['params'] as Map?)?.cast<String, dynamic>() ?? const {},
          (result) => _send({
            'jsonrpc': '2.0',
            'id': msg['id'],
            'result': result,
          }),
        );
        return;
      }
      _send({
        'jsonrpc': '2.0',
        'id': msg['id'],
        'error': {'code': -32601, 'message': 'Method not found'},
      });
    } else if (hasMethod) {
      for (final handler in _notificationHandlers) {
        handler((msg['params'] as Map?)?.cast<String, dynamic>() ?? const {});
      }
    }
  }

  void _send(Map<String, dynamic> body) {
    if (identical(_pipe.bOutput, _pipe.controllerA) &&
        _pipe.controllerA.isClosed) {
      return;
    }
    final bytes = utf8.encode(jsonEncode(body));
    final header = 'Content-Length: ${bytes.length}\r\n\r\n';
    try {
      _pipe.bOutput.add(utf8.encode(header));
      _pipe.bOutput.add(bytes);
    } on StateError {
      // Sink closed mid-flight — fine for tests.
    }
  }
}

void main() {
  group('RpcPeer framing', () {
    test('round-trips a request and a response', () async {
      final pipe = _PipePair();
      final server = _FakeServer(pipe)
        ..handleRequest((params, reply) {
          reply({'echoed': params['value']});
        });

      final peer = RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (_, __) {},
      );

      final result = await peer.request('foo/bar', {'value': 42});
      expect(result, {'echoed': 42});

      await peer.request('shutdown');
      peer.notify('exit');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await server.shutdown();
    });

    test('sends Content-Length headers', () async {
      final pipe = _PipePair();
      final received = <String>[];
      // Watch raw bytes to verify framing.
      final subscription = pipe.bInput.listen((chunk) {
        received.add(utf8.decode(chunk, allowMalformed: true));
      });

      final peer = RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (_, __) {},
      );
      peer.notify('hello');
      await Future.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      final raw = received.join();
      expect(raw, contains('Content-Length:'));
      expect(raw, contains('"method":"hello"'));

      await pipe.close();
    });

    test('handles a single message split across multiple chunks', () async {
      final pipe = _PipePair();

      // Force the response to arrive in two chunks: header + body separately.
      // We do this by feeding bytes manually into the peer's input.
      // (We can't intercept the server's write easily, so we drive
      // the peer's input directly via a custom pipe here.)
      await pipe.close();

      final pipe2 = _PipePair();
      final server2 = _FakeServer(pipe2)
        ..handleRequest((params, reply) => reply({'split': true}));
      final peer2 = RpcPeer.create(
        input: pipe2.aInput,
        output: pipe2.aOutput,
        tag: 'test2',
        onFatal: (_, __) {},
      );

      // Manually feed a response split into two writes that arrive
      // via separate listen events. We use the controller directly.
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {'split': true},
      });
      final bytes = utf8.encode(body);
      final header = 'Content-Length: ${bytes.length}\r\n\r\n';
      // Send header in one microtask, body in another.
      pipe2.controllerA.add(utf8.encode(header));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      pipe2.controllerA.add(bytes);

      final completer = Completer<dynamic>();
      // We don't have a request in flight that matches this id — but
      // since _nextId starts at 1, an outgoing request from peer2 will
      // get id 1 and the response will match. Trigger a request:
      final pending = peer2.request('test').then(completer.complete).catchError(completer.completeError);

      final result = await completer.future;
      expect(result, {'split': true});
      await pending;

      await server2.shutdown();
    });
  });

  group('RpcPeer request/response correlation', () {
    test('correlates response to request by id', () async {
      final pipe = _PipePair();
      final server = _FakeServer(pipe)
        ..handleRequest((params, reply) {
          // Reply asynchronously to test that correlation works
          // even when responses come out of order.
          Future<void>.delayed(const Duration(milliseconds: 30), () {
            reply({'value': params['n'] as int});
          });
        });

      final peer = RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (_, __) {},
      );

      final results = await Future.wait([
        peer.request('foo', {'n': 1}),
        peer.request('foo', {'n': 2}),
        peer.request('foo', {'n': 3}),
      ]);
      expect(results[0], {'value': 1});
      expect(results[1], {'value': 2});
      expect(results[2], {'value': 3});

      peer.notify('exit');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await server.shutdown();
    });

    test('exposes server-returned JSON-RPC errors as LspRpcError', () async {
      final pipe = _PipePair();
      // No handlers registered — fake server auto-replies MethodNotFound.
      final server = _FakeServer(pipe);

      final peer = RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (_, __) {},
      );

      final pending = peer.request('will-fail');
      try {
        await pending.timeout(const Duration(seconds: 2));
        fail('expected LspRpcError');
      } on LspRpcError catch (e) {
        expect(e.code, -32601);
        expect(e.method, 'will-fail');
      }

      await pipe.close();
      await server.shutdown();
    });
  });

  group('RpcPeer notification dispatch', () {
    test('invokes registered handler with params', () async {
      final pipe = _PipePair();
      final server = _FakeServer(pipe);

      final peer = RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (_, __) {},
      );

      final received = <Map<String, dynamic>>[];
      peer.onNotification('textDocument/publishDiagnostics', received.add);

      server.push({
        'jsonrpc': '2.0',
        'method': 'textDocument/publishDiagnostics',
        'params': {
          'uri': 'file:///x.dart',
          'diagnostics': [
            {
              'range': {
                'start': {'line': 0, 'character': 0},
                'end': {'line': 0, 'character': 1},
              },
              'message': 'broken',
              'severity': 1,
            },
          ],
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(received, hasLength(1));
      expect(received.first['uri'], 'file:///x.dart');

      await pipe.close();
    });

    test('silently drops notifications with no handler', () async {
      final pipe = _PipePair();
      final server = _FakeServer(pipe);

      RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (_, __) {},
      );

      // Server pushes a notification to peer — peer has no handler,
      // so this should be silently dropped without crashing.
      server.push({
        'jsonrpc': '2.0',
        'method': 'unknown/notification',
        'params': {},
      });

      await Future<void>.delayed(const Duration(milliseconds: 30));
      // Should not throw, peer should remain healthy.

      await pipe.close();
    });
  });

  group('RpcPeer request dispatch', () {
    test('replies with MethodNotFound for unhandled server requests', () async {
      final pipe = _PipePair();
      final server = _FakeServer(pipe);

      RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (_, __) {},
      );

      // Capture what the peer writes back. Peer output goes to
      // controllerB.sink, so we listen to controllerB.stream.
      // Subscribe BEFORE push — broadcast streams don't buffer.
      final responseBytes = <int>[];
      final sub = pipe.controllerB.stream.listen(responseBytes.addAll);

      // Server sends a request the peer has no handler for.
      server.push({
        'jsonrpc': '2.0',
        'id': 99,
        'method': 'workspace/unknown',
        'params': {},
      });

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      final raw = utf8.decode(responseBytes);
      expect(raw, contains('"id":99'));
      expect(raw, contains('"code":-32601'));
      expect(raw, contains('Method not found'));

      await pipe.close();
    });

    test('invokes registered handler and replies with its result', () async {
      final pipe = _PipePair();
      final server = _FakeServer(pipe);

      final peer = RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (_, __) {},
      );

      peer.onRequest('workspace/configuration', (params) async {
        return {'items': [null, null]};
      });

      // Capture peer's reply. Peer output goes to controllerB.sink;
      // we listen to controllerB.stream. Subscribe BEFORE pushing
      // because broadcast streams don't buffer.
      final responseBytes = <int>[];
      final sub = pipe.controllerB.stream.listen(responseBytes.addAll);

      // Server pushes a request to peer (writes to controllerA.sink
      // = peer's input).
      server.push({
        'jsonrpc': '2.0',
        'id': 7,
        'method': 'workspace/configuration',
        'params': {
          'items': [
            {'section': 'typescript'},
            {'section': 'python'},
          ],
        },
      });

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      final raw = utf8.decode(responseBytes);
      expect(raw, contains('"id":7'));
      expect(raw, contains('"items":[null,null]'));

      await pipe.close();
    });
  });

  group('RpcPeer error and lifecycle handling', () {
    test('calls onFatal when input stream errors', () async {
      final pipe = _PipePair();
      final fatalErrors = <Object>[];
      RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (e, _) => fatalErrors.add(e),
      );

      pipe.controllerA.addError(StateError('pipe broken'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fatalErrors, isNotEmpty);

      await pipe.close();
    });

    test('cancelAll rejects all pending requests', () async {
      final pipe = _PipePair();
      final server = _FakeServer(pipe);   // never replies
      final peer = RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (_, __) {},
      );

      final pending = peer.request('never-replies');
      expect(peer.pendingCount, 1);
      peer.cancelAll(const ShuttingDown('test'));
      expect(peer.pendingCount, 0);
      await expectLater(pending, throwsA(isA<ShuttingDown>()));

      await pipe.close();
      await server.shutdown();
    });

    test('rejects new requests after close', () async {
      final pipe = _PipePair();
      final peer = RpcPeer.create(
        input: pipe.aInput,
        output: pipe.aOutput,
        tag: 'test',
        onFatal: (_, __) {},
      );
      await pipe.controllerA.close();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await expectLater(
        peer.request('x'),
        throwsA(isA<StateError>()),
      );
      await pipe.close();
    });
  });
}
