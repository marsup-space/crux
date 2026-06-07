import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/llm_provider.dart';
import 'package:test/test.dart';

/// Spawn a tiny HTTP server on a random localhost port. The server
/// records every request's path, method, and headers in [_log], and
/// always responds with the configured [status] + JSON body. We
/// don't need a real LLM upstream for these tests — we only want to
/// verify that Crux's URL building targets the right path.
class _CapturingServer {
  _CapturingServer(this.status, this.body);

  final int status;
  final String body;
  HttpServer? _server;
  final List<HttpRequest> _log = [];

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((req) async {
      _log.add(req);
      req.response.statusCode = status;
      req.response.headers.set('content-type', 'application/json');
      req.response.write(body);
      await req.response.close();
    });
    // Give the server a tick to actually start accepting.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return 'http://127.0.0.1:${server.port}';
  }

  String? get lastPath => _log.isEmpty ? null : _log.last.uri.path;
  String? get lastMethod => _log.isEmpty ? null : _log.last.method;

  Future<void> stop() async {
    final server = _server;
    if (server != null) await server.close(force: true);
  }
}

ProviderConfig _provider({
  required String type,
  required String endpointUrl,
  String modelId = 'm',
}) {
  return ProviderConfig(
    name: 'p',
    type: type,
    wireFamily: resolveProvider(type).wire,
    endpointUrl: endpointUrl,
    models: [
      ModelConfig(id: modelId, name: modelId, contextSize: 1000),
    ],
  );
}

void main() {
  group('LlmClient — URL building (regression: bug that mangled .../v1)', () {
    test(
      'appends /chat/completions to a /v1 endpoint without dropping v1',
      () async {
        // /v1 endpoints (InfiniAI, OpenAI, etc.) used to hit 404 because
        // `uri.resolve('chat/completions')` would REPLACE the last path
        // segment, turning `.../v1` into `.../`. The fix appends
        // `/chat/completions` instead of replacing.
        final server = _CapturingServer(
          200,
          jsonEncode({
            'choices': [
              {
                'delta': {'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          }),
        );
        final base = await server.start();
        addTearDown(server.stop);

        final client = LlmClient();
        addTearDown(client.dispose);

        final config = _provider(
          type: 'openai_compatible',
          // Mirror the InfiniAI / OpenAI endpoint shape that was 404'ing.
          endpointUrl: '$base/v1',
        );

        await for (final _ in client.streamChat(
          endpointUrl: config.endpointUrl,
          config: config,
          apiKey: 'sk-fake',
          modelId: 'm',
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
        )) {
          // drain the stream
        }

        expect(
          server.lastPath,
          '/v1/chat/completions',
          reason: 'Must append /chat/completions, not replace /v1',
        );
      },
    );

    test('appends /chat/completions to a /v1/ endpoint (trailing slash)',
        () async {
      // `uri.resolve` on a trailing-slash URL yields `...//v1/...` —
      // double-slash. The fix's `_endsWithVersionSegment` strips the
      // trailing slash first, so the path stays clean.
      final server = _CapturingServer(200, '{}');
      final base = await server.start();
      addTearDown(server.stop);

      final client = LlmClient();
      addTearDown(client.dispose);

      final config = _provider(
        type: 'openai_compatible',
        endpointUrl: '$base/v1/',
      );

      await for (final _ in client.streamChat(
        endpointUrl: config.endpointUrl,
        config: config,
        apiKey: 'sk-fake',
        modelId: 'm',
        messages: const [],
      )) {}

      expect(
        server.lastPath,
        '/v1/chat/completions',
        reason: 'No double-slash, no double /v1',
      );
    });

    test('auto-appends /v1 when endpoint has no version segment', () async {
      // For endpoints that don't include /v1 in the URL (some
      // self-hosted proxies, local llama.cpp / ollama), Crux should
      // add it before /chat/completions. This was actually working
      // before the bugfix too — kept here as a regression guard.
      final server = _CapturingServer(200, '{}');
      final base = await server.start();
      addTearDown(server.stop);

      final client = LlmClient();
      addTearDown(client.dispose);

      final config = _provider(
        type: 'openai_compatible',
        endpointUrl: base, // no /v1
      );

      await for (final _ in client.streamChat(
        endpointUrl: config.endpointUrl,
        config: config,
        apiKey: 'sk-fake',
        modelId: 'm',
        messages: const [],
      )) {}

      expect(server.lastPath, '/v1/chat/completions');
    });

    test('appends /messages to an Anthropic-compatible endpoint', () async {
      // The Anthropic path was always correct (it used `replace(path:)`
      // not `uri.resolve`), but lock it down so it doesn't regress.
      final server = _CapturingServer(200, '{}');
      final base = await server.start();
      addTearDown(server.stop);

      final client = LlmClient();
      addTearDown(client.dispose);

      final config = _provider(
        type: 'anthropic_compatible',
        endpointUrl: '$base/v1',
      );

      await for (final _ in client.streamChat(
        endpointUrl: config.endpointUrl,
        config: config,
        apiKey: 'sk-fake',
        modelId: 'm',
        messages: const [],
      )) {}

      expect(server.lastPath, '/v1/messages');
    });
  });
}
