import 'dart:async';
import 'dart:io';

import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/llm_provider.dart';
import 'package:crux/src/utils/system_proxy.dart';
import 'package:test/test.dart';

/// HTTP server that accepts the connection but immediately resets
/// the socket without writing any HTTP response. This is the
/// "broken upstream" used as the LlmClient's direct target — it
/// forces a real connection error (`HttpException` / `SocketException`)
/// rather than just "connection refused", which makes the test
/// reliable across platforms (no race with TIME_WAIT port reuse).
class _ResettingServer {
  ServerSocket? _socket;
  late final int port;

  Future<void> start() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket = s;
    port = s.port;
    s.listen((conn) {
      // Accept and immediately destroy the socket — no HTTP response
      // ever reaches the client. This surfaces as a socket error
      // in the client, which the proxy wrapper recognises.
      conn.destroy();
    });
  }

  Future<void> stop() async {
    final s = _socket;
    if (s != null) await s.close();
  }
}

/// Tiny HTTP server on a random localhost port that records every
/// request and responds with a canned OpenAI streaming chunk.
/// Used as the "system proxy" target — the LlmClient is configured
/// to talk to a broken server directly, then the wrapper falls
/// back to this server after the first reset.
class _FakeProxyServer {
  final List<HttpRequest> _log = [];
  HttpServer? _server;
  late final int port;

  Future<void> start() async {
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    port = server.port;
    server.listen((req) async {
      _log.add(req);
      // Drain the body so the request actually completes.
      await req.fold<List<int>>([], (acc, b) => acc..addAll(b));
      req.response.statusCode = 200;
      req.response.headers.set('content-type', 'application/json');
      req.response.write(
        'data: {"choices":[{"delta":{"content":"hi"},'
        '"finish_reason":"stop"}]}\n\n'
        'data: [DONE]\n\n',
      );
      await req.response.close();
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  int get hits => _log.length;
  String? get lastPath => _log.isEmpty ? null : _log.last.uri.path;
  String? get lastMethod => _log.isEmpty ? null : _log.last.method;

  Future<void> stop() async {
    final server = _server;
    if (server != null) await server.close(force: true);
  }
}

ProviderConfig _provider({required String endpointUrl}) {
  return ProviderConfig(
    name: 'p',
    type: 'openai_compatible',
    wireFamily: resolveProvider('openai_compatible').wire,
    endpointUrl: endpointUrl,
    models: [ModelConfig(id: 'm', name: 'm', contextSize: 1000)],
  );
}

void main() {
  setUp(SystemProxyDetector.resetForTesting);
  tearDown(SystemProxyDetector.resetForTesting);

  test(
      'falls back to the system proxy when the direct connection is broken',
      () async {
    // Direct target: a TCP listener that immediately resets the
    // socket. Reliable across platforms (no TIME_WAIT race).
    final broken = _ResettingServer();
    await broken.start();
    addTearDown(broken.stop);

    // Proxy target: a real HTTP server.
    final proxy = _FakeProxyServer();
    await proxy.start();
    addTearDown(proxy.stop);

    // The test URL is `http://...`, so the proxy needs to be
    // registered as the http proxy (not just the https proxy) —
    // SystemProxy.findProxyFor routes by URI scheme.
    SystemProxyDetector.overrideForTesting(
      SystemProxy(
        httpUrl: 'http://127.0.0.1:${proxy.port}',
        httpsUrl: 'http://127.0.0.1:${proxy.port}',
      ),
    );

    final client = LlmClient();
    addTearDown(client.dispose);

    final config = _provider(
      endpointUrl: 'http://127.0.0.1:${broken.port}/v1',
    );

    // Drain the stream so streamChat's try/catch completes.
    var errorChunkSeen = false;
    var finishReasonSeen = false;
    await for (final chunk in client.streamChat(
      endpointUrl: config.endpointUrl,
      config: config,
      apiKey: 'sk-fake',
      modelId: 'm',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
    )) {
      if (chunk.error != null) errorChunkSeen = true;
      if (chunk.finishReason != null) finishReasonSeen = true;
    }

    // After the direct connection is reset, the LlmClient must
    // retry once through the system proxy and the proxy server
    // should see exactly one request.
    expect(proxy.hits, 1,
        reason: 'after the direct connection is broken, the LlmClient '
            'must retry once through the system proxy and the proxy '
            'server should see exactly one request');
    expect(proxy.lastMethod, 'POST');
    expect(proxy.lastPath, '/v1/chat/completions');
    // The proxy returned a clean OpenAI chunk, so the LlmClient
    // must surface a finish-reason, not an error.
    expect(errorChunkSeen, isFalse,
        reason: 'the proxy served a valid response, so the LlmClient '
            'must not surface an error chunk');
    expect(finishReasonSeen, isTrue);
    // Once we've switched to the proxy, the LlmClient remembers it.
    expect(client.isUsingSystemProxy, isTrue,
        reason: 'after the first proxy retry, the LlmClient should '
            'remember the system proxy for future calls');
  });

  test(
      'does NOT fall back to the system proxy when the direct '
      'connection succeeds', () async {
    // Direct attempt lands on the live proxy-shaped server. The
    // wouldBeProxy server is also live but is only used as the
    // "system proxy" address — we expect it NOT to be hit.
    final direct = _FakeProxyServer();
    await direct.start();
    addTearDown(direct.stop);

    final wouldBeProxy = _FakeProxyServer();
    await wouldBeProxy.start();
    addTearDown(wouldBeProxy.stop);

    SystemProxyDetector.overrideForTesting(
      SystemProxy(
        httpUrl: 'http://127.0.0.1:${wouldBeProxy.port}',
        httpsUrl: 'http://127.0.0.1:${wouldBeProxy.port}',
      ),
    );

    final client = LlmClient();
    addTearDown(client.dispose);

    final config = _provider(
      endpointUrl: 'http://127.0.0.1:${direct.port}/v1',
    );

    await for (final _ in client.streamChat(
      endpointUrl: config.endpointUrl,
      config: config,
      apiKey: 'sk-fake',
      modelId: 'm',
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
    )) {
      // drain
    }

    expect(direct.hits, 1, reason: 'direct server must get the request');
    expect(wouldBeProxy.hits, 0,
        reason: 'proxy must NOT be consulted when direct connection works');
    expect(client.isUsingSystemProxy, isFalse,
        reason: 'direct connection succeeded, no proxy switch');
  });
}
