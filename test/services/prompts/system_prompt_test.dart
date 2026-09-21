import 'dart:io';

import 'package:crux/src/i18n/app_locale.dart';
import 'package:crux/src/i18n/reply_language.dart';
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

    test('teaches the LLM the ses:// session-reference format', () {
      // The TUI parses `ses://<id>` in assistant messages as a
      // clickable link; the prompt has to mention the format or
      // the model will write bare `#NNNN` (which markdown would
      // interpret as a heading). Lock in the headline phrases so a
      // future prompt refactor can't silently drop the rule.
      final out = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('## Session references'));
      expect(out, contains('ses://<id>'));
      expect(out, contains('ses://1014'));
    });

    test('teaches the LLM the ask:// quick-reply format', () {
      // Mirrors the ses:// test above. The TUI parses `ask://…`
      // tokens as clickable buttons; if the prompt drops this
      // section, the model has no way to know the format exists
      // and will fall back to plain prose, which loses the whole
      // point of the feature.
      final out = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('## Quick reply'));
      expect(out, contains('ask://label{answer}'));
      expect(out, contains('ask://label'));
      expect(out, contains('ask://Use cache'));
    });

    test('teaches the LLM when to use structured reply formats', () {
      final out = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('## Structured replies'));
      expect(out, contains('Compare 3+ peer items'));
      expect(out, contains('compact Markdown table'));
      expect(out, contains('3+ meaningful nodes'));
      expect(out, contains('create a `surface`'));
      expect(out, contains('multi-field configuration'));
      expect(out, contains('Markdown tables for static comparisons'));
      expect(out, contains('stateDiagram-v2'));
      expect(out, contains('flowchart\nLR|TD'));
      expect(out, contains('a -> b: label'));
      expect(out, contains('Do not use `pie`'));
    });

    test('prefers prepare_commit so commit and push stay human-reviewed', () {
      final out = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('## Human-reviewed commits'));
      expect(out, contains('prefer the `prepare_commit` tool'));
      expect(out, contains('only the files that belong to the task'));
      expect(out, contains('commit title and description are user-visible'));
      expect(out, contains('same language required for your reply'));
      expect(out, contains('optional `note` argument is also user-visible'));
      expect(out, contains('Use `approval` to constrain the buttons'));
      expect(out, contains('Omit it (default `both`) to let'));
      expect(out, contains('unrelated or conflicted files'));
    });

    test('keeps shell output scoped to the next decision', () {
      final out = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('## Shell output budget'));
      expect(out, contains('cap results'));
      expect(out, contains('Prefer a summary first'));
      expect(out, contains('complete build output'));
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
        provider: _provider(systemPromptAddition: 'Provider-level tuning.'),
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

    test(
      'project notes appear between the universal layer and the env meta',
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
      },
    );

    test('available skills layer 3.5 is inserted between project notes '
        'and env meta when skills are present', () {
      final tempRoot = Directory.systemTemp.createTempSync('crux_skills_');
      try {
        // Write a real SKILL.md into .crux/skills/<name>/.
        final skillDir = Directory(
          p.join(tempRoot.path, '.crux', 'skills', 'pr-review'),
        )..createSync(recursive: true);
        File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync(
          '---\n'
          'name: pr-review\n'
          'description: Reviews pull requests for correctness, style, and risks.\n'
          '---\n'
          '# PR Review\n',
        );

        final out = buildSystemPrompt(
          provider: _provider(),
          model: _provider().models.first,
          cwd: tempRoot.path,
          worktree: tempRoot.path,
          sessionStarted: DateTime.utc(2026, 1, 1),
        );

        // The block is present.
        expect(out, contains('<available_skills>'));
        expect(out, contains('- pr-review: Reviews pull requests'));
        // And it's positioned between the universal layer and
        // the env meta — the agent sees skill names and
        // descriptions, then the env meta, never the other way
        // around.
        final skillsIdx = out.indexOf('<available_skills>');
        final envIdx = out.indexOf('<env>');
        expect(skillsIdx, greaterThan(-1));
        expect(envIdx, greaterThan(skillsIdx));
        // The block tells the LLM about the `skill` tool.
        expect(out, contains('`skill` tool'));
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    });
  });

  group('buildChatSystemPrompt', () {
    test('is minimal: identity + language, no workspace doctrine', () {
      final out = buildChatSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('Chat mode'));
      expect(out, contains('Language'));
      // None of the agent-harness / workspace framing survives.
      expect(out, isNot(contains('semantic_search')));
      expect(out, isNot(contains('Codebase exploration')));
      expect(out, isNot(contains('Tool tiers')));
      expect(out, isNot(contains('prepare_commit')));
      expect(out, isNot(contains('available_skills')));
      expect(out, isNot(contains('AGENTS.md')));
    });

    test('env meta carries no working directory (workspace-free)', () {
      final out = buildChatSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      // The whole point of Chat mode: nothing to anchor a workspace on.
      expect(out, isNot(contains('Working directory:')));
      expect(out, isNot(contains('Is directory a git repo')));
      expect(out, contains('<env>'));
      expect(out, contains('not tied to any workspace'));
    });

    test('teaches tables and diagrams for structured chat replies', () {
      final out = buildChatSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('For comparisons of 3+ peer items'));
      expect(out, contains('compact Markdown table'));
      expect(out, contains('3+\nmeaningful nodes'));
      expect(out, contains('`mermaid`'));
      expect(out, contains('`d2`'));
    });

    test('includes provider system_prompt_addition and env meta', () {
      final out = buildChatSystemPrompt(
        provider: _provider(systemPromptAddition: 'Be extra terse.'),
        model: _provider().models.first,
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(out, contains('Be extra terse.'));
      expect(out, contains('<env>'));
    });

    test('omits skills block even when skills exist on disk', () {
      final tempRoot = Directory.systemTemp.createTempSync('crux_chatprompt_');
      try {
        final skillDir = Directory(
          p.join(tempRoot.path, '.claude', 'skills', 'pr-review'),
        )..createSync(recursive: true);
        File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync(
          '---\n'
          'name: pr-review\n'
          'description: Reviews pull requests\n'
          '---\n'
          '# PR Review\n',
        );

        final out = buildChatSystemPrompt(
          provider: _provider(),
          model: _provider().models.first,
          sessionStarted: DateTime.utc(2026, 1, 1),
        );
        // Chat mode never loads workspace skills.
        expect(out, isNot(contains('<available_skills>')));
        expect(out, isNot(contains('pr-review')));
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('isStaleChatSystemPrompt flags pre-fix cached prompts', () {
      // A prompt rendered before the workspace-free env meta still has
      // a Working directory line → stale → must be rebuilt.
      expect(
        isStaleChatSystemPrompt('foo\n  Working directory: /tmp/x\nbar'),
        isTrue,
      );
      // The current template has no such line → not stale.
      final fresh = buildChatSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        sessionStarted: DateTime.utc(2026, 1, 1),
      );
      expect(isStaleChatSystemPrompt(fresh), isFalse);
      expect(
        isStaleChatSystemPrompt('Chat mode\nold diagram guidance'),
        isTrue,
      );
      // Null / empty → nothing to judge (treated as "build anyway").
      expect(isStaleChatSystemPrompt(null), isFalse);
      expect(isStaleChatSystemPrompt(''), isFalse);
    });
  });

  test('isStaleWorkspaceSystemPrompt upgrades existing workspace sessions', () {
    expect(
      isStaleWorkspaceSystemPrompt(
        'You are Crux, an interactive AI coding agent for the terminal.\n'
        '## Human-reviewed commits\n'
        'The commit title and description are user-visible\n'
        '## Shell output budget\n'
        '## Tool tiers',
      ),
      isTrue,
    );
    final fresh = buildSystemPrompt(
      provider: _provider(),
      model: _provider().models.first,
      cwd: '/tmp/x',
      worktree: '/tmp/x',
      sessionStarted: DateTime.utc(2026, 1, 1),
    );
    expect(isStaleWorkspaceSystemPrompt(fresh), isFalse);
    expect(
      isStaleWorkspaceSystemPrompt(
        'You are Crux\n'
        'The commit title and description are user-visible\n'
        '## Shell output budget\n'
        '## Structured replies',
      ),
      isFalse,
    );
    expect(isStaleWorkspaceSystemPrompt(null), isFalse);
    expect(isStaleWorkspaceSystemPrompt(''), isFalse);
  });

  group('reply-language section', () {
    test('auto mode keeps the match-user-language rule', () {
      final out = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
        replyLanguage: const ReplyLanguageSettings(
          mode: ReplyLanguageMode.auto,
          locale: AppLocale.en,
        ),
      );
      expect(out, contains("Match the user's language exactly"));
    });

    test('follow mode names the configured locale', () {
      final out = buildSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        cwd: '/tmp/x',
        worktree: '/tmp/x',
        sessionStarted: DateTime.utc(2026, 1, 1),
        replyLanguage: const ReplyLanguageSettings(
          mode: ReplyLanguageMode.follow,
          locale: AppLocale.zh,
        ),
      );
      expect(out, contains('Always reply in Chinese'));
      expect(
        out,
        contains(
          'User-visible tool arguments, including commit titles and descriptions',
        ),
      );
      expect(out, isNot(contains("Match the user's language")));
    });

    test('chat prompt follow mode names the configured locale', () {
      final out = buildChatSystemPrompt(
        provider: _provider(),
        model: _provider().models.first,
        sessionStarted: DateTime.utc(2026, 1, 1),
        replyLanguage: const ReplyLanguageSettings(
          mode: ReplyLanguageMode.follow,
          locale: AppLocale.zh,
        ),
      );
      expect(out, contains('Always reply in Chinese'));
    });
  });
}
