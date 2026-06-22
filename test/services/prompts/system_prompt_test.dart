import 'dart:io';

import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/services/prompts/system_prompt.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

ProviderConfig _provider({String? systemPromptAddition}) {
  return ProviderConfig(
    name: 'anthropic',
    type: 'anthropic_compatible',
    wireFamily: WireFamily.anthropicCompatible,
    endpointUrl: 'https://api.example.com',
    models: const [
      ModelConfig(
        id: 'claude-opus-4-6',
        name: 'Claude Opus 4.6',
        contextSize: 200000,
      ),
    ],
    systemPromptAddition: systemPromptAddition,
  );
}

void main() {
  group('buildSystemPrompt', () {
    test('always starts with the universal layer', () {
      final out = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('You are Crux'));
    });

    test('always ends with the env meta layer', () {
      final out = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('<env>'));
      expect(out, endsWith('</env>'));
      expect(out, contains('Model: claude-opus-4-6'));
    });

    test('omits the provider tuning section when nothing is defined', () {
      final out = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      // Just the universal layer + env meta, joined by a blank line.
      // No "Provider-level tuning" string anywhere.
      expect(out, isNot(contains('Provider-level tuning')));
    });

    test('includes provider-level tuning when defined', () {
      final out = buildSystemPrompt(
        provider: _provider(
          systemPromptAddition: 'Provider-level tuning.',
        ),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('Provider-level tuning.'));
    });

    test('model-level tuning overrides provider-level', () {
      final provider = _provider(
        systemPromptAddition: 'Provider-level tuning.',
      );
      final model = ModelConfig(
        id: 'claude-opus-4-6',
        name: 'Claude Opus 4.6',
        contextSize: 200000,
        systemPromptAddition: 'Model-level tuning (wins).',
      );
      final out = buildSystemPrompt(
        provider: provider,
        model: model,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('Model-level tuning (wins).'));
      expect(out, isNot(contains('Provider-level')));
    });

    test('treats empty/whitespace tuning as absent', () {
      final out = buildSystemPrompt(
        provider: _provider(systemPromptAddition: '   \n\n  '),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      // When tuning is whitespace-only it must be dropped
      // entirely, not rendered as an empty section.
      expect(out, isNot(contains('Provider-level tuning')));
      // The rendered prompt must be byte-identical to the
      // case where no tuning was configured at all — that's
      // the whole point of treating empty tuning as absent.
      final noTuning = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, equals(noTuning));
    });

    test('byte-identical render across calls (cache stability)', () {
      // The whole point of caching: re-rendering with the same
      // inputs must produce a byte-identical result. Otherwise
      // the Anthropic cache marker can't hit.
      final provider = _provider(systemPromptAddition: 'Tuning.');
      final model = provider.models.first;
      final started = DateTime.utc(2026, 1, 1);
      final first = buildSystemPrompt(
        provider: provider,
        model: model,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: started,
      );
      final second = buildSystemPrompt(
        provider: provider,
        model: model,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: started,
      );
      expect(second, equals(first));
    });

    test('changing the model changes the tuning section and the env meta '
        'model id', () {
      // When the model changes, the env meta changes too — it
      // embeds the model id, so a model swap necessarily changes
      // it. The universal layer does NOT change. The
      // session-started timestamp stays frozen at the original
      // value, so the env meta is still stable in the "not now"
      // sense.
      final provider1 = ProviderConfig(
        name: 'anthropic',
        type: 'anthropic_compatible',
        wireFamily: WireFamily.anthropicCompatible,
        endpointUrl: 'https://api.example.com',
        models: const [
          ModelConfig(
            id: 'claude-opus-4-6',
            name: 'Claude Opus 4.6',
            contextSize: 200000,
            systemPromptAddition: 'Opus-specific tuning.',
          ),
        ],
      );
      final provider2 = ProviderConfig(
        name: 'anthropic',
        type: 'anthropic_compatible',
        wireFamily: WireFamily.anthropicCompatible,
        endpointUrl: 'https://api.example.com',
        models: const [
          ModelConfig(
            id: 'claude-sonnet-4-6',
            name: 'Claude Sonnet 4.6',
            contextSize: 100000,
            systemPromptAddition: 'Sonnet-specific tuning.',
          ),
        ],
      );
      final started = DateTime.utc(2026, 1, 1);
      final opus = buildSystemPrompt(
        provider: provider1,
        model: provider1.models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: started,
      );
      final sonnet = buildSystemPrompt(
        provider: provider2,
        model: provider2.models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: started,
      );

      expect(opus, isNot(equals(sonnet)));
      // The session-started timestamp is the same in both.
      expect(opus, contains('2026-01-01'));
      expect(sonnet, contains('2026-01-01'));
      // The model ids are different in the env meta.
      expect(opus, contains('claude-opus-4-6'));
      expect(sonnet, contains('claude-sonnet-4-6'));
    });

    test('project notes appear between the universal layer and the env meta',
        () {
      final tempRoot = Directory.systemTemp.createTempSync('crux_proj_in_');
      try {
        File(p.join(tempRoot.path, 'AGENTS.md'))
            .writeAsStringSync('Project rules.');

        final out = buildSystemPrompt(
          provider: _provider(systemPromptAddition: 'Tuning.'),
          model: _provider().models.first,
          cwd: tempRoot.path,
          worktree: tempRoot.path,
          sessionStarted: DateTime.utc(2026, 1, 1),
        );

        // Universal comes first, then tuning, then project notes,
        // then env meta. We verify by substring position rather
        // than splitting — the joined string is the right
        // artifact.
        final universalIdx = out.indexOf('You are Crux');
        final tuningIdx = out.indexOf('Tuning.');
        final projectIdx = out.indexOf('Project rules.');
        final envIdx = out.indexOf('<env>');
        expect(universalIdx, lessThan(tuningIdx));
        expect(tuningIdx, lessThan(projectIdx));
        expect(projectIdx, lessThan(envIdx));
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    });
  });
}
