import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'package:crux/src/services/runtime_setup_service.dart';
import 'package:crux/src/utils/system_proxy.dart';

/// Serves [body] for every request, recording the request URIs it was asked for.
Future<HttpServer> _startServer(
  List<int> Function() body, {
  List<String>? seen,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    seen?.add(request.uri.toString());
    request.response
      ..statusCode = HttpStatus.ok
      ..add(body());
    await request.response.close();
  });
  return server;
}

String _origin(HttpServer server) =>
    'http://${server.address.address}:${server.port}';

void main() {
  test('benchmarks Semble sources and ranks the faster mirror first', () async {
    var sawRangeRequest = false;

    Future<HttpServer> startSource(Duration delay) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        sawRangeRequest |=
            request.headers.value(HttpHeaders.rangeHeader) != null;
        await Future<void>.delayed(delay);
        const sampleSize = 256 * 1024;
        request.response
          ..statusCode = HttpStatus.partialContent
          ..contentLength = sampleSize
          ..headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-${sampleSize - 1}/${1024 * 1024}',
          )
          ..add(List<int>.filled(sampleSize, 7));
        await request.response.close();
      });
      return server;
    }

    final slow = await startSource(const Duration(milliseconds: 160));
    final fast = await startSource(const Duration(milliseconds: 10));
    String endpoint(HttpServer server) =>
        'http://${server.address.address}:${server.port}';

    try {
      final service = RuntimeSetupService(
        sembleEndpoints: [endpoint(slow), endpoint(fast)],
      );
      final ranked = await service.benchmarkSembleSources();

      expect(ranked, hasLength(2));
      expect(ranked.first.endpoint, endpoint(fast));
      expect(ranked.first.totalBytes, 1024 * 1024);
      expect(
        ranked.first.bytesPerSecond,
        greaterThan(ranked.last.bytesPerSecond),
      );
      expect(sawRangeRequest, isTrue);
    } finally {
      await slow.close(force: true);
      await fast.close(force: true);
    }
  });

  // `ensureRipgrep` cannot be tested end to end: it resolves its manifest from
  // the bundled `third_party/` directory — the repo ships
  // `third_party/bin/<target>/rg`, so it would return early — and it installs
  // into the real user data directory. The download step it delegates to is
  // therefore the unit under test here.
  group('GitHub asset transport', () {
    List<int> asset() => List<int>.generate(4096, (index) => index % 251);

    test('a transport serving the wrong bytes advances to the next one', () async {
      final payload = asset();
      final directSeen = <String>[];
      final direct = await _startServer(
        () => List<int>.filled(512, 0),
        seen: directSeen,
      );
      final mirrorSeen = <String>[];
      final mirror = await _startServer(asset, seen: mirrorSeen);
      addTearDown(() => direct.close(force: true));
      addTearDown(() => mirror.close(force: true));

      final service = RuntimeSetupService(
        // A relay answering a 200 that is not the asset — a mirror's HTML error
        // page is the real-world shape — must move the chain on rather than
        // abort an install a different transport could finish.
        githubMirrors: ['${_origin(mirror)}/'],
        systemProxy: () => null,
      );
      final bytes = await service.downloadVerifiedAsset(
        url: '${_origin(direct)}/crux-macos-arm64.zip',
        expectedSha256: sha256.convert(payload).toString(),
      );

      expect(bytes, payload);
      expect(
        directSeen,
        isNotEmpty,
        reason: 'the direct transport must be tried before any relay',
      );
      expect(mirrorSeen, isNotEmpty, reason: 'the mirror carried the asset');
    });

    test(
      'a payload that never hashes correctly fails rather than installing',
      () async {
        final server = await _startServer(() => List<int>.filled(512, 0));
        addTearDown(() => server.close(force: true));

        final service = RuntimeSetupService(
          githubMirrors: ['${_origin(server)}/'],
          systemProxy: () => null,
        );

        await expectLater(
          service.downloadVerifiedAsset(
            url: '${_origin(server)}/crux-macos-arm64.zip',
            expectedSha256: sha256.convert(asset()).toString(),
          ),
          throwsA(isA<HttpException>()),
          reason: 'unverified bytes must never reach the installer',
        );
      },
    );

    test('a configured system proxy carries the download', () async {
      final payload = asset();
      final direct = await _startServer(() => List<int>.filled(512, 0));
      final proxySeen = <String>[];
      final proxy = await _startServer(asset, seen: proxySeen);
      addTearDown(() => direct.close(force: true));
      addTearDown(() => proxy.close(force: true));

      final service = RuntimeSetupService(
        // No mirrors, so the proxy is the only transport that can produce the
        // asset. `HttpClient.findProxy` is write-only, so the wiring is asserted
        // by where the request lands: if the directive never reaches the client,
        // the retry goes direct and only ever sees the corrupt payload.
        githubMirrors: const [],
        systemProxy: () => SystemProxy(httpUrl: _origin(proxy)),
      );
      final bytes = await service.downloadVerifiedAsset(
        url: '${_origin(direct)}/crux-macos-arm64.zip',
        expectedSha256: sha256.convert(payload).toString(),
      );

      expect(bytes, payload);
      expect(
        proxySeen,
        isNotEmpty,
        reason: 'the proxy transport must route through the proxy',
      );
    });
  });
}
