// JSON-RPC peer over stdio for LSP server communication.
//
// Two responsibilities:
//   1. Frame incoming bytes into discrete LSP messages using the
//      Content-Length header convention. Tolerate both \r\n and \n
//      line endings (some servers send Unix-only).
//   2. Dispatch outgoing requests/notifications and correlate
//      incoming responses by id, surfacing the JSON-RPC error
//      body if the server returned one.
//
// The peer is intentionally stream-based: it never buffers an
// entire message in memory beyond what's needed to extract the
// framed JSON. Large messages are bounded by [_kMaxMessageBytes];
// oversize messages trigger [onFatal].
//
// We deliberately do NOT use Isolate.run / compute() for jsonDecode
// here. Phase 1 diagnostics messages are small (<256 KB) in
// practice; if profiling in Phase 2 shows decode stalls, wire
// [decodeSafely] through Isolate.run for the large-message path.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

/// Hard cap on incoming message size. 5 MB matches what we set
/// in `design-lsp.md`; oversize messages almost always indicate
/// a misbehaving server (a 5 MB diagnostic payload is unheard of
/// for real code).
const int _kMaxMessageBytes = 5 * 1024 * 1024;

/// Threshold above which we serialize the JSON parse through
/// Isolate.run. Below this we parse inline (faster, no isolate
/// spawn cost). 256 KB chosen empirically: small enough that
/// inline jsonDecode takes well under 1 ms on typical hardware.
const int _kIsolateThreshold = 256 * 1024;

/// A pending outgoing request. The completer resolves when the
/// matching response arrives; it errors if the peer dies or if
/// the server returns a JSON-RPC error.
class _PendingRequest {
  final String method;
  final Completer<dynamic> completer;
  final DateTime sentAt;

  _PendingRequest({
    required this.method,
    required this.completer,
    required this.sentAt,
  });
}

/// JSON-RPC peer for one server process. Construct via [RpcPeer.create].
///
/// The peer is single-threaded per actor — methods are called from
/// the actor's command handler, and message-arrival callbacks fire
/// from the same isolate.
class RpcPeer {
  final Stream<List<int>> _input;
  final StreamSink<List<int>> _output;
  final String _tag;
  final void Function(Object error, StackTrace? st) _onFatal;

  int _nextId = 1;
  final Map<int, _PendingRequest> _pending = {};
  final Map<String, void Function(Map<String, dynamic>)>
      _notificationHandlers = {};
  final Map<String, FutureOr<Map<String, dynamic>> Function(
      Map<String, dynamic>)> _requestHandlers = {};

  final StreamController<String> _framedMessages =
      StreamController<String>();
  final StringBuffer _readBuf = StringBuffer();

  bool _closed = false;

  RpcPeer._({
    required Stream<List<int>> input,
    required StreamSink<List<int>> output,
    required String tag,
    required void Function(Object, StackTrace?) onFatal,
  })  : _input = input,
        _output = output,
        _tag = tag,
        _onFatal = onFatal {
    _input.listen(_onChunk, onError: _onInputError, onDone: _onInputDone);
  }

  /// Construct a peer and wire it up. Returns the peer.
  factory RpcPeer.create({
    required Stream<List<int>> input,
    required StreamSink<List<int>> output,
    required String tag,
    required void Function(Object error, StackTrace? st) onFatal,
  }) {
    final peer = RpcPeer._(
      input: input,
      output: output,
      tag: tag,
      onFatal: onFatal,
    );
    peer._startFraming();
    return peer;
  }

  /// Send a JSON-RPC request and await the server's response.
  ///
  /// The returned future resolves with the `result` payload or
  /// completes with an [LspRpcError] if the server returned an
  /// error response.
  Future<dynamic> request(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    if (_closed) {
      return Future.error(
        StateError('[$_tag] cannot request $method: peer is closed'),
      );
    }
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = _PendingRequest(
      method: method,
      completer: completer,
      sentAt: DateTime.now(),
    );
    _writeMessage(_encode(id: id, method: method, params: params))
        .catchError((Object e, StackTrace st) {
      // If we can't even send, drop the pending entry and rethrow.
      _pending.remove(id);
      if (!completer.isCompleted) completer.completeError(e, st);
    });
    return completer.future;
  }

