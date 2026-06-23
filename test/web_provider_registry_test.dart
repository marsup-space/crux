import 'dart:io';

import 'package:crux/src/services/providers/tinyfish_web_provider.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/services/web_service_provider.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A trivial provider that supports BOTH search and fetch, used
/// to exercise the registry's "configured" + change-event flow
/// without spinning up HTTP. Not registered as a real provider;
/// tests construct it inline.
class _CountingProvider extends WebServiceProvider {
  _CountingProvider({required this.id, this.supports = const {}});

  @override
  final String id;
  final Set<ToolCapability> supports;

  @override
  String get displayName => 'Test';

  @override
  bool get supportsSearch => supports.contains(ToolCapability.search);

  @override
  bool get supportsFetch => supports.contains(ToolCapability.fetch);

  @override
  Future<WebSearchResponse> search({
    required String query,
    String? location,
    String? language,
    int? page,
    bool includeThumbnail = false,
  }) async {
    return const WebSearchResponse(
      query: '',
      results: [],
      totalResults: 0,
      page: 0,
    );
  }

  @override
  Future<WebFetchResponse> fetch(
    List<String> urls, {
    String format = 'markdown',
    bool links = false,
    bool imageLinks = false,
    int? ttl,
    int? perUrlTimeoutMs,
  }) async {
    return const WebFetchResponse(results: [], errors: []);
  }
}

/// Marker enum so [_CountingProvider] can declare a set of
/// supported capabilities without a custom class hierarchy.
enum ToolCapability { search, fetch }

