// Tests for the auto-compaction algorithm.
//
// Two pure functions, both static on `ChatService`, are the contract:
//
//   * `computeCompactionReserveAndThreshold(contextSize)`
//     — the reserve (flat 40k) and threshold (`contextSize - 40k`)
//     that decide whether auto-compact fires.
//
//   * `estimateProjectedContextTokens({session, history, ...})`
//     — the next-turn projected prompt size. Has three paths:
//       1. session.contextTokens > 0 → use it directly + incoming user
//       2. contextTokens == 0 but some AI turn has tokens → use the
//          LAST AI message's tokensIn+tokensOut-reasoning (single
//          value, NOT a sum — summing N AI messages would give
//          N×finalPrompt because each AI's prompt is already cumulative)
//       3. no AI turn has tokens → best-effort estimate from raw content
//
// These tests pin the contract against the two bugs that motivated the
// rewrite (`b4ac61d` only fixed the primary path; the fallback still
// summed per-message cumulative `tokensIn`, blowing up the projection
// to several × contextSize and triggering compaction incorrectly).

import 'package:test/test.dart';

import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/chat_service.dart';

Message _ai({
  required int id,
  required int tokensIn,
  int tokensOut = 0,
  int reasoningTokens = 0,
  String content = 'reply',
}) {
  return Message(
    id: id,
    sessionId: 1,
    role: 'ai',
    content: content,
    tokensIn: tokensIn,
    tokensOut: tokensOut,
    reasoningTokens: reasoningTokens,
  );
}

Message _user({required int id, String content = 'hi'}) {
  return Message(id: id, sessionId: 1, role: 'user', content: content);
}

Message _toolResult({required int id, String content = 'ok'}) {
  return Message(id: id, sessionId: 1, role: 'tool', content: content);
}

Session _session({int contextTokens = 0, String model = 'minimax/MiniMax-M3'}) {
  return Session(id: 1, model: model, contextTokens: contextTokens);
}