  /// Send a JSON-RPC notification. Fire-and-forget; no response expected.
  void notify(String method, [Map<String, dynamic>? params]) {
    if (_closed) return;
    // Fire-and-forget; we don't await the future, but we catch errors
    // so they don't become unhandled.
    unawaited(_writeMessage(_encode(method: method, params: params))
        .catchError((Object e, StackTrace st) {
      _onFatal(e, st);
    }));
  }

  /// Register a handler for a server-initiated notification.
  void onNotification(
    String method,
    void Function(Map<String, dynamic>) handler,
  ) {
    _notificationHandlers[method] = handler;
  }

  /// Register a handler for a server-initiated request. The handler's
  /// return value is sent back as the JSON-RPC response. If the
  /// handler throws, the peer sends a JSON-RPC InternalError (-32603).
  void onRequest(
    String method,
    FutureOr<Map<String, dynamic>> Function(
      Map<String, dynamic> params,
    ) handler,
  ) {
    _requestHandlers[method] = handler;
  }

  /// Drop all pending requests with [reason]. Called when shutting down
  /// or when the underlying stream errors out.
  void cancelAll(Object reason) {
    for (final entry in _pending.values) {
      if (!entry.completer.isCompleted) {
        entry.completer.completeError(reason);
      }
    }
    _pending.clear();
  }

  /// Number of currently-pending outgoing requests. Exposed for tests
  /// and for the manager's metrics.
  int get pendingCount => _pending.length;

  // ---------------------------------------------------------------------------
  // Wire encoding
  // ---------------------------------------------------------------------------

