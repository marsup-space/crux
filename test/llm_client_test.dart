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

  group(
      'LlmClient — OpenAI-compatible provider runs sanitizeMessages before '
      'sending (regression: 400 errors from malformed wire payloads)', () {
    // Verifies the full path: buildRequestBody receives messages
    // whose assistant entries all carry `reasoning_content`, so
    // the wire body the server sees is valid for DeepSeek's
    // multi-round thinking-mode contract. Regression for the bug
    // where switching the active model from a non-DeepSeek
    // provider to DeepSeek mid-session triggered a 400.

    test('backfills reasoning_content on assistant messages from other '
        'providers', () async {
      String? capturedBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        capturedBody = await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.headers.set('content-type', 'application/json');
        req.response.write(jsonEncode({
          'choices': [
            {'delta': {'content': 'ok'}, 'finish_reason': 'stop'},
          ],
        }));
        await req.response.close();
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final base = 'http://127.0.0.1:${server.port}';

      final client = LlmClient();
      addTearDown(client.dispose);

      final config = _provider(
        type: 'deepseek',
        endpointUrl: base,
        modelId: 'deepseek-v4-pro',
      );

      // User asks a question, assistant replies (e.g. produced by
      // a previous MiniMax turn — no `reasoning_content` field),
      // user asks a follow-up. Without the sanitizer, the
      // second request would 400 on DeepSeek.
      final messages = [
        {'role': 'user', 'content': 'hi'},
        {'role': 'assistant', 'content': 'hello'},
        {'role': 'user', 'content': 'how are you?'},
      ];

      await for (final _ in client.streamChat(
        endpointUrl: config.endpointUrl,
        config: config,
        apiKey: 'sk-fake',
        modelId: 'deepseek-v4-pro',
        messages: messages,
      )) {}

      expect(capturedBody, isNotNull);
      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      final sentMessages = body['messages'] as List<dynamic>;
      expect(sentMessages, hasLength(3));
      // The assistant message that arrived via model switch must
      // now carry an empty reasoning_content — that's the
      // contract DeepSeek's API requires.
      final assistant = sentMessages[1] as Map<String, dynamic>;
      expect(assistant['role'], 'assistant');
      expect(assistant['content'], 'hello');
      expect(
        assistant['reasoning_content'],
        '',
        reason: 'DeepSeek sanitizer must backfill empty reasoning_content '
            'on assistant messages from other providers',
      );
      // Sanity: user messages are not touched.
      expect((sentMessages[0] as Map)['reasoning_content'], isNull);
      expect((sentMessages[2] as Map)['reasoning_content'], isNull);
    });

    test('leaves assistant messages that already have a non-null '
        'reasoning_content untouched', () async {
      String? capturedBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        capturedBody = await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.headers.set('content-type', 'application/json');
        req.response.write('{"choices":[{"delta":{"content":"ok"},'
            '"finish_reason":"stop"}]}');
        await req.response.close();
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final base = 'http://127.0.0.1:${server.port}';

      final client = LlmClient();
      addTearDown(client.dispose);

      final config = _provider(
        type: 'deepseek',
        endpointUrl: base,
        modelId: 'deepseek-v4-pro',
      );

      final preserved = 'the user said hi, I will greet them';
      final messages = [
        {'role': 'user', 'content': 'hi'},
        {
          'role': 'assistant',
          'content': 'hello',
          'reasoning_content': preserved,
        },
      ];

      await for (final _ in client.streamChat(
        endpointUrl: config.endpointUrl,
        config: config,
        apiKey: 'sk-fake',
        modelId: 'deepseek-v4-pro',
        messages: messages,
      )) {}

      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      final sentMessages = body['messages'] as List<dynamic>;
      final assistant = sentMessages[1] as Map<String, dynamic>;
      expect(assistant['reasoning_content'], preserved,
          reason: 'a real reasoning_content value must be preserved '
              '(no-op path)');
    });

    test(
        'drops orphan tool_calls from assistant messages whose tool results '
        'were never persisted (regression: 400 "an assistant message with '
        'tool_call must be followed by tool messages responding to each '
        'tool_call_id")', () async {
      // Reproduces the second error class the user hit when
      // switching to DeepSeek on a MiniMax session: a tool_call
      // assistant message with no following tool result message.
      // OpenAI-compatible endpoints (including DeepSeek) reject
      // this with a 400.
      //
      // The sanitizer on OpenAICompatibleProvider prunes the
      // orphan tool_call so the request becomes well-formed.
      String? capturedBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        capturedBody = await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.headers.set('content-type', 'application/json');
        req.response.write('{"choices":[{"delta":{"content":"ok"},'
            '"finish_reason":"stop"}]}');
        await req.response.close();
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final base = 'http://127.0.0.1:${server.port}';

      final client = LlmClient();
      addTearDown(client.dispose);

      // Use plain openai_compatible to verify the pairing fix lives
      // on the base class (not just DeepSeek). DeepSeek inherits
      // and adds the reasoning_content backfill on top.
      final config = _provider(
        type: 'openai_compatible',
        endpointUrl: base,
      );

      // The history: a tool-calling round whose tool results were
      // never written (e.g. mid-round interruption), followed by
      // the user's follow-up message. Without the sanitizer the
      // server would 400.
      final messages = [
        {'role': 'user', 'content': 'list /tmp'},
        {
          'role': 'assistant',
          'content': 'ok',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {'name': 'bash', 'arguments': '{"cmd": "ls /tmp"}'},
            },
          ],
        },
        // No `tool` message for call_1.
        {'role': 'user', 'content': 'never mind, just say hi'},
      ];

      await for (final _ in client.streamChat(
        endpointUrl: config.endpointUrl,
        config: config,
        apiKey: 'sk-fake',
        modelId: 'm',
        messages: messages,
      )) {}

      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      final sentMessages = body['messages'] as List<dynamic>;
      // The orphan tool_call must be gone from the assistant
      // message — otherwise the server would 400.
      final assistant = sentMessages[1] as Map<String, dynamic>;
      expect(assistant['role'], 'assistant');
      expect(assistant['content'], 'ok');
      expect(assistant.containsKey('tool_calls'), isFalse,
          reason: 'orphan tool_call array must be dropped entirely');
      // The user messages are preserved.
      expect((sentMessages[0] as Map)['content'], 'list /tmp');
      expect((sentMessages[2] as Map)['content'], 'never mind, just say hi');
    });

    test(
        'drops orphan tool messages that have no preceding assistant '
        'tool_call (regression: same 400 error class)', () async {
      // Symmetric case: a `role: tool` message lands in the
      // history without a matching assistant `tool_call`. OpenAI
      // rejects this with the same 400. The sanitizer drops the
      // orphan tool message.
      String? capturedBody;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        capturedBody = await utf8.decoder.bind(req).join();
        req.response.statusCode = 200;
        req.response.headers.set('content-type', 'application/json');
        req.response.write('{"choices":[{"delta":{"content":"ok"},'
            '"finish_reason":"stop"}]}');
        await req.response.close();
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final base = 'http://127.0.0.1:${server.port}';

      final client = LlmClient();
      addTearDown(client.dispose);

      final config = _provider(
        type: 'openai_compatible',
        endpointUrl: base,
      );

      final messages = [
        {'role': 'user', 'content': 'do it'},
        // Orphan tool message — no preceding assistant tool_call.
        {'role': 'tool', 'tool_call_id': 'call_ghost', 'content': 'r'},
        {'role': 'user', 'content': 'next'},
      ];

      await for (final _ in client.streamChat(
        endpointUrl: config.endpointUrl,
        config: config,
        apiKey: 'sk-fake',
        modelId: 'm',
        messages: messages,
      )) {}

      final body = jsonDecode(capturedBody!) as Map<String, dynamic>;
      final sentMessages = body['messages'] as List<dynamic>;
      expect(sentMessages, hasLength(2),
          reason: 'orphan tool message must be removed');
      expect(sentMessages.where((m) => (m as Map)['role'] == 'tool'), isEmpty);
    });
  });
}
