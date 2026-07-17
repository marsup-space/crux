import 'package:test/test.dart';
import 'package:crux/src/commands/registry.dart';
import 'package:crux/src/models/slash_command.dart';

void main() {
  group('CommandRegistry', () {
    setUp(() {
      // Each test starts with a clean state.
      CommandRegistry.instance.disableDebug();
    });

    test('starts with debug mode disabled', () {
      expect(CommandRegistry.instance.debugEnabled, isFalse);
    });

    test('enableDebug registers the debug command set', () {
      CommandRegistry.instance.enableDebug();
      expect(CommandRegistry.instance.debugEnabled, isTrue);

      final names = CommandRegistry.instance.all.map((c) => c.name).toList();
      expect(names, contains('/d-state'));
      expect(names, contains('/d-messages'));
      expect(names, contains('/d-context'));
      expect(names, contains('/d-runtime'));
      expect(names, contains('/d-providers'));
      expect(names, contains('/d-tools'));
      expect(names, contains('/d-paths'));
      expect(names, contains('/d-env'));
      expect(names, contains('/d-toast'));
    });

    test('disableDebug unregisters the debug command set', () {
      CommandRegistry.instance.enableDebug();
      CommandRegistry.instance.disableDebug();
      expect(CommandRegistry.instance.debugEnabled, isFalse);

      final names = CommandRegistry.instance.all.map((c) => c.name).toList();
      expect(names, isNot(contains('/d-state')));
      expect(names, isNot(contains('/d-tools')));
    });

    test('toggleDebug flips the flag', () {
      expect(CommandRegistry.instance.debugEnabled, isFalse);
      expect(CommandRegistry.instance.toggleDebug(), isTrue);
      expect(CommandRegistry.instance.debugEnabled, isTrue);
      expect(CommandRegistry.instance.toggleDebug(), isFalse);
      expect(CommandRegistry.instance.debugEnabled, isFalse);
    });

    test('enableDebug is idempotent', () {
      CommandRegistry.instance.enableDebug();
      final first = CommandRegistry.instance.all.length;
      CommandRegistry.instance.enableDebug();
      expect(CommandRegistry.instance.all.length, equals(first));
    });

    test('disableDebug is idempotent', () {
      CommandRegistry.instance.disableDebug();
      final first = CommandRegistry.instance.all.length;
      CommandRegistry.instance.disableDebug();
      expect(CommandRegistry.instance.all.length, equals(first));
    });

    test('notifyListeners fires on enable and disable', () {
      var calls = 0;
      void listener() {
        calls++;
      }

      CommandRegistry.instance.addListener(listener);
      try {
        CommandRegistry.instance.enableDebug();
        expect(calls, equals(1));
        CommandRegistry.instance.disableDebug();
        expect(calls, equals(2));
        // Idempotent calls should not fire.
        CommandRegistry.instance.disableDebug();
        expect(calls, equals(2));
      } finally {
        CommandRegistry.instance.removeListener(listener);
      }
    });

    test('base commands are always present', () {
      // Debug off
      final offNames = CommandRegistry.instance.all.map((c) => c.name).toList();
      expect(offNames, contains('/model'));
      expect(offNames, contains('/new'));
      expect(offNames, contains('/session'));
      expect(offNames, contains('/compact'));
      expect(offNames, contains('/help'));
      expect(offNames, contains('/theme'));
      expect(offNames, contains('/provider'));
      expect(offNames, contains('/think'));
      expect(offNames, contains('/temperature'));
      expect(offNames, contains('/auxiliary'));
      expect(offNames, contains('/tldr'));
      expect(offNames, contains('/project'));
      expect(offNames, contains('/debug'));
      expect(offNames, contains('/continue'));
      expect(offNames, contains('/retry'));
      expect(offNames, contains('/undo'));
      expect(offNames, contains('/rename'));

      // Debug on
      CommandRegistry.instance.enableDebug();
      final onNames = CommandRegistry.instance.all.map((c) => c.name).toList();
      for (final n in offNames) {
        expect(onNames, contains(n), reason: 'lost $n after enabling debug');
      }
    });

    test('removed commands stay removed when debug is off', () {
      final names = CommandRegistry.instance.all.map((c) => c.name).toList();
      expect(names, isNot(contains('/config')));
      // `/quit` is registered as a base command (not in
      // the debug set), so it stays present in both modes.
      // The check is here to make sure no future change
      // accidentally moves it into the debug list.
      expect(names, contains('/quit'));
    });
  });

  group('Aliases', () {
    setUp(() {
      CommandRegistry.instance.disableDebug();
    });

    test('/continue exposes /继续 as a Chinese alias', () {
      final cmd = findCommand('/continue');
      expect(cmd, isNotNull);
      expect(cmd!.name, equals('/continue'));
      expect(cmd.aliases, contains('/继续'));
    });

    test('/retry exposes /重试 as a Chinese alias', () {
      final cmd = findCommand('/retry');
      expect(cmd, isNotNull);
      expect(cmd!.name, equals('/retry'));
      expect(cmd.aliases, contains('/重试'));
    });

    test(
      '/rename exposes /重命名 as a Chinese alias and is available mid-stream',
      () {
        // /rename only mutates the session row, not the in-flight chat
        // stream, so it's safe to invoke while the AI is responding.
        // Mirrors the /continue and /retry alias tests.
        final cmd = findCommand('/rename');
        expect(cmd, isNotNull);
        expect(cmd!.name, equals('/rename'));
        expect(cmd.aliases, contains('/重命名'));
        expect(cmd.params, equals(['title']));
        expect(cmd.availableDuringResponse, isTrue);
      },
    );

    test('SlashCommand.allNames includes the primary name and aliases', () {
      final cmd = findCommand('/continue')!;
      expect(cmd.allNames.toList(), equals(['/continue', '/继续']));
    });

    test('findCommand resolves an alias back to the same SlashCommand', () {
      final primary = findCommand('/continue');
      final byAlias = findCommand('/继续');
      expect(byAlias, isNotNull);
      expect(byAlias, same(primary));
    });

    test('findCommand resolves /重试 back to /retry', () {
      final primary = findCommand('/retry');
      final byAlias = findCommand('/重试');
      expect(byAlias, isNotNull);
      expect(byAlias, same(primary));
    });

    test('filterCommands matches by alias prefix', () {
      // Typing /继续 should reveal the /continue command so users can
      // discover the canonical English name from the Chinese alias.
      final hits = filterCommands('/继');
      final names = hits.map((c) => c.name).toList();
      expect(names, contains('/continue'));
    });

    test(
      '/continue and /retry are not available during an active response',
      () {
        // The whole point of these commands is to act on a round that
        // has finished (or errored out). Sending them mid-stream would
        // race with the in-flight chat service call.
        final cont = findCommand('/continue');
        final retry = findCommand('/retry');
        expect(cont, isNotNull);
        expect(retry, isNotNull);
        expect(cont!.availableDuringResponse, isFalse);
        expect(retry!.availableDuringResponse, isFalse);
      },
    );
  });

  group('Top-level registry helpers', () {
    setUp(() {
      CommandRegistry.instance.disableDebug();
    });

    test('slashCommands is a non-empty unmodifiable list', () {
      expect(slashCommands, isA<List<SlashCommand>>());
      expect(slashCommands, isNotEmpty);
    });

    test('filterCommands fuzzy-matches and ranks prefix hits first', () {
      // With fuzzy matching, typing `/d` still surfaces
      // `/debug` (and the `/d-*` debug set when enabled)
      // via the prefix tier, plus lower-tier matches like
      // `/tldr` and `/model` via the subsequence tier.
      // The strongest match — `/debug` — should rank first.
      final hits = filterCommands('/d');
      final names = hits.map((c) => c.name).toList();
      expect(names, isNotEmpty);
      expect(names.first, equals('/debug'));
      // `/debug` is a prefix match, so the per-tier
      // guarantee is: every prefix-match command must
      // outrank every non-prefix match.
      final prefixMatches = names.where((n) => n.startsWith('/d')).toList();
      // With debug off, only `/debug` is a prefix match.
      expect(prefixMatches, equals(['/debug']));
    });

    test('filterCommands with empty prefix returns all', () {
      final all = filterCommands('');
      expect(all.length, equals(CommandRegistry.instance.all.length));
    });

    test('findCommand returns the exact match', () {
      final cmd = findCommand('/model');
      expect(cmd, isNotNull);
      expect(cmd!.name, equals('/model'));
    });

    test('findCommand returns null for unknown commands', () {
      expect(findCommand('/nonsense'), isNull);
    });

    test('findCommand returns null for debug commands when disabled', () {
      CommandRegistry.instance.disableDebug();
      expect(findCommand('/d-state'), isNull);
    });

    test('findCommand returns debug commands when enabled', () {
      CommandRegistry.instance.enableDebug();
      expect(findCommand('/d-state'), isNotNull);
      expect(findCommand('/d-env'), isNotNull);
      expect(findCommand('/d-toast'), isNotNull);
    });

    test(
      '/d-toast has a single message param and is available during response',
      () {
        CommandRegistry.instance.enableDebug();
        final cmd = findCommand('/d-toast');
        expect(cmd, isNotNull);
        expect(cmd!.params, equals(['message']));
        expect(cmd.availableDuringResponse, isTrue);
      },
    );

    test('/debug takes no params and is available during response', () {
      final cmd = findCommand('/debug');
      expect(cmd, isNotNull);
      expect(cmd!.params, isEmpty);
      expect(cmd.availableDuringResponse, isTrue);
    });
  });

  group('filterCommands — fuzzy matching', () {
    setUp(() {
      CommandRegistry.instance.disableDebug();
    });

    test('exact query returns the matching command first', () {
      final hits = filterCommands('/help');
      expect(hits, isNotEmpty);
      expect(hits.first.name, equals('/help'));
    });

    test('prefix query returns matching commands', () {
      // /con matches /continue as a prefix. /compact starts
      // with /com, not /con, so it should NOT appear.
      final hits = filterCommands('/con');
      final names = hits.map((c) => c.name).toList();
      expect(names, contains('/continue'));
      expect(names, isNot(contains('/compact')));
    });

    test('substring query still matches', () {
      // `tin` is a substring of `continue` and `think` but
      // not of any other command (modulo coincidence). Both
      // should appear.
      final hits = filterCommands('tin');
      final names = hits.map((c) => c.name).toList();
      expect(names, contains('/continue'));
      expect(names, contains('/think'));
    });

    test('subsequence (out-of-order chars) still matches', () {
      // `cmt` is a subsequence of `compact` (`c`...`m`...`t`)
      // and not a subseq of any other base command.
      final hits = filterCommands('cmt');
      final names = hits.map((c) => c.name).toList();
      expect(names, contains('/compact'));
    });

    test('subsequence is case-insensitive', () {
      // The candidate `/compact` lowercased is `compact`.
      // Querying with mixed case `CMT` should still match.
      final hits = filterCommands('CMT');
      final names = hits.map((c) => c.name).toList();
      expect(names, contains('/compact'));
    });

    test('exact matches outrank prefix matches in display order', () {
      // `/c` is a prefix of `/compact` and `/continue`.
      // Neither equals `/c` exactly, so the prefix tier
      // applies to both. The shorter candidate wins, so
      // `/compact` should rank first.
      final hits = filterCommands('/c');
      expect(hits.first.name, equals('/compact'));
    });

    test('returns matches ordered by descending score', () {
      // With fuzzy matching, typing `/d` matches:
      //  - `/debug` and the `/d-*` debug set via the
      //    prefix tier (when debug is on)
      //  - Other commands containing `d` somewhere via
      //    the subsequence tier (e.g. `/tldr`, `/model`,
      //    `/provider`, `/web-provider`).
      // The strongest matches rank first, so `/debug`
      // (or the `/d-*` set when enabled) should outrank
      // any subsequence-only match.
      CommandRegistry.instance.disableDebug();
      final offHits = filterCommands('/d');
      final offNames = offHits.map((c) => c.name).toList();
      expect(offNames, contains('/debug'));
      // `/debug` is the only prefix match, so it must
      // rank first. Subsequence matches like `/tldr`
      // follow in length order.
      expect(offNames.first, equals('/debug'));

      CommandRegistry.instance.enableDebug();
      final onHits = filterCommands('/d');
      final onNames = onHits.map((c) => c.name).toList();
      // `/debug` and all `/d-*` commands are prefix
      // matches; they should all rank above any
      // subsequence-only match.
      final firstNonPrefix = onNames.indexWhere((n) => !n.startsWith('/d'));
      if (firstNonPrefix >= 0) {
        final lastPrefix = firstNonPrefix - 1;
        for (var i = 0; i <= lastPrefix; i++) {
          expect(
            onNames[i].startsWith('/d'),
            isTrue,
            reason: '${onNames[i]} should be a /d prefix match',
          );
        }
      }
      // `/debug` is shorter than every `/d-*` command, so
      // it ranks first within the prefix tier.
      expect(onNames.first, equals('/debug'));
    });

    test('CJK alias prefix still reveals the primary command', () {
      // `继` is a single Chinese char. The scorer lowercases
      // both sides (lowercasing is a no-op for CJK), then
      // checks if `继续` (the alias) starts with `继`. It
      // does, so /continue is matched via prefix tier.
      final hits = filterCommands('继');
      final names = hits.map((c) => c.name).toList();
      expect(names, contains('/continue'));
    });

    test('CJK alias subsequence still reveals the primary command', () {
      // `续` is a char in `继续`. Subsequence tier applies.
      // None of the English-named commands contain `续`, so
      // only `/continue` matches.
      final hits = filterCommands('续');
      final names = hits.map((c) => c.name).toList();
      expect(names, equals(['/continue']));
    });

    test('non-matching query returns empty list (overlay closes)', () {
      final hits = filterCommands('/this-command-does-not-exist');
      expect(hits, isEmpty);
    });
  });

  group('filterSuggestions — fuzzy matching', () {
    setUp(() {
      CommandRegistry.instance.disableDebug();
    });

    test('empty query returns the full suggestion list unchanged', () {
      final suggestions = [
        const CommandSuggestion(value: 'concise', description: 'short'),
        const CommandSuggestion(value: 'detailed', description: 'long'),
        const CommandSuggestion(value: 'default', description: 'mid'),
      ];
      final filtered = filterSuggestions(suggestions, '');
      expect(filtered, equals(suggestions));
    });

    test('prefix query returns prefix matches ranked first', () {
      // `/think` suggests `off`, `low`, `normal`, `adaptive`,
      // `high`, `max`. Query `lo` should match `low` (prefix)
      // and nothing else (no other value has `l` as a
      // prefix-and-`o` as the next char, except by accident).
      final suggestions = const [
        CommandSuggestion(value: 'off'),
        CommandSuggestion(value: 'low'),
        CommandSuggestion(value: 'normal'),
        CommandSuggestion(value: 'adaptive'),
        CommandSuggestion(value: 'high'),
        CommandSuggestion(value: 'max'),
      ];
      final filtered = filterSuggestions(suggestions, 'lo');
      expect(filtered, hasLength(1));
      expect(filtered.first.value, equals('low'));
    });

    test('substring query matches across the suggestion set', () {
      // `/history` suggests `10`, `20`, `50`, `all`. Query
      // `0` is a substring of `10`, `20`, `50` — all three
      // should appear.
      final suggestions = const [
        CommandSuggestion(value: '10'),
        CommandSuggestion(value: '20'),
        CommandSuggestion(value: '50'),
        CommandSuggestion(value: 'all'),
      ];
      final filtered = filterSuggestions(suggestions, '0');
      final values = filtered.map((s) => s.value).toList();
      expect(values, containsAll(['10', '20', '50']));
      expect(values, isNot(contains('all')));
    });

    test('exact query outranks prefix and subsequence queries', () {
      // Query `normal` exactly matches `normal` (highest tier)
      // and is also a prefix match for itself. No other value
      // contains `normal` as a subseq. So `normal` should be
      // the only result.
      final suggestions = const [
        CommandSuggestion(value: 'off'),
        CommandSuggestion(value: 'low'),
        CommandSuggestion(value: 'normal'),
        CommandSuggestion(value: 'adaptive'),
        CommandSuggestion(value: 'high'),
        CommandSuggestion(value: 'max'),
      ];
      final filtered = filterSuggestions(suggestions, 'normal');
      expect(filtered, hasLength(1));
      expect(filtered.first.value, equals('normal'));
    });

    test('typo query still finds the intended suggestion', () {
      // `concie` (missing `s` and transposed letters) is a
      // subsequence of `concise` and not a subseq of
      // `detailed` or `default`. The user typing with a typo
      // should still see `concise`.
      final suggestions = const [
        CommandSuggestion(value: 'concise'),
        CommandSuggestion(value: 'detailed'),
        CommandSuggestion(value: 'default'),
      ];
      final filtered = filterSuggestions(suggestions, 'concie');
      final values = filtered.map((s) => s.value).toList();
      expect(values, contains('concise'));
    });

    test('non-matching query returns empty list', () {
      final suggestions = const [
        CommandSuggestion(value: 'concise'),
        CommandSuggestion(value: 'detailed'),
      ];
      final filtered = filterSuggestions(suggestions, 'xyzzy');
      expect(filtered, isEmpty);
    });
  });

  group('P0 command-set fixes', () {
    setUp(() {
      CommandRegistry.instance.disableDebug();
    });

    test('/undo is registered with the /撤销 alias', () {
      final cmd = findCommand('/undo');
      expect(cmd, isNotNull);
      expect(cmd!.name, equals('/undo'));
      expect(cmd.aliases, contains('/撤销'));
      // Mid-stream undo would race the in-flight turn — the
      // executor rejects it, so the overlay hides it as well.
      expect(cmd.availableDuringResponse, isFalse);
    });

    test('findCommand resolves /撤销 back to /undo', () {
      final primary = findCommand('/undo');
      final byAlias = findCommand('/撤销');
      expect(byAlias, isNotNull);
      expect(byAlias, same(primary));
    });

    test('filterCommands surfaces /undo via the Chinese alias', () {
      final hits = filterCommands('/撤');
      final names = hits.map((c) => c.name).toList();
      expect(names, contains('/undo'));
    });

    test('/clear and /history are no longer registered', () {
      // Locked P0 decision: both commands were dropped (they were
      // never implemented). They must not appear in Tab completion
      // or in findCommand lookups.
      expect(findCommand('/clear'), isNull);
      expect(findCommand('/history'), isNull);
      final names = filterCommands('').map((c) => c.name).toList();
      expect(names, isNot(contains('/clear')));
      expect(names, isNot(contains('/history')));
    });

    test('/help takes no params and is available during response', () {
      // The old entry promised `commands|models|shortcuts` topic
      // params that were never implemented; the real /help prints
      // one generated sheet, so it takes no params.
      final cmd = findCommand('/help');
      expect(cmd, isNotNull);
      expect(cmd!.params, isEmpty);
      expect(cmd.suggestionsPerParam, isEmpty);
      expect(cmd.availableDuringResponse, isTrue);
    });
  });
}
