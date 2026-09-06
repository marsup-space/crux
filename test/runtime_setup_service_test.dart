import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/services/runtime_setup_service.dart';

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
}