void main() {
  // Each test gets a fresh temp dir wired into the registry via
  // `userDataDirOverride` — no `Platform.environment` mutation
  // (the process env map is unmodifiable in modern Dart).
  late Directory tempDir;
  late Map<String, String> fakeEnv;
  late WebProviderRegistry Function() newRegistry;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_web_prov_');
    fakeEnv = {};
    newRegistry = () => WebProviderRegistry(
          userDataDirOverride: tempDir.path,
        );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('WebProviderRegistry', () {
    test('isAnySearchProviderConfigured is false when empty', () {
      final registry = newRegistry();
      expect(registry.isAnySearchProviderConfigured, isFalse);
      expect(registry.isAnyFetchProviderConfigured, isFalse);
      expect(registry.activeSearchProvider, isNull);
      expect(registry.activeFetchProvider, isNull);
    });

    test('setApiKey makes the provider active and isConfigured true',
        () async {
      final registry = newRegistry()
        ..register(_CountingProvider(
          id: 'test',
          supports: {ToolCapability.search},
        ));
      await registry.initialize();
      expect(registry.isAnySearchProviderConfigured, isFalse);

      await registry.setApiKey('test', 'sk-test-1234');
      expect(registry.getApiKey('test'), 'sk-test-1234');
      expect(registry.isAnySearchProviderConfigured, isTrue);
      expect(registry.activeSearchProvider?.id, 'test');
    });

    test('setApiKey fires the changes stream', () async {
      final registry = newRegistry()
        ..register(_CountingProvider(
          id: 'test',
          supports: {ToolCapability.search},
        ));
      await registry.initialize();

      final events = <int>[];
      final sub = registry.changes.listen((_) => events.add(events.length));
      await registry.setApiKey('test', 'sk-1');
      await registry.removeApiKey('test');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      // setApiKey + removeApiKey → 2 events (one per mutation).
      expect(events.length, greaterThanOrEqualTo(2));
    });

    test(
      'initialize fires the changes stream when it loads a persisted key',
      () async {
        // Regression: a previous version of `_loadFromAuthToml`
        // set the in-memory key but did NOT notify subscribers.
        // The chat panel's `_webProviderChangesSub` listener
        // therefore never re-ran `registerWebTools` on cold
        // start, leaving `websearch` permanently missing from
        // the LLM's tool list even though the key was sitting
        // in `auth.toml` the whole time.
        //
        // Pre-write `auth.toml` with a key, simulate the cold
        // start, and assert both: the key lands in memory AND
        // the changes stream fires.
        final authFile = File(p.join(tempDir.path, 'auth.toml'));
        await authFile.writeAsString('TEST_API_KEY = "sk-persisted"\n');

        final registry = newRegistry()
          ..register(_CountingProvider(
            id: 'test',
            supports: {ToolCapability.search},
          ));

        // Listen BEFORE initialize() — broadcast streams don't
        // replay, so a listener set up after the event would
        // miss it. This is exactly the order the chat panel
        // uses (synchronous `changes.listen` after
        // `unawaited(initialize())`).
        final events = <int>[];
        final sub = registry.changes.listen((_) => events.add(events.length));

        await registry.initialize();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await sub.cancel();

        expect(registry.getApiKey('test'), 'sk-persisted');
        expect(events, isNotEmpty,
            reason: 'changes stream must fire so listeners '
                're-register web tools');
        expect(registry.isAnySearchProviderConfigured, isTrue);
      },
    );

    test('removeApiKey clears the key and deactivates', () async {
      final registry = newRegistry()
        ..register(_CountingProvider(
          id: 'test',
          supports: {ToolCapability.search, ToolCapability.fetch},
        ));
      await registry.initialize();

      await registry.setApiKey('test', 'sk-abc');
      expect(registry.isAnySearchProviderConfigured, isTrue);
      expect(registry.isAnyFetchProviderConfigured, isTrue);

      await registry.removeApiKey('test');
      expect(registry.getApiKey('test'), isNull);
      expect(registry.isAnySearchProviderConfigured, isFalse);
      expect(registry.isAnyFetchProviderConfigured, isFalse);
    });

    test('persists key to auth.toml under the provider field name',
        () async {
      final registry = newRegistry()
        ..register(_CountingProvider(
          id: 'test',
          supports: {ToolCapability.search},
        ));
      await registry.initialize();

      await registry.setApiKey('test', 'sk-persisted');
      // The test provider doesn't override _keyEnvFieldName (which
      // is private), so the registry falls back to the default
      // naming convention `<ID_UPPER>_API_KEY`. The point of this
      // test is the file shows up at the expected path with the
      // expected content shape, not the exact field name (which
      // TinyFishWebProvider overrides to TINYFISH_API_KEY — see
      // the next test).
      final authFile = File(p.join(tempDir.path, 'auth.toml'));
      expect(await authFile.exists(), isTrue);
      final content = await authFile.readAsString();
      expect(content, contains('sk-persisted'));

      // A fresh registry should re-load the persisted value on
      // initialize().
      final registry2 = newRegistry()
        ..register(_CountingProvider(
          id: 'test',
          supports: {ToolCapability.search},
        ));
      await registry2.initialize();
      expect(registry2.getApiKey('test'), 'sk-persisted');
    });

    test('TinyFishWebProvider persists under TINYFISH_API_KEY', () async {
      final registry = newRegistry()..register(TinyFishWebProvider());
      await registry.initialize();

      await registry.setApiKey('tinyfish', 'sk-tiny-xyz');
      final authFile = File(p.join(tempDir.path, 'auth.toml'));
      final content = await authFile.readAsString();
      expect(content, contains('TINYFISH_API_KEY'));
      expect(content, contains('sk-tiny-xyz'));
    });

    test('setApiKey rejects empty string', () async {
      final registry = newRegistry()..register(TinyFishWebProvider());
      await registry.initialize();
      expect(
        () => registry.setApiKey('tinyfish', ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('activeSearchProvider picks first configured search provider',
        () async {
      final registry = newRegistry()
        ..register(_CountingProvider(
          id: 'first',
          supports: {ToolCapability.search},
        ))
        ..register(_CountingProvider(
          id: 'second',
          supports: {ToolCapability.search},
        ));
      await registry.initialize();
      // Configure both — active should be the first registered
      // one ("first").
      await registry.setApiKey('first', 'a');
      await registry.setApiKey('second', 'b');
      expect(registry.activeSearchProvider?.id, 'first');

      // Remove the first → active should fall back to second.
      await registry.removeApiKey('first');
      expect(registry.activeSearchProvider?.id, 'second');
    });

    test('activeFetchProvider ignores search-only providers', () async {
      final registry = newRegistry()
        ..register(_CountingProvider(
          id: 'search-only',
          supports: {ToolCapability.search},
        ))
        ..register(_CountingProvider(
          id: 'fetch-only',
          supports: {ToolCapability.fetch},
        ));
      await registry.initialize();
      await registry.setApiKey('search-only', 'a');
      await registry.setApiKey('fetch-only', 'b');
      expect(registry.activeSearchProvider?.id, 'search-only');
      expect(registry.activeFetchProvider?.id, 'fetch-only');
    });

    test('env var TINYFISH_API_KEY provides an in-memory override', () {
      // The provider reads env via an injected lookup, so we
      // don't need to mutate the real (unmodifiable) process env.
      fakeEnv['TINYFISH_API_KEY'] = 'sk-env-override';
      final provider = TinyFishWebProvider(envLookup: () => fakeEnv);
      // Without setApiKey, the provider is unconfigured (no
      // in-memory key). But the provider's own `apiKey` getter
      // falls back to the env var, which is what `isConfigured`
      // ultimately checks.
      expect(provider.isConfigured, isTrue);
      expect(provider.apiKey, 'sk-env-override');
    });
  });

  group('TinyFishWebProvider apiKey getter', () {
    test('in-memory key wins over env var', () {
      fakeEnv['TINYFISH_API_KEY'] = 'sk-env';
      final provider = TinyFishWebProvider(envLookup: () => fakeEnv)
        ..setApiKey('sk-mem');
      expect(provider.apiKey, 'sk-mem');
      provider.setApiKey(null);
      // After clearing, env var should come back into play.
      expect(provider.apiKey, 'sk-env');
    });

    test('isConfigured is false when both are absent', () {
      final provider = TinyFishWebProvider(envLookup: () => fakeEnv);
      expect(provider.isConfigured, isFalse);
    });
  });
}
