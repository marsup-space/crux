import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/openrouter_stealth_sync.dart';
import 'package:crux/src/i18n/strings.dart';

/// Canned `/models` catalog covering every shape the sync cares about:
/// a stealth model, an expiring free model, and a plain paid model.
const _catalogJson = '''
{
  "data": [
    {
      "id": "stealth/ox-alpha",
      "name": "Ox Alpha",
      "description": "Ox Alpha is a reasoning model for coding.",
      "context_length": 1048576,
      "architecture": {"input_modalities": ["text", "image"]},
      "pricing": {"prompt": "0", "completion": "0"},
      "top_provider": {"max_completion_tokens": 131072},
      "expiration_date": "2098-12-31",
      "reasoning": {
        "mandatory": true,
        "supported_efforts": ["max", "high", "low"],
        "default_effort": "max"
      }
    },
    {
      "id": "nvidia/nemotron-nano-9b-v2:free",
      "name": "Nemotron Nano 9B (free)",
      "description": "A small open-weight model.",
      "context_length": 128000,
      "architecture": {"input_modalities": ["text"]},
      "pricing": {"prompt": "0", "completion": "0"},
      "top_provider": {},
      "expiration_date": "2026-08-24"
    },
    {
      "id": "openai/gpt-4o",
      "name": "GPT-4o",
      "description": "Paid flagship.",
      "context_length": 128000,
      "architecture": {"input_modalities": ["text", "image"]},
      "pricing": {"prompt": "0.0000025", "completion": "0.00001"},
      "top_provider": {}
    }
  ]
}
''';

ProviderConfig _config(List<ModelConfig> models) => ProviderConfig(
  name: 'openrouter-free',
  type: 'openai_compatible',
  wireFamily: WireFamily.openaiCompatible,
  endpointUrl: 'https://openrouter.ai/api/v1',
  models: models,
);