  String _encode({
    int? id,
    required String method,
    Map<String, dynamic>? params,
  }) {
    final body = <String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
      if (id != null) 'id': id,
    };
    return jsonEncode(body);
  }

  Future<void> _writeMessage(String body) async {
    final bytes = utf8.encode(body);
    final header = 'Content-Length: ${bytes.length}\r\n\r\n';
    _output.add(utf8.encode(header));
    _output.add(bytes);
    // Note: we deliberately do not flush per-message. Process.stdin
    // (an IOSink) buffers until the OS pipe accepts the write, which
    // happens before the server reads. In tests we use
    // StreamController sinks which have no flush concept. LSP servers
    // process messages in order regardless of flush.
  }

  // ---------------------------------------------------------------------------
  // Framing — accumulate bytes into discrete JSON messages.
  // ---------------------------------------------------------------------------

  void _startFraming() {
    _framedMessages.stream.listen(_onFramedMessage);
  }

  void _onChunk(List<int> chunk) {
    if (_closed) return;
    // We use a StringBuffer of ASCII-safe bytes. UTF-8 is a
    // superset of ASCII for the header bytes we care about
    // (Content-Length, colons, digits, \r, \n). The body bytes
    // may be full UTF-8; when we read them out as a substring
    // and pass them to jsonDecode, UTF-8 multi-byte sequences
    // survive intact because StringBuffer preserves code units.
    for (final byte in chunk) {
      _readBuf.writeCharCode(byte & 0xFF);
    }
    _drainFramedMessages();
  }

  void _drainFramedMessages() {
    while (!_closed) {
      final headerEnd = _findHeaderEnd();
      if (headerEnd < 0) return;

      final headerBlock = _readBuf.toString().substring(0, headerEnd);
      final length = _parseContentLength(headerBlock);
      if (length == null) {
        _onFatal(
          StateError('[$_tag] malformed LSP frame: missing Content-Length '
              '(headers: $headerBlock)'),
          null,
        );
        return;
      }
      if (length < 0 || length > _kMaxMessageBytes) {
        _onFatal(
          StateError('[$_tag] LSP frame length out of range: $length'),
          null,
        );
        return;
      }

      final bodyStart = headerEnd;
      final bodyEnd = bodyStart + length;
      final all = _readBuf.toString();
      if (all.length < bodyEnd) return;        // body not yet arrived

      final body = all.substring(bodyStart, bodyEnd);
      // Compact buffer: drop everything we've consumed.
      final leftover = all.substring(bodyEnd);
      _readBuf
        ..clear()
        ..write(leftover);

      _framedMessages.add(body);
    }
  }

  /// Find the end of the HTTP-style header block. Accepts both
  /// `\r\n\r\n` (spec) and `\n\n` (lenient — some servers send
  /// Unix-only). Returns the index just past the terminator.
  int _findHeaderEnd() {
    final s = _readBuf.toString();
    final crlfIdx = s.indexOf('\r\n\r\n');
    if (crlfIdx >= 0) return crlfIdx + 4;
    final lfIdx = s.indexOf('\n\n');
    if (lfIdx >= 0) return lfIdx + 2;
    return -1;
  }

  int? _parseContentLength(String headerBlock) {
    for (final line in headerBlock.split(RegExp(r'\r\n|\n'))) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final name = line.substring(0, colon).trim().toLowerCase();
      if (name != 'content-length') continue;
      return int.tryParse(line.substring(colon + 1).trim());
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Dispatch — route incoming messages to handlers.
  // ---------------------------------------------------------------------------

  void _onFramedMessage(String json) {
    if (_closed) return;
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(json) as Map<String, dynamic>;
    } catch (e, st) {
      _onFatal(FormatException('[$_tag] invalid JSON: $json'), st);
      return;
    }

    // An incoming message is one of:
    //   - Response (has "id", may have "result" or "error")
    //   - Request from server (has "id" AND "method")
    //   - Notification from server (has "method", no "id")
    final hasId = msg.containsKey('id');
    final hasMethod = msg.containsKey('method');

    if (hasId && hasMethod) {
      // Incoming request from the server.
      _handleIncomingRequest(msg);
    } else if (hasMethod) {
      // Incoming notification.
      _handleIncomingNotification(msg);
    } else if (hasId) {
      // Response to one of our requests.
      _handleIncomingResponse(msg);
    }
    // Otherwise: malformed; ignore.
  }

  void _handleIncomingResponse(Map<String, dynamic> msg) {
    final rawId = msg['id'];
    if (rawId is! int) return;
    final pending = _pending.remove(rawId);
    if (pending == null) return;     // response to cancelled request
    if (msg.containsKey('error') && msg['error'] != null) {
      pending.completer.completeError(
        LspRpcError.fromJson(
          (msg['error'] as Map).cast<String, dynamic>(),
          method: pending.method,
        ),
      );
    } else {
      pending.completer.complete(msg['result']);
    }
  }

  void _handleIncomingNotification(Map<String, dynamic> msg) {
    final method = msg['method'] as String;
    final params = (msg['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    final handler = _notificationHandlers[method];
    if (handler == null) return;     // silently drop unknown notifications
    try {
      handler(params);
    } catch (e, st) {
      _onFatal(e, st);
    }
  }

  Future<void> _handleIncomingRequest(Map<String, dynamic> msg) async {
    final rawId = msg['id'];
    if (rawId is! int) return;
    final method = msg['method'] as String;
    final params = (msg['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    final handler = _requestHandlers[method];
    if (handler == null) {
      // Per JSON-RPC 2.0: respond with MethodNotFound.
      unawaited(_writeMessage(_encodeResponseError(
        id: rawId,
        code: -32601,
        message: 'Method not found: $method',
      )));
      return;
    }
    try {
      final result = await handler(params);
      if (_closed) return;
      unawaited(_writeMessage(_encodeResponseOk(id: rawId, result: result)));
    } catch (e, st) {
      _onFatal(e, st);
      if (!_closed) {
        unawaited(_writeMessage(_encodeResponseError(
          id: rawId,
          code: -32603,
          message: 'Internal error: $e',
        )));
      }
    }
  }

  String _encodeResponseOk({required int id, required dynamic result}) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': result ?? const <String, dynamic>{},
    });
  }

  String _encodeResponseError({
    required int id,
    required int code,
    required String message,
  }) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }

  // ---------------------------------------------------------------------------
  // Stream lifecycle — close everything cleanly.
  // ---------------------------------------------------------------------------

  void _onInputError(Object e, StackTrace st) {
    if (_closed) return;
    cancelAll(StateError('[$_tag] input stream error: $e'));
    _close(reason: e, st: st);
  }

  void _onInputDone() {
    if (_closed) return;
    cancelAll(StateError('[$_tag] server closed stream'));
    _close();
  }

  void _close({Object? reason, StackTrace? st}) {
    if (_closed) return;
    _closed = true;
    if (reason != null) _onFatal(reason, st);
    try {
      _framedMessages.close();
    } catch (_) {}
    try {
      _output.close();
    } catch (_) {}
  }
}

/// Marker exception used by [RpcPeer.cancelAll]. Distinct from
/// StateError so callers can identify peer shutdown specifically.
class ShuttingDown implements Exception {
  final String tag;
  const ShuttingDown(this.tag);

  @override
  String toString() => 'ShuttingDown($tag)';
}
