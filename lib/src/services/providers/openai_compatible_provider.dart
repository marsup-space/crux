import '../../models/provider_config.dart';
import '../llm_provider.dart';

class OpenAICompatibleProvider extends LlmProvider {
  @override
  String get name => 'openai_compatible';

  @override
  WireFamily get wire => WireFamily.openaiCompatible;

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    double temperature = 0,
    double topP = 1.0,
    List<Map<String, dynamic>>? tools,
    String? userId,
  }) {
    return {
      'model': modelId,
      'messages': messages,
      'stream': true,
      'stream_options': {'include_usage': true},
      'temperature': temperature,
      // Nucleus-sampling ceiling — derived from `temperature` by
      // `chat_turn_executor.topPForTemperature` so the two always
      // move together. OpenAI accepts [0.0, 1.0] and recommends
      // altering either this OR temperature (we pair them
      // automatically).
      'top_p': topP,
      'thinking': {'type': thinkingMode},
      if (thinkingMode != 'disabled' && reasoningEffort != null)
        'reasoning_effort': mapEffort(reasoningEffort),
      'max_completion_tokens': ?maxTokens,
      if (tools != null && tools.isNotEmpty)
        'tools': tools
            .map(
              (t) => {
                'type': 'function',
                'function': {
                  'name': t['name'],
                  'description': t['description'],
                  'parameters': t['parameters'],
                },
              },
            )
            .toList(),
      'user_id': ?userId,
    };
  }

  String mapEffort(String? effort) {
    switch (effort) {
      case 'normal':
        return 'high';
      case 'high':
        return 'high';
      case 'max':
        return 'max';
      default:
        return 'high';
    }
  }

  /// Enforce the OpenAI Chat Completions tool_call ↔ tool message
  /// pairing invariant on the wire-format message list.
  ///
  /// The OpenAI protocol requires:
  ///   - Every `tool_call` in an assistant message's `tool_calls`
  ///     array must be followed by a `role: 'tool'` message whose
  ///     `tool_call_id` matches.
  ///   - Those `tool` messages must immediately follow the assistant
  ///     message — no user or other assistant messages in between.
  ///   - Every `role: 'tool'` message must respond to a preceding
  ///     `assistant` `tool_call`.
  ///
  /// Crux's storage layer generally maintains this invariant (the
  /// [addToolRound] transaction wraps the tool_call row and all of
  /// its matching tool result rows so they're all-or-nothing), but
  /// it can still be violated in two real situations:
  ///
  ///   1. **Mid-round interruption.** A `tool_call` row is persisted
  ///      but the tool results for some of its calls haven't been
  ///      written yet (the `addToolRound` transaction is in flight,
  ///      or the round aborted before the persist step ran). The
  ///      next request sees an incomplete tool flow.
  ///   2. **Wire-family switch.** When the user changes the session
  ///      model from a provider using the Anthropic wire family
  ///      (MiniMax, etc.) to one using the OpenAI wire family
  ///      (DeepSeek, plain OpenAI-compatible), Crux re-serializes
  ///      the persisted history with the new wire format. Anything
  ///      that was acceptable in the Anthropic shape (a bare
  ///      tool_use block without a matching tool_result, or a
  ///      half-persisted round) can become a malformed OpenAI
  ///      payload that the new endpoint rejects with a 400 error
  ///      like "an assistant message with tool_call must be
  ///      followed by tool messages responding to each
  ///      tool_call_id".
  ///
  /// The fix: walk the list once, identify the orphan `tool_call_id`s
  /// (any tool_call that isn't immediately followed by a matching
  /// `tool` message, and any `tool` message whose preceding assistant
  /// message didn't announce its id). Rebuild the list with the
  /// orphans removed:
  ///   - On an `assistant` message, drop the orphan entries from
  ///     the `tool_calls` array (or remove the array entirely if
  ///     every entry is orphan). The assistant's text content is
  ///     always preserved.
  ///   - On a `role: 'tool'` message with an orphan id, drop the
  ///     whole message.
  ///
  /// User, system, and tool_call-free assistant messages pass
  /// through untouched. The function never deletes text content,
  /// only broken tool plumbing.
  ///
  /// Returns the original list reference unchanged when no orphans
  /// are detected, so the well-formed-history fast path is free.
  @override
  List<Map<String, dynamic>> sanitizeMessages(
    List<Map<String, dynamic>> messages,
  ) {
    return _enforceToolCallPairing(messages);
  }

  static List<Map<String, dynamic>> _enforceToolCallPairing(
    List<Map<String, dynamic>> messages,
  ) {
    // Two-pass: first find the orphan callIds, then rebuild the
    // list with orphans pruned. We do a single forward walk in
    // pass 1 to detect orphans; pass 2 is a second forward walk
    // to emit the repaired list. Two passes is O(n) and avoids
    // any lookahead in the emit pass.

    final orphanCallIds = <String>{};
    // Tracks whether any tool message had no `tool_call_id` (or a
    // non-String one). We can't record these as orphans by id, but
    // they still need to be dropped in pass 2, so the fast-path
    // early-return must consult this flag too.
    var hasMalformedToolMessage = false;
    Set<String>? pending;

    for (final m in messages) {
      final role = m['role'];
      if (role == 'assistant') {
        final toolCalls = m['tool_calls'] as List?;
        if (toolCalls != null && toolCalls.isNotEmpty) {
          // New assistant message with tool_calls. Any still-pending
          // tool_calls from a previous assistant message are now
          // confirmed orphan (they were not responded to before the
          // next assistant turn — which the protocol forbids).
          if (pending != null) {
            orphanCallIds.addAll(pending);
          }
          pending = <String>{
            for (final tc in toolCalls)
              if (tc is Map && tc['id'] is String) tc['id'] as String,
          };
        } else {
          // Assistant without tool_calls terminates the pending
          // tool flow.
          if (pending != null) {
            orphanCallIds.addAll(pending);
            pending = null;
          }
        }
      } else if (role == 'tool') {
        final callId = m['tool_call_id'] as String?;
        if (callId == null) {
          // Malformed tool message (no call id). Always drop.
          hasMalformedToolMessage = true;
          continue;
        }
        if (pending == null || !pending.remove(callId)) {
          // Either there's no preceding assistant with tool_calls,
          // or this id wasn't one of them. Orphan.
          orphanCallIds.add(callId);
        }
      } else {
        // user / system / anything else terminates the pending
        // tool flow. A user message sandwiched between a tool_call
        // assistant and its tool results is the canonical "interrupted
        // tool flow" symptom.
        if (pending != null) {
          orphanCallIds.addAll(pending);
          pending = null;
        }
      }
    }
    // End of input — anything still pending is orphan (its tool
    // results were never written).
    if (pending != null) {
      orphanCallIds.addAll(pending);
    }

    if (orphanCallIds.isEmpty && !hasMalformedToolMessage) return messages;

    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'];
      if (role == 'assistant') {
        final toolCalls = m['tool_calls'] as List?;
        if (toolCalls != null && toolCalls.isNotEmpty) {
          final kept = <Map<String, dynamic>>[
            for (final tc in toolCalls.cast<Map<String, dynamic>>())
              if (tc['id'] is String && !orphanCallIds.contains(tc['id']))
                tc,
          ];
          if (kept.length != toolCalls.length) {
            final patched = <String, dynamic>{...m};
            if (kept.isEmpty) {
              patched.remove('tool_calls');
            } else {
              patched['tool_calls'] = kept;
            }
            out.add(patched);
            continue;
          }
        }
        out.add(m);
      } else if (role == 'tool') {
        final callId = m['tool_call_id'] as String?;
        // Drop tool messages with no id (malformed — there's no
        // preceding assistant to associate it with) and any whose
        // id was marked orphan in pass 1.
        if (callId == null) continue;
        if (orphanCallIds.contains(callId)) continue;
        out.add(m);
      } else {
        out.add(m);
      }
    }
    return out;
  }
}
