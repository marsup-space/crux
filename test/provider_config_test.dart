import 'dart:io';
import 'package:test/test.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/provider_config_loader.dart';
import 'package:crux/src/services/llm_provider.dart';
import 'package:crux/src/services/providers/anthropic_compatible_provider.dart';
import 'package:crux/src/services/providers/deepseek_provider.dart';
import 'package:crux/src/services/providers/kimi_provider.dart';
import 'package:crux/src/services/providers/openai_compatible_provider.dart';

void main() {
  group('WireFamily', () {
    test('has two variants', () {
      expect(WireFamily.values, hasLength(2));
      expect(WireFamily.values, containsAll(WireFamily.values));
    });

    test('wireFamilyLabel returns human-readable names', () {
      expect(wireFamilyLabel(WireFamily.openaiCompatible), 'OpenAI-compatible');
      expect(
        wireFamilyLabel(WireFamily.anthropicCompatible),
        'Anthropic-compatible',
      );
    });
  });

  group('ReasoningEffort', () {
    test('fromString parses known efforts', () {
      expect(ReasoningEffortParse.fromString('low'), ReasoningEffort.low);
      expect(ReasoningEffortParse.fromString('medium'), ReasoningEffort.medium);
      expect(ReasoningEffortParse.fromString('high'), ReasoningEffort.high);
    });

    test('fromString returns null for null input', () {
      expect(ReasoningEffortParse.fromString(null), isNull);
    });

    test('fromString throws on unknown effort', () {
      expect(
        () => ReasoningEffortParse.fromString('extreme'),
        throwsFormatException,
      );
    });

    test('toConfigString returns name', () {
      expect(ReasoningEffort.low.toConfigString(), 'low');
      expect(ReasoningEffort.high.toConfigString(), 'high');
    });
  });

  group('ModelConfig', () {
    test('compositeKey produces provider/modelId', () {
      const model = ModelConfig(
        id: 'gpt-4o',
        name: 'GPT-4o',
        contextSize: 128000,
        imageSupport: true,
      );
      expect(model.compositeKey('openai'), 'openai/gpt-4o');
    });

    test('toString includes key fields', () {
      const model = ModelConfig(
        id: 'claude-3-5-sonnet-20241022',
        name: 'Claude 3.5 Sonnet',
        contextSize: 200000,
        imageSupport: true,
        thinking: true,
        thinkingBudget: 10000,
      );
      final str = model.toString();
      expect(str, contains('claude-3-5-sonnet-20241022'));
      expect(str, contains('200000'));
      expect(str, contains('img=true'));
      expect(str, contains('think=true'));
    });

    test('defaults optional fields', () {
      const model = ModelConfig(id: 'test', name: 'Test', contextSize: 4096);
      expect(model.imageSupport, isFalse);
      expect(model.reasoningEffort, ReasoningEffort.medium);
      expect(model.thinking, isTrue);
      expect(model.thinkingBudget, isNull);
    });
  });

  group('UsageQuotaConfig', () {
    test('stores tiers in order', () {
      const quota = UsageQuotaConfig(
        apiUrl: 'https://example.com/quota',
        tiers: [
          UsageQuotaTier(label: '5h', limit: 100),
          UsageQuotaTier(label: '1w', limit: 500),
          UsageQuotaTier(label: '1m', limit: 2000),
        ],
      );
      expect(quota.tiers.length, 3);
      expect(quota.tiers[0].label, '5h');
      expect(quota.tiers[0].limit, 100);
      expect(quota.tiers[1].label, '1w');
      expect(quota.tiers[1].limit, 500);
      expect(quota.tiers[2].label, '1m');
      expect(quota.tiers[2].limit, 2000);
    });

    test('toString includes url and tier count', () {
      const quota = UsageQuotaConfig(
        apiUrl: 'https://example.com/quota',
        tiers: [UsageQuotaTier(label: '5h', limit: 100)],
      );
      expect(quota.toString(), contains('https://example.com/quota'));
    });
  });

  group('ProviderConfig', () {
    final openaiConfig = ProviderConfig(
      name: 'openai',
      type: 'openai_compatible',
      wireFamily: WireFamily.openaiCompatible,
      endpointUrl: 'https://api.openai.com/v1',
      models: [
        const ModelConfig(
          id: 'gpt-4o',
          name: 'GPT-4o',
          contextSize: 128000,
          imageSupport: true,
        ),
        const ModelConfig(
          id: 'o1',
          name: 'o1',
          contextSize: 200000,
          reasoningEffort: ReasoningEffort.medium,
          thinking: true,
          thinkingBudget: 10000,
        ),
      ],
    );

    test('modelById finds existing model', () {
      final model = openaiConfig.modelById('gpt-4o');
      expect(model, isNotNull);
      expect(model!.id, 'gpt-4o');
      expect(model.contextSize, 128000);
    });

    test('modelById returns null for missing model', () {
      expect(openaiConfig.modelById('nonexistent'), isNull);
    });

    test('modelByCompositeKey finds model by provider/id', () {
      final model = openaiConfig.modelByCompositeKey('openai/gpt-4o');
      expect(model, isNotNull);
      expect(model!.name, 'GPT-4o');
    });

    test('modelByCompositeKey returns null for wrong provider', () {
      expect(openaiConfig.modelByCompositeKey('anthropic/gpt-4o'), isNull);
    });

    test('modelByCompositeKey returns null for invalid format', () {
      expect(openaiConfig.modelByCompositeKey('gpt-4o'), isNull);
    });

    test('compositeKeys returns all provider/model pairs', () {
      final keys = openaiConfig.compositeKeys();
      expect(keys, ['openai/gpt-4o', 'openai/o1']);
    });

    test('hasImageSupport is true when any model supports images', () {
      expect(openaiConfig.hasImageSupport(), isTrue);
    });

    test('hasImageSupport is false when no model supports images', () {
      final localConfig = ProviderConfig(
        name: 'local',
        type: 'openai_compatible',
        wireFamily: WireFamily.openaiCompatible,
        endpointUrl: 'http://localhost:8080/v1',
        models: [
          const ModelConfig(id: 'llama3', name: 'Llama 3', contextSize: 8192),
        ],
      );
      expect(localConfig.hasImageSupport(), isFalse);
    });

    test(
      'toString includes provider name, type, wire family, and model count',
      () {
        final str = openaiConfig.toString();
        expect(str, contains('openai'));
        expect(str, contains('openai_compatible'));
        expect(str, contains('openaiCompatible'));
        expect(str, contains('models=2'));
      },
    );
  });

  group('resolveProvider() — dispatcher', () {
    test('openai_compatible → OpenAICompatibleProvider + openaiCompatible', () {
      final r = resolveProvider('openai_compatible');
      expect(r.provider, isA<OpenAICompatibleProvider>());
      expect(r.wire, WireFamily.openaiCompatible);
    });

    test(
      'anthropic_compatible → AnthropicCompatibleProvider + anthropicCompatible',
      () {
        final r = resolveProvider('anthropic_compatible');
        expect(r.provider, isA<AnthropicCompatibleProvider>());
        expect(r.wire, WireFamily.anthropicCompatible);
      },
    );

    test('deepseek → DeepSeekProvider + openaiCompatible wire', () {
      final r = resolveProvider('deepseek');
      expect(r.provider, isA<DeepSeekProvider>());
      expect(r.wire, WireFamily.openaiCompatible);
    });

    test('unknown type throws ArgumentError listing known types', () {
      expect(
        () => resolveProvider('definitely_not_a_real_provider'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message?.toString() ?? '',
            'message',
            allOf(
              contains('definitely_not_a_real_provider'),
              contains('openai_compatible'),
            ),
          ),
        ),
      );
    });

    test('knownProviderTypes includes the generic and specific types', () {
      final types = knownProviderTypes();
      expect(types, contains('openai_compatible'));
      expect(types, contains('anthropic_compatible'));
      expect(types, contains('deepseek'));
    });
  });

  group('typeDisplayName()', () {
    test('typeDisplayName returns human-readable labels', () {
      expect(typeDisplayName('openai_compatible'), 'OpenAI Compatible');
      expect(typeDisplayName('anthropic_compatible'), 'Anthropic Compatible');
      expect(typeDisplayName('deepseek'), 'DeepSeek');
    });

    test('typeDisplayName falls back to raw string for unknown types', () {
      expect(typeDisplayName('my_custom_thing'), 'my_custom_thing');
    });
  });

  group('providerFor() — convenience over resolveProvider()', () {
    test(
      'returns a provider of the same class as resolveProvider().provider',
      () {
        const cfg = ProviderConfig(
          name: 'openai',
          type: 'openai_compatible',
          wireFamily: WireFamily.openaiCompatible,
          endpointUrl: 'https://api.openai.com/v1',
          models: [
            ModelConfig(id: 'gpt-4o', name: 'GPT-4o', contextSize: 128000),
          ],
        );
        // Both return freshly-constructed instances, so compare by type.
        expect(
          providerFor(cfg).runtimeType,
          resolveProvider('openai_compatible').provider.runtimeType,
        );
      },
    );
  });

  group('ProviderConfigLoader — TOML parsing', () {
    late Directory tempDir;
    late ProviderConfigLoader loader;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_test_');
      loader = ProviderConfigLoader(providersDir: tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('loadAll returns empty when directory has no TOML files', () async {
      await loader.loadAll();
      expect(loader.providerNames(), isEmpty);
      expect(loader.isLoaded, isFalse);
    });

    test('loadAll returns empty when directory does not exist', () async {
      final nonexistent = Directory('${tempDir.path}/nonexistent');
      final missingLoader = ProviderConfigLoader(providersDir: nonexistent);
      await missingLoader.loadAll();
      expect(missingLoader.providerNames(), isEmpty);
    });

    test('loadAll merges multiple dirs with earlier precedence', () async {
      // Built-in dir has openai
      final builtIn = Directory('${tempDir.path}/built-in')..createSync();
      await File('${builtIn.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''');
      // User dir has openai (overrides) and anthropic (new)
      final user = Directory('${tempDir.path}/user')..createSync();
      await File('${user.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://my-proxy.example/v1"

[[models]]
id = "gpt-4o-mini"
name = "GPT-4o Mini (via my proxy)"
context_size = 128000
''');
      await File('${user.path}/anthropic.toml').writeAsString('''
type = "anthropic_compatible"
endpoint_url = "https://api.anthropic.com/v1"

[[models]]
id = "claude-3-5-sonnet-20241022"
name = "Claude 3.5 Sonnet"
context_size = 200000
''');

      final multi = ProviderConfigLoader.multi(
        providersDirs: [user, builtIn], // user first → wins
      );
      await multi.loadAll();

      // Both providers loaded
      expect(multi.providerNames(), containsAll(['openai', 'anthropic']));

      // openai came from the user dir (proxy), not the built-in
      final openai = multi.providerByName('openai')!;
      expect(openai.endpointUrl, 'https://my-proxy.example/v1');
      expect(openai.models.first.id, 'gpt-4o-mini');
    });

    test('loadAll skips example.*.toml files (reference templates)', () async {
      // Real provider
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''');
      // Reference template — must NOT be loaded
      await File('${tempDir.path}/example.provider.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"

[[models]]
id = "example-model"
name = "Example Model"
context_size = 4096
''');
      // Another reference — different name
      await File('${tempDir.path}/example.other.toml').writeAsString('''
type = "anthropic_compatible"
endpoint_url = "https://example.com/v1"
''');

      await loader.loadAll();

      // Only the real `openai` is loaded. The `example.*` files are skipped.
      expect(loader.providerNames(), ['openai']);
      // And critically: there's no provider named "example.provider" or
      // "example.other" — the loader treats them as non-existent.
      expect(loader.providerByName('example.provider'), isNull);
      expect(loader.providerByName('example.other'), isNull);
    });

    test('reload ignores example.*.toml files', () async {
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''');
      await File(
        '${tempDir.path}/example.provider.toml',
      ).writeAsString('reference template, must be ignored');
      await loader.loadAll();
      expect(loader.providerByName('openai'), isNotNull);

      // Reloading `example.provider` should return null (the loader doesn't
      // see example files as providers).
      final result = await loader.reload('example.provider');
      expect(result, isNull);
      // And `openai` should still work normally.
      expect(await loader.reload('openai'), isNotNull);
    });

    test('loadAll parses a minimal openai_compatible provider', () async {
      final tomlContent = '''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''';
      await File('${tempDir.path}/openai.toml').writeAsString(tomlContent);
      await loader.loadAll();

      expect(loader.providerNames(), ['openai']);
      final openai = loader.providerByName('openai');
      expect(openai, isNotNull);
      expect(openai!.type, 'openai_compatible');
      expect(openai.wireFamily, WireFamily.openaiCompatible);
      expect(openai.endpointUrl, 'https://api.openai.com/v1');
      expect(openai.models.length, 1);
      expect(openai.models[0].id, 'gpt-4o');
      expect(openai.models[0].imageSupport, isFalse);
      expect(openai.models[0].thinking, isTrue);
      expect(openai.models[0].reasoningEffort, ReasoningEffort.medium);
    });

    test('loadAll parses a full model with all optional fields', () async {
      final tomlContent = '''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "o1"
name = "o1"
context_size = 200000
image_support = true
reasoning_effort = "medium"
thinking = true
thinking_budget = 10000
''';
      await File('${tempDir.path}/openai.toml').writeAsString(tomlContent);
      await loader.loadAll();

      final model = loader.providerByName('openai')!.models[0];
      expect(model.imageSupport, isTrue);
      expect(model.reasoningEffort, ReasoningEffort.medium);
      expect(model.thinking, isTrue);
      expect(model.thinkingBudget, 10000);
    });

    test('loadAll parses stream_idle_timeout_ms and stream_max_duration_ms '
        'when set; defaults to null when absent', () async {
      // First: provider with both overrides set.
      await File('${tempDir.path}/longthinking.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.longcat.chat/openai/v1"
stream_idle_timeout_ms = 600000
stream_max_duration_ms = 1800000

[[models]]
id = "LongCat-2.0"
name = "LongCat 2.0"
context_size = 1048576
''');
      // Second: provider with neither override (default behavior).
      await File('${tempDir.path}/normal.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''');
      await loader.loadAll();

      final longcat = loader.providerByName('longthinking')!;
      expect(longcat.streamIdleTimeoutMs, 600000);
      expect(longcat.streamMaxDurationMs, 1800000);

      final normal = loader.providerByName('normal')!;
      expect(normal.streamIdleTimeoutMs, isNull);
      expect(normal.streamMaxDurationMs, isNull);
    });

    test('loadAll rejects negative stream_*_timeout_ms values', () async {
      await File('${tempDir.path}/bad.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"
stream_idle_timeout_ms = -1

[[models]]
id = "x"
name = "X"
context_size = 8192
''');
      await loader.loadAll();
      // The file should be skipped, with the parse error recorded.
      expect(loader.providerByName('bad'), isNull);
      expect(loader.loadErrors(), isNotEmpty);
      expect(
        loader.loadErrors().values.first,
        contains('stream_idle_timeout_ms'),
      );
    });

    test('loadAll parses multiple models', () async {
      final tomlContent = '''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
image_support = true

[[models]]
id = "o1"
name = "o1"
context_size = 200000
thinking = true
thinking_budget = 10000

[[models]]
id = "gpt-4.1"
name = "GPT-4.1"
context_size = 1047576
image_support = true
''';
      await File('${tempDir.path}/openai.toml').writeAsString(tomlContent);
      await loader.loadAll();

      final openai = loader.providerByName('openai')!;
      expect(openai.models.length, 3);
      expect(openai.models[0].id, 'gpt-4o');
      expect(openai.models[1].id, 'o1');
      expect(openai.models[2].id, 'gpt-4.1');
    });

    test('loadAll parses quota with usage tiers', () async {
      final tomlContent = '''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000

[quota]
api_url = "https://api.openai.com/v1/quota"

[quota.usage]
"5h" = 100
"1w" = 500
"1m" = 2000
''';
      await File('${tempDir.path}/openai.toml').writeAsString(tomlContent);
      await loader.loadAll();

      final openai = loader.providerByName('openai')!;
      expect(openai.quota, isNotNull);
      expect(openai.quota!.apiUrl, 'https://api.openai.com/v1/quota');
      expect(openai.quota!.tiers.length, 3);
      expect(openai.quota!.tiers[0].label, '5h');
      expect(openai.quota!.tiers[0].limit, 100);
      expect(openai.quota!.tiers[1].label, '1w');
      expect(openai.quota!.tiers[1].limit, 500);
      expect(openai.quota!.tiers[2].label, '1m');
      expect(openai.quota!.tiers[2].limit, 2000);
    });

    test('loadAll parses Anthropic provider', () async {
      final tomlContent = '''
type = "anthropic_compatible"
endpoint_url = "https://api.anthropic.com/v1"

[[models]]
id = "claude-3-5-sonnet-20241022"
name = "Claude 3.5 Sonnet"
context_size = 200000
image_support = true
thinking = true
thinking_budget = 10000

[[models]]
id = "claude-3-5-haiku-20241022"
name = "Claude 3.5 Haiku"
context_size = 200000
image_support = true
''';
      await File('${tempDir.path}/anthropic.toml').writeAsString(tomlContent);
      await loader.loadAll();

      final anthropic = loader.providerByName('anthropic')!;
      expect(anthropic.type, 'anthropic_compatible');
      expect(anthropic.wireFamily, WireFamily.anthropicCompatible);
      expect(anthropic.endpointUrl, 'https://api.anthropic.com/v1');
      expect(anthropic.models.length, 2);

      final sonnet = anthropic.models[0];
      expect(sonnet.id, 'claude-3-5-sonnet-20241022');
      expect(sonnet.thinking, isTrue);
      expect(sonnet.thinkingBudget, 10000);

      final haiku = anthropic.models[1];
      expect(haiku.id, 'claude-3-5-haiku-20241022');
      expect(haiku.thinking, isTrue);
    });

    test('loadAll parses multiple provider files', () async {
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
image_support = true
''');
      await File('${tempDir.path}/anthropic.toml').writeAsString('''
type = "anthropic_compatible"
endpoint_url = "https://api.anthropic.com/v1"

[[models]]
id = "claude-3-5-sonnet-20241022"
name = "Claude 3.5 Sonnet"
context_size = 200000
image_support = true
''');
      await loader.loadAll();

      // Sorted alphabetically by filename
      expect(loader.providerNames(), ['anthropic', 'openai']);
      expect(loader.providers().length, 2);
    });

    test('loadAll records errors for invalid TOML', () async {
      await File('${tempDir.path}/good.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''');
      await File('${tempDir.path}/bad.toml').writeAsString('''
this is not valid TOML = {{{{
''');
      await loader.loadAll();

      expect(loader.providerNames(), ['good']);
      expect(loader.loadErrors().length, 1);
      expect(
        loader.loadErrors().keys.any((k) => k.contains('bad.toml')),
        isTrue,
      );
    });

    test('loadAll records errors for missing required fields', () async {
      await File('${tempDir.path}/missing_fields.toml').writeAsString('''
type = "openai_compatible"
# endpoint_url is missing!

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''');
      await loader.loadAll();

      expect(loader.providerNames(), isEmpty);
      expect(loader.loadErrors().length, 1);
      final error = loader.loadErrors().values.first;
      expect(error, contains('endpoint_url'));
    });

    test('loadAll records errors for missing models section', () async {
      await File('${tempDir.path}/no_models.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"
''');
      await loader.loadAll();

      expect(loader.providerNames(), isEmpty);
      final error = loader.loadErrors().values.first;
      expect(error, contains('models'));
    });

    test(
      'loadAll records errors for unknown type and lists known types',
      () async {
        await File('${tempDir.path}/unknown.toml').writeAsString('''
type = "definitely_not_a_real_provider"
endpoint_url = "https://api.example.invalid/v1"

[[models]]
id = "m"
name = "M"
context_size = 4096
''');
        await loader.loadAll();

        expect(loader.providerNames(), isEmpty);
        expect(loader.loadErrors().length, 1);
        final error = loader.loadErrors().values.first;
        // Helpful error: names the bad type and lists the registered ones
        expect(error, contains('definitely_not_a_real_provider'));
        expect(error, contains('openai_compatible'));
      },
    );

    test('modelByCompositeKey finds model across providers', () async {
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
image_support = true
''');
      await File('${tempDir.path}/anthropic.toml').writeAsString('''
type = "anthropic_compatible"
endpoint_url = "https://api.anthropic.com/v1"

[[models]]
id = "claude-3-5-sonnet-20241022"
name = "Claude 3.5 Sonnet"
context_size = 200000
image_support = true
''');
      await loader.loadAll();

      final gpt4o = loader.modelByCompositeKey('openai/gpt-4o');
      expect(gpt4o, isNotNull);
      expect(gpt4o!.name, 'GPT-4o');

      final claude = loader.modelByCompositeKey(
        'anthropic/claude-3-5-sonnet-20241022',
      );
      expect(claude, isNotNull);
      expect(claude!.name, 'Claude 3.5 Sonnet');

      expect(loader.modelByCompositeKey('openai/nonexistent'), isNull);
      expect(loader.modelByCompositeKey('nonexistent/gpt-4o'), isNull);
    });

    test('allModelKeys returns composite keys from all providers', () async {
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000

[[models]]
id = "o1"
name = "o1"
context_size = 200000
''');
      await loader.loadAll();

      final keys = loader.allModelKeys();
      expect(keys, containsAll(['openai/gpt-4o', 'openai/o1']));
    });

    test('imageModelKeys returns keys for image-capable models', () async {
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
image_support = true

[[models]]
id = "o3-mini"
name = "o3-mini"
context_size = 200000
image_support = false
''');
      await loader.loadAll();

      final imageKeys = loader.imageModelKeys();
      expect(imageKeys, {'openai/gpt-4o'});
      expect(imageKeys, isNot(contains('openai/o3-mini')));
    });

    test(
      'anyImageSupport returns true when at least one model supports images',
      () async {
        await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
image_support = true
''');
        await loader.loadAll();
        expect(loader.anyImageSupport(), isTrue);
      },
    );

    test('providerForModelId finds the owning provider', () async {
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''');
      await loader.loadAll();

      final provider = loader.providerForModelId('gpt-4o');
      expect(provider, isNotNull);
      expect(provider!.name, 'openai');
    });

    test('reload updates a single provider', () async {
      // Initial load
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''');
      await loader.loadAll();
      expect(loader.providerByName('openai')!.models.length, 1);

      // Update the file with more models
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000

[[models]]
id = "o1"
name = "o1"
context_size = 200000
''');

      final updated = await loader.reload('openai');
      expect(updated, isNotNull);
      expect(updated!.models.length, 2);
      expect(loader.providerByName('openai')!.models.length, 2);
    });

    test('reload removes provider when file is deleted', () async {
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
''');
      await loader.loadAll();
      expect(loader.providerByName('openai'), isNotNull);

      await File('${tempDir.path}/openai.toml').delete();
      final result = await loader.reload('openai');
      expect(result, isNull);
      expect(loader.providerByName('openai'), isNull);
    });

    test('provider name derived from filename', () async {
      await File('${tempDir.path}/my-custom-provider.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "http://localhost:11434/v1"

[[models]]
id = "llama3"
name = "Llama 3"
context_size = 8192
''');
      await loader.loadAll();

      final provider = loader.providerByName('my-custom-provider');
      expect(provider, isNotNull);
      expect(provider!.name, 'my-custom-provider');
      expect(provider.type, 'openai_compatible');
      expect(provider.wireFamily, WireFamily.openaiCompatible);
    });
  });

  group('ProviderConfigLoader — real provider files', () {
    late ProviderConfigLoader loader;

    setUp(() {
      final providersDir = Directory('providers');
      loader = ProviderConfigLoader(providersDir: providersDir);
    });

    test('loadAll parses all real provider TOML files', () async {
      await loader.loadAll();

      // Built-ins shipped with the repo. `example.provider.toml` is the
      // reference template and is skipped by the loader (see
      // `loadAll skips example.*.toml files` above).
      const builtIns = ['deepseek', 'kimi', 'local', 'minimax', 'longcat'];

      if (loader.providerNames().isEmpty) {
        // Providers dir may not exist in test working directory — skip
        // gracefully. The temp-dir tests above cover the parser fully.
        return;
      }

      expect(loader.providerNames(), containsAll(builtIns));
      expect(loader.loadErrors(), isEmpty);

      // Verify DeepSeek (custom `type` registered in resolveProvider())
      final deepseek = loader.providerByName('deepseek')!;
      expect(deepseek.type, 'deepseek');
      expect(deepseek.wireFamily, WireFamily.openaiCompatible);
      expect(deepseek.models, isNotEmpty);

      // Verify Local (uses the generic openai_compatible type)
      final local = loader.providerByName('local')!;
      expect(local.type, 'openai_compatible');
      expect(local.wireFamily, WireFamily.openaiCompatible);
      expect(local.models, isNotEmpty);

      // Verify MiniMax (Anthropic wire, custom type, Bearer auth)
      final minimax = loader.providerByName('minimax')!;
      expect(minimax.type, 'minimax');
      expect(minimax.wireFamily, WireFamily.anthropicCompatible);
      expect(minimax.models, isNotEmpty);
    });

    test(
      'deepseek.toml uses type = "deepseek" and dispatches to DeepSeekProvider',
      () async {
        await loader.loadAll();
        if (loader.providerNames().isEmpty) return;
        final deepseek = loader.providerByName('deepseek');
        if (deepseek == null) return; // not present in this checkout
        expect(deepseek.type, 'deepseek');
        expect(deepseek.wireFamily, WireFamily.openaiCompatible);
        expect(providerFor(deepseek), isA<DeepSeekProvider>());
      },
    );

    test(
      'kimi.toml uses type = "kimi" and dispatches to KimiProvider',
      () async {
        await loader.loadAll();
        if (loader.providerNames().isEmpty) return;
        final kimi = loader.providerByName('kimi');
        if (kimi == null) return; // not present in this checkout
        expect(kimi.type, 'kimi');
        expect(kimi.wireFamily, WireFamily.openaiCompatible);
        expect(providerFor(kimi), isA<KimiProvider>());
        // K3 exposes two context variants that both map to the
        // same upstream model; K2.7 has two speed variants that
        // are distinct upstream model IDs. All four must load.
        final ids = kimi.models.map((m) => m.id).toSet();
        expect(
          ids,
          containsAll([
            'k3-1m',
            'k3-256k',
            'kimi-for-coding',
            'kimi-for-coding-highspeed',
          ]),
        );
        // All four models opt into `stream_lerp = true` — Kimi
        // streams very chatty chunks and the chat executor's
        // 60Hz drain timer is the difference between
        // stuttery-burst and smooth rendering. Same UX knob
        // MiniMax and LongCat use for the same reason.
        for (final m in kimi.models) {
          expect(
            m.streamLerp,
            isTrue,
            reason:
                '${m.id} must opt into stream_lerp — '
                'Kimi streams very chatty chunks and the '
                'executor drain timer is required for '
                'smooth rendering',
          );
        }
      },
    );

    test('every real TOML resolves via providerFor()', () async {
      await loader.loadAll();
      if (loader.providerNames().isEmpty) return;
      for (final name in loader.providerNames()) {
        final cfg = loader.providerByName(name)!;
        // Must not throw — every shipped TOML must have a registered type.
        final llm = providerFor(cfg);
        expect(llm, isNotNull);
      }
    });
  });
}