void main() {
  final sync = OpenRouterStealthSync();
  final catalog = OpenRouterStealthSync.parseCatalogJson(_catalogJson);

  group('parseCatalogJson', () {
    test('parses all models keyed by id', () {
      expect(catalog.keys.toSet(), {
        'stealth/ox-alpha',
        'nvidia/nemotron-nano-9b-v2:free',
        'openai/gpt-4o',
      });
    });

    test('captures expiration_date when present', () {
      expect(catalog['stealth/ox-alpha']!.expirationDate, '2098-12-31');
      expect(
        catalog['nvidia/nemotron-nano-9b-v2:free']!.expirationDate,
        '2026-08-24',
      );
    });

    test('absent expiration_date parses as null', () {
      expect(catalog['openai/gpt-4o']!.expirationDate, isNull);
    });

    test('stealth detection by id prefix and description', () {
      expect(catalog['stealth/ox-alpha']!.isStealth, isTrue);
      expect(catalog['nvidia/nemotron-nano-9b-v2:free']!.isStealth, isFalse);
      expect(catalog['openai/gpt-4o']!.isStealth, isFalse);
    });
  });

  group('diff — expiry warnings', () {
    test('warns expired for a past date on any model kind', () {
      final plan = sync.diff(
        catalog: catalog,
        current: _config([
          ModelConfig(
            id: 'nvidia/nemotron-nano-9b-v2:free',
            name: 'Nemotron Nano (free)',
            contextSize: 128000,
          ),
        ]),
      );
      // 2026-08-24 is in the past relative to any real "now" after it;
      // pin via a far-future-safe check instead of wall clock:
      final w = plan.warnings
          .where((w) => w.modelId == 'nvidia/nemotron-nano-9b-v2:free')
          .toList();
      expect(w, hasLength(1));
      expect(
        w.single.kind,
        anyOf(SyncWarningKind.expired, SyncWarningKind.expiringSoon),
      );
    });

    test('far-future placeholder dates produce no warning', () {
      final plan = sync.diff(
        catalog: catalog,
        current: _config([
          ModelConfig(
            id: 'stealth/ox-alpha',
            name: 'Ox Alpha (stealth, free)',
            contextSize: 1048576,
          ),
        ]),
      );
      expect(
        plan.warnings.where((w) => w.kind != SyncWarningKind.vanished),
        isEmpty,
      );
      // Managed survivor still refreshed with expiry persisted.
      expect(plan.updated.single.expirationDate, '2098-12-31');
      expect(plan.removed, isEmpty);
    });

    test('no published expiry → no warning, field stays null', () {
      final plan = sync.diff(
        catalog: catalog,
        current: _config([
          ModelConfig(id: 'openai/gpt-4o', name: 'GPT-4o', contextSize: 128000),
        ]),
      );
      expect(plan.warnings, isEmpty);
      expect(plan.kept.single.expirationDate, isNull);
    });

    test('hand-maintained model gone upstream warns vanished, not removed', () {
      final plan = sync.diff(
        catalog: catalog,
        current: _config([
          ModelConfig(id: 'gone/model:free', name: 'Gone', contextSize: 8192),
        ]),
      );
      expect(plan.removed, isEmpty); // never auto-remove hand-maintained
      expect(
        plan.warnings.map((w) => w.kind),
        contains(SyncWarningKind.vanished),
      );
    });

    test('managed stealth gone upstream is removed without warning', () {
      final plan = sync.diff(
        catalog: catalog,
        current: _config([
          ModelConfig(
            id: 'stealth/dead-model',
            name: 'Dead stealth',
            contextSize: 8192,
          ),
        ]),
      );
      expect(plan.removed, ['stealth/dead-model']);
      expect(plan.warnings, isEmpty);
    });

    test('new upstream stealth is added; non-stealth ignored', () {
      final plan = sync.diff(catalog: catalog, current: _config([]));
      expect(plan.added.map((m) => m.id), ['stealth/ox-alpha']);
    });
  });

  group('previewLines', () {
    test('renders warnings first with i18n keys resolved', () {
      final plan = StealthSyncPlan(
        kept: [],
        updated: [],
        removed: [],
        added: [],
        warnings: [
          SyncWarning.expired('a/model', '2026-01-01'),
          SyncWarning.expiringSoon('b/model', '2026-09-01'),
          SyncWarning.vanished('c/model'),
        ],
      );
      final lines = plan.previewLines(kEnglishStrings);
      expect(lines[0], contains('EXPIRED'));
      expect(lines[0], contains('a/model'));
      expect(lines[1], contains('b/model'));
      expect(lines[1], contains('2026-09-01'));
      expect(lines[2], contains('c/model'));
    });

    test('empty plan renders no-changes line', () {
      final lines = StealthSyncPlan(
        kept: [],
        updated: [],
        removed: [],
        added: [],
      ).previewLines(kEnglishStrings);
      expect(lines, hasLength(1));
      expect(lines.single, contains('no changes'));
    });
  });

  group('write', () {
    test('preserves provider-level stream watchdog overrides', () async {
      // The shipped openrouter-free.toml tightens
      // stream_idle_timeout_ms for the flaky free tier. Sync used to
      // drop it on rewrite (it only preserved type/endpoint_url/
      // default_max_rounds), silently restoring the 120s default.
      // Pin the round-trip so a sync can't regress the watchdog.
      final dir = await Directory.systemTemp.createTemp('sync_write');
      addTearDown(() => dir.delete(recursive: true));

      final current = ProviderConfig(
        name: 'openrouter-free',
        type: 'openai_compatible',
        wireFamily: WireFamily.openaiCompatible,
        endpointUrl: 'https://openrouter.ai/api/v1',
        defaultMaxRounds: 50,
        streamIdleTimeoutMs: 45000,
        streamMaxDurationMs: 600000,
        maxRetries: 12,
        retryBaseDelayMs: 250,
        dataIdleTimeoutMs: 60000,
        models: [
          ModelConfig(
            id: 'nvidia/nemotron-nano-9b-v2:free',
            name: 'Nemotron (free)',
            contextSize: 128000,
          ),
        ],
      );
      final plan = sync.diff(catalog: catalog, current: current);
      final file = await sync.write(
        current: current,
        syncPlan: plan,
        userProvidersDir: dir.path,
      );

      final body = await file.readAsString();
      expect(body, contains('stream_idle_timeout_ms = 45000'));
      expect(body, contains('stream_max_duration_ms = 600000'));
      expect(body, contains('default_max_rounds = 50'));
      expect(body, contains('max_retries = 12'));
      expect(body, contains('retry_base_delay_ms = 250'));
      expect(body, contains('data_idle_timeout_ms = 60000'));
    });

    test('omits watchdog lines when unset', () async {
      final dir = await Directory.systemTemp.createTemp('sync_write');
      addTearDown(() => dir.delete(recursive: true));

      final current = _config([
        ModelConfig(
          id: 'nvidia/nemotron-nano-9b-v2:free',
          name: 'Nemotron (free)',
          contextSize: 128000,
        ),
      ]);
      final plan = sync.diff(catalog: catalog, current: current);
      final file = await sync.write(
        current: current,
        syncPlan: plan,
        userProvidersDir: dir.path,
      );

      final body = await file.readAsString();
      expect(body, isNot(contains('stream_idle_timeout_ms')));
      expect(body, isNot(contains('stream_max_duration_ms')));
    });
  });
}
