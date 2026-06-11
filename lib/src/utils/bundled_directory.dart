import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

typedef PackageUriResolver = Future<Uri?> Function(Uri packageUri);

Future<Directory> resolveBundledDirectory(
  String name, {
  String? executablePath,
  Uri? scriptUri,
  String? launchDirectory,
  PackageUriResolver packageUriResolver = Isolate.resolvePackageUri,
}) async {
  final candidates = <Directory>[];

  void addCandidate(String path) {
    final normalized = p.normalize(p.absolute(path));
    if (candidates.any((directory) => directory.path == normalized)) return;
    candidates.add(Directory(normalized));
  }

  try {
    addCandidate(
      p.join(p.dirname(executablePath ?? Platform.resolvedExecutable), name),
    );
  } catch (_) {}

  try {
    final script = scriptUri ?? Platform.script;
    if (script.scheme == 'file') {
      final scriptDirectory = p.dirname(script.toFilePath());
      addCandidate(p.join(scriptDirectory, name));
      addCandidate(p.join(scriptDirectory, '..', name));
    }
  } catch (_) {}

  try {
    final packageUri = await packageUriResolver(
      Uri.parse('package:crux/crux.dart'),
    );
    if (packageUri?.scheme == 'file') {
      addCandidate(p.join(p.dirname(packageUri!.toFilePath()), '..', name));
    }
  } catch (_) {}

  addCandidate(p.join(launchDirectory ?? Directory.current.path, name));

  for (final candidate in candidates) {
    if (candidate.existsSync()) return candidate;
  }
  return candidates.last;
}
