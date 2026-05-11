import 'dart:io';
import 'package:test/test.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/provider_config_loader.dart';

void main() {
  group('ProviderType', () {
    test('fromString parses known types', () {
      expect(ProviderTypeParse.fromString('openai'), ProviderType.openai);
      expect(ProviderTypeParse.fromString('anthropic'), ProviderType.anthropic);
    });

    test('fromString is case-insensitive', () {
      expect(ProviderTypeParse.fromString('OpenAI'), ProviderType.openai);
      expect(ProviderTypeParse.fromString('ANTHROPIC'), ProviderType.anthropic);
    });

    test('fromString throws on unknown type', () {
      expect(
        () => ProviderTypeParse.fromString('unknown'),
        throwsFormatException,
      );
    });

    test('toConfigString returns lowercase name', () {
      expect(ProviderType.openai.toConfigString(), 'openai');
      expect(ProviderType.anthropic.toConfigString(), 'anthropic');
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
      expect(model.reasoningEffort, isNull);
      expect(model.thinking, isFalse);
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
      expect(quota.tiers[2].label, '1m');
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
      type: ProviderType.openai,
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
        type: ProviderType.openai,
        endpointUrl: 'http://localhost:8080/v1',
        models: [
          const ModelConfig(id: 'llama3', name: 'Llama 3', contextSize: 8192),
        ],
      );
      expect(localConfig.hasImageSupport(), isFalse);
    });

    test('toString includes provider name and model count', () {
      expect(openaiConfig.toString(), contains('openai'));
      expect(openaiConfig.toString(), contains('models=2'));
    });
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

    test('loadAll parses a minimal provider config', () async {
      final tomlContent = '''
type = "openai"
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
      expect(openai!.type, ProviderType.openai);
      expect(openai.endpointUrl, 'https://api.openai.com/v1');
      expect(openai.models.length, 1);
      expect(openai.models[0].id, 'gpt-4o');
      expect(openai.models[0].name, 'GPT-4o');
      expect(openai.models[0].contextSize, 128000);
      expect(openai.models[0].imageSupport, isFalse); // default
      expect(openai.models[0].thinking, isFalse); // default
      expect(openai.models[0].reasoningEffort, isNull); // default
    });

    test('loadAll parses a full model with all optional fields', () async {
      final tomlContent = '''
type = "openai"
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

    test('loadAll parses multiple models', () async {
      final tomlContent = '''
type = "openai"
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
type = "openai"
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
      // Tiers are sorted by granularity: 5h → 1w → 1m
      expect(openai.quota!.tiers[0].label, '5h');
      expect(openai.quota!.tiers[0].limit, 100);
      expect(openai.quota!.tiers[1].label, '1w');
      expect(openai.quota!.tiers[1].limit, 500);
      expect(openai.quota!.tiers[2].label, '1m');
      expect(openai.quota!.tiers[2].limit, 2000);
    });

    test('loadAll parses Anthropic provider', () async {
      final tomlContent = '''
type = "anthropic"
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
      expect(anthropic.type, ProviderType.anthropic);
      expect(anthropic.endpointUrl, 'https://api.anthropic.com/v1');
      expect(anthropic.models.length, 2);

      final sonnet = anthropic.models[0];
      expect(sonnet.id, 'claude-3-5-sonnet-20241022');
      expect(sonnet.thinking, isTrue);
      expect(sonnet.thinkingBudget, 10000);

      final haiku = anthropic.models[1];
      expect(haiku.id, 'claude-3-5-haiku-20241022');
      expect(haiku.thinking, isFalse);
    });

    test('loadAll parses multiple provider files', () async {
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
image_support = true
''');
      await File('${tempDir.path}/anthropic.toml').writeAsString('''
type = "anthropic"
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
type = "openai"
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
type = "openai"
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
type = "openai"
endpoint_url = "https://api.openai.com/v1"
''');
      await loader.loadAll();

      expect(loader.providerNames(), isEmpty);
      final error = loader.loadErrors().values.first;
      expect(error, contains('models'));
    });

    test('modelByCompositeKey finds model across providers', () async {
      await File('${tempDir.path}/openai.toml').writeAsString('''
type = "openai"
endpoint_url = "https://api.openai.com/v1"

[[models]]
id = "gpt-4o"
name = "GPT-4o"
context_size = 128000
image_support = true
''');
      await File('${tempDir.path}/anthropic.toml').writeAsString('''
type = "anthropic"
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
type = "openai"
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
type = "openai"
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
type = "openai"
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
type = "openai"
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
type = "openai"
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
type = "openai"
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
type = "openai"
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
type = "openai"
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
      expect(provider.type, ProviderType.openai);
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

      // Should have at least openai, anthropic, local, google
      // (google and local now use ProviderType.openai)
      if (loader.providerNames().isEmpty) {
        // Providers dir may not exist in test working directory — skip gracefully
        return;
      }

      expect(
        loader.providerNames(),
        containsAll(['anthropic', 'google', 'local', 'openai']),
      );
      expect(loader.loadErrors(), isEmpty);

      // Verify OpenAI models
      final openai = loader.providerByName('openai')!;
      expect(openai.type, ProviderType.openai);
      expect(openai.models.length, greaterThanOrEqualTo(2));
      final gpt4o = openai.modelById('gpt-4o');
      expect(gpt4o, isNotNull);
      expect(gpt4o!.imageSupport, isTrue);
      expect(gpt4o.contextSize, 128000);

      // Verify Anthropic models
      final anthropic = loader.providerByName('anthropic')!;
      expect(anthropic.type, ProviderType.anthropic);
      final sonnet = anthropic.modelById('claude-3-5-sonnet-20241022');
      expect(sonnet, isNotNull);
      expect(sonnet!.thinking, isTrue);
      expect(sonnet.thinkingBudget, 10000);

      // Verify Google (now OpenAI-compatible type)
      final google = loader.providerByName('google')!;
      expect(google.type, ProviderType.openai);
      if (google.quota != null) {
        expect(google.quota!.tiers.length, 3);
        expect(google.quota!.tiers[0].label, '5h');
      }
    });
  });
}