void main() {
  group('computeCompactionReserveAndThreshold', () {
    test('flat 40k reserve regardless of contextSize', () {
      // Reserve is intentionally constant. Per-model reserve tuning
      // (proportional to maxTokens, capped at some fraction of
      // context) is a separate design question — out of scope here.
      const cases = [1000000, 204800, 128000, 32768];
      for (final ctx in cases) {
        final rt = ChatService.computeCompactionReserveAndThreshold(
          contextSize: ctx,
        );
        expect(rt.reserve, 40000, reason: 'contextSize=$ctx');
        expect(rt.threshold, ctx - 40000, reason: 'contextSize=$ctx');
      }
    });

    test('threshold is always contextSize - reserve', () {
      const cases = [1000000, 204800, 128000, 32768];
      for (final ctx in cases) {
        final rt = ChatService.computeCompactionReserveAndThreshold(
          contextSize: ctx,
        );
        expect(
          rt.reserve + rt.threshold,
          ctx,
          reason: 'contextSize=$ctx',
        );
      }
    });
  });

  group('estimateProjectedContextTokens — primary path', () {
    test('uses session.contextTokens + incoming when set', () {
      final session = _session(contextTokens: 100000);
      final projected = ChatService.estimateProjectedContextTokens(
        session: session,
        systemPrompt: 'sys',
        history: [_ai(id: 1, tokensIn: 80000, tokensOut: 2000)],
        incomingUserContent: 'next question',
        toolDefs: const [],
      );
      // 100000 + estimateTokens('next question') (14 ASCII chars → 4 tokens)
      expect(projected, 100004);
    });

    test('null incoming user content leaves projection unchanged', () {
      final session = _session(contextTokens: 100000);
      final projected = ChatService.estimateProjectedContextTokens(
        session: session,
        systemPrompt: 'sys',
        history: const [],
        incomingUserContent: null,
        toolDefs: const [],
      );
      expect(projected, 100000);
    });
  });

  group('estimateProjectedContextTokens — fallback (contextTokens == 0)', () {
    test('uses last AI tokensIn+tokensOut-reasoning (NOT sum of all)', () {
      // Regression test for the Bug B fallback double-count. Two AI
      // messages each with cumulative-ish tokensIn — the projection
      // MUST use only the last one.
      final session = _session(contextTokens: 0);
      final history = [
        _user(id: 1),
        _ai(id: 2, tokensIn: 50000, tokensOut: 5000, reasoningTokens: 0),
        _user(id: 3),
        _toolResult(id: 4),
        _ai(id: 5, tokensIn: 100000, tokensOut: 3000, reasoningTokens: 500),
      ];
      final projected = ChatService.estimateProjectedContextTokens(
        session: session,
        systemPrompt: 'sys',
        history: history,
        incomingUserContent: 'more',
        toolDefs: const [],
      );
      // Last AI: 100000 + 3000 - 500 = 102500. Plus incoming user
      // content 'more' (4 ASCII chars → estimateTokens returns
      // ceil(4/4) = 1 token).
      expect(projected, 102501);
    });

    test('skips AI messages without tokens, picks the most recent one', () {
      // Empty AI messages (Bug A victims) shouldn't be picked. Walk
      // past them to find the LAST one with tokensIn > 0.
      final session = _session(contextTokens: 0);
      final history = [
        _user(id: 1),
        _ai(id: 2, tokensIn: 50000, tokensOut: 1000),
        _ai(id: 3, tokensIn: 0, tokensOut: 0, content: ''), // empty
        _user(id: 4),
        _ai(id: 5, tokensIn: 80000, tokensOut: 2000),
      ];
      final projected = ChatService.estimateProjectedContextTokens(
        session: session,
        systemPrompt: 'sys',
        history: history,
        incomingUserContent: null,
        toolDefs: const [],
      );
      // Last AI with tokens: id 5 → 80000 + 2000 = 82000.
      expect(projected, 82000);
    });

    test('falls through to raw-content estimate when no AI has tokens', () {
      // Fresh session — no AI turns yet. The estimate should be from
      // system + tools + raw content, not 0.
      final session = _session(contextTokens: 0);
      final history = [_user(id: 1, content: 'hello world')];
      final projected = ChatService.estimateProjectedContextTokens(
        session: session,
        systemPrompt: 'short system',
        history: history,
        incomingUserContent: null,
        toolDefs: const [],
      );
      // 'short system' (12 ASCII) + 'hello world' (11 ASCII) + nothing
      // else. estimateTokens uses (chars/4).ceil() per rune.
      // 12 → 3, 11 → 3 → total 6.
      expect(projected, greaterThan(0));
      expect(projected, lessThan(20));
    });
  });

  group('auto-compact threshold decision (algorithm-level)', () {
    test('M3: 130k projection does NOT trigger (threshold = 960k)', () {
      // The user's reported scenario: at 130k context on M3, the
      // algorithm should NOT compact. Threshold = 1M - 40k = 960k,
      // so 130k is well under.
      final session = _session(contextTokens: 130000);
      final projected = ChatService.estimateProjectedContextTokens(
        session: session,
        systemPrompt: null,
        history: const [],
        incomingUserContent: null,
        toolDefs: const [],
      );
      final rt = ChatService.computeCompactionReserveAndThreshold(
        contextSize: 1000000,
      );
      expect(rt.threshold, 960000);
      expect(projected > rt.threshold, isFalse,
          reason: '130k on 1M-context M3 must NOT trigger');
    });

    test('M3: 970k projection DOES trigger', () {
      final session = _session(contextTokens: 970000);
      final projected = ChatService.estimateProjectedContextTokens(
        session: session,
        systemPrompt: null,
        history: const [],
        incomingUserContent: null,
        toolDefs: const [],
      );
      final rt = ChatService.computeCompactionReserveAndThreshold(
        contextSize: 1000000,
      );
      expect(projected > rt.threshold, isTrue);
    });

    test('Bug B regression: summed fallback no longer triggers at 130k',
        () {
      // With the OLD buggy fallback (summing per-message cumulative
      // tokensIn), a session with even 2-3 AI messages would project
      // to 500k-1M+ even though actual context was 100-200k. Verify
      // the new fallback does NOT do this.
      final session = _session(contextTokens: 0);
      final history = [
        _user(id: 1),
        _ai(id: 2, tokensIn: 100000, tokensOut: 2000), // turn 1: 100k
        _user(id: 3),
        _ai(id: 4, tokensIn: 130000, tokensOut: 3000), // turn 2: 130k
        _user(id: 5),
        _ai(id: 6, tokensIn: 150000, tokensOut: 4000), // turn 3: 150k
      ];
      final projected = ChatService.estimateProjectedContextTokens(
        session: session,
        systemPrompt: null,
        history: history,
        incomingUserContent: null,
        toolDefs: const [],
      );
      // Last AI = 150000 + 4000 = 154000. NOT a sum (which would be
      // 389000). On M3 (threshold 960k), neither triggers — correct.
      expect(projected, 154000,
          reason: 'must use only the last AI, not sum across history');
      final rt = ChatService.computeCompactionReserveAndThreshold(
        contextSize: 1000000,
      );
      expect(projected > rt.threshold, isFalse);
    });

    test('128k example: triggers earlier than M3 (smaller ctx)', () {
      // On a 128k-context model with flat 40k reserve, threshold is
      // 88k. A session at 115k definitely triggers.
      final session = _session(contextTokens: 115000);
      final projected = ChatService.estimateProjectedContextTokens(
        session: session,
        systemPrompt: null,
        history: const [],
        incomingUserContent: null,
        toolDefs: const [],
      );
      final rt = ChatService.computeCompactionReserveAndThreshold(
        contextSize: 128000,
      );
      expect(rt.threshold, 88000);
      expect(projected > rt.threshold, isTrue);
    });
  });
}