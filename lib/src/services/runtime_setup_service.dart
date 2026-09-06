import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import '../tools/semble_warmup.dart';
import '../utils/bundled_directory.dart';
import '../utils/bundled_executable.dart';
import '../utils/user_data_directory.dart';
import 'semble_client.dart';

class RuntimeTransferStats {
  final int? receivedBytes;
  final int? totalBytes;
  final double? bytesPerSecond;
  final String? source;
  final int? sourceCount;

  const RuntimeTransferStats({
    this.receivedBytes,
    this.totalBytes,
    this.bytesPerSecond,
    this.source,
    this.sourceCount,
  });
}

typedef RuntimeProgressCallback = void Function(
  double progress,
  String stage, [
  RuntimeTransferStats? stats,
]);

class SembleDownloadSource {
  final String endpoint;
  final String probeFile;
  final double bytesPerSecond;
  final int? totalBytes;

  const SembleDownloadSource({
    required this.endpoint,
    required this.probeFile,
    required this.bytesPerSecond,
    required this.totalBytes,
  });
}

class RuntimeSetupService {
  static const _modelPath = 'minishlab/potion-code-16M/resolve/main';
  static const _probeBytes = 256 * 1024;

  final List<String>? sembleEndpoints;
  final HttpClient Function() _httpClientFactory;
  final Map<String, String> Function() _environment;

