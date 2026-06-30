import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:semble_dart/semble_dart.dart';

import '../utils/bundled_executable.dart' show currentRuntimeTarget;
import '../utils/bundled_directory.dart';

class SembleClient {
  SembleClient._();
  static final SembleClient instance = SembleClient._();

  Completer<SembleSearchIsolate>? _spawnCompleter;

  Future<void> prewarm(String path) async {
    final client = await _ensureClient();
    await client.prewarm(path);
  }

  Future<List<SearchResult>> search(
    String query, {
    required String path,
    required int topK,
  }) async {
    final client = await _ensureClient();
    return client.search(query, path: path, topK: topK);
  }

  Future<List<SearchResult>> findRelated({
    required String file,
    required int line,
    required String path,
    required int topK,
  }) async {
    final client = await _ensureClient();
    return client.findRelated(file: file, line: line, path: path, topK: topK);
  }

  Future<void> refresh(String path) async {
    final client = await _ensureClient();
    client.refresh(path);
  }

  Future<void> shutdown() async {
    final completer = _spawnCompleter;
    _spawnCompleter = null;
    if (completer == null) return;
    try {
      final client = await completer.future;
      await client.shutdown();
    } catch (_) {
      // Best-effort shutdown.
    }
  }

  void debugReset() {
    final completer = _spawnCompleter;
    _spawnCompleter = null;
    if (completer != null) {
      unawaited(
        completer.future.then((client) => client.shutdown()).catchError((_) {}),
      );
    }
  }

  Future<SembleSearchIsolate> _ensureClient() {
    final existing = _spawnCompleter;
    if (existing != null) return existing.future;

    final completer = Completer<SembleSearchIsolate>();
    _spawnCompleter = completer;
    unawaited(
      _spawn().then(completer.complete).catchError((
        Object error,
        StackTrace stack,
      ) {
        if (identical(_spawnCompleter, completer)) _spawnCompleter = null;
        completer.completeError(error, stack);
      }),
    );
    return completer.future;
  }

  Future<SembleSearchIsolate> _spawn() async {
    final assets = await _resolveAssets();
    return SembleSearchIsolate.spawn(
      modelPath: assets.modelPath ?? '',
      tokenizerPath: assets.tokenizerPath ?? '',
      grammarsLibPath: assets.grammarsLibPath ?? '',
    );
  }

  Future<_SembleAssets> _resolveAssets() async {
    final thirdParty = await resolveBundledDirectory('third_party');
    final grammar = await _resolveGrammar(thirdParty);
    final model = await _resolveModelPair(thirdParty);
    return _SembleAssets(
      grammarsLibPath: grammar,
      modelPath: model?.$1,
      tokenizerPath: model?.$2,
    );
  }

  Future<String?> _resolveGrammar(Directory thirdParty) async {
    final fileName = 'libcrux_grammars.${_dynamicLibraryExtension()}';
    final candidates = <String>[
      p.join(thirdParty.path, 'bin', currentRuntimeTarget(), fileName),
      p.join(thirdParty.path, 'bin', fileName),
    ];

    final packageUri = await Isolate.resolvePackageUri(
      Uri.parse('package:semble_dart/semble_dart.dart'),
    );
    if (packageUri != null && packageUri.scheme == 'file') {
      final packageRoot = p.normalize(
        p.join(p.dirname(packageUri.toFilePath()), '..'),
      );
      candidates.add(
        p.join(
          packageRoot,
          'third_party',
          'bin',
          currentRuntimeTarget(),
          fileName,
        ),
      );
    }

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return p.normalize(p.absolute(candidate));
      }
    }
    return null;
  }

  Future<(String, String)?> _resolveModelPair(Directory thirdParty) async {
    final envModel = Platform.environment['CRUX_SEMBLE_MODEL_PATH'];
    final envTokenizer = Platform.environment['CRUX_SEMBLE_TOKENIZER_PATH'];
    if (envModel != null &&
        envTokenizer != null &&
        File(envModel).existsSync() &&
        File(envTokenizer).existsSync()) {
      return (envModel, envTokenizer);
    }

    final candidates = [
      p.join(thirdParty.path, 'semblemodel'),
      p.join(thirdParty.path, 'semble', 'model'),
      _huggingFaceSnapshotPath(),
    ].whereType<String>();

    for (final root in candidates) {
      final model = p.join(root, 'model.safetensors');
      final tokenizer = p.join(root, 'tokenizer.json');
      if (File(model).existsSync() && File(tokenizer).existsSync()) {
        return (
          p.normalize(p.absolute(model)),
          p.normalize(p.absolute(tokenizer)),
        );
      }
    }
    return null;
  }

  String? _huggingFaceSnapshotPath() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    final ref = File(
      p.join(
        home,
        '.cache',
        'huggingface',
        'hub',
        'models--minishlab--potion-code-16M',
        'refs',
        'main',
      ),
    );
    if (!ref.existsSync()) return null;
    final snapshot = ref.readAsStringSync().trim();
    if (snapshot.isEmpty) return null;
    return p.join(
      home,
      '.cache',
      'huggingface',
      'hub',
      'models--minishlab--potion-code-16M',
      'snapshots',
      snapshot,
    );
  }

  String _dynamicLibraryExtension() {
    if (Platform.isMacOS) return 'dylib';
    if (Platform.isWindows) return 'dll';
    return 'so';
  }
}

class _SembleAssets {
  final String? grammarsLibPath;
  final String? modelPath;
  final String? tokenizerPath;

  const _SembleAssets({
    required this.grammarsLibPath,
    required this.modelPath,
    required this.tokenizerPath,
  });
}
