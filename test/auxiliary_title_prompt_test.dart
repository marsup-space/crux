import 'package:test/test.dart';

import 'package:crux/src/services/auxiliary_prompts.dart';

void main() {
  group('titleSystemPromptFor', () {
    test('no language keeps the match-the-user rule', () {
      final prompt = titleSystemPromptFor();
      expect(prompt, contains('same language as the user'));
      // The follow-mode instruction must NOT leak in.
      expect(prompt, isNot(contains('follow the UI language')));
    });

    test('auto mode (null language) matches the legacy prompt', () {
      // The backwards-compatible alias is the historical auto-mode
      // prompt — titleSystemPromptFor(null) must equal it.
      expect(titleSystemPromptFor(language: null), titleSystemPrompt);
    });

    test('follow mode injects the UI locale label', () {
      final prompt = titleSystemPromptFor(language: '中文');
      expect(prompt, contains('MUST write the title in 中文'));
      expect(prompt, contains('regardless of the'));
      // The match-the-user rule must be gone.
      expect(prompt, isNot(contains('same language as the user')));
    });

    test('English follow mode names English', () {
      final prompt = titleSystemPromptFor(language: 'English');
      expect(prompt, contains('MUST write the title in English'));
    });

    test('empty language falls back to match-the-user', () {
      // Defensive: an empty label (unknown locale) must not produce
      // "write the title in " — it degrades to the auto behaviour.
      final prompt = titleSystemPromptFor(language: '');
      expect(prompt, contains('same language as the user'));
    });

    test('both modes keep the topic-not-reply rule', () {
      // The meta-question rule from the historical prompt survives
      // in every mode: title by the subject, not the model's answer.
      for (final prompt in [
        titleSystemPromptFor(),
        titleSystemPromptFor(language: '中文'),
      ]) {
        expect(prompt, contains('not by the model\'s'));
        expect(prompt, contains('Output ONLY the'));
      }
    });
  });

  group('commitMessageSystemPromptFor', () {
    test('follow mode requires the configured language', () {
      final prompt = commitMessageSystemPromptFor(language: '中文');
      expect(prompt, contains('MUST write both the subject and body in 中文'));
      expect(prompt, contains('must never\n  override the required language'));
    });

    test('auto mode follows the current user request language', () {
      final prompt = commitMessageSystemPromptFor();
      expect(prompt, contains('same language as the USER REQUEST'));
      expect(prompt, isNot(contains('MUST write both')));
      expect(prompt, commitMessageSystemPrompt);
    });
  });
}