  RuntimeSetupService({
    this.sembleEndpoints,
    HttpClient Function()? httpClientFactory,
    Map<String, String> Function()? environment,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _environment = environment ?? (() => Platform.environment);

  Future<void> ensureSemble(
    String projectPath, {
    RuntimeProgressCallback? onProgress,
  }) async {
    onProgress?.call(0.02, 'checking');
    if (!await SembleClient.instance.hasModelAssets()) {
      final dir = Directory(p.join(resolveUserDataDirectory(), 'semblemodel'));
      await dir.create(recursive: true);
      final model = File(p.join(dir.path, 'model.safetensors'));
      final tokenizer = File(p.join(dir.path, 'tokenizer.json'));
      final probeFile = !await model.exists()
          ? 'model.safetensors'
          : 'tokenizer.json';
      onProgress?.call(
        0.03,
        'testing_sources',
        RuntimeTransferStats(sourceCount: _candidateEndpoints.length),
      );
      final sources = await benchmarkSembleSources(probeFile: probeFile);
      if (!await model.exists()) {
        await _downloadSembleFile(
          sources,
          'model.safetensors',
          model,
          stage: 'downloading_model',
          progressStart: 0.05,
          progressSpan: 0.80,
          onProgress: onProgress,
        );
      }
      if (!await tokenizer.exists()) {
        await _downloadSembleFile(
          sources,
          'tokenizer.json',
          tokenizer,
          stage: 'downloading_tokenizer',
          progressStart: 0.85,
          progressSpan: 0.10,
          onProgress: onProgress,
        );
      }
    }
    onProgress?.call(0.96, 'warming_up');
    if (SembleWarmup.instance.isWarming) {
      try {
        await SembleWarmup.instance.awaitReady(projectPath);
      } catch (_) {
        // The boot-time warmup may have raced ahead before setup downloaded
        // the missing files. Retry below against the now-complete model pair.
      }
    }
    if (!SembleWarmup.instance.succeeded) {
      await SembleWarmup.instance.retry(projectPath);
    }
    onProgress?.call(1, 'ready');
  }

  List<String> get _candidateEndpoints {
    final configured = sembleEndpoints;
    final environment = _environment();
    final values =
        configured ??
        <String>[
          ...?environment['CRUX_SEMBLE_MIRRORS']?.split(RegExp(r'[,;\s]+')),
          ?environment['HF_ENDPOINT'],
          'https://modelscope.cn',
          'https://hf-mirror.com',
          'https://huggingface.co',
        ];
    final result = <String>[];
    for (final value in values) {
      final endpoint = value.trim().replaceFirst(RegExp(r'/+$'), '');
      final uri = Uri.tryParse(endpoint);
      if (endpoint.isEmpty ||
          uri == null ||
          !uri.hasAuthority ||
          (uri.scheme != 'https' && uri.scheme != 'http') ||
          result.contains(endpoint)) {
        continue;
      }
      result.add(endpoint);
    }
    return result.take(6).toList(growable: false);
  }

  Future<List<SembleDownloadSource>> benchmarkSembleSources({
    String probeFile = 'model.safetensors',
  }) async {
    final results = await Future.wait(
      _candidateEndpoints.map(
        (endpoint) => _tryBenchmarkSource(endpoint, probeFile),
      ),
    );
    final available = results.whereType<SembleDownloadSource>().toList()
      ..sort((a, b) => b.bytesPerSecond.compareTo(a.bytesPerSecond));
    if (available.isEmpty) {
      throw const HttpException('no Semble download source is reachable');
    }
    return available;
  }

  Future<SembleDownloadSource?> _tryBenchmarkSource(
    String endpoint,
    String fileName,
  ) async {
    try {
      return await _benchmarkSource(
        endpoint,
        fileName,
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  Future<SembleDownloadSource> _benchmarkSource(
    String endpoint,
    String fileName,
  ) async {
    final client = _newHttpClient();
    final watch = Stopwatch()..start();
    var received = 0;
    try {
      final response = await _openResponse(
        client,
        _sembleFileUrl(endpoint, fileName),
        rangeEnd: _probeBytes - 1,
      );
      final total = _responseTotalBytes(response);
      await for (final chunk in response.timeout(const Duration(seconds: 8))) {
        received += chunk.length;
        if (received >= _probeBytes) break;
      }
      watch.stop();
      if (received == 0) throw const HttpException('empty benchmark response');
      return SembleDownloadSource(
        endpoint: endpoint,
        probeFile: fileName,
        bytesPerSecond:
            received / (watch.elapsedMicroseconds.clamp(1, 1 << 62) / 1e6),
        totalBytes: total,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _downloadSembleFile(
    List<SembleDownloadSource> sources,
    String fileName,
    File destination, {
    required String stage,
    required double progressStart,
    required double progressSpan,
    RuntimeProgressCallback? onProgress,
  }) async {
    Object? lastError;
    for (final source in sources) {
      try {
        await _downloadFile(
          _sembleFileUrl(source.endpoint, fileName),
          destination,
          onProgress: (progress, received, total, bytesPerSecond) {
            final effectiveTotal =
                total ??
                (source.probeFile == fileName ? source.totalBytes : null);
            final effectiveProgress = effectiveTotal == null
                ? progress
                : (received / effectiveTotal).clamp(0.0, 1.0).toDouble();
            onProgress?.call(
              progressStart + effectiveProgress * progressSpan,
              stage,
              RuntimeTransferStats(
                receivedBytes: received,
                totalBytes: effectiveTotal,
                bytesPerSecond: bytesPerSecond,
                source: Uri.parse(source.endpoint).host,
              ),
            );
          },
        );
        return;
      } catch (error) {
        lastError = error;
      }
    }
    throw HttpException(
      'all Semble download sources failed: ${_briefError(lastError)}',
    );
  }

  String _briefError(Object? error) => switch (error) {
    HttpException(:final message) => message,
    SocketException(:final message) => message,
    _ => '$error',
  };

  String _sembleFileUrl(String endpoint, String fileName) {
    final host = Uri.parse(endpoint).host;
    if (host.endsWith('modelscope.cn') || host.endsWith('modelscope.ai')) {
      return '$endpoint/models/minishlab/potion-code-16M/resolve/master/$fileName';
    }
    return '$endpoint/$_modelPath/$fileName';
  }

  Future<void> ensureRipgrep({RuntimeProgressCallback? onProgress}) async {
    onProgress?.call(0.02, 'checking');
    final executableName = Platform.isWindows ? 'rg.exe' : 'rg';
    final existing = await resolveBundledExecutable(executableName);
    if (await _works(existing)) {
      onProgress?.call(1, 'ready');
      return;
    }

    final thirdParty = await resolveBundledDirectory('third_party');
    final manifestFile = File(p.join(thirdParty.path, 'manifest.toml'));
    if (!await manifestFile.exists()) {
      throw StateError('ripgrep manifest is not available');
    }
    final manifest = TomlDocument.parse(await manifestFile.readAsString())
        .toMap();
    final tools = manifest['tools'] as Map;
    final ripgrep = tools['ripgrep'] as Map;
    final targets = ripgrep['targets'] as Map;
    final config = targets[currentRuntimeTarget()] as Map?;
    if (config == null) {
      throw StateError('ripgrep is unavailable for ${currentRuntimeTarget()}');
    }

    final bytes = await _downloadBytes(
      config['url'] as String,
      onProgress: (progress, received, total, bytesPerSecond) =>
          onProgress?.call(
            0.05 + progress * 0.75,
            'downloading',
            RuntimeTransferStats(
              receivedBytes: received,
              totalBytes: total,
              bytesPerSecond: bytesPerSecond,
              source: Uri.parse(config['url'] as String).host,
            ),
          ),
    );
    onProgress?.call(0.82, 'verifying');
    final expected = config['sha256'] as String;
    final actual = sha256.convert(bytes).toString();
    if (actual != expected) {
      throw StateError('ripgrep download checksum mismatch');
    }
    final archiveType = config['archive'] as String;
    onProgress?.call(0.88, 'extracting');
    final archive = archiveType == 'zip'
        ? ZipDecoder().decodeBytes(bytes, verify: true)
        : TarDecoder().decodeBytes(
            const GZipDecoder().decodeBytes(bytes, verify: true),
          );
    final files = config['files'] as Map;
    final outputDir = Directory(
      p.join(resolveUserDataDirectory(), 'bin', currentRuntimeTarget()),
    );
    await outputDir.create(recursive: true);
    for (final entry in files.entries) {
      final source = archive.find(entry.key as String);
      if (source == null || !source.isFile) {
        throw StateError('ripgrep archive is incomplete');
      }
      final target = File(p.join(outputDir.path, entry.value as String));
      await target.writeAsBytes(source.content as List<int>, flush: true);
      if (!Platform.isWindows) await Process.run('chmod', ['755', target.path]);
    }
    final installed = p.join(outputDir.path, executableName);
    if (!await _works(installed)) {
      throw StateError('downloaded ripgrep failed to start');
    }
    onProgress?.call(1, 'ready');
  }

  Future<bool> _works(String executable) async {
    try {
      final result = await Process.run(executable, const [
        '--version',
      ]).timeout(const Duration(seconds: 5));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _downloadFile(
    String url,
    File destination, {
    void Function(
      double progress,
      int receivedBytes,
      int? totalBytes,
      double bytesPerSecond,
    )?
    onProgress,
  }) async {
    final temp = File('${destination.path}.tmp');
    final client = _newHttpClient();
    IOSink? sink;
    try {
      final response = await _openResponse(client, url);
      sink = temp.openWrite();
      var received = 0;
      final total = _responseTotalBytes(response);
      final watch = Stopwatch()..start();
      var lastReport = Duration.zero;
      await for (final chunk in response.timeout(const Duration(minutes: 5))) {
        sink.add(chunk);
        received += chunk.length;
        final elapsed = watch.elapsed;
        if (elapsed - lastReport >= const Duration(milliseconds: 100)) {
          lastReport = elapsed;
          onProgress?.call(
            total == null ? 0 : (received / total).clamp(0.0, 1.0).toDouble(),
            received,
            total,
            received / (elapsed.inMicroseconds.clamp(1, 1 << 62) / 1e6),
          );
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      watch.stop();
      onProgress?.call(
        1,
        received,
        total ?? received,
        received / (watch.elapsedMicroseconds.clamp(1, 1 << 62) / 1e6),
      );
      await temp.rename(destination.path);
    } catch (_) {
      await sink?.close();
      if (await temp.exists()) await temp.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<List<int>> _downloadBytes(
    String url, {
    void Function(
      double progress,
      int receivedBytes,
      int? totalBytes,
      double bytesPerSecond,
    )?
    onProgress,
  }) async {
    final client = _newHttpClient();
    try {
      final response = await _openResponse(client, url);
      final chunks = <int>[];
      var received = 0;
      final total = _responseTotalBytes(response);
      final watch = Stopwatch()..start();
      var lastReport = Duration.zero;
      await for (final chunk in response.timeout(const Duration(minutes: 3))) {
        chunks.addAll(chunk);
        received += chunk.length;
        final elapsed = watch.elapsed;
        if (elapsed - lastReport >= const Duration(milliseconds: 100)) {
          lastReport = elapsed;
          onProgress?.call(
            total == null ? 0 : (received / total).clamp(0.0, 1.0).toDouble(),
            received,
            total,
            received / (elapsed.inMicroseconds.clamp(1, 1 << 62) / 1e6),
          );
        }
      }
      watch.stop();
      onProgress?.call(
        1,
        received,
        total ?? received,
        received / (watch.elapsedMicroseconds.clamp(1, 1 << 62) / 1e6),
      );
      return chunks;
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientResponse> _openResponse(
    HttpClient client,
    String url, {
    int? rangeEnd,
  }) async {
    var uri = Uri.parse(url);
    for (var redirects = 0; redirects < 6; redirects++) {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 30));
      request.headers.set(HttpHeaders.userAgentHeader, 'crux-setup');
      if (rangeEnd != null) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-$rangeEnd');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) {
          throw StateError('download redirect has no location');
        }
        await response.drain<void>();
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw HttpException(
          'download failed with HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      return response;
    }
    throw StateError('too many download redirects');
  }

  HttpClient _newHttpClient() => _httpClientFactory()
    ..connectionTimeout = const Duration(seconds: 20)
    ..autoUncompress = false;

  int? _responseTotalBytes(HttpClientResponse response) {
    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = contentRange == null
        ? null
        : RegExp(r'/([0-9]+)$').firstMatch(contentRange);
    if (match != null) return int.tryParse(match.group(1)!);
    return response.contentLength > 0 ? response.contentLength : null;
  }
}
