// cruxd control server — the loopback HTTP face of the daemon
// (plan §4). Bare HTTP/1.1 + JSON bodies, same conventions as the
// dev-harness control channel and plugin `http` actions:
//
//   GET  /status             → {ok, daemon, instances, producers}
//   POST /register           → instance up; mount its producers
//   POST /deregister         → instance down (explicit)
//   POST /heartbeat          → keep-alive (re-declares producers)
//   POST /producer/restart   → restart one producer by key
//
// Deliberately no auth and no routing framework: loopback-only bind,
// four paths, and every consumer is our own code or a curl debug.

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'daemon.dart';
import 'protocol.dart';

class ControlServer {
  final DaemonCore core;
  HttpServer? _server;

  ControlServer(this.core);

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
  }

  Future<void> close() async {
    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      final body = req.method == 'POST' ? await _readJson(req) : null;
      final (status, json) = await _route(req.method, path, body);
      res.statusCode = status;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode(json));
    } catch (e) {
      res.statusCode = 500;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'ok': false, 'error': '$e'}));
    } finally {
      await res.close();
    }
  }

  Future<Map<String, dynamic>?> _readJson(HttpRequest req) async {
    try {
      final raw = await utf8.decoder.bind(req).join();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<(int, Map<String, dynamic>)> _route(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    switch ('$method $path') {
      case 'GET /status':
        return (200, {'ok': true, ...core.statusJson()});
      case 'POST /register':
        final err = _need(body, ['instanceId', 'pid', 'project']);
        if (err != null) return err;
        final decls = _parseDecls(body!['producers']);
        core.register(
          InstanceInfo(
            id: body['instanceId'] as String,
            pid: body['pid'] as int,
            project: body['project'] as String,
            producerKeys: decls.map((d) => d.key).toSet(),
            lastSeen: DateTime.now(),
          ),
          decls,
        );
        return (200, {
          'ok': true,
          'daemon': {'pid': pid, 'port': port},
        });
      case 'POST /deregister':
        final err = _need(body, ['instanceId']);
        if (err != null) return err;
        final gone = core.deregister(body!['instanceId'] as String);
        return (
          200,
          {'ok': true, 'deregistered': gone},
        );
      case 'POST /heartbeat':
        final err = _need(body, ['instanceId']);
        if (err != null) return err;
        final decls = _parseDecls(body!['producers']);
        // Supplied for the self-heal path (unknown instance after a
        // daemon restart re-registers from the heartbeat body).
        core.bodyPid = body['pid'] as int?;
        core.bodyProject = body['project'] as String?;
        core.heartbeat(
          body['instanceId'] as String,
          decls,
        );
        return (200, {'ok': true});
      case 'POST /producer/restart':
        final err = _need(body, ['key']);
        if (err != null) return err;
        final ok = await core.restartProducer(body!['key'] as String);
        if (!ok) {
          return (
            404,
            {'ok': false, 'error': 'unknown producer: ${body['key']}'},
          );
        }
        return (200, {'ok': true, 'restarted': true});
      default:
        return (404, {'ok': false, 'error': 'unknown endpoint'});
    }
  }

  static List<ProducerDecl> _parseDecls(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>)
          if (ProducerDecl.fromJson(e) case final d?) d,
    ];
  }

  static (int, Map<String, dynamic>)? _need(
    Map<String, dynamic>? body,
    List<String> fields,
  ) {
    if (body == null) return (400, {'ok': false, 'error': 'missing body'});
    for (final f in fields) {
      if (body[f] == null) {
        return (400, {'ok': false, 'error': 'missing field: $f'});
      }
    }
    return null;
  }
}
