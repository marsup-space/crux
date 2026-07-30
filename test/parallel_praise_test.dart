// Tests for the parallel-tool-call hint feature.
//
// The feature has four moving parts, each covered by a group below:
//
//   1. Prompt rendering — the in-context text the LLM sees (both
//      the praise hint and the single-call reminder), plus the
//      user-facing bubble label.
//   2. LLM-provider resolver — the precedence rules for
//      model > provider > class default, for both the toggle and
//      the single-call threshold.
//   3. TOML parsing — provider-level and model-level
//      `hint_parallel_calls` round-trip through the loader
//      (including the legacy `praise_parallel_calls` fallback),
//      and `hint_parallel_calls_single_threshold` parsing.
//   4. End-to-end — given a session with a multi-call tool round,
//      MessageStore persists a `parallel_praise` row in the right
//      place with the right `parallelCount` value.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/models/message.dart';
import 'package:crux/src/services/prompts/praise_prompts.dart';
import 'package:crux/src/services/provider_config_loader.dart';
import 'package:crux/src/services/providers/anthropic_compatible_provider.dart';
import 'package:crux/src/services/providers/openai_compatible_provider.dart';
import 'package:crux/src/storage/storage.dart';

/// A subclass used to verify the `defaultHintParallelCalls` getter
/// can be overridden per-LLM. Hoisted to top level because Dart
/// doesn't allow nested class declarations.
class _SilentProvider extends AnthropicCompatibleProvider {
  _SilentProvider();
  @override
  bool get defaultHintParallelCalls => false;
}

/// A subclass used to verify the `defaultHintParallelCallsSingleThreshold`
/// getter can be overridden per-LLM.
class _ThresholdOverrideProvider extends OpenAICompatibleProvider {
  _ThresholdOverrideProvider();
  @override
  int get defaultHintParallelCallsSingleThreshold => 3;
}

