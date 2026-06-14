// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $SessionsTable extends Sessions with TableInfo<$SessionsTable, Session> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _slugMeta = const VerificationMeta('slug');
  @override
  late final GeneratedColumn<String> slug = GeneratedColumn<String>(
    'slug',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
    'model',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  late final GeneratedColumnWithTypeConverter<SessionStatus, String> status =
      GeneratedColumn<String>(
        'status',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<SessionStatus>($SessionsTable.$converterstatus);
  static const VerificationMeta _agentMeta = const VerificationMeta('agent');
  @override
  late final GeneratedColumn<String> agent = GeneratedColumn<String>(
    'agent',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<int> parentId = GeneratedColumn<int>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _projectPathMeta = const VerificationMeta(
    'projectPath',
  );
  @override
  late final GeneratedColumn<String> projectPath = GeneratedColumn<String>(
    'project_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _costMeta = const VerificationMeta('cost');
  @override
  late final GeneratedColumn<double> cost = GeneratedColumn<double>(
    'cost',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  static const VerificationMeta _tokensInMeta = const VerificationMeta(
    'tokensIn',
  );
  @override
  late final GeneratedColumn<int> tokensIn = GeneratedColumn<int>(
    'tokens_in',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _tokensOutMeta = const VerificationMeta(
    'tokensOut',
  );
  @override
  late final GeneratedColumn<int> tokensOut = GeneratedColumn<int>(
    'tokens_out',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _contextTokensMeta = const VerificationMeta(
    'contextTokens',
  );
  @override
  late final GeneratedColumn<int> contextTokens = GeneratedColumn<int>(
    'context_tokens',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _ttftMsMeta = const VerificationMeta('ttftMs');
  @override
  late final GeneratedColumn<double> ttftMs = GeneratedColumn<double>(
    'ttft_ms',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  static const VerificationMeta _tokPerSecMeta = const VerificationMeta(
    'tokPerSec',
  );
  @override
  late final GeneratedColumn<double> tokPerSec = GeneratedColumn<double>(
    'tok_per_sec',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  static const VerificationMeta _promptCacheHitTokensMeta =
      const VerificationMeta('promptCacheHitTokens');
  @override
  late final GeneratedColumn<int> promptCacheHitTokens = GeneratedColumn<int>(
    'prompt_cache_hit_tokens',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _thinkingModeMeta = const VerificationMeta(
    'thinkingMode',
  );
  @override
  late final GeneratedColumn<String> thinkingMode = GeneratedColumn<String>(
    'thinking_mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('enabled'),
  );
  static const VerificationMeta _reasoningEffortMeta = const VerificationMeta(
    'reasoningEffort',
  );
  @override
  late final GeneratedColumn<String> reasoningEffort = GeneratedColumn<String>(
    'reasoning_effort',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _archivedAtMeta = const VerificationMeta(
    'archivedAt',
  );
  @override
  late final GeneratedColumn<int> archivedAt = GeneratedColumn<int>(
    'archived_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    slug,
    title,
    model,
    status,
    agent,
    parentId,
    projectPath,
    cost,
    tokensIn,
    tokensOut,
    contextTokens,
    ttftMs,
    tokPerSec,
    promptCacheHitTokens,
    thinkingMode,
    reasoningEffort,
    createdAt,
    updatedAt,
    archivedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sessions';
  @override
  VerificationContext validateIntegrity(
    Insertable<Session> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('slug')) {
      context.handle(
        _slugMeta,
        slug.isAcceptableOrUnknown(data['slug']!, _slugMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('model')) {
      context.handle(
        _modelMeta,
        model.isAcceptableOrUnknown(data['model']!, _modelMeta),
      );
    }
    if (data.containsKey('agent')) {
      context.handle(
        _agentMeta,
        agent.isAcceptableOrUnknown(data['agent']!, _agentMeta),
      );
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('project_path')) {
      context.handle(
        _projectPathMeta,
        projectPath.isAcceptableOrUnknown(
          data['project_path']!,
          _projectPathMeta,
        ),
      );
    }
    if (data.containsKey('cost')) {
      context.handle(
        _costMeta,
        cost.isAcceptableOrUnknown(data['cost']!, _costMeta),
      );
    }
    if (data.containsKey('tokens_in')) {
      context.handle(
        _tokensInMeta,
        tokensIn.isAcceptableOrUnknown(data['tokens_in']!, _tokensInMeta),
      );
    }
    if (data.containsKey('tokens_out')) {
      context.handle(
        _tokensOutMeta,
        tokensOut.isAcceptableOrUnknown(data['tokens_out']!, _tokensOutMeta),
      );
    }
    if (data.containsKey('context_tokens')) {
      context.handle(
        _contextTokensMeta,
        contextTokens.isAcceptableOrUnknown(
          data['context_tokens']!,
          _contextTokensMeta,
        ),
      );
    }
    if (data.containsKey('ttft_ms')) {
      context.handle(
        _ttftMsMeta,
        ttftMs.isAcceptableOrUnknown(data['ttft_ms']!, _ttftMsMeta),
      );
    }
    if (data.containsKey('tok_per_sec')) {
      context.handle(
        _tokPerSecMeta,
        tokPerSec.isAcceptableOrUnknown(data['tok_per_sec']!, _tokPerSecMeta),
      );
    }
    if (data.containsKey('prompt_cache_hit_tokens')) {
      context.handle(
        _promptCacheHitTokensMeta,
        promptCacheHitTokens.isAcceptableOrUnknown(
          data['prompt_cache_hit_tokens']!,
          _promptCacheHitTokensMeta,
        ),
      );
    }
    if (data.containsKey('thinking_mode')) {
      context.handle(
        _thinkingModeMeta,
        thinkingMode.isAcceptableOrUnknown(
          data['thinking_mode']!,
          _thinkingModeMeta,
        ),
      );
    }
    if (data.containsKey('reasoning_effort')) {
      context.handle(
        _reasoningEffortMeta,
        reasoningEffort.isAcceptableOrUnknown(
          data['reasoning_effort']!,
          _reasoningEffortMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('archived_at')) {
      context.handle(
        _archivedAtMeta,
        archivedAt.isAcceptableOrUnknown(data['archived_at']!, _archivedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Session map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Session(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      slug: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}slug'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      model: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model'],
      )!,
      status: $SessionsTable.$converterstatus.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}status'],
        )!,
      ),
      agent: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}agent'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent_id'],
      ),
      projectPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}project_path'],
      )!,
      cost: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}cost'],
      )!,
      tokensIn: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tokens_in'],
      )!,
      tokensOut: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tokens_out'],
      )!,
      contextTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}context_tokens'],
      )!,
      ttftMs: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}ttft_ms'],
      )!,
      tokPerSec: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}tok_per_sec'],
      )!,
      promptCacheHitTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}prompt_cache_hit_tokens'],
      )!,
      thinkingMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thinking_mode'],
      )!,
      reasoningEffort: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reasoning_effort'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      archivedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}archived_at'],
      ),
    );
  }

  @override
  $SessionsTable createAlias(String alias) {
    return $SessionsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<SessionStatus, String, String> $converterstatus =
      const EnumNameConverter<SessionStatus>(SessionStatus.values);
}

class Session extends DataClass implements Insertable<Session> {
  final int id;
  final String slug;
  final String title;
  final String model;
  final SessionStatus status;
  final String agent;
  final int? parentId;
  final String projectPath;
  final double cost;
  final int tokensIn;
  final int tokensOut;
  final int contextTokens;
  final double ttftMs;
  final double tokPerSec;
  final int promptCacheHitTokens;
  final String thinkingMode;
  final String? reasoningEffort;
  final int createdAt;
  final int updatedAt;
  final int? archivedAt;
  const Session({
    required this.id,
    required this.slug,
    required this.title,
    required this.model,
    required this.status,
    required this.agent,
    this.parentId,
    required this.projectPath,
    required this.cost,
    required this.tokensIn,
    required this.tokensOut,
    required this.contextTokens,
    required this.ttftMs,
    required this.tokPerSec,
    required this.promptCacheHitTokens,
    required this.thinkingMode,
    this.reasoningEffort,
    required this.createdAt,
    required this.updatedAt,
    this.archivedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['slug'] = Variable<String>(slug);
    map['title'] = Variable<String>(title);
    map['model'] = Variable<String>(model);
    {
      map['status'] = Variable<String>(
        $SessionsTable.$converterstatus.toSql(status),
      );
    }
    map['agent'] = Variable<String>(agent);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<int>(parentId);
    }
    map['project_path'] = Variable<String>(projectPath);
    map['cost'] = Variable<double>(cost);
    map['tokens_in'] = Variable<int>(tokensIn);
    map['tokens_out'] = Variable<int>(tokensOut);
    map['context_tokens'] = Variable<int>(contextTokens);
    map['ttft_ms'] = Variable<double>(ttftMs);
    map['tok_per_sec'] = Variable<double>(tokPerSec);
    map['prompt_cache_hit_tokens'] = Variable<int>(promptCacheHitTokens);
    map['thinking_mode'] = Variable<String>(thinkingMode);
    if (!nullToAbsent || reasoningEffort != null) {
      map['reasoning_effort'] = Variable<String>(reasoningEffort);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || archivedAt != null) {
      map['archived_at'] = Variable<int>(archivedAt);
    }
    return map;
  }

