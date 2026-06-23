// Tests for the context-size threshold re-fires of the
// `code_search` preference hint.
//
// The feature has three moving parts:
//
//   1. **Threshold helper** — `nextCodeSearchHintThreshold` finds
//      the next unsatisfied threshold given the current context and
//      the last threshold fired. Pure function — no side effects,
//      easy to pin.
//
//   2. **Threshold constants** — `codeSearchHintContextThresholds`
//      holds the [200k, 400k, 600k] tokens list. Updated as
//      context windows grow.
//
//   3. **End-to-end injection shape** — the chat service's
//      injection logic considers BOTH the one-shot flag AND
//      the threshold helper. Synthetic version of the rule
//      exercised against synthetic ToolResult maps.
//
// The existing `code_search_hint_test.dart` covers the one-shot
// behavior. This file focuses on the threshold re-fires (the
// 200k / 400k / 600k re-fires in long sessions).

import 'package:test/test.dart';

import 'package:crux/src/services/prompts/code_search_hint.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  // ===========================================================================
  // 1. Threshold helper
  // ===========================================================================

  group('nextCodeSearchHintThreshold', () {
    test('returns null when no threshold has been crossed', () {
      // Below the first threshold (200k). Helper says no fire.
      expect(nextCodeSearchHintThreshold(100, 0), isNull);
      expect(nextCodeSearchHintThreshold(50_000, 0), isNull);
      expect(nextCodeSearchHintThreshold(199_999, 0), isNull);
    });

    test('returns 200k on first crossing when lastFired=0', () {
      expect(nextCodeSearchHintThreshold(200_000, 0), 200000);
      expect(nextCodeSearchHintThreshold(250_000, 0), 200000);
      expect(nextCodeSearchHintThreshold(199_999, 0), isNull);
    });

    test('returns 400k after 200k has fired', () {
      expect(nextCodeSearchHintThreshold(400_000, 200000), 400000);
      expect(nextCodeSearchHintThreshold(500_000, 200000), 400000);
      expect(nextCodeSearchHintThreshold(399_999, 200000), isNull);
    });

    test('returns 600k after 400k has fired', () {
      expect(nextCodeSearchHintThreshold(600_000, 400000), 600000);
      expect(nextCodeSearchHintThreshold(900_000, 400000), 600000);
      expect(nextCodeSearchHintThreshold(599_999, 400000), isNull);
    });

    test('returns null above the highest threshold (600k)', () {
      // All thresholds configured above 600k have fired. No more.
      expect(nextCodeSearchHintThreshold(700_000, 600000), isNull);
      expect(nextCodeSearchHintThreshold(1_000_000, 600000), isNull);
    });

    test('handles a context jump past multiple thresholds', () {
      // Context jumps 100k → 600k in one round (e.g. user pasted a
      // long message). Helper returns the LOWEST unsatisfied
      // threshold (200k). Subsequent rounds handle the higher
      // ones as the threshold still satisfies T > lastFired.
      expect(nextCodeSearchHintThreshold(600_000, 0), 200000);
      expect(nextCodeSearchHintThreshold(600_000, 200000), 400000);
      expect(nextCodeSearchHintThreshold(600_000, 400000), 600000);
      expect(nextCodeSearchHintThreshold(600_000, 600000), isNull);
    });

    test('handles a context jump past all thresholds', () {
      // 100k → 900k in one round. Helper still returns 200k
      // first; the chat service updates lastFired as each
      // threshold fires in subsequent rounds.
      expect(nextCodeSearchHintThreshold(900_000, 0), 200000);
    });

    test('is idempotent (same input → same output, every call)', () {
      expect(nextCodeSearchHintThreshold(450_000, 200000),
          nextCodeSearchHintThreshold(450_000, 200000));
    });

    test('the thresholds constant is [200k, 400k, 600k]', () {
      expect(codeSearchHintContextThresholds, [200000, 400000, 600000]);
    });
  });

  // ===========================================================================
  // 2. End-to-end injection shape with threshold re-fires
  // ===========================================================================

  group('injection rule with threshold re-fires', () {
    /// Synthetic version of the chat_service injection logic that
    /// also handles threshold re-fires. Mirrors the real logic
    /// in `chat_service.dart` (the `if (!runtime.hasShownCodeSearchHint ||
    /// nextCodeSearchHintThreshold(...) != null)` block).
    ///
    /// Returns the (possibly mutated) results map, the post-injection
    /// flag value, and the post-injection threshold value. Lets us
    /// pin the full state-machine behaviour without standing up a
    /// session.
    ({
      Map<String, ToolResult> results,
      bool flag,
      int lastThreshold,
    }) injectHint({
      required Map<String, ToolResult> results,
      required List<String> toolNamesInOrder,
      required bool flagBefore,
      required int lastThresholdBefore,
      required int currentContextTokens,
    }) {
      var flag = flagBefore;
      var lastThreshold = lastThresholdBefore;

      final shouldFire = !flag ||
          nextCodeSearchHintThreshold(currentContextTokens, lastThreshold) !=
              null;
      if (!shouldFire) {
        return (results: results, flag: flag, lastThreshold: lastThreshold);
      }

      const trigger = <String>{'grep', 'glob'};
      for (final name in toolNamesInOrder) {
        final lower = name.toLowerCase();
        if (!trigger.contains(lower)) continue;
        final entry = results.entries.firstWhere(
          (e) => results[e.key] != null && results[e.key]!.title != 'Error',
          orElse: () => MapEntry(
            '',
            const ToolResult(title: 'Error', output: 'placeholder'),
          ),
        );
        if (entry.key.isEmpty) continue;
        final r = results[entry.key]!;
        if (r.title == 'Error') continue;
        if (r.metadata['guardTriggered'] == true) continue;

        results[entry.key] = ToolResult(
          title: r.title,
          output: r.output + renderCodeSearchHintEmbedded(),
          truncated: r.truncated,
          outputPath: r.outputPath,
          metadata: r.metadata,
        );
        // Update state: initial one-shot flips the flag; threshold
        // re-fires bump lastThreshold. Both are mutually exclusive
        // per round — the one-shot fires only when the flag is
        // still false.
        if (!flag) {
          flag = true;
        } else {
          final t = nextCodeSearchHintThreshold(
            currentContextTokens,
            lastThreshold,
          );
          if (t != null) lastThreshold = t;
        }
        break; // only the first grep/glob in the round
      }
      return (results: results, flag: flag, lastThreshold: lastThreshold);
    }

    test('initial one-shot fires at context < 200k (first session grep/glob)',
        () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: foo', output: 'matches'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: false,
        lastThresholdBefore: 0,
        currentContextTokens: 100_000, // well below 200k
      );
      expect(out.results['a']!.output, contains(renderCodeSearchHintEmbedded()));
      expect(out.flag, isTrue);
      // One-shot doesn't bump lastThreshold — the threshold logic
      // is for subsequent fires. lastThreshold stays at 0.
      expect(out.lastThreshold, 0);
    });

    test('no re-fire at context < 200k after the one-shot', () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: foo', output: 'matches'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true, // already shown
        lastThresholdBefore: 0,
        currentContextTokens: 100_000,
      );
      // No fire — flag is true, no threshold crossed.
      expect(out.results['a']!.output,
          isNot(contains(renderCodeSearchHintEmbedded())));
      expect(out.lastThreshold, 0);
    });

    test('re-fires at 200k threshold when context crosses', () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: foo', output: 'matches'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true,
        lastThresholdBefore: 0,
        currentContextTokens: 250_000, // crossed 200k
      );
      expect(out.results['a']!.output, contains(renderCodeSearchHintEmbedded()));
      expect(out.flag, isTrue); // stays true
      expect(out.lastThreshold, 200000); // bumped to 200k
    });

    test('re-fires at 400k threshold when context crosses', () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: foo', output: 'matches'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true,
        lastThresholdBefore: 200000,
        currentContextTokens: 450_000, // crossed 400k
      );
      expect(out.results['a']!.output, contains(renderCodeSearchHintEmbedded()));
      expect(out.lastThreshold, 400000);
    });

    test('re-fires at 600k threshold when context crosses', () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: foo', output: 'matches'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true,
        lastThresholdBefore: 400000,
        currentContextTokens: 700_000, // crossed 600k
      );
      expect(out.results['a']!.output, contains(renderCodeSearchHintEmbedded()));
      expect(out.lastThreshold, 600000);
    });

    test('does NOT re-fire above the highest threshold', () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: foo', output: 'matches'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true,
        lastThresholdBefore: 600000,
        currentContextTokens: 900_000, // above 600k, no more thresholds
      );
      expect(out.results['a']!.output,
          isNot(contains(renderCodeSearchHintEmbedded())));
      expect(out.lastThreshold, 600000);
    });

    test('does NOT re-fire below the next threshold', () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: foo', output: 'matches'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true,
        lastThresholdBefore: 200000,
        currentContextTokens: 300_000, // below 400k
      );
      expect(out.results['a']!.output,
          isNot(contains(renderCodeSearchHintEmbedded())));
      expect(out.lastThreshold, 200000); // unchanged
    });

    test('multi-threshold context jump: first round fires 200k, subsequent rounds climb',
        () {
      // Simulate: context jumps 100k → 900k in one turn. The LLM
      // does 3 rounds of grep/glob across the conversation,
      // gradually bumping lastThreshold as each threshold fires.
      const initialOutput = 'matches';

      // Round 1 (context = 900k, lastThreshold = 0):
      //   - one-shot would have fired (but flag is already true here)
      //   - threshold helper returns 200k (the lowest unsatisfied)
      //   - hint fires, lastThreshold → 200k
      Map<String, ToolResult> results = {
        'a': const ToolResult(title: 'Grep: 1', output: initialOutput),
      };
      var out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true,
        lastThresholdBefore: 0,
        currentContextTokens: 900_000,
      );
      expect(out.results['a']!.output, contains(renderCodeSearchHintEmbedded()));
      expect(out.lastThreshold, 200000);

      // Round 2 (context = 900k, lastThreshold = 200k):
      //   - threshold helper returns 400k
      //   - hint fires, lastThreshold → 400k
      results = {
        'a': const ToolResult(title: 'Grep: 2', output: initialOutput),
      };
      out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true,
        lastThresholdBefore: 200000,
        currentContextTokens: 900_000,
      );
      expect(out.results['a']!.output, contains(renderCodeSearchHintEmbedded()));
      expect(out.lastThreshold, 400000);

      // Round 3 (context = 900k, lastThreshold = 400k):
      //   - threshold helper returns 600k
      //   - hint fires, lastThreshold → 600k
      results = {
        'a': const ToolResult(title: 'Grep: 3', output: initialOutput),
      };
      out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true,
        lastThresholdBefore: 400000,
        currentContextTokens: 900_000,
      );
      expect(out.results['a']!.output, contains(renderCodeSearchHintEmbedded()));
      expect(out.lastThreshold, 600000);

      // Round 4 (context = 900k, lastThreshold = 600k):
      //   - no threshold above 600k
      //   - hint does NOT fire
      results = {
        'a': const ToolResult(title: 'Grep: 4', output: initialOutput),
      };
      out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true,
        lastThresholdBefore: 600000,
        currentContextTokens: 900_000,
      );
      expect(out.results['a']!.output,
          isNot(contains(renderCodeSearchHintEmbedded())));
      expect(out.lastThreshold, 600000); // unchanged
    });

    test('glob triggers threshold re-fires (same as grep)', () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Glob: **.dart', output: 'files'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['glob'],
        flagBefore: true,
        lastThresholdBefore: 200000,
        currentContextTokens: 450_000, // crossed 400k
      );
      expect(out.results['a']!.output, contains(renderCodeSearchHintEmbedded()));
      expect(out.lastThreshold, 400000);
    });

    test('mixed round: threshold re-fire on the first grep, not on later read/code_search',
        () {
      // LLM called grep, read, code_search all in one round. The
      // threshold re-fire should hit the grep, not the others.
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: auth', output: 'matches'),
        'b': const ToolResult(title: 'Read: auth.dart', output: 'file'),
        'c': const ToolResult(title: 'code_search: auth', output: 'snippets'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep', 'read', 'code_search'],
        flagBefore: true,
        lastThresholdBefore: 200000,
        currentContextTokens: 450_000, // crossed 400k
      );
      expect(out.results['a']!.output, contains(renderCodeSearchHintEmbedded()));
      expect(out.results['b']!.output,
          isNot(contains(renderCodeSearchHintEmbedded())));
      expect(out.results['c']!.output,
          isNot(contains(renderCodeSearchHintEmbedded())));
      expect(out.lastThreshold, 400000);
    });
  });
}