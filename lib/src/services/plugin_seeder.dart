import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Name of the marker file (kept inside the user plugins dir) that
/// records the SHA-256 of each spec content the seeder last wrote.
///
/// Dot-prefixed and non-TOML so the plugin registry (which only reads
/// `*.toml`) never sees it. Deleting the whole plugins dir therefore
/// resets provenance to "never seeded" — a clean-slate re-seed.
const String kPluginSeedMarkerFileName = '.seeded.json';

/// What the seeder did with a particular bundled spec.
enum PluginSeedAction {
  /// No user file and no marker entry (first run): wrote the bundled
  /// spec.
  created,

  /// User file already identical to the bundled spec: nothing to do.
  unchanged,

  /// User file was still *exactly* what we last wrote (marker SHA
  /// matches) but the bundled spec changed (upgrade): replaced it
  /// with the new bundled content.
  updated,

  /// User file differs from both the bundled spec and the marker: the
  /// user owns this file now. Left untouched — **never overwritten**.
  userModified,

  /// Marker entry exists but the file does not: the user deleted it.
  /// Deletion is final; the seeder does not resurrect deleted specs.
  deleted,
}

/// Result of seeding one bundled plugin spec. Returned in
/// [seedBundledPlugins]'s output list so callers can log or assert.
class PluginSeedResult {
  /// The filename (e.g. `"my-notes.toml"`).
  final String fileName;

  /// What we did with it.
  final PluginSeedAction action;

  /// SHA-256 of the bundled spec content (what a `created`/`updated`
  /// write produced, or would have produced).
  final String newSha256;

  const PluginSeedResult({
    required this.fileName,
    required this.action,
    required this.newSha256,
  });

  @override
  String toString() =>
      'PluginSeedResult($fileName, ${action.name}, '
      'new=${newSha256.substring(0, 8)})';
}

/// Seed bundled plugin specs into the user's global plugins dir.
///
/// Unlike [seedExampleProviders] (which writes `example.*.toml`
/// reference templates and destructively resets them), a seeded
/// plugin spec is **live config** the user may edit or delete. The
/// contract is therefore non-destructive:
///
/// - **No user file, no marker entry** → write it (`created`).
/// - **User file == bundled content** → `unchanged`.
/// - **User file == what we last wrote** (marker SHA) but the bundle
///   changed → `updated` (crux upgrades its own unmodified specs).
/// - **User file == anything else** → `userModified`: the user edited
///   it; we never touch it again (upgrades stop applying to it).
/// - **Marker entry but no file** → `deleted`: the user removed it;
///   we never resurrect it.
///
/// Provenance lives in `<userDir>/.seeded.json` (filename → SHA-256
/// of the content we last wrote). A user file whose SHA is in no
/// marker (e.g. hand-copied before first seed) is treated as
/// user-owned unless byte-identical to the bundled spec.
///
/// [userDir] is created (recursively) if missing. If [builtInDir]
/// doesn't exist (development checkout without a `plugins/` dir) the
/// seeder is a no-op returning `[]` — safe in any deployment context.
///
/// Returns one [PluginSeedResult] per bundled `.toml` file, in
/// alphabetical order.
Future<List<PluginSeedResult>> seedBundledPlugins({
  required Directory builtInDir,
  required Directory userDir,
}) async {
  if (!builtInDir.existsSync()) return const [];

  await userDir.create(recursive: true);

  final bundledFiles =
      builtInDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.toml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final markerFile = File(p.join(userDir.path, kPluginSeedMarkerFileName));
  final marker = await _readMarker(markerFile);
  var markerDirty = false;

  final results = <PluginSeedResult>[];
  for (final bundledFile in bundledFiles) {
    final name = p.basename(bundledFile.path);
    final content = await bundledFile.readAsString();
    final bundledSha = _sha256(content);
    final userFile = File(p.join(userDir.path, name));
    final seededSha = marker[name];

    if (!userFile.existsSync()) {
      if (seededSha != null) {
        // We wrote it once; the user deleted it since. Respect that.
        results.add(
          PluginSeedResult(
            fileName: name,
            action: PluginSeedAction.deleted,
            newSha256: bundledSha,
          ),
        );
      } else {
        await userFile.writeAsString(content);
        marker[name] = bundledSha;
        markerDirty = true;
        results.add(
          PluginSeedResult(
            fileName: name,
            action: PluginSeedAction.created,
            newSha256: bundledSha,
          ),
        );
      }
      continue;
    }

    final userSha = _sha256(await userFile.readAsString());
    if (userSha == bundledSha) {
      // Already current. Adopt it into the marker if the marker lost
      // the entry (e.g. hand-copied before first seed) so future
      // upgrades apply unless the user edits it.
      if (seededSha != userSha) {
        marker[name] = userSha;
        markerDirty = true;
      }
      results.add(
        PluginSeedResult(
          fileName: name,
          action: PluginSeedAction.unchanged,
          newSha256: bundledSha,
        ),
      );
    } else if (seededSha != null && userSha == seededSha) {
      // Still exactly what we last wrote — safe to upgrade.
      await userFile.writeAsString(content);
      marker[name] = bundledSha;
      markerDirty = true;
      results.add(
        PluginSeedResult(
          fileName: name,
          action: PluginSeedAction.updated,
          newSha256: bundledSha,
        ),
      );
    } else {
      // User-modified (or unknown provenance): never overwrite.
      results.add(
        PluginSeedResult(
          fileName: name,
          action: PluginSeedAction.userModified,
          newSha256: bundledSha,
        ),
      );
    }
  }

  if (markerDirty) await _writeMarker(markerFile, marker);
  return results;
}

String _sha256(String content) =>
    sha256.convert(utf8.encode(content)).toString();

Future<Map<String, String>> _readMarker(File markerFile) async {
  if (!markerFile.existsSync()) return {};
  try {
    final decoded = jsonDecode(await markerFile.readAsString());
    if (decoded is Map<String, dynamic>) {
      return decoded.map(
        (key, value) => MapEntry(key, value is String ? value : ''),
      )..removeWhere((_, value) => value.isEmpty);
    }
  } catch (_) {
    // Corrupt marker → treat as empty (everything user-owned unless
    // byte-identical to the bundle; conservative and self-healing).
  }
  return {};
}

Future<void> _writeMarker(File markerFile, Map<String, String> marker) async {
  const encoder = JsonEncoder.withIndent('  ');
  await markerFile.writeAsString('${encoder.convert(marker)}\n');
}