  SessionsCompanion toCompanion(bool nullToAbsent) {
    return SessionsCompanion(
      id: Value(id),
      slug: Value(slug),
      title: Value(title),
      model: Value(model),
      status: Value(status),
      agent: Value(agent),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      projectPath: Value(projectPath),
      cost: Value(cost),
      tokensIn: Value(tokensIn),
      tokensOut: Value(tokensOut),
      contextTokens: Value(contextTokens),
      ttftMs: Value(ttftMs),
      tokPerSec: Value(tokPerSec),
      promptCacheHitTokens: Value(promptCacheHitTokens),
      thinkingMode: Value(thinkingMode),
      reasoningEffort: reasoningEffort == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoningEffort),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      archivedAt: archivedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(archivedAt),
    );
  }

  factory Session.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Session(
      id: serializer.fromJson<int>(json['id']),
      slug: serializer.fromJson<String>(json['slug']),
      title: serializer.fromJson<String>(json['title']),
      model: serializer.fromJson<String>(json['model']),
      status: $SessionsTable.$converterstatus.fromJson(
        serializer.fromJson<String>(json['status']),
      ),
      agent: serializer.fromJson<String>(json['agent']),
      parentId: serializer.fromJson<int?>(json['parentId']),
      projectPath: serializer.fromJson<String>(json['projectPath']),
      cost: serializer.fromJson<double>(json['cost']),
      tokensIn: serializer.fromJson<int>(json['tokensIn']),
      tokensOut: serializer.fromJson<int>(json['tokensOut']),
      contextTokens: serializer.fromJson<int>(json['contextTokens']),
      ttftMs: serializer.fromJson<double>(json['ttftMs']),
      tokPerSec: serializer.fromJson<double>(json['tokPerSec']),
      promptCacheHitTokens: serializer.fromJson<int>(
        json['promptCacheHitTokens'],
      ),
      thinkingMode: serializer.fromJson<String>(json['thinkingMode']),
      reasoningEffort: serializer.fromJson<String?>(json['reasoningEffort']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      archivedAt: serializer.fromJson<int?>(json['archivedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'slug': serializer.toJson<String>(slug),
      'title': serializer.toJson<String>(title),
      'model': serializer.toJson<String>(model),
      'status': serializer.toJson<String>(
        $SessionsTable.$converterstatus.toJson(status),
      ),
      'agent': serializer.toJson<String>(agent),
      'parentId': serializer.toJson<int?>(parentId),
      'projectPath': serializer.toJson<String>(projectPath),
      'cost': serializer.toJson<double>(cost),
      'tokensIn': serializer.toJson<int>(tokensIn),
      'tokensOut': serializer.toJson<int>(tokensOut),
      'contextTokens': serializer.toJson<int>(contextTokens),
      'ttftMs': serializer.toJson<double>(ttftMs),
      'tokPerSec': serializer.toJson<double>(tokPerSec),
      'promptCacheHitTokens': serializer.toJson<int>(promptCacheHitTokens),
      'thinkingMode': serializer.toJson<String>(thinkingMode),
      'reasoningEffort': serializer.toJson<String?>(reasoningEffort),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'archivedAt': serializer.toJson<int?>(archivedAt),
    };
  }

  Session copyWith({
    int? id,
    String? slug,
    String? title,
    String? model,
    SessionStatus? status,
    String? agent,
    Value<int?> parentId = const Value.absent(),
    String? projectPath,
    double? cost,
    int? tokensIn,
    int? tokensOut,
    int? contextTokens,
    double? ttftMs,
    double? tokPerSec,
    int? promptCacheHitTokens,
    String? thinkingMode,
    Value<String?> reasoningEffort = const Value.absent(),
    int? createdAt,
    int? updatedAt,
    Value<int?> archivedAt = const Value.absent(),
  }) => Session(
    id: id ?? this.id,
    slug: slug ?? this.slug,
    title: title ?? this.title,
    model: model ?? this.model,
    status: status ?? this.status,
    agent: agent ?? this.agent,
    parentId: parentId.present ? parentId.value : this.parentId,
    projectPath: projectPath ?? this.projectPath,
    cost: cost ?? this.cost,
    tokensIn: tokensIn ?? this.tokensIn,
    tokensOut: tokensOut ?? this.tokensOut,
    contextTokens: contextTokens ?? this.contextTokens,
    ttftMs: ttftMs ?? this.ttftMs,
    tokPerSec: tokPerSec ?? this.tokPerSec,
    promptCacheHitTokens: promptCacheHitTokens ?? this.promptCacheHitTokens,
    thinkingMode: thinkingMode ?? this.thinkingMode,
    reasoningEffort: reasoningEffort.present
        ? reasoningEffort.value
        : this.reasoningEffort,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    archivedAt: archivedAt.present ? archivedAt.value : this.archivedAt,
  );
  Session copyWithCompanion(SessionsCompanion data) {
    return Session(
      id: data.id.present ? data.id.value : this.id,
      slug: data.slug.present ? data.slug.value : this.slug,
      title: data.title.present ? data.title.value : this.title,
      model: data.model.present ? data.model.value : this.model,
      status: data.status.present ? data.status.value : this.status,
      agent: data.agent.present ? data.agent.value : this.agent,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      projectPath: data.projectPath.present
          ? data.projectPath.value
          : this.projectPath,
      cost: data.cost.present ? data.cost.value : this.cost,
      tokensIn: data.tokensIn.present ? data.tokensIn.value : this.tokensIn,
      tokensOut: data.tokensOut.present ? data.tokensOut.value : this.tokensOut,
      contextTokens: data.contextTokens.present
          ? data.contextTokens.value
          : this.contextTokens,
      ttftMs: data.ttftMs.present ? data.ttftMs.value : this.ttftMs,
      tokPerSec: data.tokPerSec.present ? data.tokPerSec.value : this.tokPerSec,
      promptCacheHitTokens: data.promptCacheHitTokens.present
          ? data.promptCacheHitTokens.value
          : this.promptCacheHitTokens,
      thinkingMode: data.thinkingMode.present
          ? data.thinkingMode.value
          : this.thinkingMode,
      reasoningEffort: data.reasoningEffort.present
          ? data.reasoningEffort.value
          : this.reasoningEffort,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      archivedAt: data.archivedAt.present
          ? data.archivedAt.value
          : this.archivedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Session(')
          ..write('id: $id, ')
          ..write('slug: $slug, ')
          ..write('title: $title, ')
          ..write('model: $model, ')
          ..write('status: $status, ')
          ..write('agent: $agent, ')
          ..write('parentId: $parentId, ')
          ..write('projectPath: $projectPath, ')
          ..write('cost: $cost, ')
          ..write('tokensIn: $tokensIn, ')
          ..write('tokensOut: $tokensOut, ')
          ..write('contextTokens: $contextTokens, ')
          ..write('ttftMs: $ttftMs, ')
          ..write('tokPerSec: $tokPerSec, ')
          ..write('promptCacheHitTokens: $promptCacheHitTokens, ')
          ..write('thinkingMode: $thinkingMode, ')
          ..write('reasoningEffort: $reasoningEffort, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('archivedAt: $archivedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    slug,
    title,
    model,
    status,
    agent,
    parentId,
    projectPath,
    cost,
    tokensIn,
    tokensOut,
    contextTokens,
    ttftMs,
    tokPerSec,
    promptCacheHitTokens,
    thinkingMode,
    reasoningEffort,
    createdAt,
    updatedAt,
    archivedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Session &&
          other.id == this.id &&
          other.slug == this.slug &&
          other.title == this.title &&
          other.model == this.model &&
          other.status == this.status &&
          other.agent == this.agent &&
          other.parentId == this.parentId &&
          other.projectPath == this.projectPath &&
          other.cost == this.cost &&
          other.tokensIn == this.tokensIn &&
          other.tokensOut == this.tokensOut &&
          other.contextTokens == this.contextTokens &&
          other.ttftMs == this.ttftMs &&
          other.tokPerSec == this.tokPerSec &&
          other.promptCacheHitTokens == this.promptCacheHitTokens &&
          other.thinkingMode == this.thinkingMode &&
          other.reasoningEffort == this.reasoningEffort &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.archivedAt == this.archivedAt);
}

class SessionsCompanion extends UpdateCompanion<Session> {
  final Value<int> id;
  final Value<String> slug;
  final Value<String> title;
  final Value<String> model;
  final Value<SessionStatus> status;
  final Value<String> agent;
  final Value<int?> parentId;
  final Value<String> projectPath;
  final Value<double> cost;
  final Value<int> tokensIn;
  final Value<int> tokensOut;
  final Value<int> contextTokens;
  final Value<double> ttftMs;
  final Value<double> tokPerSec;
  final Value<int> promptCacheHitTokens;
  final Value<String> thinkingMode;
  final Value<String?> reasoningEffort;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int?> archivedAt;
  const SessionsCompanion({
    this.id = const Value.absent(),
    this.slug = const Value.absent(),
    this.title = const Value.absent(),
    this.model = const Value.absent(),
    this.status = const Value.absent(),
    this.agent = const Value.absent(),
    this.parentId = const Value.absent(),
    this.projectPath = const Value.absent(),
    this.cost = const Value.absent(),
    this.tokensIn = const Value.absent(),
    this.tokensOut = const Value.absent(),
    this.contextTokens = const Value.absent(),
    this.ttftMs = const Value.absent(),
    this.tokPerSec = const Value.absent(),
    this.promptCacheHitTokens = const Value.absent(),
    this.thinkingMode = const Value.absent(),
    this.reasoningEffort = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.archivedAt = const Value.absent(),
  });
  SessionsCompanion.insert({
    this.id = const Value.absent(),
    this.slug = const Value.absent(),
    this.title = const Value.absent(),
    this.model = const Value.absent(),
    required SessionStatus status,
    this.agent = const Value.absent(),
    this.parentId = const Value.absent(),
    this.projectPath = const Value.absent(),
    this.cost = const Value.absent(),
    this.tokensIn = const Value.absent(),
    this.tokensOut = const Value.absent(),
    this.contextTokens = const Value.absent(),
    this.ttftMs = const Value.absent(),
    this.tokPerSec = const Value.absent(),
    this.promptCacheHitTokens = const Value.absent(),
    this.thinkingMode = const Value.absent(),
    this.reasoningEffort = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.archivedAt = const Value.absent(),
  }) : status = Value(status),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<Session> custom({
    Expression<int>? id,
    Expression<String>? slug,
    Expression<String>? title,
    Expression<String>? model,
    Expression<String>? status,
    Expression<String>? agent,
    Expression<int>? parentId,
    Expression<String>? projectPath,
    Expression<double>? cost,
    Expression<int>? tokensIn,
    Expression<int>? tokensOut,
    Expression<int>? contextTokens,
    Expression<double>? ttftMs,
    Expression<double>? tokPerSec,
    Expression<int>? promptCacheHitTokens,
    Expression<String>? thinkingMode,
    Expression<String>? reasoningEffort,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? archivedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (slug != null) 'slug': slug,
      if (title != null) 'title': title,
      if (model != null) 'model': model,
      if (status != null) 'status': status,
      if (agent != null) 'agent': agent,
      if (parentId != null) 'parent_id': parentId,
      if (projectPath != null) 'project_path': projectPath,
      if (cost != null) 'cost': cost,
      if (tokensIn != null) 'tokens_in': tokensIn,
      if (tokensOut != null) 'tokens_out': tokensOut,
      if (contextTokens != null) 'context_tokens': contextTokens,
      if (ttftMs != null) 'ttft_ms': ttftMs,
      if (tokPerSec != null) 'tok_per_sec': tokPerSec,
      if (promptCacheHitTokens != null)
        'prompt_cache_hit_tokens': promptCacheHitTokens,
      if (thinkingMode != null) 'thinking_mode': thinkingMode,
      if (reasoningEffort != null) 'reasoning_effort': reasoningEffort,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (archivedAt != null) 'archived_at': archivedAt,
    });
  }

  SessionsCompanion copyWith({
    Value<int>? id,
    Value<String>? slug,
    Value<String>? title,
    Value<String>? model,
    Value<SessionStatus>? status,
    Value<String>? agent,
    Value<int?>? parentId,
    Value<String>? projectPath,
    Value<double>? cost,
    Value<int>? tokensIn,
    Value<int>? tokensOut,
    Value<int>? contextTokens,
    Value<double>? ttftMs,
    Value<double>? tokPerSec,
    Value<int>? promptCacheHitTokens,
    Value<String>? thinkingMode,
    Value<String?>? reasoningEffort,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int?>? archivedAt,
  }) {
    return SessionsCompanion(
      id: id ?? this.id,
      slug: slug ?? this.slug,
      title: title ?? this.title,
      model: model ?? this.model,
      status: status ?? this.status,
      agent: agent ?? this.agent,
      parentId: parentId ?? this.parentId,
      projectPath: projectPath ?? this.projectPath,
      cost: cost ?? this.cost,
      tokensIn: tokensIn ?? this.tokensIn,
      tokensOut: tokensOut ?? this.tokensOut,
      contextTokens: contextTokens ?? this.contextTokens,
      ttftMs: ttftMs ?? this.ttftMs,
      tokPerSec: tokPerSec ?? this.tokPerSec,
      promptCacheHitTokens: promptCacheHitTokens ?? this.promptCacheHitTokens,
      thinkingMode: thinkingMode ?? this.thinkingMode,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      archivedAt: archivedAt ?? this.archivedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (slug.present) {
      map['slug'] = Variable<String>(slug.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(
        $SessionsTable.$converterstatus.toSql(status.value),
      );
    }
    if (agent.present) {
      map['agent'] = Variable<String>(agent.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<int>(parentId.value);
    }
    if (projectPath.present) {
      map['project_path'] = Variable<String>(projectPath.value);
    }
    if (cost.present) {
      map['cost'] = Variable<double>(cost.value);
    }
    if (tokensIn.present) {
      map['tokens_in'] = Variable<int>(tokensIn.value);
    }
    if (tokensOut.present) {
      map['tokens_out'] = Variable<int>(tokensOut.value);
    }
    if (contextTokens.present) {
      map['context_tokens'] = Variable<int>(contextTokens.value);
    }
    if (ttftMs.present) {
      map['ttft_ms'] = Variable<double>(ttftMs.value);
    }
    if (tokPerSec.present) {
      map['tok_per_sec'] = Variable<double>(tokPerSec.value);
    }
    if (promptCacheHitTokens.present) {
      map['prompt_cache_hit_tokens'] = Variable<int>(
        promptCacheHitTokens.value,
      );
    }
    if (thinkingMode.present) {
      map['thinking_mode'] = Variable<String>(thinkingMode.value);
    }
    if (reasoningEffort.present) {
      map['reasoning_effort'] = Variable<String>(reasoningEffort.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (archivedAt.present) {
      map['archived_at'] = Variable<int>(archivedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SessionsCompanion(')
          ..write('id: $id, ')
          ..write('slug: $slug, ')
          ..write('title: $title, ')
          ..write('model: $model, ')
          ..write('status: $status, ')
          ..write('agent: $agent, ')
          ..write('parentId: $parentId, ')
          ..write('projectPath: $projectPath, ')
          ..write('cost: $cost, ')
          ..write('tokensIn: $tokensIn, ')
          ..write('tokensOut: $tokensOut, ')
          ..write('contextTokens: $contextTokens, ')
          ..write('ttftMs: $ttftMs, ')
          ..write('tokPerSec: $tokPerSec, ')
          ..write('promptCacheHitTokens: $promptCacheHitTokens, ')
          ..write('thinkingMode: $thinkingMode, ')
          ..write('reasoningEffort: $reasoningEffort, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('archivedAt: $archivedAt')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages with TableInfo<$MessagesTable, Message> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<int> sessionId = GeneratedColumn<int>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES sessions (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _reasoningContentMeta = const VerificationMeta(
    'reasoningContent',
  );
  @override
  late final GeneratedColumn<String> reasoningContent = GeneratedColumn<String>(
    'reasoning_content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _reasoningSignatureMeta =
      const VerificationMeta('reasoningSignature');
  @override
  late final GeneratedColumn<String> reasoningSignature =
      GeneratedColumn<String>(
        'reasoning_signature',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant(''),
      );
  static const VerificationMeta _reasoningTokensMeta = const VerificationMeta(
    'reasoningTokens',
  );
  @override
  late final GeneratedColumn<int> reasoningTokens = GeneratedColumn<int>(
    'reasoning_tokens',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _thinkingDurationMsMeta =
      const VerificationMeta('thinkingDurationMs');
  @override
  late final GeneratedColumn<int> thinkingDurationMs = GeneratedColumn<int>(
    'thinking_duration_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _reasoningEffortMeta = const VerificationMeta(
    'reasoningEffort',
  );
  @override
  late final GeneratedColumn<String> reasoningEffort = GeneratedColumn<String>(
    'reasoning_effort',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _modelMeta = const VerificationMeta('model');
  @override
  late final GeneratedColumn<String> model = GeneratedColumn<String>(
    'model',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _costMeta = const VerificationMeta('cost');
  @override
  late final GeneratedColumn<double> cost = GeneratedColumn<double>(
    'cost',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
    defaultValue: const Constant(0.0),
  );
  static const VerificationMeta _tokensInMeta = const VerificationMeta(
    'tokensIn',
  );
  @override
  late final GeneratedColumn<int> tokensIn = GeneratedColumn<int>(
    'tokens_in',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _tokensOutMeta = const VerificationMeta(
    'tokensOut',
  );
  @override
  late final GeneratedColumn<int> tokensOut = GeneratedColumn<int>(
    'tokens_out',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _toolCallsMeta = const VerificationMeta(
    'toolCalls',
  );
  @override
  late final GeneratedColumn<String> toolCalls = GeneratedColumn<String>(
    'tool_calls',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _toolCallIdMeta = const VerificationMeta(
    'toolCallId',
  );
  @override
  late final GeneratedColumn<String> toolCallId = GeneratedColumn<String>(
    'tool_call_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _tldrMeta = const VerificationMeta('tldr');
  @override
  late final GeneratedColumn<String> tldr = GeneratedColumn<String>(
    'tldr',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _parentMsgIdMeta = const VerificationMeta(
    'parentMsgId',
  );
  @override
  late final GeneratedColumn<int> parentMsgId = GeneratedColumn<int>(
    'parent_msg_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _preCompressTokensMeta = const VerificationMeta(
    'preCompressTokens',
  );
  @override
  late final GeneratedColumn<int> preCompressTokens = GeneratedColumn<int>(
    'pre_compress_tokens',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    sessionId,
    role,
    content,
    reasoningContent,
    reasoningSignature,
    reasoningTokens,
    thinkingDurationMs,
    reasoningEffort,
    model,
    cost,
    tokensIn,
    tokensOut,
    toolCalls,
    toolCallId,
    tldr,
    error,
    parentMsgId,
    preCompressTokens,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<Message> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    }
    if (data.containsKey('reasoning_content')) {
      context.handle(
        _reasoningContentMeta,
        reasoningContent.isAcceptableOrUnknown(
          data['reasoning_content']!,
          _reasoningContentMeta,
        ),
      );
    }
    if (data.containsKey('reasoning_signature')) {
      context.handle(
        _reasoningSignatureMeta,
        reasoningSignature.isAcceptableOrUnknown(
          data['reasoning_signature']!,
          _reasoningSignatureMeta,
        ),
      );
    }
    if (data.containsKey('reasoning_tokens')) {
      context.handle(
        _reasoningTokensMeta,
        reasoningTokens.isAcceptableOrUnknown(
          data['reasoning_tokens']!,
          _reasoningTokensMeta,
        ),
      );
    }
    if (data.containsKey('thinking_duration_ms')) {
      context.handle(
        _thinkingDurationMsMeta,
        thinkingDurationMs.isAcceptableOrUnknown(
          data['thinking_duration_ms']!,
          _thinkingDurationMsMeta,
        ),
      );
    }
    if (data.containsKey('reasoning_effort')) {
      context.handle(
        _reasoningEffortMeta,
        reasoningEffort.isAcceptableOrUnknown(
          data['reasoning_effort']!,
          _reasoningEffortMeta,
        ),
      );
    }
    if (data.containsKey('model')) {
      context.handle(
        _modelMeta,
        model.isAcceptableOrUnknown(data['model']!, _modelMeta),
      );
    }
    if (data.containsKey('cost')) {
      context.handle(
        _costMeta,
        cost.isAcceptableOrUnknown(data['cost']!, _costMeta),
      );
    }
    if (data.containsKey('tokens_in')) {
      context.handle(
        _tokensInMeta,
        tokensIn.isAcceptableOrUnknown(data['tokens_in']!, _tokensInMeta),
      );
    }
    if (data.containsKey('tokens_out')) {
      context.handle(
        _tokensOutMeta,
        tokensOut.isAcceptableOrUnknown(data['tokens_out']!, _tokensOutMeta),
      );
    }
    if (data.containsKey('tool_calls')) {
      context.handle(
        _toolCallsMeta,
        toolCalls.isAcceptableOrUnknown(data['tool_calls']!, _toolCallsMeta),
      );
    }
    if (data.containsKey('tool_call_id')) {
      context.handle(
        _toolCallIdMeta,
        toolCallId.isAcceptableOrUnknown(
          data['tool_call_id']!,
          _toolCallIdMeta,
        ),
      );
    }
    if (data.containsKey('tldr')) {
      context.handle(
        _tldrMeta,
        tldr.isAcceptableOrUnknown(data['tldr']!, _tldrMeta),
      );
    }
    if (data.containsKey('error')) {
      context.handle(
        _errorMeta,
        error.isAcceptableOrUnknown(data['error']!, _errorMeta),
      );
    }
    if (data.containsKey('parent_msg_id')) {
      context.handle(
        _parentMsgIdMeta,
        parentMsgId.isAcceptableOrUnknown(
          data['parent_msg_id']!,
          _parentMsgIdMeta,
        ),
      );
    }
    if (data.containsKey('pre_compress_tokens')) {
      context.handle(
        _preCompressTokensMeta,
        preCompressTokens.isAcceptableOrUnknown(
          data['pre_compress_tokens']!,
          _preCompressTokensMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Message map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Message(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}session_id'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      reasoningContent: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reasoning_content'],
      )!,
      reasoningSignature: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reasoning_signature'],
      )!,
      reasoningTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reasoning_tokens'],
      )!,
      thinkingDurationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}thinking_duration_ms'],
      )!,
      reasoningEffort: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reasoning_effort'],
      ),
      model: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}model'],
      )!,
      cost: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}cost'],
      )!,
      tokensIn: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tokens_in'],
      )!,
      tokensOut: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}tokens_out'],
      )!,
      toolCalls: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_calls'],
      )!,
      toolCallId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_call_id'],
      )!,
      tldr: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tldr'],
      )!,
      error: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error'],
      ),
      parentMsgId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent_msg_id'],
      ),
      preCompressTokens: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}pre_compress_tokens'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }
}

class Message extends DataClass implements Insertable<Message> {
  final int id;
  final int sessionId;
  final String role;
  final String content;
  final String reasoningContent;
  final String reasoningSignature;
  final int reasoningTokens;
  final int thinkingDurationMs;
  final String? reasoningEffort;
  final String model;
  final double cost;
  final int tokensIn;
  final int tokensOut;
  final String toolCalls;
  final String toolCallId;
  final String tldr;
  final String? error;
  final int? parentMsgId;

  /// Total round-trip token cost of the tool_call's args *before*
  /// compression. Set by the chat service when a LargePayloadTool's
  /// large args were off-loaded. Null for non-tool-call messages
  /// and for tool_call messages whose args were small enough to
  /// keep in full. The chat bubble uses this to render the
  /// pre/post compression comparison (e.g. `~~5000t~~, compressed: 15t`).
  final int? preCompressTokens;
  final int createdAt;
  const Message({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.reasoningContent,
    required this.reasoningSignature,
    required this.reasoningTokens,
    required this.thinkingDurationMs,
    this.reasoningEffort,
    required this.model,
    required this.cost,
    required this.tokensIn,
    required this.tokensOut,
    required this.toolCalls,
    required this.toolCallId,
    required this.tldr,
    this.error,
    this.parentMsgId,
    this.preCompressTokens,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['session_id'] = Variable<int>(sessionId);
    map['role'] = Variable<String>(role);
    map['content'] = Variable<String>(content);
    map['reasoning_content'] = Variable<String>(reasoningContent);
    map['reasoning_signature'] = Variable<String>(reasoningSignature);
    map['reasoning_tokens'] = Variable<int>(reasoningTokens);
    map['thinking_duration_ms'] = Variable<int>(thinkingDurationMs);
    if (!nullToAbsent || reasoningEffort != null) {
      map['reasoning_effort'] = Variable<String>(reasoningEffort);
    }
    map['model'] = Variable<String>(model);
    map['cost'] = Variable<double>(cost);
    map['tokens_in'] = Variable<int>(tokensIn);
    map['tokens_out'] = Variable<int>(tokensOut);
    map['tool_calls'] = Variable<String>(toolCalls);
    map['tool_call_id'] = Variable<String>(toolCallId);
    map['tldr'] = Variable<String>(tldr);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    if (!nullToAbsent || parentMsgId != null) {
      map['parent_msg_id'] = Variable<int>(parentMsgId);
    }
    if (!nullToAbsent || preCompressTokens != null) {
      map['pre_compress_tokens'] = Variable<int>(preCompressTokens);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      sessionId: Value(sessionId),
      role: Value(role),
      content: Value(content),
      reasoningContent: Value(reasoningContent),
      reasoningSignature: Value(reasoningSignature),
      reasoningTokens: Value(reasoningTokens),
      thinkingDurationMs: Value(thinkingDurationMs),
      reasoningEffort: reasoningEffort == null && nullToAbsent
          ? const Value.absent()
          : Value(reasoningEffort),
      model: Value(model),
      cost: Value(cost),
      tokensIn: Value(tokensIn),
      tokensOut: Value(tokensOut),
      toolCalls: Value(toolCalls),
      toolCallId: Value(toolCallId),
      tldr: Value(tldr),
      error: error == null && nullToAbsent
          ? const Value.absent()
          : Value(error),
      parentMsgId: parentMsgId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentMsgId),
      preCompressTokens: preCompressTokens == null && nullToAbsent
          ? const Value.absent()
          : Value(preCompressTokens),
      createdAt: Value(createdAt),
    );
  }

  factory Message.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Message(
      id: serializer.fromJson<int>(json['id']),
      sessionId: serializer.fromJson<int>(json['sessionId']),
      role: serializer.fromJson<String>(json['role']),
      content: serializer.fromJson<String>(json['content']),
      reasoningContent: serializer.fromJson<String>(json['reasoningContent']),
      reasoningSignature: serializer.fromJson<String>(
        json['reasoningSignature'],
      ),
      reasoningTokens: serializer.fromJson<int>(json['reasoningTokens']),
      thinkingDurationMs: serializer.fromJson<int>(json['thinkingDurationMs']),
      reasoningEffort: serializer.fromJson<String?>(json['reasoningEffort']),
      model: serializer.fromJson<String>(json['model']),
      cost: serializer.fromJson<double>(json['cost']),
      tokensIn: serializer.fromJson<int>(json['tokensIn']),
      tokensOut: serializer.fromJson<int>(json['tokensOut']),
      toolCalls: serializer.fromJson<String>(json['toolCalls']),
      toolCallId: serializer.fromJson<String>(json['toolCallId']),
      tldr: serializer.fromJson<String>(json['tldr']),
      error: serializer.fromJson<String?>(json['error']),
      parentMsgId: serializer.fromJson<int?>(json['parentMsgId']),
      preCompressTokens: serializer.fromJson<int?>(json['preCompressTokens']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'sessionId': serializer.toJson<int>(sessionId),
      'role': serializer.toJson<String>(role),
      'content': serializer.toJson<String>(content),
      'reasoningContent': serializer.toJson<String>(reasoningContent),
      'reasoningSignature': serializer.toJson<String>(reasoningSignature),
      'reasoningTokens': serializer.toJson<int>(reasoningTokens),
      'thinkingDurationMs': serializer.toJson<int>(thinkingDurationMs),
      'reasoningEffort': serializer.toJson<String?>(reasoningEffort),
      'model': serializer.toJson<String>(model),
      'cost': serializer.toJson<double>(cost),
      'tokensIn': serializer.toJson<int>(tokensIn),
      'tokensOut': serializer.toJson<int>(tokensOut),
      'toolCalls': serializer.toJson<String>(toolCalls),
      'toolCallId': serializer.toJson<String>(toolCallId),
      'tldr': serializer.toJson<String>(tldr),
      'error': serializer.toJson<String?>(error),
      'parentMsgId': serializer.toJson<int?>(parentMsgId),
      'preCompressTokens': serializer.toJson<int?>(preCompressTokens),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  Message copyWith({
    int? id,
    int? sessionId,
    String? role,
    String? content,
    String? reasoningContent,
    String? reasoningSignature,
    int? reasoningTokens,
    int? thinkingDurationMs,
    Value<String?> reasoningEffort = const Value.absent(),
    String? model,
    double? cost,
    int? tokensIn,
    int? tokensOut,
    String? toolCalls,
    String? toolCallId,
    String? tldr,
    Value<String?> error = const Value.absent(),
    Value<int?> parentMsgId = const Value.absent(),
    Value<int?> preCompressTokens = const Value.absent(),
    int? createdAt,
  }) => Message(
    id: id ?? this.id,
    sessionId: sessionId ?? this.sessionId,
    role: role ?? this.role,
    content: content ?? this.content,
    reasoningContent: reasoningContent ?? this.reasoningContent,
    reasoningSignature: reasoningSignature ?? this.reasoningSignature,
    reasoningTokens: reasoningTokens ?? this.reasoningTokens,
    thinkingDurationMs: thinkingDurationMs ?? this.thinkingDurationMs,
    reasoningEffort: reasoningEffort.present
        ? reasoningEffort.value
        : this.reasoningEffort,
    model: model ?? this.model,
    cost: cost ?? this.cost,
    tokensIn: tokensIn ?? this.tokensIn,
    tokensOut: tokensOut ?? this.tokensOut,
    toolCalls: toolCalls ?? this.toolCalls,
    toolCallId: toolCallId ?? this.toolCallId,
    tldr: tldr ?? this.tldr,
    error: error.present ? error.value : this.error,
    parentMsgId: parentMsgId.present ? parentMsgId.value : this.parentMsgId,
    preCompressTokens: preCompressTokens.present
        ? preCompressTokens.value
        : this.preCompressTokens,
    createdAt: createdAt ?? this.createdAt,
  );
  Message copyWithCompanion(MessagesCompanion data) {
    return Message(
      id: data.id.present ? data.id.value : this.id,
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      role: data.role.present ? data.role.value : this.role,
      content: data.content.present ? data.content.value : this.content,
      reasoningContent: data.reasoningContent.present
          ? data.reasoningContent.value
          : this.reasoningContent,
      reasoningSignature: data.reasoningSignature.present
          ? data.reasoningSignature.value
          : this.reasoningSignature,
      reasoningTokens: data.reasoningTokens.present
          ? data.reasoningTokens.value
          : this.reasoningTokens,
      thinkingDurationMs: data.thinkingDurationMs.present
          ? data.thinkingDurationMs.value
          : this.thinkingDurationMs,
      reasoningEffort: data.reasoningEffort.present
          ? data.reasoningEffort.value
          : this.reasoningEffort,
      model: data.model.present ? data.model.value : this.model,
      cost: data.cost.present ? data.cost.value : this.cost,
      tokensIn: data.tokensIn.present ? data.tokensIn.value : this.tokensIn,
      tokensOut: data.tokensOut.present ? data.tokensOut.value : this.tokensOut,
      toolCalls: data.toolCalls.present ? data.toolCalls.value : this.toolCalls,
      toolCallId: data.toolCallId.present
          ? data.toolCallId.value
          : this.toolCallId,
      tldr: data.tldr.present ? data.tldr.value : this.tldr,
      error: data.error.present ? data.error.value : this.error,
      parentMsgId: data.parentMsgId.present
          ? data.parentMsgId.value
          : this.parentMsgId,
      preCompressTokens: data.preCompressTokens.present
          ? data.preCompressTokens.value
          : this.preCompressTokens,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Message(')
          ..write('id: $id, ')
          ..write('sessionId: $sessionId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('reasoningContent: $reasoningContent, ')
          ..write('reasoningSignature: $reasoningSignature, ')
          ..write('reasoningTokens: $reasoningTokens, ')
          ..write('thinkingDurationMs: $thinkingDurationMs, ')
          ..write('reasoningEffort: $reasoningEffort, ')
          ..write('model: $model, ')
          ..write('cost: $cost, ')
          ..write('tokensIn: $tokensIn, ')
          ..write('tokensOut: $tokensOut, ')
          ..write('toolCalls: $toolCalls, ')
          ..write('toolCallId: $toolCallId, ')
          ..write('tldr: $tldr, ')
          ..write('error: $error, ')
          ..write('parentMsgId: $parentMsgId, ')
          ..write('preCompressTokens: $preCompressTokens, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    role,
    content,
    reasoningContent,
    reasoningSignature,
    reasoningTokens,
    thinkingDurationMs,
    reasoningEffort,
    model,
    cost,
    tokensIn,
    tokensOut,
    toolCalls,
    toolCallId,
    tldr,
    error,
    parentMsgId,
    preCompressTokens,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Message &&
          other.id == this.id &&
          other.sessionId == this.sessionId &&
          other.role == this.role &&
          other.content == this.content &&
          other.reasoningContent == this.reasoningContent &&
          other.reasoningSignature == this.reasoningSignature &&
          other.reasoningTokens == this.reasoningTokens &&
          other.thinkingDurationMs == this.thinkingDurationMs &&
          other.reasoningEffort == this.reasoningEffort &&
          other.model == this.model &&
          other.cost == this.cost &&
          other.tokensIn == this.tokensIn &&
          other.tokensOut == this.tokensOut &&
          other.toolCalls == this.toolCalls &&
          other.toolCallId == this.toolCallId &&
          other.tldr == this.tldr &&
          other.error == this.error &&
          other.parentMsgId == this.parentMsgId &&
          other.preCompressTokens == this.preCompressTokens &&
          other.createdAt == this.createdAt);
}

class MessagesCompanion extends UpdateCompanion<Message> {
  final Value<int> id;
  final Value<int> sessionId;
  final Value<String> role;
  final Value<String> content;
  final Value<String> reasoningContent;
  final Value<String> reasoningSignature;
  final Value<int> reasoningTokens;
  final Value<int> thinkingDurationMs;
  final Value<String?> reasoningEffort;
  final Value<String> model;
  final Value<double> cost;
  final Value<int> tokensIn;
  final Value<int> tokensOut;
  final Value<String> toolCalls;
  final Value<String> toolCallId;
  final Value<String> tldr;
  final Value<String?> error;
  final Value<int?> parentMsgId;
  final Value<int?> preCompressTokens;
  final Value<int> createdAt;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.sessionId = const Value.absent(),
    this.role = const Value.absent(),
    this.content = const Value.absent(),
    this.reasoningContent = const Value.absent(),
    this.reasoningSignature = const Value.absent(),
    this.reasoningTokens = const Value.absent(),
    this.thinkingDurationMs = const Value.absent(),
    this.reasoningEffort = const Value.absent(),
    this.model = const Value.absent(),
    this.cost = const Value.absent(),
    this.tokensIn = const Value.absent(),
    this.tokensOut = const Value.absent(),
    this.toolCalls = const Value.absent(),
    this.toolCallId = const Value.absent(),
    this.tldr = const Value.absent(),
    this.error = const Value.absent(),
    this.parentMsgId = const Value.absent(),
    this.preCompressTokens = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  MessagesCompanion.insert({
    this.id = const Value.absent(),
    required int sessionId,
    required String role,
    this.content = const Value.absent(),
    this.reasoningContent = const Value.absent(),
    this.reasoningSignature = const Value.absent(),
    this.reasoningTokens = const Value.absent(),
    this.thinkingDurationMs = const Value.absent(),
    this.reasoningEffort = const Value.absent(),
    this.model = const Value.absent(),
    this.cost = const Value.absent(),
    this.tokensIn = const Value.absent(),
    this.tokensOut = const Value.absent(),
    this.toolCalls = const Value.absent(),
    this.toolCallId = const Value.absent(),
    this.tldr = const Value.absent(),
    this.error = const Value.absent(),
    this.parentMsgId = const Value.absent(),
    this.preCompressTokens = const Value.absent(),
    required int createdAt,
  }) : sessionId = Value(sessionId),
       role = Value(role),
       createdAt = Value(createdAt);
  static Insertable<Message> custom({
    Expression<int>? id,
    Expression<int>? sessionId,
    Expression<String>? role,
    Expression<String>? content,
    Expression<String>? reasoningContent,
    Expression<String>? reasoningSignature,
    Expression<int>? reasoningTokens,
    Expression<int>? thinkingDurationMs,
    Expression<String>? reasoningEffort,
    Expression<String>? model,
    Expression<double>? cost,
    Expression<int>? tokensIn,
    Expression<int>? tokensOut,
    Expression<String>? toolCalls,
    Expression<String>? toolCallId,
    Expression<String>? tldr,
    Expression<String>? error,
    Expression<int>? parentMsgId,
    Expression<int>? preCompressTokens,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (sessionId != null) 'session_id': sessionId,
      if (role != null) 'role': role,
      if (content != null) 'content': content,
      if (reasoningContent != null) 'reasoning_content': reasoningContent,
      if (reasoningSignature != null) 'reasoning_signature': reasoningSignature,
      if (reasoningTokens != null) 'reasoning_tokens': reasoningTokens,
      if (thinkingDurationMs != null)
        'thinking_duration_ms': thinkingDurationMs,
      if (reasoningEffort != null) 'reasoning_effort': reasoningEffort,
      if (model != null) 'model': model,
      if (cost != null) 'cost': cost,
      if (tokensIn != null) 'tokens_in': tokensIn,
      if (tokensOut != null) 'tokens_out': tokensOut,
      if (toolCalls != null) 'tool_calls': toolCalls,
      if (toolCallId != null) 'tool_call_id': toolCallId,
      if (tldr != null) 'tldr': tldr,
      if (error != null) 'error': error,
      if (parentMsgId != null) 'parent_msg_id': parentMsgId,
      if (preCompressTokens != null) 'pre_compress_tokens': preCompressTokens,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  MessagesCompanion copyWith({
    Value<int>? id,
    Value<int>? sessionId,
    Value<String>? role,
    Value<String>? content,
    Value<String>? reasoningContent,
    Value<String>? reasoningSignature,
    Value<int>? reasoningTokens,
    Value<int>? thinkingDurationMs,
    Value<String?>? reasoningEffort,
    Value<String>? model,
    Value<double>? cost,
    Value<int>? tokensIn,
    Value<int>? tokensOut,
    Value<String>? toolCalls,
    Value<String>? toolCallId,
    Value<String>? tldr,
    Value<String?>? error,
    Value<int?>? parentMsgId,
    Value<int?>? preCompressTokens,
    Value<int>? createdAt,
  }) {
    return MessagesCompanion(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      content: content ?? this.content,
      reasoningContent: reasoningContent ?? this.reasoningContent,
      reasoningSignature: reasoningSignature ?? this.reasoningSignature,
      reasoningTokens: reasoningTokens ?? this.reasoningTokens,
      thinkingDurationMs: thinkingDurationMs ?? this.thinkingDurationMs,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      model: model ?? this.model,
      cost: cost ?? this.cost,
      tokensIn: tokensIn ?? this.tokensIn,
      tokensOut: tokensOut ?? this.tokensOut,
      toolCalls: toolCalls ?? this.toolCalls,
      toolCallId: toolCallId ?? this.toolCallId,
      tldr: tldr ?? this.tldr,
      error: error ?? this.error,
      parentMsgId: parentMsgId ?? this.parentMsgId,
      preCompressTokens: preCompressTokens ?? this.preCompressTokens,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (sessionId.present) {
      map['session_id'] = Variable<int>(sessionId.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (reasoningContent.present) {
      map['reasoning_content'] = Variable<String>(reasoningContent.value);
    }
    if (reasoningSignature.present) {
      map['reasoning_signature'] = Variable<String>(reasoningSignature.value);
    }
    if (reasoningTokens.present) {
      map['reasoning_tokens'] = Variable<int>(reasoningTokens.value);
    }
    if (thinkingDurationMs.present) {
      map['thinking_duration_ms'] = Variable<int>(thinkingDurationMs.value);
    }
    if (reasoningEffort.present) {
      map['reasoning_effort'] = Variable<String>(reasoningEffort.value);
    }
    if (model.present) {
      map['model'] = Variable<String>(model.value);
    }
    if (cost.present) {
      map['cost'] = Variable<double>(cost.value);
    }
    if (tokensIn.present) {
      map['tokens_in'] = Variable<int>(tokensIn.value);
    }
    if (tokensOut.present) {
      map['tokens_out'] = Variable<int>(tokensOut.value);
    }
    if (toolCalls.present) {
      map['tool_calls'] = Variable<String>(toolCalls.value);
    }
    if (toolCallId.present) {
      map['tool_call_id'] = Variable<String>(toolCallId.value);
    }
    if (tldr.present) {
      map['tldr'] = Variable<String>(tldr.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (parentMsgId.present) {
      map['parent_msg_id'] = Variable<int>(parentMsgId.value);
    }
    if (preCompressTokens.present) {
      map['pre_compress_tokens'] = Variable<int>(preCompressTokens.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('sessionId: $sessionId, ')
          ..write('role: $role, ')
          ..write('content: $content, ')
          ..write('reasoningContent: $reasoningContent, ')
          ..write('reasoningSignature: $reasoningSignature, ')
          ..write('reasoningTokens: $reasoningTokens, ')
          ..write('thinkingDurationMs: $thinkingDurationMs, ')
          ..write('reasoningEffort: $reasoningEffort, ')
          ..write('model: $model, ')
          ..write('cost: $cost, ')
          ..write('tokensIn: $tokensIn, ')
          ..write('tokensOut: $tokensOut, ')
          ..write('toolCalls: $toolCalls, ')
          ..write('toolCallId: $toolCallId, ')
          ..write('tldr: $tldr, ')
          ..write('error: $error, ')
          ..write('parentMsgId: $parentMsgId, ')
          ..write('preCompressTokens: $preCompressTokens, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $PartsTable extends Parts with TableInfo<$PartsTable, Part> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PartsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<int> messageId = GeneratedColumn<int>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES messages (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<int> sessionId = GeneratedColumn<int>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES sessions (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<String> data = GeneratedColumn<String>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    messageId,
    sessionId,
    type,
    data,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'parts';
  @override
  VerificationContext validateIntegrity(
    Insertable<Part> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Part map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Part(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}message_id'],
      )!,
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}session_id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $PartsTable createAlias(String alias) {
    return $PartsTable(attachedDatabase, alias);
  }
}

class Part extends DataClass implements Insertable<Part> {
  final int id;
  final int messageId;
  final int sessionId;
  final String type;
  final String data;
  final int createdAt;
  const Part({
    required this.id,
    required this.messageId,
    required this.sessionId,
    required this.type,
    required this.data,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['message_id'] = Variable<int>(messageId);
    map['session_id'] = Variable<int>(sessionId);
    map['type'] = Variable<String>(type);
    map['data'] = Variable<String>(data);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  PartsCompanion toCompanion(bool nullToAbsent) {
    return PartsCompanion(
      id: Value(id),
      messageId: Value(messageId),
      sessionId: Value(sessionId),
      type: Value(type),
      data: Value(data),
      createdAt: Value(createdAt),
    );
  }

  factory Part.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Part(
      id: serializer.fromJson<int>(json['id']),
      messageId: serializer.fromJson<int>(json['messageId']),
      sessionId: serializer.fromJson<int>(json['sessionId']),
      type: serializer.fromJson<String>(json['type']),
      data: serializer.fromJson<String>(json['data']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'messageId': serializer.toJson<int>(messageId),
      'sessionId': serializer.toJson<int>(sessionId),
      'type': serializer.toJson<String>(type),
      'data': serializer.toJson<String>(data),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  Part copyWith({
    int? id,
    int? messageId,
    int? sessionId,
    String? type,
    String? data,
    int? createdAt,
  }) => Part(
    id: id ?? this.id,
    messageId: messageId ?? this.messageId,
    sessionId: sessionId ?? this.sessionId,
    type: type ?? this.type,
    data: data ?? this.data,
    createdAt: createdAt ?? this.createdAt,
  );
  Part copyWithCompanion(PartsCompanion data) {
    return Part(
      id: data.id.present ? data.id.value : this.id,
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      type: data.type.present ? data.type.value : this.type,
      data: data.data.present ? data.data.value : this.data,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Part(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('sessionId: $sessionId, ')
          ..write('type: $type, ')
          ..write('data: $data, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, messageId, sessionId, type, data, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Part &&
          other.id == this.id &&
          other.messageId == this.messageId &&
          other.sessionId == this.sessionId &&
          other.type == this.type &&
          other.data == this.data &&
          other.createdAt == this.createdAt);
}

class PartsCompanion extends UpdateCompanion<Part> {
  final Value<int> id;
  final Value<int> messageId;
  final Value<int> sessionId;
  final Value<String> type;
  final Value<String> data;
  final Value<int> createdAt;
  const PartsCompanion({
    this.id = const Value.absent(),
    this.messageId = const Value.absent(),
    this.sessionId = const Value.absent(),
    this.type = const Value.absent(),
    this.data = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  PartsCompanion.insert({
    this.id = const Value.absent(),
    required int messageId,
    required int sessionId,
    required String type,
    this.data = const Value.absent(),
    required int createdAt,
  }) : messageId = Value(messageId),
       sessionId = Value(sessionId),
       type = Value(type),
       createdAt = Value(createdAt);
  static Insertable<Part> custom({
    Expression<int>? id,
    Expression<int>? messageId,
    Expression<int>? sessionId,
    Expression<String>? type,
    Expression<String>? data,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (messageId != null) 'message_id': messageId,
      if (sessionId != null) 'session_id': sessionId,
      if (type != null) 'type': type,
      if (data != null) 'data': data,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  PartsCompanion copyWith({
    Value<int>? id,
    Value<int>? messageId,
    Value<int>? sessionId,
    Value<String>? type,
    Value<String>? data,
    Value<int>? createdAt,
  }) {
    return PartsCompanion(
      id: id ?? this.id,
      messageId: messageId ?? this.messageId,
      sessionId: sessionId ?? this.sessionId,
      type: type ?? this.type,
      data: data ?? this.data,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (messageId.present) {
      map['message_id'] = Variable<int>(messageId.value);
    }
    if (sessionId.present) {
      map['session_id'] = Variable<int>(sessionId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (data.present) {
      map['data'] = Variable<String>(data.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PartsCompanion(')
          ..write('id: $id, ')
          ..write('messageId: $messageId, ')
          ..write('sessionId: $sessionId, ')
          ..write('type: $type, ')
          ..write('data: $data, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $FileReadStateTable extends FileReadState
    with TableInfo<$FileReadStateTable, FileReadStateData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FileReadStateTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<int> sessionId = GeneratedColumn<int>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES sessions (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mtimeMsMeta = const VerificationMeta(
    'mtimeMs',
  );
  @override
  late final GeneratedColumn<int> mtimeMs = GeneratedColumn<int>(
    'mtime_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [sessionId, path, mtimeMs];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'file_read_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<FileReadStateData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('mtime_ms')) {
      context.handle(
        _mtimeMsMeta,
        mtimeMs.isAcceptableOrUnknown(data['mtime_ms']!, _mtimeMsMeta),
      );
    } else if (isInserting) {
      context.missing(_mtimeMsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => const {};
  @override
  FileReadStateData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FileReadStateData(
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}session_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      mtimeMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}mtime_ms'],
      )!,
    );
  }

  @override
  $FileReadStateTable createAlias(String alias) {
    return $FileReadStateTable(attachedDatabase, alias);
  }
}

class FileReadStateData extends DataClass
    implements Insertable<FileReadStateData> {
  final int sessionId;
  final String path;
  final int mtimeMs;
  const FileReadStateData({
    required this.sessionId,
    required this.path,
    required this.mtimeMs,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['session_id'] = Variable<int>(sessionId);
    map['path'] = Variable<String>(path);
    map['mtime_ms'] = Variable<int>(mtimeMs);
    return map;
  }

  FileReadStateCompanion toCompanion(bool nullToAbsent) {
    return FileReadStateCompanion(
      sessionId: Value(sessionId),
      path: Value(path),
      mtimeMs: Value(mtimeMs),
    );
  }

  factory FileReadStateData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FileReadStateData(
      sessionId: serializer.fromJson<int>(json['sessionId']),
      path: serializer.fromJson<String>(json['path']),
      mtimeMs: serializer.fromJson<int>(json['mtimeMs']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sessionId': serializer.toJson<int>(sessionId),
      'path': serializer.toJson<String>(path),
      'mtimeMs': serializer.toJson<int>(mtimeMs),
    };
  }

  FileReadStateData copyWith({int? sessionId, String? path, int? mtimeMs}) =>
      FileReadStateData(
        sessionId: sessionId ?? this.sessionId,
        path: path ?? this.path,
        mtimeMs: mtimeMs ?? this.mtimeMs,
      );
  FileReadStateData copyWithCompanion(FileReadStateCompanion data) {
    return FileReadStateData(
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      path: data.path.present ? data.path.value : this.path,
      mtimeMs: data.mtimeMs.present ? data.mtimeMs.value : this.mtimeMs,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FileReadStateData(')
          ..write('sessionId: $sessionId, ')
          ..write('path: $path, ')
          ..write('mtimeMs: $mtimeMs')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(sessionId, path, mtimeMs);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FileReadStateData &&
          other.sessionId == this.sessionId &&
          other.path == this.path &&
          other.mtimeMs == this.mtimeMs);
}

class FileReadStateCompanion extends UpdateCompanion<FileReadStateData> {
  final Value<int> sessionId;
  final Value<String> path;
  final Value<int> mtimeMs;
  final Value<int> rowid;
  const FileReadStateCompanion({
    this.sessionId = const Value.absent(),
    this.path = const Value.absent(),
    this.mtimeMs = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FileReadStateCompanion.insert({
    required int sessionId,
    required String path,
    required int mtimeMs,
    this.rowid = const Value.absent(),
  }) : sessionId = Value(sessionId),
       path = Value(path),
       mtimeMs = Value(mtimeMs);
  static Insertable<FileReadStateData> custom({
    Expression<int>? sessionId,
    Expression<String>? path,
    Expression<int>? mtimeMs,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sessionId != null) 'session_id': sessionId,
      if (path != null) 'path': path,
      if (mtimeMs != null) 'mtime_ms': mtimeMs,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FileReadStateCompanion copyWith({
    Value<int>? sessionId,
    Value<String>? path,
    Value<int>? mtimeMs,
    Value<int>? rowid,
  }) {
    return FileReadStateCompanion(
      sessionId: sessionId ?? this.sessionId,
      path: path ?? this.path,
      mtimeMs: mtimeMs ?? this.mtimeMs,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sessionId.present) {
      map['session_id'] = Variable<int>(sessionId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (mtimeMs.present) {
      map['mtime_ms'] = Variable<int>(mtimeMs.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FileReadStateCompanion(')
          ..write('sessionId: $sessionId, ')
          ..write('path: $path, ')
          ..write('mtimeMs: $mtimeMs, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OffloadedContentTable extends OffloadedContent
    with TableInfo<$OffloadedContentTable, OffloadedContentData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OffloadedContentTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<int> sessionId = GeneratedColumn<int>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES sessions (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _callIdMeta = const VerificationMeta('callId');
  @override
  late final GeneratedColumn<String> callId = GeneratedColumn<String>(
    'call_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _toolNameMeta = const VerificationMeta(
    'toolName',
  );
  @override
  late final GeneratedColumn<String> toolName = GeneratedColumn<String>(
    'tool_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _byteSizeMeta = const VerificationMeta(
    'byteSize',
  );
  @override
  late final GeneratedColumn<int> byteSize = GeneratedColumn<int>(
    'byte_size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lineCountMeta = const VerificationMeta(
    'lineCount',
  );
  @override
  late final GeneratedColumn<int> lineCount = GeneratedColumn<int>(
    'line_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentMeta = const VerificationMeta(
    'content',
  );
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
    'content',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _intentMeta = const VerificationMeta('intent');
  @override
  late final GeneratedColumn<String> intent = GeneratedColumn<String>(
    'intent',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    sessionId,
    callId,
    toolName,
    byteSize,
    lineCount,
    content,
    intent,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'offloaded_content';
  @override
  VerificationContext validateIntegrity(
    Insertable<OffloadedContentData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('call_id')) {
      context.handle(
        _callIdMeta,
        callId.isAcceptableOrUnknown(data['call_id']!, _callIdMeta),
      );
    } else if (isInserting) {
      context.missing(_callIdMeta);
    }
    if (data.containsKey('tool_name')) {
      context.handle(
        _toolNameMeta,
        toolName.isAcceptableOrUnknown(data['tool_name']!, _toolNameMeta),
      );
    } else if (isInserting) {
      context.missing(_toolNameMeta);
    }
    if (data.containsKey('byte_size')) {
      context.handle(
        _byteSizeMeta,
        byteSize.isAcceptableOrUnknown(data['byte_size']!, _byteSizeMeta),
      );
    } else if (isInserting) {
      context.missing(_byteSizeMeta);
    }
    if (data.containsKey('line_count')) {
      context.handle(
        _lineCountMeta,
        lineCount.isAcceptableOrUnknown(data['line_count']!, _lineCountMeta),
      );
    } else if (isInserting) {
      context.missing(_lineCountMeta);
    }
    if (data.containsKey('content')) {
      context.handle(
        _contentMeta,
        content.isAcceptableOrUnknown(data['content']!, _contentMeta),
      );
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('intent')) {
      context.handle(
        _intentMeta,
        intent.isAcceptableOrUnknown(data['intent']!, _intentMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sessionId, callId};
  @override
  OffloadedContentData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OffloadedContentData(
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}session_id'],
      )!,
      callId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}call_id'],
      )!,
      toolName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tool_name'],
      )!,
      byteSize: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}byte_size'],
      )!,
      lineCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}line_count'],
      )!,
      content: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content'],
      )!,
      intent: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}intent'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $OffloadedContentTable createAlias(String alias) {
    return $OffloadedContentTable(attachedDatabase, alias);
  }
}

class OffloadedContentData extends DataClass
    implements Insertable<OffloadedContentData> {
  final int sessionId;
  final String callId;
  final String toolName;
  final int byteSize;
  final int lineCount;
  final String content;
  final String intent;
  final int createdAt;
  const OffloadedContentData({
    required this.sessionId,
    required this.callId,
    required this.toolName,
    required this.byteSize,
    required this.lineCount,
    required this.content,
    required this.intent,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['session_id'] = Variable<int>(sessionId);
    map['call_id'] = Variable<String>(callId);
    map['tool_name'] = Variable<String>(toolName);
    map['byte_size'] = Variable<int>(byteSize);
    map['line_count'] = Variable<int>(lineCount);
    map['content'] = Variable<String>(content);
    map['intent'] = Variable<String>(intent);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  OffloadedContentCompanion toCompanion(bool nullToAbsent) {
    return OffloadedContentCompanion(
      sessionId: Value(sessionId),
      callId: Value(callId),
      toolName: Value(toolName),
      byteSize: Value(byteSize),
      lineCount: Value(lineCount),
      content: Value(content),
      intent: Value(intent),
      createdAt: Value(createdAt),
    );
  }

  factory OffloadedContentData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OffloadedContentData(
      sessionId: serializer.fromJson<int>(json['sessionId']),
      callId: serializer.fromJson<String>(json['callId']),
      toolName: serializer.fromJson<String>(json['toolName']),
      byteSize: serializer.fromJson<int>(json['byteSize']),
      lineCount: serializer.fromJson<int>(json['lineCount']),
      content: serializer.fromJson<String>(json['content']),
      intent: serializer.fromJson<String>(json['intent']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sessionId': serializer.toJson<int>(sessionId),
      'callId': serializer.toJson<String>(callId),
      'toolName': serializer.toJson<String>(toolName),
      'byteSize': serializer.toJson<int>(byteSize),
      'lineCount': serializer.toJson<int>(lineCount),
      'content': serializer.toJson<String>(content),
      'intent': serializer.toJson<String>(intent),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  OffloadedContentData copyWith({
    int? sessionId,
    String? callId,
    String? toolName,
    int? byteSize,
    int? lineCount,
    String? content,
    String? intent,
    int? createdAt,
  }) => OffloadedContentData(
    sessionId: sessionId ?? this.sessionId,
    callId: callId ?? this.callId,
    toolName: toolName ?? this.toolName,
    byteSize: byteSize ?? this.byteSize,
    lineCount: lineCount ?? this.lineCount,
    content: content ?? this.content,
    intent: intent ?? this.intent,
    createdAt: createdAt ?? this.createdAt,
  );
  OffloadedContentData copyWithCompanion(OffloadedContentCompanion data) {
    return OffloadedContentData(
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      callId: data.callId.present ? data.callId.value : this.callId,
      toolName: data.toolName.present ? data.toolName.value : this.toolName,
      byteSize: data.byteSize.present ? data.byteSize.value : this.byteSize,
      lineCount: data.lineCount.present ? data.lineCount.value : this.lineCount,
      content: data.content.present ? data.content.value : this.content,
      intent: data.intent.present ? data.intent.value : this.intent,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OffloadedContentData(')
          ..write('sessionId: $sessionId, ')
          ..write('callId: $callId, ')
          ..write('toolName: $toolName, ')
          ..write('byteSize: $byteSize, ')
          ..write('lineCount: $lineCount, ')
          ..write('content: $content, ')
          ..write('intent: $intent, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    sessionId,
    callId,
    toolName,
    byteSize,
    lineCount,
    content,
    intent,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OffloadedContentData &&
          other.sessionId == this.sessionId &&
          other.callId == this.callId &&
          other.toolName == this.toolName &&
          other.byteSize == this.byteSize &&
          other.lineCount == this.lineCount &&
          other.content == this.content &&
          other.intent == this.intent &&
          other.createdAt == this.createdAt);
}

class OffloadedContentCompanion extends UpdateCompanion<OffloadedContentData> {
  final Value<int> sessionId;
  final Value<String> callId;
  final Value<String> toolName;
  final Value<int> byteSize;
  final Value<int> lineCount;
  final Value<String> content;
  final Value<String> intent;
  final Value<int> createdAt;
  final Value<int> rowid;
  const OffloadedContentCompanion({
    this.sessionId = const Value.absent(),
    this.callId = const Value.absent(),
    this.toolName = const Value.absent(),
    this.byteSize = const Value.absent(),
    this.lineCount = const Value.absent(),
    this.content = const Value.absent(),
    this.intent = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OffloadedContentCompanion.insert({
    required int sessionId,
    required String callId,
    required String toolName,
    required int byteSize,
    required int lineCount,
    required String content,
    this.intent = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : sessionId = Value(sessionId),
       callId = Value(callId),
       toolName = Value(toolName),
       byteSize = Value(byteSize),
       lineCount = Value(lineCount),
       content = Value(content),
       createdAt = Value(createdAt);
  static Insertable<OffloadedContentData> custom({
    Expression<int>? sessionId,
    Expression<String>? callId,
    Expression<String>? toolName,
    Expression<int>? byteSize,
    Expression<int>? lineCount,
    Expression<String>? content,
    Expression<String>? intent,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sessionId != null) 'session_id': sessionId,
      if (callId != null) 'call_id': callId,
      if (toolName != null) 'tool_name': toolName,
      if (byteSize != null) 'byte_size': byteSize,
      if (lineCount != null) 'line_count': lineCount,
      if (content != null) 'content': content,
      if (intent != null) 'intent': intent,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OffloadedContentCompanion copyWith({
    Value<int>? sessionId,
    Value<String>? callId,
    Value<String>? toolName,
    Value<int>? byteSize,
    Value<int>? lineCount,
    Value<String>? content,
    Value<String>? intent,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return OffloadedContentCompanion(
      sessionId: sessionId ?? this.sessionId,
      callId: callId ?? this.callId,
      toolName: toolName ?? this.toolName,
      byteSize: byteSize ?? this.byteSize,
      lineCount: lineCount ?? this.lineCount,
      content: content ?? this.content,
      intent: intent ?? this.intent,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sessionId.present) {
      map['session_id'] = Variable<int>(sessionId.value);
    }
    if (callId.present) {
      map['call_id'] = Variable<String>(callId.value);
    }
    if (toolName.present) {
      map['tool_name'] = Variable<String>(toolName.value);
    }
    if (byteSize.present) {
      map['byte_size'] = Variable<int>(byteSize.value);
    }
    if (lineCount.present) {
      map['line_count'] = Variable<int>(lineCount.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (intent.present) {
      map['intent'] = Variable<String>(intent.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OffloadedContentCompanion(')
          ..write('sessionId: $sessionId, ')
          ..write('callId: $callId, ')
          ..write('toolName: $toolName, ')
          ..write('byteSize: $byteSize, ')
          ..write('lineCount: $lineCount, ')
          ..write('content: $content, ')
          ..write('intent: $intent, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$CruxDatabase extends GeneratedDatabase {
  _$CruxDatabase(QueryExecutor e) : super(e);
  $CruxDatabaseManager get managers => $CruxDatabaseManager(this);
  late final $SessionsTable sessions = $SessionsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $PartsTable parts = $PartsTable(this);
  late final $FileReadStateTable fileReadState = $FileReadStateTable(this);
  late final $OffloadedContentTable offloadedContent = $OffloadedContentTable(
    this,
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    sessions,
    messages,
    parts,
    fileReadState,
    offloadedContent,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'sessions',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('messages', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'messages',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('parts', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'sessions',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('parts', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'sessions',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('file_read_state', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'sessions',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('offloaded_content', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$SessionsTableCreateCompanionBuilder =
    SessionsCompanion Function({
      Value<int> id,
      Value<String> slug,
      Value<String> title,
      Value<String> model,
      required SessionStatus status,
      Value<String> agent,
      Value<int?> parentId,
      Value<String> projectPath,
      Value<double> cost,
      Value<int> tokensIn,
      Value<int> tokensOut,
      Value<int> contextTokens,
      Value<double> ttftMs,
      Value<double> tokPerSec,
      Value<int> promptCacheHitTokens,
      Value<String> thinkingMode,
      Value<String?> reasoningEffort,
      required int createdAt,
      required int updatedAt,
      Value<int?> archivedAt,
    });
typedef $$SessionsTableUpdateCompanionBuilder =
    SessionsCompanion Function({
      Value<int> id,
      Value<String> slug,
      Value<String> title,
      Value<String> model,
      Value<SessionStatus> status,
      Value<String> agent,
      Value<int?> parentId,
      Value<String> projectPath,
      Value<double> cost,
      Value<int> tokensIn,
      Value<int> tokensOut,
      Value<int> contextTokens,
      Value<double> ttftMs,
      Value<double> tokPerSec,
      Value<int> promptCacheHitTokens,
      Value<String> thinkingMode,
      Value<String?> reasoningEffort,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int?> archivedAt,
    });

final class $$SessionsTableReferences
    extends BaseReferences<_$CruxDatabase, $SessionsTable, Session> {
  $$SessionsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$MessagesTable, List<Message>> _messagesRefsTable(
    _$CruxDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.messages,
    aliasName: $_aliasNameGenerator(db.sessions.id, db.messages.sessionId),
  );

  $$MessagesTableProcessedTableManager get messagesRefs {
    final manager = $$MessagesTableTableManager(
      $_db,
      $_db.messages,
    ).filter((f) => f.sessionId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$PartsTable, List<Part>> _partsRefsTable(
    _$CruxDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.parts,
    aliasName: $_aliasNameGenerator(db.sessions.id, db.parts.sessionId),
  );

  $$PartsTableProcessedTableManager get partsRefs {
    final manager = $$PartsTableTableManager(
      $_db,
      $_db.parts,
    ).filter((f) => f.sessionId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_partsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$FileReadStateTable, List<FileReadStateData>>
  _fileReadStateRefsTable(_$CruxDatabase db) => MultiTypedResultKey.fromTable(
    db.fileReadState,
    aliasName: $_aliasNameGenerator(db.sessions.id, db.fileReadState.sessionId),
  );

  $$FileReadStateTableProcessedTableManager get fileReadStateRefs {
    final manager = $$FileReadStateTableTableManager(
      $_db,
      $_db.fileReadState,
    ).filter((f) => f.sessionId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_fileReadStateRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$OffloadedContentTable, List<OffloadedContentData>>
  _offloadedContentRefsTable(_$CruxDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.offloadedContent,
        aliasName: $_aliasNameGenerator(
          db.sessions.id,
          db.offloadedContent.sessionId,
        ),
      );

  $$OffloadedContentTableProcessedTableManager get offloadedContentRefs {
    final manager = $$OffloadedContentTableTableManager(
      $_db,
      $_db.offloadedContent,
    ).filter((f) => f.sessionId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _offloadedContentRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SessionsTableFilterComposer
    extends Composer<_$CruxDatabase, $SessionsTable> {
  $$SessionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get slug => $composableBuilder(
    column: $table.slug,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<SessionStatus, SessionStatus, String>
  get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<String> get agent => $composableBuilder(
    column: $table.agent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get projectPath => $composableBuilder(
    column: $table.projectPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cost => $composableBuilder(
    column: $table.cost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tokensIn => $composableBuilder(
    column: $table.tokensIn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tokensOut => $composableBuilder(
    column: $table.tokensOut,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get contextTokens => $composableBuilder(
    column: $table.contextTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get ttftMs => $composableBuilder(
    column: $table.ttftMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get tokPerSec => $composableBuilder(
    column: $table.tokPerSec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get promptCacheHitTokens => $composableBuilder(
    column: $table.promptCacheHitTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thinkingMode => $composableBuilder(
    column: $table.thinkingMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reasoningEffort => $composableBuilder(
    column: $table.reasoningEffort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get archivedAt => $composableBuilder(
    column: $table.archivedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> messagesRefs(
    Expression<bool> Function($$MessagesTableFilterComposer f) f,
  ) {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.sessionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableFilterComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> partsRefs(
    Expression<bool> Function($$PartsTableFilterComposer f) f,
  ) {
    final $$PartsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.parts,
      getReferencedColumn: (t) => t.sessionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PartsTableFilterComposer(
            $db: $db,
            $table: $db.parts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> fileReadStateRefs(
    Expression<bool> Function($$FileReadStateTableFilterComposer f) f,
  ) {
    final $$FileReadStateTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.fileReadState,
      getReferencedColumn: (t) => t.sessionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FileReadStateTableFilterComposer(
            $db: $db,
            $table: $db.fileReadState,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> offloadedContentRefs(
    Expression<bool> Function($$OffloadedContentTableFilterComposer f) f,
  ) {
    final $$OffloadedContentTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.offloadedContent,
      getReferencedColumn: (t) => t.sessionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$OffloadedContentTableFilterComposer(
            $db: $db,
            $table: $db.offloadedContent,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SessionsTableOrderingComposer
    extends Composer<_$CruxDatabase, $SessionsTable> {
  $$SessionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get slug => $composableBuilder(
    column: $table.slug,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get agent => $composableBuilder(
    column: $table.agent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get parentId => $composableBuilder(
    column: $table.parentId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get projectPath => $composableBuilder(
    column: $table.projectPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cost => $composableBuilder(
    column: $table.cost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tokensIn => $composableBuilder(
    column: $table.tokensIn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tokensOut => $composableBuilder(
    column: $table.tokensOut,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get contextTokens => $composableBuilder(
    column: $table.contextTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get ttftMs => $composableBuilder(
    column: $table.ttftMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get tokPerSec => $composableBuilder(
    column: $table.tokPerSec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get promptCacheHitTokens => $composableBuilder(
    column: $table.promptCacheHitTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thinkingMode => $composableBuilder(
    column: $table.thinkingMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reasoningEffort => $composableBuilder(
    column: $table.reasoningEffort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get archivedAt => $composableBuilder(
    column: $table.archivedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SessionsTableAnnotationComposer
    extends Composer<_$CruxDatabase, $SessionsTable> {
  $$SessionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get slug =>
      $composableBuilder(column: $table.slug, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumnWithTypeConverter<SessionStatus, String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get agent =>
      $composableBuilder(column: $table.agent, builder: (column) => column);

  GeneratedColumn<int> get parentId =>
      $composableBuilder(column: $table.parentId, builder: (column) => column);

  GeneratedColumn<String> get projectPath => $composableBuilder(
    column: $table.projectPath,
    builder: (column) => column,
  );

  GeneratedColumn<double> get cost =>
      $composableBuilder(column: $table.cost, builder: (column) => column);

  GeneratedColumn<int> get tokensIn =>
      $composableBuilder(column: $table.tokensIn, builder: (column) => column);

  GeneratedColumn<int> get tokensOut =>
      $composableBuilder(column: $table.tokensOut, builder: (column) => column);

  GeneratedColumn<int> get contextTokens => $composableBuilder(
    column: $table.contextTokens,
    builder: (column) => column,
  );

  GeneratedColumn<double> get ttftMs =>
      $composableBuilder(column: $table.ttftMs, builder: (column) => column);

  GeneratedColumn<double> get tokPerSec =>
      $composableBuilder(column: $table.tokPerSec, builder: (column) => column);

  GeneratedColumn<int> get promptCacheHitTokens => $composableBuilder(
    column: $table.promptCacheHitTokens,
    builder: (column) => column,
  );

  GeneratedColumn<String> get thinkingMode => $composableBuilder(
    column: $table.thinkingMode,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reasoningEffort => $composableBuilder(
    column: $table.reasoningEffort,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get archivedAt => $composableBuilder(
    column: $table.archivedAt,
    builder: (column) => column,
  );

  Expression<T> messagesRefs<T extends Object>(
    Expression<T> Function($$MessagesTableAnnotationComposer a) f,
  ) {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.sessionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> partsRefs<T extends Object>(
    Expression<T> Function($$PartsTableAnnotationComposer a) f,
  ) {
    final $$PartsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.parts,
      getReferencedColumn: (t) => t.sessionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PartsTableAnnotationComposer(
            $db: $db,
            $table: $db.parts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> fileReadStateRefs<T extends Object>(
    Expression<T> Function($$FileReadStateTableAnnotationComposer a) f,
  ) {
    final $$FileReadStateTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.fileReadState,
      getReferencedColumn: (t) => t.sessionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FileReadStateTableAnnotationComposer(
            $db: $db,
            $table: $db.fileReadState,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> offloadedContentRefs<T extends Object>(
    Expression<T> Function($$OffloadedContentTableAnnotationComposer a) f,
  ) {
    final $$OffloadedContentTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.offloadedContent,
      getReferencedColumn: (t) => t.sessionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$OffloadedContentTableAnnotationComposer(
            $db: $db,
            $table: $db.offloadedContent,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SessionsTableTableManager
    extends
        RootTableManager<
          _$CruxDatabase,
          $SessionsTable,
          Session,
          $$SessionsTableFilterComposer,
          $$SessionsTableOrderingComposer,
          $$SessionsTableAnnotationComposer,
          $$SessionsTableCreateCompanionBuilder,
          $$SessionsTableUpdateCompanionBuilder,
          (Session, $$SessionsTableReferences),
          Session,
          PrefetchHooks Function({
            bool messagesRefs,
            bool partsRefs,
            bool fileReadStateRefs,
            bool offloadedContentRefs,
          })
        > {
  $$SessionsTableTableManager(_$CruxDatabase db, $SessionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SessionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SessionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SessionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> slug = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> model = const Value.absent(),
                Value<SessionStatus> status = const Value.absent(),
                Value<String> agent = const Value.absent(),
                Value<int?> parentId = const Value.absent(),
                Value<String> projectPath = const Value.absent(),
                Value<double> cost = const Value.absent(),
                Value<int> tokensIn = const Value.absent(),
                Value<int> tokensOut = const Value.absent(),
                Value<int> contextTokens = const Value.absent(),
                Value<double> ttftMs = const Value.absent(),
                Value<double> tokPerSec = const Value.absent(),
                Value<int> promptCacheHitTokens = const Value.absent(),
                Value<String> thinkingMode = const Value.absent(),
                Value<String?> reasoningEffort = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> archivedAt = const Value.absent(),
              }) => SessionsCompanion(
                id: id,
                slug: slug,
                title: title,
                model: model,
                status: status,
                agent: agent,
                parentId: parentId,
                projectPath: projectPath,
                cost: cost,
                tokensIn: tokensIn,
                tokensOut: tokensOut,
                contextTokens: contextTokens,
                ttftMs: ttftMs,
                tokPerSec: tokPerSec,
                promptCacheHitTokens: promptCacheHitTokens,
                thinkingMode: thinkingMode,
                reasoningEffort: reasoningEffort,
                createdAt: createdAt,
                updatedAt: updatedAt,
                archivedAt: archivedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> slug = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> model = const Value.absent(),
                required SessionStatus status,
                Value<String> agent = const Value.absent(),
                Value<int?> parentId = const Value.absent(),
                Value<String> projectPath = const Value.absent(),
                Value<double> cost = const Value.absent(),
                Value<int> tokensIn = const Value.absent(),
                Value<int> tokensOut = const Value.absent(),
                Value<int> contextTokens = const Value.absent(),
                Value<double> ttftMs = const Value.absent(),
                Value<double> tokPerSec = const Value.absent(),
                Value<int> promptCacheHitTokens = const Value.absent(),
                Value<String> thinkingMode = const Value.absent(),
                Value<String?> reasoningEffort = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int?> archivedAt = const Value.absent(),
              }) => SessionsCompanion.insert(
                id: id,
                slug: slug,
                title: title,
                model: model,
                status: status,
                agent: agent,
                parentId: parentId,
                projectPath: projectPath,
                cost: cost,
                tokensIn: tokensIn,
                tokensOut: tokensOut,
                contextTokens: contextTokens,
                ttftMs: ttftMs,
                tokPerSec: tokPerSec,
                promptCacheHitTokens: promptCacheHitTokens,
                thinkingMode: thinkingMode,
                reasoningEffort: reasoningEffort,
                createdAt: createdAt,
                updatedAt: updatedAt,
                archivedAt: archivedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SessionsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                messagesRefs = false,
                partsRefs = false,
                fileReadStateRefs = false,
                offloadedContentRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (messagesRefs) db.messages,
                    if (partsRefs) db.parts,
                    if (fileReadStateRefs) db.fileReadState,
                    if (offloadedContentRefs) db.offloadedContent,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (messagesRefs)
                        await $_getPrefetchedData<
                          Session,
                          $SessionsTable,
                          Message
                        >(
                          currentTable: table,
                          referencedTable: $$SessionsTableReferences
                              ._messagesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SessionsTableReferences(
                                db,
                                table,
                                p0,
                              ).messagesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.sessionId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (partsRefs)
                        await $_getPrefetchedData<
                          Session,
                          $SessionsTable,
                          Part
                        >(
                          currentTable: table,
                          referencedTable: $$SessionsTableReferences
                              ._partsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SessionsTableReferences(
                                db,
                                table,
                                p0,
                              ).partsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.sessionId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (fileReadStateRefs)
                        await $_getPrefetchedData<
                          Session,
                          $SessionsTable,
                          FileReadStateData
                        >(
                          currentTable: table,
                          referencedTable: $$SessionsTableReferences
                              ._fileReadStateRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SessionsTableReferences(
                                db,
                                table,
                                p0,
                              ).fileReadStateRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.sessionId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (offloadedContentRefs)
                        await $_getPrefetchedData<
                          Session,
                          $SessionsTable,
                          OffloadedContentData
                        >(
                          currentTable: table,
                          referencedTable: $$SessionsTableReferences
                              ._offloadedContentRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SessionsTableReferences(
                                db,
                                table,
                                p0,
                              ).offloadedContentRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.sessionId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$SessionsTableProcessedTableManager =
    ProcessedTableManager<
      _$CruxDatabase,
      $SessionsTable,
      Session,
      $$SessionsTableFilterComposer,
      $$SessionsTableOrderingComposer,
      $$SessionsTableAnnotationComposer,
      $$SessionsTableCreateCompanionBuilder,
      $$SessionsTableUpdateCompanionBuilder,
      (Session, $$SessionsTableReferences),
      Session,
      PrefetchHooks Function({
        bool messagesRefs,
        bool partsRefs,
        bool fileReadStateRefs,
        bool offloadedContentRefs,
      })
    >;
typedef $$MessagesTableCreateCompanionBuilder =
    MessagesCompanion Function({
      Value<int> id,
      required int sessionId,
      required String role,
      Value<String> content,
      Value<String> reasoningContent,
      Value<String> reasoningSignature,
      Value<int> reasoningTokens,
      Value<int> thinkingDurationMs,
      Value<String?> reasoningEffort,
      Value<String> model,
      Value<double> cost,
      Value<int> tokensIn,
      Value<int> tokensOut,
      Value<String> toolCalls,
      Value<String> toolCallId,
      Value<String> tldr,
      Value<String?> error,
      Value<int?> parentMsgId,
      Value<int?> preCompressTokens,
      required int createdAt,
    });
typedef $$MessagesTableUpdateCompanionBuilder =
    MessagesCompanion Function({
      Value<int> id,
      Value<int> sessionId,
      Value<String> role,
      Value<String> content,
      Value<String> reasoningContent,
      Value<String> reasoningSignature,
      Value<int> reasoningTokens,
      Value<int> thinkingDurationMs,
      Value<String?> reasoningEffort,
      Value<String> model,
      Value<double> cost,
      Value<int> tokensIn,
      Value<int> tokensOut,
      Value<String> toolCalls,
      Value<String> toolCallId,
      Value<String> tldr,
      Value<String?> error,
      Value<int?> parentMsgId,
      Value<int?> preCompressTokens,
      Value<int> createdAt,
    });

final class $$MessagesTableReferences
    extends BaseReferences<_$CruxDatabase, $MessagesTable, Message> {
  $$MessagesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SessionsTable _sessionIdTable(_$CruxDatabase db) => db.sessions
      .createAlias($_aliasNameGenerator(db.messages.sessionId, db.sessions.id));

  $$SessionsTableProcessedTableManager get sessionId {
    final $_column = $_itemColumn<int>('session_id')!;

    final manager = $$SessionsTableTableManager(
      $_db,
      $_db.sessions,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_sessionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$PartsTable, List<Part>> _partsRefsTable(
    _$CruxDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.parts,
    aliasName: $_aliasNameGenerator(db.messages.id, db.parts.messageId),
  );

  $$PartsTableProcessedTableManager get partsRefs {
    final manager = $$PartsTableTableManager(
      $_db,
      $_db.parts,
    ).filter((f) => f.messageId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_partsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$MessagesTableFilterComposer
    extends Composer<_$CruxDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reasoningContent => $composableBuilder(
    column: $table.reasoningContent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reasoningSignature => $composableBuilder(
    column: $table.reasoningSignature,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reasoningTokens => $composableBuilder(
    column: $table.reasoningTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get thinkingDurationMs => $composableBuilder(
    column: $table.thinkingDurationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get reasoningEffort => $composableBuilder(
    column: $table.reasoningEffort,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get cost => $composableBuilder(
    column: $table.cost,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tokensIn => $composableBuilder(
    column: $table.tokensIn,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tokensOut => $composableBuilder(
    column: $table.tokensOut,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolCalls => $composableBuilder(
    column: $table.toolCalls,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolCallId => $composableBuilder(
    column: $table.toolCallId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tldr => $composableBuilder(
    column: $table.tldr,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get parentMsgId => $composableBuilder(
    column: $table.parentMsgId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get preCompressTokens => $composableBuilder(
    column: $table.preCompressTokens,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$SessionsTableFilterComposer get sessionId {
    final $$SessionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableFilterComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> partsRefs(
    Expression<bool> Function($$PartsTableFilterComposer f) f,
  ) {
    final $$PartsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.parts,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PartsTableFilterComposer(
            $db: $db,
            $table: $db.parts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MessagesTableOrderingComposer
    extends Composer<_$CruxDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reasoningContent => $composableBuilder(
    column: $table.reasoningContent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reasoningSignature => $composableBuilder(
    column: $table.reasoningSignature,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reasoningTokens => $composableBuilder(
    column: $table.reasoningTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get thinkingDurationMs => $composableBuilder(
    column: $table.thinkingDurationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get reasoningEffort => $composableBuilder(
    column: $table.reasoningEffort,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get model => $composableBuilder(
    column: $table.model,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get cost => $composableBuilder(
    column: $table.cost,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tokensIn => $composableBuilder(
    column: $table.tokensIn,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tokensOut => $composableBuilder(
    column: $table.tokensOut,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolCalls => $composableBuilder(
    column: $table.toolCalls,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolCallId => $composableBuilder(
    column: $table.toolCallId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tldr => $composableBuilder(
    column: $table.tldr,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get parentMsgId => $composableBuilder(
    column: $table.parentMsgId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get preCompressTokens => $composableBuilder(
    column: $table.preCompressTokens,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$SessionsTableOrderingComposer get sessionId {
    final $$SessionsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableOrderingComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$CruxDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get reasoningContent => $composableBuilder(
    column: $table.reasoningContent,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reasoningSignature => $composableBuilder(
    column: $table.reasoningSignature,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reasoningTokens => $composableBuilder(
    column: $table.reasoningTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get thinkingDurationMs => $composableBuilder(
    column: $table.thinkingDurationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get reasoningEffort => $composableBuilder(
    column: $table.reasoningEffort,
    builder: (column) => column,
  );

  GeneratedColumn<String> get model =>
      $composableBuilder(column: $table.model, builder: (column) => column);

  GeneratedColumn<double> get cost =>
      $composableBuilder(column: $table.cost, builder: (column) => column);

  GeneratedColumn<int> get tokensIn =>
      $composableBuilder(column: $table.tokensIn, builder: (column) => column);

  GeneratedColumn<int> get tokensOut =>
      $composableBuilder(column: $table.tokensOut, builder: (column) => column);

  GeneratedColumn<String> get toolCalls =>
      $composableBuilder(column: $table.toolCalls, builder: (column) => column);

  GeneratedColumn<String> get toolCallId => $composableBuilder(
    column: $table.toolCallId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tldr =>
      $composableBuilder(column: $table.tldr, builder: (column) => column);

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);

  GeneratedColumn<int> get parentMsgId => $composableBuilder(
    column: $table.parentMsgId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get preCompressTokens => $composableBuilder(
    column: $table.preCompressTokens,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$SessionsTableAnnotationComposer get sessionId {
    final $$SessionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableAnnotationComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> partsRefs<T extends Object>(
    Expression<T> Function($$PartsTableAnnotationComposer a) f,
  ) {
    final $$PartsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.parts,
      getReferencedColumn: (t) => t.messageId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PartsTableAnnotationComposer(
            $db: $db,
            $table: $db.parts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MessagesTableTableManager
    extends
        RootTableManager<
          _$CruxDatabase,
          $MessagesTable,
          Message,
          $$MessagesTableFilterComposer,
          $$MessagesTableOrderingComposer,
          $$MessagesTableAnnotationComposer,
          $$MessagesTableCreateCompanionBuilder,
          $$MessagesTableUpdateCompanionBuilder,
          (Message, $$MessagesTableReferences),
          Message,
          PrefetchHooks Function({bool sessionId, bool partsRefs})
        > {
  $$MessagesTableTableManager(_$CruxDatabase db, $MessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> sessionId = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<String> reasoningContent = const Value.absent(),
                Value<String> reasoningSignature = const Value.absent(),
                Value<int> reasoningTokens = const Value.absent(),
                Value<int> thinkingDurationMs = const Value.absent(),
                Value<String?> reasoningEffort = const Value.absent(),
                Value<String> model = const Value.absent(),
                Value<double> cost = const Value.absent(),
                Value<int> tokensIn = const Value.absent(),
                Value<int> tokensOut = const Value.absent(),
                Value<String> toolCalls = const Value.absent(),
                Value<String> toolCallId = const Value.absent(),
                Value<String> tldr = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<int?> parentMsgId = const Value.absent(),
                Value<int?> preCompressTokens = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
              }) => MessagesCompanion(
                id: id,
                sessionId: sessionId,
                role: role,
                content: content,
                reasoningContent: reasoningContent,
                reasoningSignature: reasoningSignature,
                reasoningTokens: reasoningTokens,
                thinkingDurationMs: thinkingDurationMs,
                reasoningEffort: reasoningEffort,
                model: model,
                cost: cost,
                tokensIn: tokensIn,
                tokensOut: tokensOut,
                toolCalls: toolCalls,
                toolCallId: toolCallId,
                tldr: tldr,
                error: error,
                parentMsgId: parentMsgId,
                preCompressTokens: preCompressTokens,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int sessionId,
                required String role,
                Value<String> content = const Value.absent(),
                Value<String> reasoningContent = const Value.absent(),
                Value<String> reasoningSignature = const Value.absent(),
                Value<int> reasoningTokens = const Value.absent(),
                Value<int> thinkingDurationMs = const Value.absent(),
                Value<String?> reasoningEffort = const Value.absent(),
                Value<String> model = const Value.absent(),
                Value<double> cost = const Value.absent(),
                Value<int> tokensIn = const Value.absent(),
                Value<int> tokensOut = const Value.absent(),
                Value<String> toolCalls = const Value.absent(),
                Value<String> toolCallId = const Value.absent(),
                Value<String> tldr = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<int?> parentMsgId = const Value.absent(),
                Value<int?> preCompressTokens = const Value.absent(),
                required int createdAt,
              }) => MessagesCompanion.insert(
                id: id,
                sessionId: sessionId,
                role: role,
                content: content,
                reasoningContent: reasoningContent,
                reasoningSignature: reasoningSignature,
                reasoningTokens: reasoningTokens,
                thinkingDurationMs: thinkingDurationMs,
                reasoningEffort: reasoningEffort,
                model: model,
                cost: cost,
                tokensIn: tokensIn,
                tokensOut: tokensOut,
                toolCalls: toolCalls,
                toolCallId: toolCallId,
                tldr: tldr,
                error: error,
                parentMsgId: parentMsgId,
                preCompressTokens: preCompressTokens,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$MessagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({sessionId = false, partsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (partsRefs) db.parts],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (sessionId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.sessionId,
                                referencedTable: $$MessagesTableReferences
                                    ._sessionIdTable(db),
                                referencedColumn: $$MessagesTableReferences
                                    ._sessionIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (partsRefs)
                    await $_getPrefetchedData<Message, $MessagesTable, Part>(
                      currentTable: table,
                      referencedTable: $$MessagesTableReferences
                          ._partsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$MessagesTableReferences(db, table, p0).partsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.messageId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$MessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$CruxDatabase,
      $MessagesTable,
      Message,
      $$MessagesTableFilterComposer,
      $$MessagesTableOrderingComposer,
      $$MessagesTableAnnotationComposer,
      $$MessagesTableCreateCompanionBuilder,
      $$MessagesTableUpdateCompanionBuilder,
      (Message, $$MessagesTableReferences),
      Message,
      PrefetchHooks Function({bool sessionId, bool partsRefs})
    >;
typedef $$PartsTableCreateCompanionBuilder =
    PartsCompanion Function({
      Value<int> id,
      required int messageId,
      required int sessionId,
      required String type,
      Value<String> data,
      required int createdAt,
    });
typedef $$PartsTableUpdateCompanionBuilder =
    PartsCompanion Function({
      Value<int> id,
      Value<int> messageId,
      Value<int> sessionId,
      Value<String> type,
      Value<String> data,
      Value<int> createdAt,
    });

final class $$PartsTableReferences
    extends BaseReferences<_$CruxDatabase, $PartsTable, Part> {
  $$PartsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MessagesTable _messageIdTable(_$CruxDatabase db) => db.messages
      .createAlias($_aliasNameGenerator(db.parts.messageId, db.messages.id));

  $$MessagesTableProcessedTableManager get messageId {
    final $_column = $_itemColumn<int>('message_id')!;

    final manager = $$MessagesTableTableManager(
      $_db,
      $_db.messages,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $SessionsTable _sessionIdTable(_$CruxDatabase db) => db.sessions
      .createAlias($_aliasNameGenerator(db.parts.sessionId, db.sessions.id));

  $$SessionsTableProcessedTableManager get sessionId {
    final $_column = $_itemColumn<int>('session_id')!;

    final manager = $$SessionsTableTableManager(
      $_db,
      $_db.sessions,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_sessionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PartsTableFilterComposer extends Composer<_$CruxDatabase, $PartsTable> {
  $$PartsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$MessagesTableFilterComposer get messageId {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableFilterComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SessionsTableFilterComposer get sessionId {
    final $$SessionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableFilterComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PartsTableOrderingComposer
    extends Composer<_$CruxDatabase, $PartsTable> {
  $$PartsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$MessagesTableOrderingComposer get messageId {
    final $$MessagesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableOrderingComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SessionsTableOrderingComposer get sessionId {
    final $$SessionsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableOrderingComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PartsTableAnnotationComposer
    extends Composer<_$CruxDatabase, $PartsTable> {
  $$PartsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$MessagesTableAnnotationComposer get messageId {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SessionsTableAnnotationComposer get sessionId {
    final $$SessionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableAnnotationComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PartsTableTableManager
    extends
        RootTableManager<
          _$CruxDatabase,
          $PartsTable,
          Part,
          $$PartsTableFilterComposer,
          $$PartsTableOrderingComposer,
          $$PartsTableAnnotationComposer,
          $$PartsTableCreateCompanionBuilder,
          $$PartsTableUpdateCompanionBuilder,
          (Part, $$PartsTableReferences),
          Part,
          PrefetchHooks Function({bool messageId, bool sessionId})
        > {
  $$PartsTableTableManager(_$CruxDatabase db, $PartsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PartsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PartsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PartsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<int> messageId = const Value.absent(),
                Value<int> sessionId = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> data = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
              }) => PartsCompanion(
                id: id,
                messageId: messageId,
                sessionId: sessionId,
                type: type,
                data: data,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required int messageId,
                required int sessionId,
                required String type,
                Value<String> data = const Value.absent(),
                required int createdAt,
              }) => PartsCompanion.insert(
                id: id,
                messageId: messageId,
                sessionId: sessionId,
                type: type,
                data: data,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$PartsTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback: ({messageId = false, sessionId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (messageId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.messageId,
                                referencedTable: $$PartsTableReferences
                                    ._messageIdTable(db),
                                referencedColumn: $$PartsTableReferences
                                    ._messageIdTable(db)
                                    .id,
                              )
                              as T;
                    }
                    if (sessionId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.sessionId,
                                referencedTable: $$PartsTableReferences
                                    ._sessionIdTable(db),
                                referencedColumn: $$PartsTableReferences
                                    ._sessionIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$PartsTableProcessedTableManager =
    ProcessedTableManager<
      _$CruxDatabase,
      $PartsTable,
      Part,
      $$PartsTableFilterComposer,
      $$PartsTableOrderingComposer,
      $$PartsTableAnnotationComposer,
      $$PartsTableCreateCompanionBuilder,
      $$PartsTableUpdateCompanionBuilder,
      (Part, $$PartsTableReferences),
      Part,
      PrefetchHooks Function({bool messageId, bool sessionId})
    >;
typedef $$FileReadStateTableCreateCompanionBuilder =
    FileReadStateCompanion Function({
      required int sessionId,
      required String path,
      required int mtimeMs,
      Value<int> rowid,
    });
typedef $$FileReadStateTableUpdateCompanionBuilder =
    FileReadStateCompanion Function({
      Value<int> sessionId,
      Value<String> path,
      Value<int> mtimeMs,
      Value<int> rowid,
    });

final class $$FileReadStateTableReferences
    extends
        BaseReferences<_$CruxDatabase, $FileReadStateTable, FileReadStateData> {
  $$FileReadStateTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SessionsTable _sessionIdTable(_$CruxDatabase db) =>
      db.sessions.createAlias(
        $_aliasNameGenerator(db.fileReadState.sessionId, db.sessions.id),
      );

  $$SessionsTableProcessedTableManager get sessionId {
    final $_column = $_itemColumn<int>('session_id')!;

    final manager = $$SessionsTableTableManager(
      $_db,
      $_db.sessions,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_sessionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$FileReadStateTableFilterComposer
    extends Composer<_$CruxDatabase, $FileReadStateTable> {
  $$FileReadStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mtimeMs => $composableBuilder(
    column: $table.mtimeMs,
    builder: (column) => ColumnFilters(column),
  );

  $$SessionsTableFilterComposer get sessionId {
    final $$SessionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableFilterComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FileReadStateTableOrderingComposer
    extends Composer<_$CruxDatabase, $FileReadStateTable> {
  $$FileReadStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mtimeMs => $composableBuilder(
    column: $table.mtimeMs,
    builder: (column) => ColumnOrderings(column),
  );

  $$SessionsTableOrderingComposer get sessionId {
    final $$SessionsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableOrderingComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FileReadStateTableAnnotationComposer
    extends Composer<_$CruxDatabase, $FileReadStateTable> {
  $$FileReadStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get mtimeMs =>
      $composableBuilder(column: $table.mtimeMs, builder: (column) => column);

  $$SessionsTableAnnotationComposer get sessionId {
    final $$SessionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableAnnotationComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FileReadStateTableTableManager
    extends
        RootTableManager<
          _$CruxDatabase,
          $FileReadStateTable,
          FileReadStateData,
          $$FileReadStateTableFilterComposer,
          $$FileReadStateTableOrderingComposer,
          $$FileReadStateTableAnnotationComposer,
          $$FileReadStateTableCreateCompanionBuilder,
          $$FileReadStateTableUpdateCompanionBuilder,
          (FileReadStateData, $$FileReadStateTableReferences),
          FileReadStateData,
          PrefetchHooks Function({bool sessionId})
        > {
  $$FileReadStateTableTableManager(_$CruxDatabase db, $FileReadStateTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FileReadStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FileReadStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FileReadStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> sessionId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<int> mtimeMs = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FileReadStateCompanion(
                sessionId: sessionId,
                path: path,
                mtimeMs: mtimeMs,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int sessionId,
                required String path,
                required int mtimeMs,
                Value<int> rowid = const Value.absent(),
              }) => FileReadStateCompanion.insert(
                sessionId: sessionId,
                path: path,
                mtimeMs: mtimeMs,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$FileReadStateTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({sessionId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (sessionId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.sessionId,
                                referencedTable: $$FileReadStateTableReferences
                                    ._sessionIdTable(db),
                                referencedColumn: $$FileReadStateTableReferences
                                    ._sessionIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$FileReadStateTableProcessedTableManager =
    ProcessedTableManager<
      _$CruxDatabase,
      $FileReadStateTable,
      FileReadStateData,
      $$FileReadStateTableFilterComposer,
      $$FileReadStateTableOrderingComposer,
      $$FileReadStateTableAnnotationComposer,
      $$FileReadStateTableCreateCompanionBuilder,
      $$FileReadStateTableUpdateCompanionBuilder,
      (FileReadStateData, $$FileReadStateTableReferences),
      FileReadStateData,
      PrefetchHooks Function({bool sessionId})
    >;
typedef $$OffloadedContentTableCreateCompanionBuilder =
    OffloadedContentCompanion Function({
      required int sessionId,
      required String callId,
      required String toolName,
      required int byteSize,
      required int lineCount,
      required String content,
      Value<String> intent,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$OffloadedContentTableUpdateCompanionBuilder =
    OffloadedContentCompanion Function({
      Value<int> sessionId,
      Value<String> callId,
      Value<String> toolName,
      Value<int> byteSize,
      Value<int> lineCount,
      Value<String> content,
      Value<String> intent,
      Value<int> createdAt,
      Value<int> rowid,
    });

final class $$OffloadedContentTableReferences
    extends
        BaseReferences<
          _$CruxDatabase,
          $OffloadedContentTable,
          OffloadedContentData
        > {
  $$OffloadedContentTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SessionsTable _sessionIdTable(_$CruxDatabase db) =>
      db.sessions.createAlias(
        $_aliasNameGenerator(db.offloadedContent.sessionId, db.sessions.id),
      );

  $$SessionsTableProcessedTableManager get sessionId {
    final $_column = $_itemColumn<int>('session_id')!;

    final manager = $$SessionsTableTableManager(
      $_db,
      $_db.sessions,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_sessionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$OffloadedContentTableFilterComposer
    extends Composer<_$CruxDatabase, $OffloadedContentTable> {
  $$OffloadedContentTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get callId => $composableBuilder(
    column: $table.callId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get byteSize => $composableBuilder(
    column: $table.byteSize,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lineCount => $composableBuilder(
    column: $table.lineCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get intent => $composableBuilder(
    column: $table.intent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$SessionsTableFilterComposer get sessionId {
    final $$SessionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableFilterComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$OffloadedContentTableOrderingComposer
    extends Composer<_$CruxDatabase, $OffloadedContentTable> {
  $$OffloadedContentTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get callId => $composableBuilder(
    column: $table.callId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get toolName => $composableBuilder(
    column: $table.toolName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get byteSize => $composableBuilder(
    column: $table.byteSize,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lineCount => $composableBuilder(
    column: $table.lineCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get content => $composableBuilder(
    column: $table.content,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get intent => $composableBuilder(
    column: $table.intent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$SessionsTableOrderingComposer get sessionId {
    final $$SessionsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableOrderingComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$OffloadedContentTableAnnotationComposer
    extends Composer<_$CruxDatabase, $OffloadedContentTable> {
  $$OffloadedContentTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get callId =>
      $composableBuilder(column: $table.callId, builder: (column) => column);

  GeneratedColumn<String> get toolName =>
      $composableBuilder(column: $table.toolName, builder: (column) => column);

  GeneratedColumn<int> get byteSize =>
      $composableBuilder(column: $table.byteSize, builder: (column) => column);

  GeneratedColumn<int> get lineCount =>
      $composableBuilder(column: $table.lineCount, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<String> get intent =>
      $composableBuilder(column: $table.intent, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$SessionsTableAnnotationComposer get sessionId {
    final $$SessionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sessionId,
      referencedTable: $db.sessions,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SessionsTableAnnotationComposer(
            $db: $db,
            $table: $db.sessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$OffloadedContentTableTableManager
    extends
        RootTableManager<
          _$CruxDatabase,
          $OffloadedContentTable,
          OffloadedContentData,
          $$OffloadedContentTableFilterComposer,
          $$OffloadedContentTableOrderingComposer,
          $$OffloadedContentTableAnnotationComposer,
          $$OffloadedContentTableCreateCompanionBuilder,
          $$OffloadedContentTableUpdateCompanionBuilder,
          (OffloadedContentData, $$OffloadedContentTableReferences),
          OffloadedContentData,
          PrefetchHooks Function({bool sessionId})
        > {
  $$OffloadedContentTableTableManager(
    _$CruxDatabase db,
    $OffloadedContentTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OffloadedContentTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OffloadedContentTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OffloadedContentTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> sessionId = const Value.absent(),
                Value<String> callId = const Value.absent(),
                Value<String> toolName = const Value.absent(),
                Value<int> byteSize = const Value.absent(),
                Value<int> lineCount = const Value.absent(),
                Value<String> content = const Value.absent(),
                Value<String> intent = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OffloadedContentCompanion(
                sessionId: sessionId,
                callId: callId,
                toolName: toolName,
                byteSize: byteSize,
                lineCount: lineCount,
                content: content,
                intent: intent,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int sessionId,
                required String callId,
                required String toolName,
                required int byteSize,
                required int lineCount,
                required String content,
                Value<String> intent = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => OffloadedContentCompanion.insert(
                sessionId: sessionId,
                callId: callId,
                toolName: toolName,
                byteSize: byteSize,
                lineCount: lineCount,
                content: content,
                intent: intent,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$OffloadedContentTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({sessionId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (sessionId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.sessionId,
                                referencedTable:
                                    $$OffloadedContentTableReferences
                                        ._sessionIdTable(db),
                                referencedColumn:
                                    $$OffloadedContentTableReferences
                                        ._sessionIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$OffloadedContentTableProcessedTableManager =
    ProcessedTableManager<
      _$CruxDatabase,
      $OffloadedContentTable,
      OffloadedContentData,
      $$OffloadedContentTableFilterComposer,
      $$OffloadedContentTableOrderingComposer,
      $$OffloadedContentTableAnnotationComposer,
      $$OffloadedContentTableCreateCompanionBuilder,
      $$OffloadedContentTableUpdateCompanionBuilder,
      (OffloadedContentData, $$OffloadedContentTableReferences),
      OffloadedContentData,
      PrefetchHooks Function({bool sessionId})
    >;

class $CruxDatabaseManager {
  final _$CruxDatabase _db;
  $CruxDatabaseManager(this._db);
  $$SessionsTableTableManager get sessions =>
      $$SessionsTableTableManager(_db, _db.sessions);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$PartsTableTableManager get parts =>
      $$PartsTableTableManager(_db, _db.parts);
  $$FileReadStateTableTableManager get fileReadState =>
      $$FileReadStateTableTableManager(_db, _db.fileReadState);
  $$OffloadedContentTableTableManager get offloadedContent =>
      $$OffloadedContentTableTableManager(_db, _db.offloadedContent);
}
