import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import '../../models/subagent.dart';

/// Reads and writes the `[subagent]` section of user `config.toml`.
///
/// Mirrors `LocaleConfigStore` / `ThemeConfigStore`: a read-modify-write
/// over the whole config file (so every other section survives),
/// persisted with an atomic temp-file + rename.
///
/// Shape (v2):
///
/// ```toml
/// [subagent]
/// workers_on = false
/// experts_on = false
///
/// [subagent.workers]
/// models = [
///   { model = "zhipu/glm-5.3", concurrency = 2 },
///   { model = "deepseek/deepseek-v4.1-flash", concurrency = 8 },
/// ]
///
/// [subagent.experts]
/// models = [{ model = "zhipu/glm-5.3", concurrency = 1 }]
/// ```
///
/// The v1 single `advisor` key is read as an alias for `experts` so an
/// existing config file migrates silently on first save.
class SubagentConfigStore {
  final File file;

  const SubagentConfigStore(this.file);

  /// The toggles live in memory + this file; the read returns the merged
  /// default when the section is absent.
  Future<SubagentRuntimeToggles> readToggles() async {
    final map = await _readMap();
    final section = map['subagent'];
    if (section is! Map) return const SubagentRuntimeToggles();
    return SubagentRuntimeToggles(
      workersOn: section['workers_on'] is bool
          ? section['workers_on'] as bool
          : false,
      expertsOn: section['experts_on'] is bool
          ? section['experts_on'] as bool
          : false,
    );
  }

  Future<void> writeToggles(SubagentRuntimeToggles toggles) =>
      _writeSection((section) {
        section['workers_on'] = toggles.workersOn;
        section['experts_on'] = toggles.expertsOn;
      });

  Future<SubagentConfig> readPools() async {
    final map = await _readMap();
    final section = map['subagent'];
    if (section is! Map) return const SubagentConfig();
    final experts = _parseRole(section['experts']);
    return SubagentConfig(
      workers: _parseRole(section['workers']),
      // The v1 `advisor` key is an alias for `experts`: used only when
      // the v2 key is absent so an existing config keeps working.
      experts: section.containsKey('experts')
          ? experts
          : _parseRole(section['advisor']),
    );
  }

  Future<void> writePools(SubagentConfig config) => _writeSection((section) {
    section['workers'] = _writeRole(config.workers);
    section['experts'] = _writeRole(config.experts);
    // Drop the legacy v1 key if present so it cannot shadow the new one
    // on a later read.
    section.remove('advisor');
  });

  SubagentModelConfig _parseRole(Object? value) {
    if (value is! Map) return const SubagentModelConfig();
    final rawModels = value['models'] is List ? value['models'] as List : const [];
    return SubagentModelConfig(
      models: [
        for (final entry in rawModels)
          ?SubagentModelEntry.fromJson(entry),
      ],
    );
  }

  Map<String, dynamic> _writeRole(SubagentModelConfig config) => {
    'models': [for (final entry in config.models) entry.toJson()],
  };

  Future<Map<String, dynamic>> _readMap() async {
    if (!await file.exists()) return {};
    return TomlDocument.parse(await file.readAsString()).toMap();
  }

  Future<void> _writeSection(
    void Function(Map<String, dynamic> section) mutate,
  ) async {
    Map<String, dynamic> map = await _readMap();
    final section = map['subagent'] is Map
        ? Map<String, dynamic>.from(map['subagent'] as Map)
        : <String, dynamic>{};
    mutate(section);
    map['subagent'] = section;

    final document = TomlDocument.fromMap(map);
    final printer = TomlPrettyPrinter();
    document.acceptVisitor(printer);

    await file.parent.create(recursive: true);
    final temporary = File(
      p.join(
        file.parent.path,
        '.${p.basename(file.path)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await temporary.writeAsString('${printer.toString()}\n', flush: true);
    try {
      await temporary.rename(file.path);
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}

/// The two independent runtime toggles. Kept as a separate tiny value
/// object so flipping one does not rewrite the model pools.
class SubagentRuntimeToggles {
  final bool workersOn;
  final bool expertsOn;

  const SubagentRuntimeToggles({this.workersOn = false, this.expertsOn = false});

  bool get anyOn => workersOn || expertsOn;

  SubagentRuntimeToggles copyWith({bool? workersOn, bool? expertsOn}) =>
      SubagentRuntimeToggles(
        workersOn: workersOn ?? this.workersOn,
        expertsOn: expertsOn ?? this.expertsOn,
      );

  @override
  bool operator ==(Object other) =>
      other is SubagentRuntimeToggles &&
      other.workersOn == workersOn &&
      other.expertsOn == expertsOn;

  @override
  int get hashCode => Object.hash(workersOn, expertsOn);
}
