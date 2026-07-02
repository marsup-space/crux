// Tests for the one-shot `semantic_search` preference hint.
//
// The feature has three moving parts:
//
//   1. **Renderer** — pure function that produces the
//      embedded hint text wrapped in the `[Crux system note —
//      prefer semantic_search]` marker. Stable string contract so
//      the LLM can pattern-match the intent.
//
//   2. **End-to-end injection** — the chat service appends the
//      hint to the FIRST `grep` or `glob` tool result in a
//      session, then sets a flag so subsequent grep/glob calls
//      in the same session don't get the hint. Companion to the
//      shell-tool fallback guard's semantic_search verdict (which
//      fires on `rg | head` bash pipelines) — this hint fires
//      when the LLM uses grep/glob DIRECTLY as a tool.
//
//   3. **State semantics** — the `hasShownsemanticSearchHint` flag
//      is per-chat (in-memory, resets on app restart), not per
//      turn. Once fired, the hint never fires again in the same
//      session.

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/services/prompts/semantic_search_hint.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/tool_def.dart';

// =============================================================================
// 1. Renderer
// =============================================================================

void main() {
  group('renderSemanticSearchHintEmbedded', () {
    test('returns a non-empty string', () {
      final out = renderSemanticSearchHintEmbedded();
      expect(out, isNotEmpty);
    });

    test('wraps the body in the `[Crux system note — prefer semantic_search]` marker',
        () {
      final out = renderSemanticSearchHintEmbedded();
      expect(out, contains(semanticSearchHintMarker));
    });

    test('mentions semantic_search by name (semantic search)', () {
      final out = renderSemanticSearchHintEmbedded();
      expect(out, contains('semantic_search'));
      expect(out, contains('semantic search'));
    });

    test('mentions grep and glob as the tools to reserve for other uses', () {
      final out = renderSemanticSearchHintEmbedded();
      expect(out, contains('grep'));
      expect(out, contains('glob'));
    });

    test('explains the "concept not regex" differentiator', () {
      final out = renderSemanticSearchHintEmbedded();
      expect(out, contains('CONCEPT'));
      expect(out, contains('regex'));
    });

    test('shape mirrors other embedded hints (leading/trailing newlines)', () {
      final out = renderSemanticSearchHintEmbedded();
      // Leading `\n\n` separates the hint from the tool's real
      // output; the marker tag is on its own line.
      expect(out, startsWith('\n\n[Crux system note'));
      // Trailing `\n` so the next line of LLM-facing context
      // starts cleanly.
      expect(out, endsWith('\n'));
    });

    test('is idempotent (same input → same output, every call)', () {
      // The renderer is pure; verify no hidden state.
      expect(renderSemanticSearchHintEmbedded(), renderSemanticSearchHintEmbedded());
    });
  });

  // ===========================================================================
  // 2. End-to-end injection via the tool-result augmentation pipeline
  // ===========================================================================
  //
  // The chat_service injection logic is small enough to test directly
  // without standing up a full session: the rule is "find the first
  // successful grep/glob call in the round, append the hint to its
  // output, set the flag". These tests exercise that rule using a
  // synthetic ToolResult map (mirroring the chat_service pattern).

  group('injection rule (executed via the chat_service mutation shape)', () {
    ToolResult placeholderError() =>
        const ToolResult(title: 'Error', output: 'placeholder');

    /// Synthetic version of the chat_service injection logic, for
    /// testing the rule in isolation. Returns the (possibly mutated)
    /// results map and the post-injection flag value.
    ({Map<String, ToolResult> results, bool flag}) injectHint({
      required Map<String, ToolResult> results,
      required List<String> toolNamesInOrder,
      required bool flagBefore,
    }) {
      var flag = flagBefore;
      if (flag) return (results: results, flag: flag);
      const trigger = <String>{'grep', 'glob'};
      for (final name in toolNamesInOrder) {
        final lower = name.toLowerCase();
        if (!trigger.contains(lower)) continue;
        final entry = results.entries.firstWhere(
          (e) => results[e.key] != null && results[e.key]!.title != 'Error',
          orElse: () => MapEntry('', placeholderError()),
        );
        if (entry.key.isEmpty) continue;
        final r = results[entry.key]!;
        if (r.title == 'Error') continue;
        if (r.metadata['guardTriggered'] == true) continue;
        results[entry.key] = ToolResult(
          title: r.title,
          output: r.output + renderSemanticSearchHintEmbedded(),
          truncated: r.truncated,
          outputPath: r.outputPath,
          metadata: r.metadata,
        );
        flag = true;
        break;
      }
      return (results: results, flag: flag);
    }

    test('appends hint to the first successful grep result', () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: foo', output: 'matches'),
        'b': const ToolResult(title: 'Read: file', output: 'contents'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep', 'read'],
        flagBefore: false,
      );
      expect(out.results['a']!.output, contains(renderSemanticSearchHintEmbedded()));
      expect(out.results['b']!.output, isNot(contains(renderSemanticSearchHintEmbedded())));
      expect(out.flag, isTrue);
    });

    test('appends hint to the first successful glob result (grep not called)',
        () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Glob: **.dart', output: 'files'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['glob'],
        flagBefore: false,
      );
      expect(out.results['a']!.output, contains(renderSemanticSearchHintEmbedded()));
      expect(out.flag, isTrue);
    });

    test('does NOT append hint when flag is already true', () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: foo', output: 'matches'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: true, // already shown
      );
      expect(out.results['a']!.output, isNot(contains(renderSemanticSearchHintEmbedded())));
      expect(out.flag, isTrue); // stays true
    });

    test('only the FIRST grep/glob gets the hint (subsequent ones don\'t)',
        () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: 1', output: 'out1'),
        'b': const ToolResult(title: 'Grep: 2', output: 'out2'),
        'c': const ToolResult(title: 'Grep: 3', output: 'out3'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep', 'grep', 'grep'],
        flagBefore: false,
      );
      // First one: hint appended.
      expect(out.results['a']!.output, contains(renderSemanticSearchHintEmbedded()));
      // Second and third: no hint.
      expect(out.results['b']!.output, isNot(contains(renderSemanticSearchHintEmbedded())));
      expect(out.results['c']!.output, isNot(contains(renderSemanticSearchHintEmbedded())));
      expect(out.flag, isTrue);
    });

    test('does NOT append hint for non-trigger tools (read / write / bash)',
        () {
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Read: file', output: 'contents'),
        'b': const ToolResult(title: 'Bash: ls', output: 'files'),
        'c': const ToolResult(title: 'Write: file', output: 'ok'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['read', 'bash', 'write'],
        flagBefore: false,
      );
      for (final r in out.results.values) {
        expect(r.output, isNot(contains(renderSemanticSearchHintEmbedded())));
      }
      expect(out.flag, isFalse); // never fired
    });

    test('does NOT append hint to an error result (skip the failed call)', () {
      // In chat_service, a `title == 'Error'` result means the tool
      // failed; the hint shouldn't be appended to a failure (the
      // LLM needs the error context, not the nudge).
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Error', output: 'failed'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: false,
      );
      // The Error result should not get the hint.
      expect(out.results['a']!.output, isNot(contains(renderSemanticSearchHintEmbedded())));
    });

    test('does NOT append hint when grep result is guard-triggered', () {
      // E.g. an auto-read guard or a read-before-write guard on a
      // grep-with-side-effect result. The guard meta flag is
      // upstream-set; the hint logic respects it.
      final results = <String, ToolResult>{
        'a': const ToolResult(
          title: 'Grep: foo',
          output: 'matches',
          metadata: {'guardTriggered': true},
        ),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep'],
        flagBefore: false,
      );
      expect(out.results['a']!.output, isNot(contains(renderSemanticSearchHintEmbedded())));
    });

    test('mixed round: hint fires on the first grep, not on later read/semantic_search',
        () {
      // LLM called grep, read, semantic_search all in one round. Hint
      // fires on grep; the others (including semantic_search, which is
      // already the right tool) get no hint.
      final results = <String, ToolResult>{
        'a': const ToolResult(title: 'Grep: auth', output: 'matches'),
        'b': const ToolResult(title: 'Read: auth.dart', output: 'file'),
        'c': const ToolResult(title: 'semantic_search: auth', output: 'snippets'),
      };
      final out = injectHint(
        results: results,
        toolNamesInOrder: ['grep', 'read', 'semantic_search'],
        flagBefore: false,
      );
      expect(out.results['a']!.output, contains(renderSemanticSearchHintEmbedded()));
      expect(out.results['b']!.output, isNot(contains(renderSemanticSearchHintEmbedded())));
      expect(out.results['c']!.output, isNot(contains(renderSemanticSearchHintEmbedded())));
    });
  });

  // ===========================================================================
  // 3. State semantics — SessionRuntimeState field exists and defaults to false
  // ===========================================================================

  group('SessionRuntimeState.hasShownsemanticSearchHint', () {
    test('defaults to false on a freshly-constructed runtime', () {
      final rt = SessionRuntimeState(sessionId: 1);
      expect(rt.hasShownsemanticSearchHint, isFalse);
    });

    test('can be flipped to true after the first grep/glob success', () {
      final rt = SessionRuntimeState(sessionId: 1);
      rt.hasShownsemanticSearchHint = true;
      expect(rt.hasShownsemanticSearchHint, isTrue);
    });

    test('stays true across multiple user turns in the same session', () {
      // The flag is per-chat, not per-turn. A long chat that fires
      // the hint on turn 1 must NOT re-fire on turn 5 — that would
      // be noisy and undermine the "one-shot per session" intent.
      final rt = SessionRuntimeState(sessionId: 1);
      rt.hasShownsemanticSearchHint = true;
      // Simulate: user sends 4 more messages, each with grep/glob.
      // The chat_service should NOT inject the hint again because
      // the flag is already true.
      expect(rt.hasShownsemanticSearchHint, isTrue);
    });
  });

  // ===========================================================================
  // 4. Persistence sanity (chat history shows the appended output)
  // ===========================================================================

  group('MessageStore — appended hint persists in the tool result', () {
    late CruxDatabase db;
    late SessionStore store;
    late int sessionId;

    setUp(() async {
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      final session = await store.create(
        title: 'semantic-search-hint-test',
        model: 'openai/gpt-4o',
        projectPath: '/tmp',
      );
      sessionId = session.id;
    });

    tearDown(() async {
      await db.close();
    });

    test('the hint text round-trips through addToolRound when appended', () async {
      await store.messageStore.addMessage(
        sessionId,
        role: 'user',
        content: 'find auth logic',
      );
      // Simulate the chat_service post-processing: append the hint
      // to the grep result before persisting.
      const rawOutput = 'lib/auth.dart:5: authenticate(user)';
      final augmentedOutput = rawOutput + renderSemanticSearchHintEmbedded();
      await store.messageStore.addToolRound(
        sessionId,
        roundText: '',
        toolCalls: [
          ToolCallData(callId: 'a', name: 'grep', input: {'pattern': 'auth'}),
        ],
        results: [
          (callId: 'a', output: augmentedOutput, meta: ''),
        ],
      );

      final msgs = await store.messageStore.getMessages(sessionId);
      final toolResult = msgs.firstWhere(
        (m) => m.role == 'tool',
      );
      expect(toolResult.content, contains(semanticSearchHintMarker));
      expect(toolResult.content, contains(rawOutput));
      // The hint goes AFTER the tool's real output, so the raw
      // output precedes the marker in the persisted text.
      expect(
        toolResult.content.indexOf(rawOutput),
        lessThan(toolResult.content.indexOf(semanticSearchHintMarker)),
      );
    });
  });
}