/// A preconfigured model role. Roles are user-defined routing labels, not a
/// Crux judgement about a model's quality or vendor.
///
/// v2 naming: `expert` (read-only advisors you consult) and `worker`
/// (agents you dispatch to do work). The persisted config key and database
/// values use the same words.
enum SubagentRole {
  expert,
  worker;

  String get configKey => name;
}

/// One model in a role's pool, with the number of runs that model may serve
/// at the same time.
///
/// Concurrency belongs to the **model**, not to the role that picked it: two
/// models in the same pool can carry different upstream limits (a flagship
/// model may allow two concurrent requests while its flash sibling allows
/// five), and the runtime must respect the limit of whichever model a run
/// actually landed on.
class SubagentModelEntry {
  /// Composite `provider/model` key, as configured in the provider TOML.
  final String model;

  /// Maximum simultaneous runs on [model]. Always at least one.
  final int concurrency;

  const SubagentModelEntry({required this.model, this.concurrency = 1})
    : assert(concurrency > 0);

  SubagentModelEntry copyWith({int? concurrency}) => SubagentModelEntry(
    model: model,
    concurrency: concurrency ?? this.concurrency,
  );

  Map<String, dynamic> toJson() => {
    'model': model,
    'concurrency': concurrency,
  };

  /// Parses one entry, returning null for anything unusable (missing model,
  /// non-positive concurrency falls back to a single slot).
  static SubagentModelEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final model = value['model'];
    if (model is! String || model.trim().isEmpty) return null;
    final rawConcurrency = value['concurrency'];
    return SubagentModelEntry(
      model: model,
      concurrency: rawConcurrency is int && rawConcurrency > 0
          ? rawConcurrency
          : 1,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SubagentModelEntry &&
      other.model == model &&
      other.concurrency == concurrency;

  @override
  int get hashCode => Object.hash(model, concurrency);

  @override
  String toString() => 'SubagentModelEntry($model x$concurrency)';
}

/// User-level configuration for one subagent role: an ordered model pool.
///
/// Index 0 is the preferred model; the rest are the fallback chain, in the
/// order the user wrote them (recovery walks the pool front to back, so the
/// list is a priority order and is never re-sorted). Every entry carries its
  /// own concurrency, so the pool is the single source of truth for both
/// "which models may run" and "how many of them at once".
///
/// An empty pool means the role has not been configured, so callers must not
/// start a run for it.
class SubagentModelConfig {
  final List<SubagentModelEntry> models;

  const SubagentModelConfig({this.models = const []});

  bool get isConfigured =>
      models.isNotEmpty && models.every((entry) => entry.model.isNotEmpty);

  /// The pool's model ids, in priority order.
  List<String> get modelIds => [for (final entry in models) entry.model];

  /// The preferred model — the pool's first entry.
  ///
  /// Readable alias for the common "what does this role run on" question.
  /// Only valid when [isConfigured]: an empty pool has no model to name.
  String get primaryModel => models.first.model;

  SubagentModelEntry? entryFor(String model) {
    for (final entry in models) {
      if (entry.model == model) return entry;
    }
    return null;
  }

  /// How many runs [model] may serve at once.
  ///
  /// A model outside the pool is capped at one: an assignment restored from a
  /// row that predates per-model concurrency, or one whose model was removed
  /// from the pool, must never exceed the conservative default.
  int concurrencyFor(String model) => entryFor(model)?.concurrency ?? 1;

  /// Index of the first pool entry that still has a free slot, or null when
  /// every model is saturated.
  ///
  /// [runningForModel] reports the live run count for one model. Callers use
  /// this to prefer a model that can start now, instead of parking new work
  /// behind a full preferred model.
  int? firstIndexWithCapacity(int Function(String model) runningForModel) {
    for (var index = 0; index < models.length; index++) {
      final entry = models[index];
      if (runningForModel(entry.model) < entry.concurrency) return index;
    }
    return null;
  }

  SubagentModelConfig copyWith({List<SubagentModelEntry>? models}) =>
      SubagentModelConfig(models: models ?? this.models);

  @override
  bool operator ==(Object other) {
    if (other is! SubagentModelConfig) return false;
    if (other.models.length != models.length) return false;
    for (var index = 0; index < models.length; index++) {
      if (other.models[index] != models[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(models);

  @override
  String toString() => 'SubagentModelConfig(${models.join(', ')})';
}

/// The complete `[subagent]` section of user `config.toml`.
///
/// v2 keys: `workers` and `experts` (each an ordered model pool). The v1
/// `advisor` key is read as an alias for `experts` so an existing config
/// file migrates silently on first save.
class SubagentConfig {
  final SubagentModelConfig workers;
  final SubagentModelConfig experts;

  const SubagentConfig({
    this.workers = const SubagentModelConfig(),
    this.experts = const SubagentModelConfig(),
  });

  SubagentModelConfig forRole(SubagentRole role) => switch (role) {
    SubagentRole.worker => workers,
    SubagentRole.expert => experts,
  };

  SubagentConfig copyWith({
    SubagentModelConfig? workers,
    SubagentModelConfig? experts,
  }) => SubagentConfig(
    workers: workers ?? this.workers,
    experts: experts ?? this.experts,
  );

  @override
  bool operator ==(Object other) =>
      other is SubagentConfig &&
      other.workers == workers &&
      other.experts == experts;

  @override
  int get hashCode => Object.hash(workers, experts);
}
