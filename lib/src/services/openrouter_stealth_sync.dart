import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/provider_config.dart';

/// Syncs the `openrouter-free` provider's stealth-model entries against
/// OpenRouter's live catalog.
///
/// Why this exists: OpenRouter's stealth models (anonymous third-party
/// previews) appear, get renamed, and disappear without notice — the
/// hand-maintained `providers/openrouter-free.toml` goes stale within
/// weeks. This class fetches `GET {endpoint}/models` (a key-free,
/// stable JSON API) and reconciles the provider's `[[models]]` entries:
///
///   - **Stealth entries are managed.** A model counts as stealth when
///     its catalog `id` starts with `stealth/` OR its description
///     mentions "stealth model" (OpenRouter's own phrasing — verified
///     against the live API). Stealth entries in the TOML that no
///     longer exist upstream are removed; new upstream stealths are
///     appended; survivors get `context_size` / `image_support` /
///     `max_tokens` refreshed.
///   - **Non-stealth entries are never touched.** The hand-picked
///     `:free` workhorses (nemotron, the `openrouter/free` router)
///     stay exactly as configured.
///
/// The synced file is written to the *user* providers dir
/// (`~/.config/crux/providers/openrouter-free.toml`), which the loader
/// searches before the built-in dir — so the runtime-writable override
/// shadows the shipped default without modifying the repo. Call
/// [ProviderConfigLoader.reload] after [write] to pick the changes up
/// without a restart.
class OpenRouterStealthSync {
  OpenRouterStealthSync({HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;

  /// The provider name this syncer manages.
  static const providerName = 'openrouter-free';

  /// Fetch the live catalog and diff it against [current].
  ///
  /// [endpointUrl] is the provider's configured base URL (e.g.
  /// `https://openrouter.ai/api/v1`); `/models` is appended.
  ///
  /// Pure with respect to the filesystem — safe to call for a preview.
  Future<StealthSyncPlan> plan({
    required String endpointUrl,
    required ProviderConfig current,
  }) async {
    final catalog = await _fetchStealthModels(endpointUrl);
    final upstreamById = {for (final m in catalog) m.id: m};

    final kept = <ModelConfig>[];
    final updated = <ModelConfig>[];
    final removed = <String>[];
    final added = <_StealthModel>[];

    for (final m in current.models) {
      if (!_isStealthId(m.id)) {
        kept.add(m); // hand-picked non-stealth — untouched
        continue;
      }
      final upstream = upstreamById.remove(m.id);
      if (upstream == null) {
        removed.add(m.id);
      } else {
        updated.add(_mergeExisting(m, upstream));
      }
    }
    // Whatever is left in upstreamById is new.
    added.addAll(upstreamById.values);

    return StealthSyncPlan(
      kept: kept,
      updated: updated,
      removed: removed,
      added: added.map(_toModelConfig).toList(),
    );
  }

  /// Apply [syncPlan] to the provider's TOML in the user dir and
  /// return the file written. The caller is responsible for reloading
  /// (e.g. `ProviderService.reload()`).
  ///
  /// The whole `[[models]]` list is rewritten as: non-stealth entries
  /// (in their original order) followed by updated survivors and new
  /// additions. Provider-level fields (`type`, `endpoint_url`,
  /// `default_max_rounds`) are preserved; the file's comments are
  /// regenerated — non-stealth entries get a stable "hand-maintained"
  /// banner, stealth entries a "managed by sync" one.
  Future<File> write({
    required ProviderConfig current,
    required StealthSyncPlan syncPlan,
    required String userProvidersDir,
  }) async {
    final file = File(p.join(userProvidersDir, '$providerName.toml'));
    await file.create(recursive: true);

    final buf = StringBuffer()
      ..writeln('# OpenRouter Free provider configuration')
      ..writeln('# Filename serves as the provider name: "$providerName"')
      ..writeln('# OpenAI-compatible API: ${current.endpointUrl}')
      ..writeln('#')
      ..writeln(
        '# Zero-cost OpenRouter tier. The stealth [[models]] entries below',
      )
      ..writeln(
        '# are managed by `/provider $providerName sync` — hand edits to',
      )
      ..writeln(
        '# them are overwritten on the next sync. The non-stealth entries',
      )
      ..writeln('# (nemotron, the free router) are yours; sync never touches them.')
      ..writeln()
      ..writeln('type = "${current.type}"')
      ..writeln('endpoint_url = "${current.endpointUrl}"');
    if (current.defaultMaxRounds != null) {
      buf.writeln('default_max_rounds = ${current.defaultMaxRounds}');
    }
    buf.writeln();

    void emitModel(ModelConfig m, {String? comment}) {
      if (comment != null) buf.writeln(comment);
      buf
        ..writeln('[[models]]')
        ..writeln('id = "${m.id}"')
        ..writeln('name = "${_escape(m.name)}"')
        ..writeln('context_size = ${m.contextSize}')
        ..writeln('image_support = ${m.imageSupport}');
      if (m.thinking) {
        buf.writeln('thinking = true');
      } else {
        buf.writeln('thinking = false');
      }
      buf.writeln(
        'reasoning_effort = "${m.reasoningEffort?.name ?? 'none'}"',
      );
      if (m.maxTokens != null) buf.writeln('max_tokens = ${m.maxTokens}');
      buf.writeln('temperature = ${m.temperature}');
      if (m.reasoningLabels.isNotEmpty) {
        buf.writeln();
        buf.writeln('[models.reasoning_labels]');
        for (final e in m.reasoningLabels.entries) {
          buf.writeln('${e.key} = "${e.value}"');
        }
      }
      buf.writeln();
    }

    // Non-stealth entries first, in original order, with their
    // hand-written comments preserved from the current file where we
    // can recover them — the stock file's comments are well-known.
    for (final m in syncPlan.kept) {
      emitModel(m, comment: _commentForNonStealth(m.id));
    }
    for (final m in syncPlan.updated) {
      emitModel(m, comment: _commentForStealth(m, isNew: false));
    }
    for (final m in syncPlan.added) {
      emitModel(m, comment: _commentForStealth(m, isNew: true));
    }

    await file.writeAsString(buf.toString());
    return file;
  }

  // --- internals ---------------------------------------------------------

  /// True when a TOML-side model id is one we manage. We key on the
  /// `stealth/` prefix for entries already in the file — the synced
  /// entries are always written with upstream ids, so a prefixed id in
  /// the file means "came from a previous sync".
  bool _isStealthId(String id) => id.startsWith('stealth/');

  Future<List<_StealthModel>> _fetchStealthModels(String endpointUrl) async {
    final uri = Uri.parse('${endpointUrl.replaceAll(RegExp(r'/$'), '')}/models');
    final req = await _httpClient.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final resp = await req.close().timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw HttpException('GET $uri → ${resp.statusCode}', uri: uri);
    }
    final body = await resp.transform(utf8.decoder).join();
    final data = (jsonDecode(body) as Map<String, dynamic>)['data'] as List;

    final out = <_StealthModel>[];
    for (final raw in data) {
      final m = raw as Map<String, dynamic>;
      final id = m['id'] as String? ?? '';
      final desc = (m['description'] as String? ?? '').toLowerCase();
      final isStealth =
          id.startsWith('stealth/') || desc.contains('stealth model');
      if (!isStealth) continue;

      final pricing = m['pricing'] as Map<String, dynamic>? ?? {};
      final reasoning = m['reasoning'] as Map<String, dynamic>?;
      final arch = m['architecture'] as Map<String, dynamic>? ?? {};
      final inputs =
          (arch['input_modalities'] as List?)?.cast<String>() ?? const [];
      final top = m['top_provider'] as Map<String, dynamic>? ?? {};

      out.add(
        _StealthModel(
          id: id,
          name: m['name'] as String? ?? id,
          contextLength: (m['context_length'] as num?)?.toInt() ?? 200000,
          isFree: pricing['prompt'] == '0' && pricing['completion'] == '0',
          imageSupport: inputs.contains('image'),
          reasoningEfforts:
              (reasoning?['supported_efforts'] as List?)?.cast<String>() ??
              const [],
          reasoningMandatory: reasoning?['mandatory'] as bool? ?? false,
          defaultEffort: reasoning?['default_effort'] as String?,
          maxCompletionTokens:
              (top['max_completion_tokens'] as num?)?.toInt(),
        ),
      );
    }
    return out;
  }

  /// Merge upstream catalog facts into an existing TOML entry, keeping
  /// the user's display name and reasoning-label overrides but
  /// refreshing the fields OpenRouter owns.
  ModelConfig _mergeExisting(ModelConfig existing, _StealthModel up) {
    return ModelConfig(
      id: existing.id,
      name: existing.name,
      contextSize: up.contextLength,
      imageSupport: up.imageSupport,
      reasoningEffort: _pickEffort(up),
      thinking: up.reasoningMandatory || up.reasoningEfforts.isNotEmpty,
      maxTokens: up.maxCompletionTokens ?? existing.maxTokens,
      temperature: existing.temperature,
      reasoningLabels: existing.reasoningLabels,
    );
  }

  ModelConfig _toModelConfig(_StealthModel up) {
    return ModelConfig(
      id: up.id,
      name: '${up.name} (stealth, free)',
      contextSize: up.contextLength,
      imageSupport: up.imageSupport,
      reasoningEffort: _pickEffort(up),
      thinking: up.reasoningMandatory || up.reasoningEfforts.isNotEmpty,
      maxTokens: up.maxCompletionTokens,
      temperature: 0,
    );
  }

  /// Map OpenRouter's effort vocabulary onto Crux's
  /// [ReasoningEffort] scale, preferring the upstream default and
  /// falling back to the highest supported level. Reasoning-mandatory
  /// models with no list default to `max` (ox-alpha's shape). Returns
  /// `null` (TOML `"none"`) when the model offers no reasoning control.
  ReasoningEffort? _pickEffort(_StealthModel up) {
    String? e = up.defaultEffort;
    if (e == null || e == 'none') {
      e = up.reasoningEfforts.isEmpty ? null : up.reasoningEfforts.first;
    }
    switch (e) {
      case 'max':
      case 'xhigh':
        return ReasoningEffort.max;
      case 'high':
        return ReasoningEffort.high;
      case 'medium':
        return ReasoningEffort.medium;
      case 'low':
      case 'minimal':
        return ReasoningEffort.low;
      default:
        return up.reasoningMandatory ? ReasoningEffort.max : null;
    }
  }

  String? _commentForNonStealth(String id) {
    if (id == 'openrouter/free') {
      return '# === Free Models Router — random pick from the free pool ===\n'
          '# Hand-maintained; sync never touches this entry.';
    }
    return '# === Hand-maintained free model — sync never touches this entry ===';
  }

  String _commentForStealth(ModelConfig m, {required bool isNew}) {
    final tag = isNew ? 'added by sync' : 'updated by sync';
    final date = DateTime.now().toIso8601String().substring(0, 10);
    return '# === Stealth model ($tag $date) ===\n'
        '# Managed by `/provider $providerName sync` — hand edits overwritten.';
  }

  String _escape(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

/// The diff between the live catalog and the current config.
class StealthSyncPlan {
  StealthSyncPlan({
    required this.kept,
    required this.updated,
    required this.removed,
    required this.added,
  });

  /// Non-stealth models carried through untouched.
  final List<ModelConfig> kept;

  /// Stealth models that still exist upstream, fields refreshed.
  final List<ModelConfig> updated;

  /// Stealth model ids that vanished upstream (to be removed).
  final List<String> removed;

  /// New stealth models to append.
  final List<ModelConfig> added;

  bool get isEmpty => removed.isEmpty && added.isEmpty && !_anyFieldChanged;

  bool get _anyFieldChanged => false; // field-level diffs are silent

  /// Human-readable preview lines for the confirmation prompt.
  List<String> previewLines() {
    final lines = <String>[];
    for (final id in removed) {
      lines.add('  − remove $id (gone upstream)');
    }
    for (final m in added) {
      lines.add('  + add ${m.id} (ctx ${m.contextSize})');
    }
    for (final m in updated) {
      lines.add('  = keep ${m.id} (refreshed)');
    }
    if (lines.isEmpty) lines.add('  (no changes — already in sync)');
    return lines;
  }
}

/// A stealth-model record from OpenRouter's `/models` catalog.
class _StealthModel {
  _StealthModel({
    required this.id,
    required this.name,
    required this.contextLength,
    required this.isFree,
    required this.imageSupport,
    required this.reasoningEfforts,
    required this.reasoningMandatory,
    required this.defaultEffort,
    required this.maxCompletionTokens,
  });

  final String id;
  final String name;
  final int contextLength;
  final bool isFree;
  final bool imageSupport;
  final List<String> reasoningEfforts;
  final bool reasoningMandatory;
  final String? defaultEffort;
  final int? maxCompletionTokens;
}
