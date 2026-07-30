import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The filename prefix used for example/reference provider configs.
///
/// Files matching `example.*.toml` are written by [seedExampleProviders]
/// and **skipped by the loader** — they're not real providers, just
/// templates the user can copy.
///
/// To customize an example, copy it to a new file:
/// ```sh
/// cp ~/.config/crux/providers/example.provider.toml \
///    ~/.config/crux/providers/mycorp.toml
/// # then edit mycorp.toml
/// ```
const String kExampleFilePrefix = 'example.';

/// Returns `true` if [filename] is an example/reference file that the
/// loader should ignore.
///
/// Matches any `*.toml` whose basename starts with [kExampleFilePrefix],
/// e.g. `example.provider.toml`.
bool isExampleProviderFile(String filename) {
  final base = p.basename(filename);
  return base.endsWith('.toml') && base.startsWith(kExampleFilePrefix);
}

/// What the seeder did with a particular example file.
enum SeedAction {
  /// The file did not exist in the user dir; we wrote the bundled example.
  created,

  /// The file existed with the same SHA-256 as the bundled example; we
  /// skipped it (the write would be a no-op).
  unchanged,

  /// The file existed with a different SHA-256; we overwrote it with the
  /// bundled example. **This is destructive of user customizations** —
  /// examples are intended as reference templates, not editable configs.
  /// If you want a customized provider, use the in-app `/provider add`
  /// wizard, or rename the file to a unique provider name.
  overwritten,
}

/// Result of seeding a single example file. Returned in
/// [seedExampleProviders]'s output list so callers can log or assert.
class SeedResult {
  /// The filename (e.g. `"openai.toml"`).
  final String fileName;

  /// What we did with it.
  final SeedAction action;

  /// SHA-256 of the file's previous content, or `null` if it didn't exist.
  final String? oldSha256;

  /// SHA-256 of the bundled example that was (or would have been) written.
  final String newSha256;

  const SeedResult({
    required this.fileName,
    required this.action,
    required this.oldSha256,
    required this.newSha256,
  });

  @override
  String toString() =>
      'SeedResult($fileName, ${action.name}, '
      'old=${oldSha256?.substring(0, 8) ?? "null"}, '
      'new=${newSha256.substring(0, 8)})';
}

/// Seed the user providers directory with example TOML files from the
/// built-in directory.
///
/// For each `*.toml` file in [builtInDir], the seeder writes a copy
/// to [userDir] under the [kExampleFilePrefix] name
/// (e.g. `provider.toml` → `example.provider.toml`). The example file
/// is a **reference template** — the loader skips it; the user copies
/// it to a real provider name (`mycorp.toml`) to customize.
///
/// SHA-256 comparison is destructive by design:
/// - **No file in user dir** → write the bundled example (`created`).
/// - **Identical SHA-256** → skip (`unchanged`).
/// - **Different SHA-256** → overwrite with the bundled example
///   (`overwritten`). Examples are factory state, not user-editable.
///
/// [userDir] is created (recursively) if it doesn't exist.
///
/// If [builtInDir] doesn't exist, the seeder is a no-op (returns `[]`).
/// This makes it safe to call in any deployment context.
///
/// Returns one [SeedResult] per bundled `.toml` file, in alphabetical
/// order, describing what the seeder did. Callers can filter to
/// `action != SeedAction.unchanged` to get a log of changes.
Future<List<SeedResult>> seedExampleProviders({
  required Directory builtInDir,
  required Directory userDir,
}) async {
  if (!builtInDir.existsSync()) return const [];

  if (!userDir.existsSync()) {
    await userDir.create(recursive: true);
  }

  final builtInFiles =
      builtInDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.toml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final results = <SeedResult>[];
  for (final builtInFile in builtInFiles) {
    // Strip a pre-existing `example.` prefix from the built-in basename
    // so the user-dir copy isn't doubly prefixed (e.g. a built-in named
    // `example.foo.toml` would otherwise seed as `example.example.foo.toml`).
    // The loader would still skip it (startsWith("example.")), but the
    // double prefix is ugly and confusing for the user.
    final baseName = p
        .basenameWithoutExtension(builtInFile.path)
        .replaceFirst(kExampleFilePrefix, '');
    // Write as `example.<name>.toml` so the loader skips it.
    final exampleName = '$kExampleFilePrefix$baseName.toml';
    final userFile = File(p.join(userDir.path, exampleName));
    final builtInContent = await builtInFile.readAsString();
    final builtInSha = sha256.convert(utf8.encode(builtInContent)).toString();

    if (userFile.existsSync()) {
      final userContent = await userFile.readAsString();
      final userSha = sha256.convert(utf8.encode(userContent)).toString();
      if (userSha == builtInSha) {
        results.add(
          SeedResult(
            fileName: exampleName,
            action: SeedAction.unchanged,
            oldSha256: userSha,
            newSha256: builtInSha,
          ),
        );
        continue;
      }
      // SHA differs — overwrite.
      await userFile.writeAsString(builtInContent);
      results.add(
        SeedResult(
          fileName: exampleName,
          action: SeedAction.overwritten,
          oldSha256: userSha,
          newSha256: builtInSha,
        ),
      );
    } else {
      // File doesn't exist — create.
      await userFile.writeAsString(builtInContent);
      results.add(
        SeedResult(
          fileName: exampleName,
          action: SeedAction.created,
          oldSha256: null,
          newSha256: builtInSha,
        ),
      );
    }
  }

  return results;
}