void main() {
  // ─────────────────────────────────────────────────────────────────────
  // 1. Prompt rendering
  // ─────────────────────────────────────────────────────────────────────
  group('renderParallelToolCallHint (in-context praise prompt)', () {
    test('substitutes count and savings placeholders', () {
      final out = renderParallelToolCallHint(3);
      expect(out, contains('3 tool calls'));
      expect(out, contains('saving 2 round trips'));
    });

    test('savings is count - 1, never negative', () {
      expect(renderParallelToolCallHint(2), contains('saving 1'));
      expect(renderParallelToolCallHint(5), contains('saving 4'));
    });

    test('uses singular "round trip" when savings == 1 (no "(s)")', () {
      // The typical case: 2 parallel calls save exactly 1 round
      // trip. The previous "saving 1 round trip(s)" read
      // awkwardly; this test pins the cleaner form.
      final out = renderParallelToolCallHint(2);
      expect(out, contains('saving 1 round trip '));
      expect(out, isNot(contains('trip(s)')));
    });

    test('uses plural "round trips" when savings >= 2', () {
      expect(renderParallelToolCallHint(3), contains('saving 2 round trips'));
      expect(renderParallelToolCallHint(5), contains('saving 4 round trips'));
    });
  });

  group('renderParallelToolCallHintEmbedded (appended to last tool)', () {
    test('wraps the bare praise with the system-note marker', () {
      final out = renderParallelToolCallHintEmbedded(3);
      expect(out, contains(parallelHintEmbeddedMarker));
      expect(out, contains('You emitted 3 tool calls'));
      // The marker must come *before* the body, not the other way
      // around — the LLM parses the tag, then reads what follows.
      expect(
        out.indexOf(parallelHintEmbeddedMarker),
        lessThan(out.indexOf('You emitted 3 tool calls')),
      );
    });

    test('produces output suitable for appending to a tool result', () {
      // The leading blank line(s) and the bracketed marker give the
      // LLM a clean boundary between the tool's real output and the
      // injected note. The trailing newline terminates cleanly.
      final out = renderParallelToolCallHintEmbedded(2);
      expect(out, startsWith('\n\n'));
      expect(out, endsWith('\n'));
    });

    test('does NOT include "user" framing — it is appended, not spoken', () {
      // The bare praise is preserved verbatim. Crucially, the
      // embedded variant does not introduce any wording that would
      // make the LLM think a human is talking.
      final bare = renderParallelToolCallHint(4);
      final embedded = renderParallelToolCallHintEmbedded(4);
      // Strip the framing and the body should still be present.
      expect(embedded, contains(bare));
    });

    test('uses the renamed marker text (no longer "praise")', () {
      // The feature was renamed from "praise" to "hint" because
      // the toggle now governs two signals. The marker tag the LLM
      // pattern-matches on must reflect the new name.
      expect(parallelHintEmbeddedMarker, contains('hint'));
      expect(parallelHintEmbeddedMarker, isNot(contains('praise')));
    });
  });

  group('renderParallelPraiseBubbleLabel (user-facing bubble)', () {
    test('shows count and savings in a single short line', () {
      final out = renderParallelPraiseBubbleLabel(4);
      expect(out, contains('4 tool calls parallelized'));
      expect(out, contains('saving 3 round trips'));
    });

    test('uses singular "round trip" when savings == 1', () {
      // Mirrors the in-context singular form so the user sees the
      // same grammar the LLM does.
      final out = renderParallelPraiseBubbleLabel(2);
      expect(out, '2 tool calls parallelized · saving 1 round trip');
    });
  });

  group('renderSingleCallReminderBubbleLabel (user-facing reminder)', () {
    test('shows the consecutive count and a parallel-tool-call suggestion', () {
      final out = renderSingleCallReminderBubbleLabel(10);
      expect(out, contains('10 consecutive single-tool-call rounds'));
      expect(out, contains('try parallel tool calls'));
    });

    test('uses the actual count (no plural/singular branching needed)', () {
      // Unlike the praise label (which switches "round trip"/"round
      // trips" on the savings count), the reminder label only
      // prints the consecutive round count once — no singular
      // special case to test.
      expect(renderSingleCallReminderBubbleLabel(20), contains('20'));
      expect(renderSingleCallReminderBubbleLabel(30), contains('30'));
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 1b. Single-call hint prompt rendering (new feature)
  // ─────────────────────────────────────────────────────────────────
  group('renderParallelSingleCallHint (in-context reminder prompt)', () {
    test('substitutes the consecutive-count placeholder', () {
      final out = renderParallelSingleCallHint(10);
      expect(out, contains('10 consecutive single-tool-call rounds'));
    });

    test('uses neutral framing — not an accusation', () {
      // The mild-tier reminder (round == threshold, e.g. 10) is
      // phrased conditionally ("if those tool calls were
      // independent") rather than as a complaint. Some serial
      // workflows are legitimate; the nudge is a suggestion, not a
      // verdict. The firm (round 20) and urgent (round 30+) tiers
      // are more direct because the model has evidently not
      // responded to softer nudges.
      final out = renderParallelSingleCallHint(10);
      expect(out, contains('If those tool calls were independent'));
      expect(out, contains('parallel tool calls'));
      // No accusatory language — the model should not feel scolded.
      expect(out.toLowerCase(), isNot(contains('you should have')));
      expect(out.toLowerCase(), isNot(contains('you failed')));
    });
  });

  group('renderParallelSingleCallHintEmbedded (appended to last tool)', () {
    test('wraps the bare reminder with its own system-note marker', () {
      final out = renderParallelSingleCallHintEmbedded(10);
      expect(
        out,
        contains(parallelSingleCallHintMarker(SingleCallHintSeverity.mild)),
      );
      expect(out, contains('You have emitted 10 consecutive'));
      // The marker must come before the body.
      expect(
        out.indexOf(parallelSingleCallHintMarker(SingleCallHintSeverity.mild)),
        lessThan(out.indexOf('You have emitted')),
      );
    });

    test('uses a DIFFERENT marker than the praise hint', () {
      // Both hints share the wire-format placement but use
      // distinct marker tags so the model can pattern-match
      // which signal it's seeing. Pinned by this test.
      expect(
        parallelSingleCallHintMarker(SingleCallHintSeverity.mild),
        isNot(equals(parallelHintEmbeddedMarker)),
      );
    });

    test('produces output suitable for appending to a tool result', () {
      // Same boundary conventions as the praise hint: leading
      // blank lines, bracketed marker, trailing newline.
      final out = renderParallelSingleCallHintEmbedded(5);
      expect(out, startsWith('\n\n'));
      expect(out, endsWith('\n'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // 2b. Wire-format injection (regression net for the "no user
  //     message" requirement)
  // ─────────────────────────────────────────────────────────────────────
  group('injectParallelToolCallHintIntoLastTool (praise wire format)', () {
    test('OpenAI: appends to the last tool message, not a sibling user', () {
      final msgs = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'go'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'a',
              'type': 'function',
              'function': {'name': 'grep', 'arguments': '{}'},
            },
            {
              'id': 'b',
              'type': 'function',
              'function': {'name': 'read', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'a', 'content': 'match'},
        {'role': 'tool', 'tool_call_id': 'b', 'content': 'contents'},
      ];

      injectParallelToolCallHintIntoLastTool(
        msgs,
        isAnthropic: false,
        count: 2,
      );

      // Length must be unchanged — no new sibling user message.
      expect(msgs, hasLength(4));
      // Praise is appended to the LAST tool message's content, not
      // the assistant message and not a new user message.
      final last = msgs.last;
      expect(last['role'], 'tool');
      expect(last['tool_call_id'], 'b');
      final content = last['content'] as String;
      expect(content, startsWith('contents'));
      expect(content, contains(parallelHintEmbeddedMarker));
      expect(content, contains('You emitted 2 tool calls'));

      // No new user message appeared.
      expect(
        msgs.where((m) => m['role'] == 'user').toList(),
        hasLength(1),
        reason: 'hint must not introduce a sibling user message',
      );
    });

    test('Anthropic: appends to the last tool_result block, no new block', () {
      final msgs = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'go'},
        {
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': 'a', 'name': 'grep', 'input': {}},
            {'type': 'tool_use', 'id': 'b', 'name': 'read', 'input': {}},
          ],
        },
        {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 'a', 'content': 'match'},
            {'type': 'tool_result', 'tool_use_id': 'b', 'content': 'contents'},
          ],
        },
      ];

      injectParallelToolCallHintIntoLastTool(msgs, isAnthropic: true, count: 2);

      // Length unchanged: hint must not add a sibling text block or
      // a new user message.
      expect(msgs, hasLength(3));
      final lastMessage = msgs.last;
      expect(lastMessage['role'], 'user');
      final blocks = lastMessage['content'] as List;
      expect(blocks, hasLength(2), reason: 'no new sibling block added');

      final lastBlock = blocks.last;
      expect(
        lastBlock['type'],
        'tool_result',
        reason: 'last block must remain a tool_result, not a text block',
      );
      final lastContent = lastBlock['content'] as String;
      expect(lastContent, startsWith('contents'));
      expect(lastContent, contains(parallelHintEmbeddedMarker));
      expect(lastContent, contains('You emitted 2 tool calls'));

      // The first tool_result's content is untouched.
      final firstBlock = blocks.first;
      expect(firstBlock['content'], 'match');
    });

    test('is a no-op on an empty message list (defensive)', () {
      final msgs = <Map<String, dynamic>>[];
      injectParallelToolCallHintIntoLastTool(
        msgs,
        isAnthropic: false,
        count: 2,
      );
      expect(msgs, isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 2c. Single-call hint wire-format injection (new feature)
  // ─────────────────────────────────────────────────────────────────
  group('injectParallelSingleCallHintIntoLastTool (reminder wire format)', () {
    test('OpenAI: appends to the last (and only) tool message', () {
      final msgs = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'go'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'a',
              'type': 'function',
              'function': {'name': 'read', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'a', 'content': 'file contents'},
      ];

      injectParallelSingleCallHintIntoLastTool(
        msgs,
        isAnthropic: false,
        consecutiveCount: 10,
      );

      expect(
        msgs,
        hasLength(3),
        reason: 'no new sibling user or text block added',
      );
      final last = msgs.last;
      expect(last['role'], 'tool');
      final content = last['content'] as String;
      expect(content, startsWith('file contents'));
      expect(
        content,
        contains(parallelSingleCallHintMarker(SingleCallHintSeverity.mild)),
      );
      expect(content, contains('10 consecutive'));
      // And critically: NOT the praise marker. Same placement,
      // different signal.
      expect(content, isNot(contains(parallelHintEmbeddedMarker)));
    });

    test('Anthropic: appends to the last tool_result block', () {
      final msgs = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'go'},
        {
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': 'a', 'name': 'read', 'input': {}},
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'a',
              'content': 'file contents',
            },
          ],
        },
      ];

      injectParallelSingleCallHintIntoLastTool(
        msgs,
        isAnthropic: true,
        consecutiveCount: 10,
      );

      expect(msgs, hasLength(3));
      final lastMessage = msgs.last;
      expect(lastMessage['role'], 'user');
      final blocks = lastMessage['content'] as List;
      expect(blocks, hasLength(1));
      final block = blocks.first;
      expect(block['type'], 'tool_result');
      final content = block['content'] as String;
      expect(
        content,
        contains(parallelSingleCallHintMarker(SingleCallHintSeverity.mild)),
      );
      expect(content, contains('10 consecutive'));
    });

    test('is a no-op on an empty message list (defensive)', () {
      final msgs = <Map<String, dynamic>>[];
      injectParallelSingleCallHintIntoLastTool(
        msgs,
        isAnthropic: false,
        consecutiveCount: 5,
      );
      expect(msgs, isEmpty);
    });

    test(
      'THROWS if called for the urgent tier (use the user-message helper)',
      () {
        // Round 30 with default threshold → urgent tier. The
        // tool-result-append helper refuses to render this and
        // tells the caller to use the user-role helper instead.
        // Without this guard, a regression in chat_service that
        // routes urgent hints through the wrong helper would
        // silently append the urgent text to a tool result — the
        // exact behaviour the tier split exists to prevent.
        final msgs = <Map<String, dynamic>>[
          {'role': 'tool', 'tool_call_id': 'a', 'content': 'x'},
        ];
        expect(
          () => injectParallelSingleCallHintIntoLastTool(
            msgs,
            isAnthropic: false,
            consecutiveCount: 30,
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────
  // 2d. Single-call hint tier logic (mild / firm / urgent)
  // ─────────────────────────────────────────────────────────────────
  group('singleCallHintSeverityFor (tier boundary)', () {
    test('count == threshold → mild', () {
      expect(singleCallHintSeverityFor(10), SingleCallHintSeverity.mild);
      expect(
        singleCallHintSeverityFor(5, threshold: 5),
        SingleCallHintSeverity.mild,
      );
    });

    test('count == 2 * threshold → firm', () {
      expect(singleCallHintSeverityFor(20), SingleCallHintSeverity.firm);
      expect(
        singleCallHintSeverityFor(6, threshold: 3),
        SingleCallHintSeverity.firm,
      );
    });

    test('count >= 3 * threshold → urgent', () {
      expect(singleCallHintSeverityFor(30), SingleCallHintSeverity.urgent);
      expect(singleCallHintSeverityFor(40), SingleCallHintSeverity.urgent);
      expect(singleCallHintSeverityFor(100), SingleCallHintSeverity.urgent);
    });

    test('count below threshold (sub-tier 0) is still mild', () {
      // The modulo gate only fires at multiples of threshold, but
      // the tier function is forgiving — counts below threshold
      // map to mild, never to firm/urgent.
      expect(singleCallHintSeverityFor(1), SingleCallHintSeverity.mild);
      expect(singleCallHintSeverityFor(9), SingleCallHintSeverity.mild);
    });

    test('threshold == 0 → mild (defensive — avoids div-by-zero)', () {
      // The chat_service guards against `counter % 0` separately;
      // the tier function must not throw.
      expect(
        singleCallHintSeverityFor(10, threshold: 0),
        SingleCallHintSeverity.mild,
      );
    });
  });

  group('parallelSingleCallHintMarker (tier-specific tag)', () {
    test('mild tag is the bare marker', () {
      expect(
        parallelSingleCallHintMarker(SingleCallHintSeverity.mild),
        '[Crux system note — single-tool-call hint]',
      );
    });

    test('firm tag has a tier suffix', () {
      expect(
        parallelSingleCallHintMarker(SingleCallHintSeverity.firm),
        '[Crux system note — single-tool-call hint — firm]',
      );
    });

    test('urgent tag has a tier suffix', () {
      expect(
        parallelSingleCallHintMarker(SingleCallHintSeverity.urgent),
        '[Crux system note — single-tool-call hint — urgent]',
      );
    });

    test('all three markers contain the base reminder kind', () {
      // Pinned so a rename that drops "single-tool-call hint" from
      // any tier trips the suite.
      for (final m in [
        parallelSingleCallHintMarker(SingleCallHintSeverity.mild),
        parallelSingleCallHintMarker(SingleCallHintSeverity.firm),
        parallelSingleCallHintMarker(SingleCallHintSeverity.urgent),
      ]) {
        expect(m, contains('single-tool-call hint'));
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 2e. Urgent tier: user-role message injection
  // ──────────────────────────────────────────────────────���──────────
  group('injectParallelSingleCallHintAsUserMessage (urgent wire format)', () {
    test('OpenAI: pushes a new user-role message after the tool results', () {
      final msgs = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'go'},
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {
              'id': 'a',
              'type': 'function',
              'function': {'name': 'read', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'a', 'content': 'file contents'},
      ];

      injectParallelSingleCallHintAsUserMessage(
        msgs,
        isAnthropic: false,
        consecutiveCount: 30,
      );

      // Length grew by exactly one — the new user message.
      expect(msgs, hasLength(4));
      final newMsg = msgs.last;
      expect(
        newMsg['role'],
        'user',
        reason: 'urgent tier must surface as a user-role message',
      );
      final content = newMsg['content'] as String;
      // The urgent-tier body is user-voice coaching rather than
      // meta-commentary, so the integer counter is gone. Pin the
      // educational definition of "parallel tool calls" instead —
      // that's the load-bearing content the urgent tier was
      // rewritten to deliver.
      expect(content, contains('"parallel tool calls"'));
      expect(content, contains('parallel tool calls'));
      // And the wire-format guidance that names the Anthropic /
      // OpenAI shape directly, since the model has evidently not
      // been inferring it from context.
      expect(content, contains('tool_use blocks'));
      expect(content, contains('tool_calls array'));
      // CRITICAL: the urgent-tier user message must NOT carry the
      // `[Crux system note — …]` marker. The whole point of
      // escalating to a user-role message is for the LLM to read
      // it as the human speaking — a bracketed system tag would
      // re-introduce the "ignoreable system tag" pattern the
      // urgent tier exists to escape. See
      // `renderParallelSingleCallHintUserMessage` docstring.
      expect(
        content,
        isNot(
          contains(parallelSingleCallHintMarker(SingleCallHintSeverity.urgent)),
        ),
        reason: 'urgent-tier user message must not carry a system-note marker',
      );
      expect(
        content,
        isNot(
          contains(parallelSingleCallHintMarker(SingleCallHintSeverity.mild)),
        ),
      );
      expect(
        content,
        isNot(
          contains(parallelSingleCallHintMarker(SingleCallHintSeverity.firm)),
        ),
      );
      // And NOT the praise marker — this is the corrective signal,
      // not the positive one.
      expect(content, isNot(contains(parallelHintEmbeddedMarker)));
    });

    test('Anthropic: pushes a user message with a single text block', () {
      final msgs = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'go'},
        {
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': 'a', 'name': 'read', 'input': {}},
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'a',
              'content': 'file contents',
            },
          ],
        },
      ];

      injectParallelSingleCallHintAsUserMessage(
        msgs,
        isAnthropic: true,
        consecutiveCount: 30,
      );

      // Two user messages now: one with tool_results, one with the
      // urgent hint as a text block.
      expect(msgs, hasLength(4));
      final newMsg = msgs.last;
      expect(newMsg['role'], 'user');
      final blocks = newMsg['content'] as List;
      expect(blocks, hasLength(1), reason: 'exactly one text block');
      final block = blocks.first;
      expect(block['type'], 'text');
      final text = block['text'] as String;
      expect(text, contains('"parallel tool calls"'));
      expect(text, contains('tool_use blocks'));
      expect(text, contains('tool_calls array'));
      // Same critical assertion as the OpenAI branch: no
      // system-note marker on the urgent-tier user message.
      expect(
        text,
        isNot(
          contains(parallelSingleCallHintMarker(SingleCallHintSeverity.urgent)),
        ),
        reason: 'urgent-tier user message must not carry a system-note marker',
      );
      expect(text, isNot(contains(parallelHintEmbeddedMarker)));
    });

    test('count=30 (default threshold) routes to urgent, not mild', () {
      // Sanity check that the tier math picks the urgent tier at
      // round 30 with default threshold — without this, the chat
      // service's branch would always pick the tool-result
      // helper and the user-message helper would never be
      // exercised in normal use.
      expect(singleCallHintSeverityFor(30), SingleCallHintSeverity.urgent);
      expect(
        singleCallHintSeverityFor(20),
        isNot(SingleCallHintSeverity.urgent),
      );
    });
  });

  // ────────────────────��────────────────────────────────────────────────
  // 2. LLM-provider resolver (precedence)
  // ─────────────────────────────────────────────────────────────────────
  group('LlmProvider.effectiveHintParallelCallsFor (toggle)', () {
    final llm = OpenAICompatibleProvider();

    test('defaults to true when no override is set', () {
      expect(
        llm.effectiveHintParallelCallsFor(),
        isTrue,
        reason: 'class default should be true',
      );
      expect(
        llm.effectiveHintParallelCallsFor(
          modelOverride: null,
          providerOverride: null,
        ),
        isTrue,
      );
    });

    test('model override beats provider override', () {
      expect(
        llm.effectiveHintParallelCallsFor(
          modelOverride: false,
          providerOverride: true,
        ),
        isFalse,
      );
      expect(
        llm.effectiveHintParallelCallsFor(
          modelOverride: true,
          providerOverride: false,
        ),
        isTrue,
      );
    });

    test('provider override beats class default', () {
      expect(
        llm.effectiveHintParallelCallsFor(providerOverride: false),
        isFalse,
      );
    });

    test('class default is overridable on a subclass', () {
      final silent = _SilentProvider();
      expect(silent.defaultHintParallelCalls, isFalse);
      expect(
        silent.effectiveHintParallelCallsFor(),
        isFalse,
        reason: 'subclass default should propagate when no TOML override',
      );
      // But a provider-level TOML `true` still wins over the class default.
      expect(
        silent.effectiveHintParallelCallsFor(providerOverride: true),
        isTrue,
      );
    });
  });

  group(
    'LlmProvider.effectiveHintParallelCallsSingleThresholdFor (threshold)',
    () {
      final llm = OpenAICompatibleProvider();

      test('defaults to 10 when no override is set', () {
        expect(
          llm.effectiveHintParallelCallsSingleThresholdFor(),
          equals(10),
          reason: 'class default should be 10',
        );
        expect(
          llm.effectiveHintParallelCallsSingleThresholdFor(
            modelOverride: null,
            providerOverride: null,
          ),
          equals(10),
        );
      });

      test('model override beats provider override', () {
        expect(
          llm.effectiveHintParallelCallsSingleThresholdFor(
            modelOverride: 5,
            providerOverride: 20,
          ),
          equals(5),
        );
        expect(
          llm.effectiveHintParallelCallsSingleThresholdFor(
            modelOverride: 50,
            providerOverride: 20,
          ),
          equals(50),
        );
      });

      test('provider override beats class default', () {
        expect(
          llm.effectiveHintParallelCallsSingleThresholdFor(
            providerOverride: 25,
          ),
          equals(25),
        );
      });

      test('class default is overridable on a subclass', () {
        final override = _ThresholdOverrideProvider();
        expect(override.defaultHintParallelCallsSingleThreshold, equals(3));
        expect(
          override.effectiveHintParallelCallsSingleThresholdFor(),
          equals(3),
          reason: 'subclass default should propagate when no TOML override',
        );
        // But a provider-level TOML still wins over the class default.
        expect(
          override.effectiveHintParallelCallsSingleThresholdFor(
            providerOverride: 50,
          ),
          equals(50),
        );
      });

      test('0 is a valid override (used in tests for "always fire")', () {
        // 0 collapses the modulo gate to "always fire" — useful for
        // testing but never useful in production. The resolver
        // should pass it through untouched rather than treating it
        // as "absent".
        expect(
          llm.effectiveHintParallelCallsSingleThresholdFor(modelOverride: 0),
          equals(0),
        );
      });
    },
  );

  // ─────────────────────────────────────────────────────────────────────
  // 3. TOML parsing
  // ─────────────────────────────────────────────────────────────────────
  group('ProviderConfigLoader — hint_parallel_calls', () {
    late Directory tempDir;
    late ProviderConfigLoader loader;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_praise_');
      loader = ProviderConfigLoader(providersDir: tempDir);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    Future<void> writeProvider(String body) async {
      final f = File('${tempDir.path}/custom.toml');
      await f.writeAsString(body);
      await loader.loadAll();
    }

    test('defaults to null on both provider and model', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      final p = loader.providerByName('custom')!;
      expect(p.hintParallelCalls, isNull);
      expect(p.hintParallelCallsSingleThreshold, isNull);
      expect(p.models.first.hintParallelCalls, isNull);
      expect(p.models.first.hintParallelCallsSingleThreshold, isNull);
    });

    test('provider-level override parses to true', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"
hint_parallel_calls = true

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      expect(loader.providerByName('custom')!.hintParallelCalls, isTrue);
    });

    test('provider-level override parses to false', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"
hint_parallel_calls = false

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      expect(loader.providerByName('custom')!.hintParallelCalls, isFalse);
    });

    test('model-level override parses independently', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"

[[models]]
id = "m1"
name = "M1"
context_size = 1000
hint_parallel_calls = false
''');
      final p = loader.providerByName('custom')!;
      expect(p.hintParallelCalls, isNull);
      expect(p.models.first.hintParallelCalls, isFalse);
    });

    test('non-boolean value is rejected with FormatException', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"
hint_parallel_calls = "yes"

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      // Loader catches the parse error and records it; the provider
      // simply doesn't appear in the index.
      expect(loader.providerByName('custom'), isNull);
      expect(loader.loadErrors(), isNotEmpty);
    });

    test(
      'legacy praise_parallel_calls key is still accepted at provider level',
      () async {
        await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"
praise_parallel_calls = true

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
        // The legacy name should round-trip through the same field.
        expect(
          loader.providerByName('custom')!.hintParallelCalls,
          isTrue,
          reason: 'legacy key must still resolve to hintParallelCalls',
        );
      },
    );

    test(
      'legacy praise_parallel_calls key is still accepted at model level',
      () async {
        await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"

[[models]]
id = "m1"
name = "M1"
context_size = 1000
praise_parallel_calls = false
''');
        final p = loader.providerByName('custom')!;
        expect(p.models.first.hintParallelCalls, isFalse);
      },
    );

    test('new key wins when both new and legacy keys are present', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"
hint_parallel_calls = false
praise_parallel_calls = true

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      // The legacy key disagrees (true) but the new key (false) wins.
      expect(
        loader.providerByName('custom')!.hintParallelCalls,
        isFalse,
        reason: 'new key should win over legacy key on conflict',
      );
    });

    test('legacy key with wrong type alongside valid new key surfaces '
        'a clear error', () async {
      // The new key is valid (false), but the legacy key is a
      // string. The loader should reject the whole config rather
      // than silently co-exist — otherwise a malformed legacy
      // value would be invisible to the user.
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"
hint_parallel_calls = false
praise_parallel_calls = "yes"

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      expect(loader.providerByName('custom'), isNull);
      final errors = loader.loadErrors().values.join('\n');
      expect(
        errors,
        contains('praise_parallel_calls'),
        reason: 'error message should name the legacy key',
      );
      expect(
        errors,
        contains('deprecated'),
        reason: 'error message should hint at migration',
      );
    });
  });

  group('ProviderConfigLoader — hint_parallel_calls_single_threshold', () {
    late Directory tempDir;
    late ProviderConfigLoader loader;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_threshold_');
      loader = ProviderConfigLoader(providersDir: tempDir);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    Future<void> writeProvider(String body) async {
      final f = File('${tempDir.path}/custom.toml');
      await f.writeAsString(body);
      await loader.loadAll();
    }

    test('defaults to null on both provider and model', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      final p = loader.providerByName('custom')!;
      expect(p.hintParallelCallsSingleThreshold, isNull);
      expect(p.models.first.hintParallelCallsSingleThreshold, isNull);
    });

    test('provider-level threshold parses', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"
hint_parallel_calls_single_threshold = 25

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      expect(
        loader.providerByName('custom')!.hintParallelCallsSingleThreshold,
        equals(25),
      );
    });

    test('model-level threshold parses independently', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"

[[models]]
id = "m1"
name = "M1"
context_size = 1000
hint_parallel_calls_single_threshold = 5
''');
      final p = loader.providerByName('custom')!;
      expect(p.hintParallelCallsSingleThreshold, isNull);
      expect(p.models.first.hintParallelCallsSingleThreshold, equals(5));
    });

    test('0 is accepted (the modulo gate collapses to "always")', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"
hint_parallel_calls_single_threshold = 0

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      expect(
        loader.providerByName('custom')!.hintParallelCallsSingleThreshold,
        equals(0),
      );
    });

    test('negative value is rejected with FormatException', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"
hint_parallel_calls_single_threshold = -1

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      expect(loader.providerByName('custom'), isNull);
      final errors = loader.loadErrors().values.join('\n');
      expect(errors, contains('>= 0'));
    });

    test('non-integer value is rejected with FormatException', () async {
      await writeProvider('''
type = "openai_compatible"
endpoint_url = "https://example.com/v1"
hint_parallel_calls_single_threshold = "ten"

[[models]]
id = "m1"
name = "M1"
context_size = 1000
''');
      expect(loader.providerByName('custom'), isNull);
      final errors = loader.loadErrors().values.join('\n');
      expect(errors, contains('must be an integer'));
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // 4. End-to-end persistence: parallel_praise row + value integrity
  // ─────────────────────────────────────────────────────────────────────
  group('MessageStore — parallel_praise persistence', () {
    late CruxDatabase db;
    late SessionStore store;
    late int sessionId;

    setUp(() async {
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      final session = await store.create(
        title: 'praise',
        model: 'openai/gpt-4o',
        projectPath: '/tmp',
      );
      sessionId = session.id;
    });

    tearDown(() async {
      await db.close();
    });

    test('addMessage with role=parallel_praise stores parallelCount', () async {
      final msg = await store.messageStore.addMessage(
        sessionId,
        role: 'parallel_praise',
        content: renderParallelPraiseBubbleLabel(3),
        parallelCount: 3,
      );
      expect(msg.role, 'parallel_praise');
      expect(msg.parallelCount, 3);
      expect(msg.content, contains('3 tool calls parallelized'));

      // Round-trip through the DB to confirm the column persists.
      final loaded = (await store.messageStore.getMessages(sessionId)).first;
      expect(loaded.role, 'parallel_praise');
      expect(loaded.parallelCount, 3);
    });

    test('addMessage without parallelCount defaults to 0', () async {
      final msg = await store.messageStore.addMessage(
        sessionId,
        role: 'user',
        content: 'hi',
      );
      expect(msg.parallelCount, 0);
    });

    test(
      'parallel_praise row appears after a tool_call row in order',
      () async {
        await store.messageStore.addMessage(
          sessionId,
          role: 'user',
          content: 'q',
        );
        await store.messageStore.addToolRound(
          sessionId,
          roundText: '',
          toolCalls: [
            ToolCallData(callId: 'a', name: 'grep', input: {}),
            ToolCallData(callId: 'b', name: 'read', input: {}),
          ],
          results: [
            (callId: 'a', output: 'match', meta: ''),
            (callId: 'b', output: 'contents', meta: ''),
          ],
        );
        await store.messageStore.addMessage(
          sessionId,
          role: 'parallel_praise',
          content: renderParallelPraiseBubbleLabel(2),
          parallelCount: 2,
        );

        final msgs = await store.messageStore.getMessages(sessionId);
        // The renderer relies on this order to draw the praise inline
        // directly below the matching tool-call list.
        expect(msgs.map((m) => m.role).toList(), [
          'user',
          'tool_call',
          'tool',
          'tool',
          'parallel_praise',
        ]);
        expect(msgs.last.parallelCount, 2);
      },
    );
  });

  // ─────────────────────────────────────────────────────────────────────
  // 5. End-to-end persistence: single_call_reminder row + value integrity
  //
  // Mirrors the parallel_praise persistence group above. The
  // `parallelCount` column is reused as the "telemetry int" for both
  // system-role bubbles — for `single_call_reminder` rows it carries
  // the consecutive single-call round count rather than the
  // parallelised call count. The renderer dispatches on `role` and
  // interprets the value with the role-appropriate meaning.
  // ─────────────────────────────────────────────────────────────────────
  group('MessageStore — single_call_reminder persistence', () {
    late CruxDatabase db;
    late SessionStore store;
    late int sessionId;

    setUp(() async {
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      final session = await store.create(
        title: 'reminder',
        model: 'openai/gpt-4o',
        projectPath: '/tmp',
      );
      sessionId = session.id;
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'addMessage with role=single_call_reminder stores consecutiveCount',
      () async {
        final msg = await store.messageStore.addMessage(
          sessionId,
          role: 'single_call_reminder',
          content: renderSingleCallReminderBubbleLabel(10),
          parallelCount: 10,
        );
        expect(msg.role, 'single_call_reminder');
        expect(msg.parallelCount, 10);
        expect(msg.content, contains('10 consecutive single-tool-call rounds'));

        // Round-trip through the DB to confirm the column persists.
        final loaded = (await store.messageStore.getMessages(sessionId)).first;
        expect(loaded.role, 'single_call_reminder');
        expect(loaded.parallelCount, 10);
      },
    );

    test(
      'single_call_reminder row appears after a tool_call row in order',
      () async {
        await store.messageStore.addMessage(
          sessionId,
          role: 'user',
          content: 'q',
        );
        await store.messageStore.addToolRound(
          sessionId,
          roundText: '',
          toolCalls: [
            // Single tool call (drift round) — produces one tool row.
            ToolCallData(callId: 'a', name: 'read', input: {}),
          ],
          results: [(callId: 'a', output: 'contents', meta: '')],
        );
        await store.messageStore.addMessage(
          sessionId,
          role: 'single_call_reminder',
          content: renderSingleCallReminderBubbleLabel(10),
          parallelCount: 10,
        );

        final msgs = await store.messageStore.getMessages(sessionId);
        // Same inline-under-the-tool-call-list ordering contract as
        // the praise bubble: the renderer draws the reminder
        // directly below the matching tool-call row.
        expect(msgs.map((m) => m.role).toList(), [
          'user',
          'tool_call',
          'tool',
          'single_call_reminder',
        ]);
        expect(msgs.last.parallelCount, 10);
      },
    );

    test(
      'parallel_praise and single_call_reminder can coexist in one session',
      () async {
        // Round 1: praise (batched).
        await store.messageStore.addMessage(
          sessionId,
          role: 'user',
          content: 'q',
        );
        await store.messageStore.addToolRound(
          sessionId,
          roundText: '',
          toolCalls: [
            ToolCallData(callId: 'a', name: 'grep', input: {}),
            ToolCallData(callId: 'b', name: 'read', input: {}),
          ],
          results: [
            (callId: 'a', output: 'match', meta: ''),
            (callId: 'b', output: 'contents', meta: ''),
          ],
        );
        await store.messageStore.addMessage(
          sessionId,
          role: 'parallel_praise',
          content: renderParallelPraiseBubbleLabel(2),
          parallelCount: 2,
        );
        // Round 2: drift (single call) + reminder.
        await store.messageStore.addMessage(
          sessionId,
          role: 'user',
          content: 'q2',
        );
        await store.messageStore.addToolRound(
          sessionId,
          roundText: '',
          toolCalls: [ToolCallData(callId: 'c', name: 'read', input: {})],
          results: [(callId: 'c', output: 'contents', meta: '')],
        );
        await store.messageStore.addMessage(
          sessionId,
          role: 'single_call_reminder',
          content: renderSingleCallReminderBubbleLabel(10),
          parallelCount: 10,
        );

        final msgs = await store.messageStore.getMessages(sessionId);
        expect(msgs.map((m) => m.role).toList(), [
          'user',
          'tool_call',
          'tool',
          'tool',
          'parallel_praise',
          'user',
          'tool_call',
          'tool',
          'single_call_reminder',
        ]);
      },
    );
  });
}
