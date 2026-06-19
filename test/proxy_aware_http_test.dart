import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux/src/utils/proxy_aware_http.dart';
import 'package:crux/src/utils/system_proxy.dart';
import 'package:test/test.dart';

void main() {
  setUp(SystemProxyDetector.resetForTesting);
  tearDown(SystemProxyDetector.resetForTesting);

  group('isConnectionError', () {
    test('true for SocketException', () {
      expect(
        isConnectionError(const SocketException('refused')),
        isTrue,
      );
    });

    test('true for HandshakeException', () {
      expect(
        isConnectionError(
          const HandshakeException('TLS error'),
        ),
        isTrue,
      );
    });

    test('true for HttpException', () {
      expect(
        isConnectionError(const HttpException('bad response')),
        isTrue,
      );
    });

    test('true for TimeoutException', () {
      expect(
        isConnectionError(TimeoutException('timed out')),
        isTrue,
      );
    });

    test('false for FormatException (bad payload, not a network issue)', () {
      expect(
        isConnectionError(const FormatException('bad json')),
        isFalse,
      );
    });

    test('false for a plain Exception', () {
      expect(
        isConnectionError(Exception('something else')),
        isFalse,
      );
    });

    test('false for a state error (programming error, not network)', () {
      expect(
        isConnectionError(StateError('bad state')),
        isFalse,
      );
    });
  });

  group('withProxyRetry', () {
    test('returns the direct attempt result without retry on success', () async {
      var calls = 0;
      final result = await withProxyRetry<String>(
        attempt: (proxy) async {
          calls++;
          expect(proxy, isNull, reason: 'first call is always direct');
          return 'ok';
        },
      );
      expect(result, 'ok');
      expect(calls, 1, reason: 'must not retry on success');
    });

    test('retries through the system proxy on a connection error', () async {
      SystemProxyDetector.overrideForTesting(
        const SystemProxy(httpsUrl: 'http://proxy.example.com:7897'),
      );

      var calls = 0;
      final result = await withProxyRetry<String>(
        attempt: (proxy) async {
          calls++;
          if (proxy == null) {
            throw const SocketException('refused');
          }
          return 'ok-via-proxy';
        },
      );
      expect(result, 'ok-via-proxy');
      expect(calls, 2);
    });

    test('retries through the system proxy on a TimeoutException', () async {
      SystemProxyDetector.overrideForTesting(
        const SystemProxy(httpsUrl: 'http://p:1'),
      );

      var calls = 0;
      final result = await withProxyRetry<int>(
        attempt: (proxy) async {
          calls++;
          if (proxy == null) {
            throw TimeoutException('connect');
          }
          return 42;
        },
      );
      expect(result, 42);
      expect(calls, 2);
    });

    test('does NOT retry on a non-connection error', () async {
      SystemProxyDetector.overrideForTesting(
        const SystemProxy(httpsUrl: 'http://p:1'),
      );

      var calls = 0;
      await expectLater(
        withProxyRetry<String>(
          attempt: (proxy) async {
            calls++;
            throw const FormatException('bad payload');
          },
        ),
        throwsA(isA<FormatException>()),
      );
      expect(calls, 1, reason: 'non-connection errors propagate immediately');
    });

    test(
        'does NOT retry on a connection error when no system proxy is '
        'configured', () async {
      SystemProxyDetector.overrideForTesting(null);

      var calls = 0;
      await expectLater(
        withProxyRetry<String>(
          attempt: (proxy) async {
            calls++;
            throw const SocketException('refused');
          },
        ),
        throwsA(isA<SocketException>()),
      );
      expect(calls, 1, reason: 'no proxy → no retry → first error propagates');
    });

    test('propagates the second error when both attempts fail', () async {
      SystemProxyDetector.overrideForTesting(
        const SystemProxy(httpsUrl: 'http://p:1'),
      );

      await expectLater(
        withProxyRetry<String>(
          attempt: (proxy) async {
            if (proxy == null) {
              throw const SocketException('first failure');
            }
            throw const SocketException('proxy also failed');
          },
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            'proxy also failed',
          ),
        ),
      );
    });

    test('does not retry when enabled = false', () async {
      SystemProxyDetector.overrideForTesting(
        const SystemProxy(httpsUrl: 'http://p:1'),
      );

      var calls = 0;
      await expectLater(
        withProxyRetry<String>(
          enabled: false,
          attempt: (proxy) async {
            calls++;
            throw const SocketException('refused');
          },
        ),
        throwsA(isA<SocketException>()),
      );
      expect(calls, 1);
    });

    test('respects a custom isRetriableError predicate', () async {
      SystemProxyDetector.overrideForTesting(
        const SystemProxy(httpsUrl: 'http://p:1'),
      );

      // Without the custom predicate, a FormatException would propagate
      // without retry. With the predicate, the caller decides.
      var calls = 0;
      final result = await withProxyRetry<String>(
        isRetriableError: (e) => e is FormatException,
        attempt: (proxy) async {
          calls++;
          if (proxy == null) {
            throw const FormatException('first');
          }
          return 'ok';
        },
      );
      expect(result, 'ok');
      expect(calls, 2);
    });

    test('passes the detected SystemProxy to the second attempt', () async {
      const injected = SystemProxy(
        httpsUrl: 'http://proxy.example.com:7897',
        noProxy: ['internal.example.com'],
      );
      SystemProxyDetector.overrideForTesting(injected);

      SystemProxy? seenProxy;
      await withProxyRetry<String>(
        attempt: (proxy) async {
          if (proxy == null) throw const SocketException('first');
          seenProxy = proxy;
          return 'ok';
        },
      );
      expect(seenProxy, isNotNull);
      expect(seenProxy!.httpsUrl, injected.httpsUrl);
      expect(seenProxy!.noProxy, injected.noProxy);
    });
  });

  group('isSystemProxyFallbackGloballyEnabled', () {
    test('returns true when CRUX_NO_PROXY_FALLBACK is unset', () {
      // We can't easily unset the env var mid-test, but in the test
      // runner env it is unset. Sanity check.
      expect(
        isSystemProxyFallbackGloballyEnabled(),
        isTrue,
        reason: 'default is on; opt-out is the env var',
      );
    });
  });

  group('integration: withProxyRetry against a real local server', () {
    test('first attempt gets a connection error → second attempt succeeds',
        () async {
      // Start a real HTTP server on a random localhost port that
      // the retry attempt will target. The "direct" attempt is
      // aimed at a TCP socket that accepts the connection and
      // immediately resets it — a reliable way to force a
      // connection error without depending on port-reuse races.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var proxyHits = 0;
      server.listen((req) async {
        proxyHits++;
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.text;
        req.response.write('hello from proxy');
        await req.response.close();
      });

      final broken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => broken.close());
      broken.listen((conn) {
        // Accept and immediately destroy — the client sees a
        // broken-pipe / connection-reset error, which `isConnectionError`
        // recognises.
        conn.destroy();
      });
      final directPort = broken.port;
      final proxyPort = server.port;

      SystemProxyDetector.overrideForTesting(
        SystemProxy(httpsUrl: 'http://127.0.0.1:$proxyPort'),
      );

      var calls = 0;
      final result = await withProxyRetry<String>(
        attempt: (proxy) async {
          calls++;
          final client = HttpClient();
          if (proxy != null) client.findProxy = proxy.findProxyFor;
          try {
            // Note: we hit the proxy server directly (not via the
            // findProxy callback) because this is a synthetic
            // integration test — we're verifying the wrapper's
            // retry logic, not the OS-level proxy plumbing.
            final url = proxy != null
                ? Uri.parse('http://127.0.0.1:$proxyPort/')
                : Uri.parse('http://127.0.0.1:$directPort/');
            final response = await client.getUrl(url).then(
                  (req) => req.close(),
                );
            if (response.statusCode != 200) {
              throw HttpException('status ${response.statusCode}');
            }
            return await response.transform(utf8.decoder).join();
          } finally {
            client.close(force: true);
          }
        },
      );

      expect(result, 'hello from proxy');
      expect(calls, 2);
      expect(proxyHits, 1);
    });
  });
}
