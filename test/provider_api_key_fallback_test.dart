// Tests for `ProviderService.getApiKey`'s base-name fallback.
//
// Regression net for the "key lost after restart" bug: a user runs
// `/provider openrouter api-key sk-or-…` (or stores `CRUX_API_KEY_OPENROUTER`
// in the environment), but the actual provider id is `openrouter-free`.
// Lookup used to build `CRUX_API_KEY_OPENROUTER-FREE`, find nothing, and the
// provider appeared keyless on every restart — even though the key was
// sitting in `auth.toml` under the short service name.
//
// The fix makes `getApiKey` strip one `-segment` at a time from the right
// (`openrouter-free` → `openrouter`) and retry both the in-memory map and
// the process environment before giving up.

import 'dart:io';

import 'package:crux/src/services/provider_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late ProviderService service;

  ProviderService freshService() => ProviderService(
    userProvidersDir: tempDir.path,
    userDataDirOverride: tempDir.path,
  );

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_apikey_fallback_');
    addTearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
    service = freshService();
  });

  group('base-name fallback', () {
    test('hyphenated provider falls back to base-name key in auth.toml',
        () async {
      // Simulate the user's real situation: key stored under the short name.
      await service.setApiKey('openrouter', 'sk-or-short-name');

      // Variant provider id must resolve to the same key.
      expect(service.getApiKey('openrouter-free'), 'sk-or-short-name');
    });

    test('exact-name key wins over base-name key', () async {
      await service.setApiKey('openrouter', 'sk-or-base');
      await service.setApiKey('openrouter-free', 'sk-or-exact');

      expect(service.getApiKey('openrouter-free'), 'sk-or-exact');
      expect(service.getApiKey('openrouter'), 'sk-or-base');
    });

    test('multi-hyphen name strips one segment at a time', () async {
      await service.setApiKey('acme', 'sk-acme');

      // `acme-coding-fast` → tries `acme-coding` → `acme`.
      expect(service.getApiKey('acme-coding-fast'), 'sk-acme');
    });

    test('non-hyphenated name is unaffected', () async {
      await service.setApiKey('mimo', 'sk-mimo');

      expect(service.getApiKey('mimo'), 'sk-mimo');
      // No fallback path — a different bare name still misses.
      expect(service.getApiKey('deepseek'), isNull);
    });

    test('fallback key survives a reload from auth.toml', () async {
      await service.setApiKey('openrouter', 'sk-or-persisted');

      // Fresh instance over the same dir — proves persistence, not just
      // in-memory state, drives the fallback.
      final reloaded = freshService();
      // `initialize()` reads auth.toml; getApiKey must fall back after it.
      await reloaded.initialize();
      expect(reloaded.getApiKey('openrouter-free'), 'sk-or-persisted');
    });

    test('falls back to environment variable under the base name', () {
      // Only meaningful when the process env actually carries the key —
      // the CI / dev shell here doesn't, so skip unless it's present.
      final envKey = Platform.environment['CRUX_API_KEY_FALLBACKTEST'];
      if (envKey == null) {
        markTestSkipped(
          'set CRUX_API_KEY_FALLBACKTEST in the environment to run',
        );
        return;
      }
      expect(service.getApiKey('fallbacktest-free'), envKey);
    });
  });

  group('auth.toml layout (persistence regression)', () {
    test('top-level settings stay out of the [apiKeys] section', () async {
      await service.setApiKey('mimo', 'sk-mimo');
      await service.setLastUsedModel('mimo/mimo-v2.5');

      final raw = await File(
        p.join(tempDir.path, 'auth.toml'),
      ).readAsString();

      // `lastUsedModel` must appear BEFORE the `[apiKeys]` header —
      // anything after that header is parsed as part of the section and
      // comes back null on load (the original "settings lost" bug).
      final apiKeysIdx = raw.indexOf('[apiKeys]');
      final lastUsedIdx = raw.indexOf('lastUsedModel');
      expect(apiKeysIdx, greaterThanOrEqualTo(0));
      expect(lastUsedIdx, greaterThanOrEqualTo(0));
      expect(lastUsedIdx, lessThan(apiKeysIdx));
    });

    test('settings written before keys are not clobbered by a later key write',
        () async {
      // Order matters: reproduce the exact sequence that ate MiMo's key —
      // a `/model` switch (writes settings) followed by an api-key write.
      await service.setApiKey('mimo', 'sk-mimo');
      await service.setLastUsedModel('deepseek/deepseek-v4-flash');
      await service.setApiKey('openrouter', 'sk-or');

      final reloaded = freshService();
      await reloaded.initialize();
      expect(reloaded.getApiKey('mimo'), 'sk-mimo');
      expect(reloaded.getApiKey('openrouter'), 'sk-or');
      expect(reloaded.lastUsedModel, 'deepseek/deepseek-v4-flash');
    });
  });
}
