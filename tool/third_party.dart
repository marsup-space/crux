import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:crux/src/utils/bundled_executable.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first != 'fetch') {
    _usage();
    exitCode = 64;
    return;
  }

  var target = 'current';
  String? selectedTool;
  var force = false;
  for (var i = args.isEmpty ? 0 : 1; i < args.length; i++) {
    switch (args[i]) {
      case '--target':
        target = args[++i];
      case '--tool':
        selectedTool = args[++i];
      case '--force':
        force = true;
      case '--help':
      case '-h':
        _usage();
        return;
      default:
        stderr.writeln('Unknown argument: ${args[i]}');
        _usage();
        exitCode = 64;
        return;
    }
  }

  final root = p.normalize(
    p.join(p.dirname(Platform.script.toFilePath()), '..'),
  );
  final manifestFile = File(p.join(root, 'third_party', 'manifest.json'));
  final manifest =
      jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
  final tools = manifest['tools'] as Map<String, dynamic>;
  final toolNames = selectedTool == null ? tools.keys : [selectedTool];

  if (selectedTool != null && !tools.containsKey(selectedTool)) {
    stderr.writeln('Unknown third-party tool: $selectedTool');
    exitCode = 64;
    return;
  }

  final requestedTargets = target == 'all'
      ? _allTargets(tools, toolNames)
      : [target == 'current' ? currentRuntimeTarget() : target];

  for (final toolName in toolNames) {
    final tool = tools[toolName] as Map<String, dynamic>;
    final targets = tool['targets'] as Map<String, dynamic>;
    for (final requestedTarget in requestedTargets) {
      final targetConfig = targets[requestedTarget];
      if (targetConfig == null) {
        stderr.writeln('$toolName does not support $requestedTarget');
        exitCode = 64;
        return;
      }
      await _fetchTarget(
        root: root,
        toolName: toolName,
        tool: tool,
        target: requestedTarget,
        config: targetConfig as Map<String, dynamic>,
        force: force,
      );
    }
  }
}

Set<String> _allTargets(
  Map<String, dynamic> tools,
  Iterable<String> toolNames,
) {
  final targets = <String>{};
  for (final toolName in toolNames) {
    final tool = tools[toolName] as Map<String, dynamic>;
    targets.addAll((tool['targets'] as Map<String, dynamic>).keys);
  }
  return targets;
}

Future<void> _fetchTarget({
  required String root,
  required String toolName,
  required Map<String, dynamic> tool,
  required String target,
  required Map<String, dynamic> config,
  required bool force,
}) async {
  final files = config['files'] as Map<String, dynamic>;
  final outputDirectory = Directory(p.join(root, 'third_party', 'bin', target));
  final outputs = files.values
      .map((name) => File(p.join(outputDirectory.path, name as String)))
      .toList();
  final licenseDirectory = Directory(
    p.join(root, 'third_party', 'licenses', toolName),
  );
  final licenses = (tool['licenses'] as List<dynamic>).cast<String>();
  final licenseOutputs = licenses
      .map((name) => File(p.join(licenseDirectory.path, name)))
      .toList();

  if (!force &&
      outputs.every((file) => file.existsSync()) &&
      licenseOutputs.every((file) => file.existsSync())) {
    stdout.writeln('$toolName $target is already available');
    return;
  }

  final url = Uri.parse(config['url'] as String);
  stdout.writeln('Downloading $toolName ${tool['version']} for $target...');
  final bytes = await _download(url);
  final actualDigest = sha256.convert(bytes).toString();
  final expectedDigest = config['sha256'] as String;
  if (actualDigest != expectedDigest) {
    throw StateError(
      'SHA-256 mismatch for $url\n'
      'expected: $expectedDigest\n'
      'actual:   $actualDigest',
    );
  }

  final archive = switch (config['archive']) {
    'zip' => ZipDecoder().decodeBytes(bytes, verify: true),
    'tar.gz' => TarDecoder().decodeBytes(
      const GZipDecoder().decodeBytes(bytes, verify: true),
    ),
    final type => throw UnsupportedError('Unsupported archive type: $type'),
  };

  await outputDirectory.create(recursive: true);
  for (final entry in files.entries) {
    final archiveFile = archive.find(entry.key);
    if (archiveFile == null || !archiveFile.isFile) {
      throw StateError('Archive is missing ${entry.key}');
    }
    final destination = File(
      p.join(outputDirectory.path, entry.value as String),
    );
    await destination.writeAsBytes(archiveFile.content, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['755', destination.path]);
    }
  }

  await licenseDirectory.create(recursive: true);
  for (final license in licenses) {
    final archiveFile = archive.files.cast<ArchiveFile?>().firstWhere(
      (file) => file!.isFile && p.basename(file.name) == license,
      orElse: () => null,
    );
    if (archiveFile == null) {
      throw StateError('Archive is missing license file $license');
    }
    await File(
      p.join(licenseDirectory.path, license),
    ).writeAsBytes(archiveFile.content, flush: true);
  }
  stdout.writeln('Installed $toolName $target');
}

Future<Uint8List> _download(Uri url) async {
  Object? lastError;
  for (var attempt = 1; attempt <= 3; attempt++) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client
          .getUrl(url)
          .timeout(const Duration(seconds: 30));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'crux-third-party-fetcher',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Download failed with HTTP ${response.statusCode}',
          uri: url,
        );
      }
      final builder = BytesBuilder(copy: false);
      await response.timeout(const Duration(seconds: 60)).forEach(builder.add);
      return builder.takeBytes();
    } catch (error) {
      lastError = error;
      if (attempt < 3) {
        stderr.writeln('Download attempt $attempt failed; retrying...');
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    } finally {
      client.close(force: true);
    }
  }
  throw StateError('Failed to download $url after 3 attempts: $lastError');
}

void _usage() {
  stdout.writeln(
    'Usage: dart run tool/third_party.dart fetch '
    '[--target current|all|<os-arch>] [--tool <name>] [--force]',
  );
}
