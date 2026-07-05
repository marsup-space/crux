import '../../models/provider_config.dart';
import '../llm_provider.dart';

class AnthropicCompatibleProvider extends LlmProvider {
  @override
  String get name => 'anthropic_compatible';

  @override
  WireFamily get wire => WireFamily.anthropicCompatible;

  @override
  AuthStyle get authStyle => AuthStyle.anthropicApiKey;

  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    double temperature = 0,
    List<Map<String, dynamic>>? tools,
    String? userId,
  }) {
    final systemMsg = messages.where((m) => m['role'] == 'system').toList();
    final chatMsgs = messages.where((m) => m['role'] != 'system').toList();
    final body = <String, dynamic>{
      'model': modelId,
      'messages': injectCacheBreakpoints(chatMsgs),
      'max_tokens': maxTokens ?? 16384,
      'stream': true,
      'temperature': temperature,
    };
    if (systemMsg.isNotEmpty) {
      body['system'] = buildCachedSystemBlocks(systemMsg);
    }
    if (thinkingMode == 'enabled') {
      body['thinking'] = {
        'type': 'enabled',
        'budget_tokens': thinkingBudget ?? 10000,
      };
      if (reasoningEffort != null) {
        body['output_config'] = {
          'effort': mapEffort(reasoningEffort),
        };
      }
    }
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = buildCachedTools(tools);
    }
    return body;
  }

  List<Map<String, dynamic>> buildCachedSystemBlocks(
    List<Map<String, dynamic>> systemMsg,
  ) {
    if (systemMsg.isEmpty) return [];
    final blocks = systemMsg
        .map((m) => <String, dynamic>{
              'type': 'text',
              'text': m['content'] as String,
            })
        .toList();
    blocks.last['cache_control'] = <String, dynamic>{'type': 'ephemeral'};
    return blocks;
  }

  List<Map<String, dynamic>> buildCachedTools(
    List<Map<String, dynamic>> tools,
  ) {
    if (tools.isEmpty) return [];
    final result = tools
        .map((t) => <String, dynamic>{
              'name': t['name'],
              'description': t['description'],
              'input_schema': t['parameters'] as Map<String, dynamic>,
            })
        .toList();
    result.last['cache_control'] = <String, dynamic>{'type': 'ephemeral'};
    return result;
  }

  List<Map<String, dynamic>> injectCacheBreakpoints(
    List<Map<String, dynamic>> chatMsgs,
  ) {
    if (chatMsgs.isEmpty) return chatMsgs;
    final result = chatMsgs
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    final last = result.last;
    final content = last['content'];
    if (content == null) return result;
    if (content is String) {
      if (content.isEmpty) return result;
      last['content'] = <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'text',
          'text': content,
          'cache_control': <String, dynamic>{'type': 'ephemeral'},
        },
      ];
    } else if (content is List) {
      final blocks = content
          .map((b) => Map<String, dynamic>.from(b as Map))
          .toList();
      if (blocks.isNotEmpty) {
        blocks.last['cache_control'] = <String, dynamic>{'type': 'ephemeral'};
      }
      last['content'] = blocks;
    }
    return result;
  }

  String mapEffort(String? effort) {
    switch (effort) {
      case 'low':
        return 'low';
      case 'normal':
      case 'medium':
        return 'medium';
      case 'high':
        return 'high';
      case 'max':
        return 'max';
      default:
        return 'medium';
    }
  }

  /// Enforce the Anthropic tool_use ↔ tool_result pairing invariant
  /// on the wire-format message list.
  ///
  /// The Anthropic Messages protocol requires:
  ///   - Every `tool_use` block in an assistant message's `content`
  ///     list must be answered by a `role: 'user'` message that
  ///     contains a `tool_result` block with the matching
  ///     `tool_use_id`. Crux batches consecutive tool messages into a
  ///     single user message (see `buildApiMessages`), so the answer
  ///     is usually the very next message.
  ///   - `tool_result` blocks must immediately follow the assistant
  ///     `tool_use` — no intervening user/assistant message without
  ///     matching responses.
  ///   - Every `tool_result` block must respond to a preceding
  ///     assistant `tool_use`.
  ///
  /// Crux's storage layer generally maintains this invariant (the
  /// `addToolRound` transaction wraps the tool_call row and all of
  /// its matching tool result rows so they're all-or-nothing), but it
  /// can still be violated in two real situations:
  ///
  ///   1. **Mid-round interruption.** A `tool_call` row is persisted
  ///      but the tool results for some of its calls haven't been
  ///      written yet (the `addToolRound` transaction is in flight,
  ///      or the round aborted before the persist step ran). The
  ///      next request sees a dangling `tool_use` block in an
  ///      assistant message that nothing in the history answers.
  ///   2. **Wire-family switch.** When the user changes the session
  ///      model from a provider using the OpenAI wire family to one
  ///      using the Anthropic wire family (MiniMax etc.), Crux
  ///      re-serializes the persisted history with the new wire
  ///      format. Anything that was acceptable in the OpenAI shape
  ///      (an empty `tool_calls` array after orphan pruning, or a
  ///      half-persisted round) can become a malformed Anthropic
  ///      payload that the new endpoint rejects with a 400 error
  ///      like "tool result's tool id ... not found" (vendor code
  ///      2013 on MiniMax).
  ///
  /// The fix: walk the list once to identify the orphan `use_ids`
  /// (any `tool_use` block that isn't answered by a matching
  /// `tool_result` block, and any `tool_result` block whose preceding
  /// assistant message didn't announce its id). Rebuild the list
  /// with the orphans removed:
  ///   - On an `assistant` message, drop the orphan entries from the
  ///     `content` block list (or remove the whole message if every
  ///     surviving block was a `tool_use`). `thinking` and `text`
  ///     blocks are always preserved — a `thinking` block carries a
  ///     `signature` the API needs, so we never silently drop it.
  ///   - On a `role: 'user'` message, drop the orphan entries from
  ///     the `content` block list (or remove the whole message if
  ///     every surviving block was an orphan `tool_result`).
  ///
  /// System messages and tool_use-free assistant messages pass
  /// through untouched. The function never deletes text or thinking
  /// content, only broken tool plumbing.
  ///
  /// Returns the original list reference unchanged when no orphans
  /// are detected, so the well-formed-history fast path is free.
  @override
  List<Map<String, dynamic>> sanitizeMessages(
    List<Map<String, dynamic>> messages,
  ) {
    return _enforceToolUsePairing(messages);
  }

  static List<Map<String, dynamic>> _enforceToolUsePairing(
    List<Map<String, dynamic>> messages,
  ) {
    // Two-pass: first find the orphan useIds, then rebuild the
    // list with orphans pruned. We do a single forward walk in
    // pass 1 to detect orphans; pass 2 is a second forward walk
    // to emit the repaired list. Two passes is O(n) and avoids
    // any lookahead in the emit pass.

    final orphanUseIds = <String>{};
    // Tracks whether any tool_result block had no `tool_use_id`
    // (or a non-String one). We can't record these as orphans by
    // id, but they still need to be dropped in pass 2, so the
    // fast-path early-return must consult this flag too.
    var hasMalformedToolResult = false;
    Set<String>? pending;

    for (final m in messages) {
      final role = m['role'];
      if (role == 'assistant') {
        final ids = _collectToolUseIds(m['content']);
        if (ids.isNotEmpty) {
          // New assistant message with tool_use blocks. Any
          // still-pending tool_use blocks from a previous
          // assistant message are now confirmed orphan (they were
          // not responded to before the next assistant turn —
          // which the protocol forbids).
          if (pending != null) {
            orphanUseIds.addAll(pending);
          }
          pending = ids;
        } else {
          // Assistant without tool_use terminates the pending
          // tool flow.
          if (pending != null) {
            orphanUseIds.addAll(pending);
            pending = null;
          }
        }
      } else if (role == 'user') {
        // Walk the user message's content blocks. tool_result
        // blocks answer any pending tool_use ids by matching
        // tool_use_id; non-tool_result blocks (text/image) are
        // ignored for pairing purposes (they can't answer a
        // tool_use). After the user message, no more tool_result
        // blocks will arrive in this batch, so the still-pending
        // ids are orphan.
        final content = m['content'];
        if (content is List) {
          for (final block in content) {
            if (block is Map && block['type'] == 'tool_result') {
              final useId = block['tool_use_id'];
              if (useId is! String) {
                // Malformed tool_result block (no id). Always drop.
                hasMalformedToolResult = true;
                continue;
              }
              if (pending == null || !pending.remove(useId)) {
                // Either there's no preceding assistant with
                // tool_use, or this id wasn't one of them. Orphan.
                orphanUseIds.add(useId);
              }
            }
          }
        }
        // User message terminates the pending tool flow. A user
        // message sandwiched between an assistant tool_use and
        // its tool_result blocks is the canonical "interrupted
        // tool flow" symptom.
        if (pending != null) {
          orphanUseIds.addAll(pending);
          pending = null;
        }
      } else {
        // system / anything else terminates the pending tool flow.
        if (pending != null) {
          orphanUseIds.addAll(pending);
          pending = null;
        }
      }
    }
    // End of input — anything still pending is orphan (its tool
    // results were never written).
    if (pending != null) {
      orphanUseIds.addAll(pending);
    }

    if (orphanUseIds.isEmpty && !hasMalformedToolResult) return messages;

    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'];
      if (role == 'assistant') {
        final content = m['content'];
        if (content is! List) {
          out.add(m);
          continue;
        }
        final kept = <Map<String, dynamic>>[];
        var droppedToolUse = false;
        for (final block in content.cast<Map<String, dynamic>>()) {
          if (block['type'] == 'tool_use') {
            final id = block['id'];
            if (id is String && !orphanUseIds.contains(id)) {
              kept.add(block);
            } else {
              droppedToolUse = true;
            }
          } else {
            // thinking / text blocks pass through untouched.
            // We must never drop a `thinking` block — it carries
            // a `signature` the Anthropic API needs.
            kept.add(block);
          }
        }
        if (!droppedToolUse) {
          out.add(m);
          continue;
        }
        if (kept.isEmpty) {
          // The assistant message was ONLY tool_use, all orphan.
          // Drop the whole message — an assistant message with
          // no content blocks is invalid in Anthropic format.
          continue;
        }
        out.add({...m, 'content': kept});
      } else if (role == 'user') {
        final content = m['content'];
        if (content is! List) {
          out.add(m);
          continue;
        }
        final kept = <Map<String, dynamic>>[];
        var droppedToolResult = false;
        for (final block in content.cast<Map<String, dynamic>>()) {
          if (block['type'] == 'tool_result') {
            final useId = block['tool_use_id'];
            if (useId is! String) {
              // Malformed (no id). Always drop.
              droppedToolResult = true;
              continue;
            }
            if (orphanUseIds.contains(useId)) {
              droppedToolResult = true;
              continue;
            }
            kept.add(block);
          } else {
            // text / image blocks pass through untouched.
            kept.add(block);
          }
        }
        if (!droppedToolResult) {
          out.add(m);
          continue;
        }
        if (kept.isEmpty) {
          // User message was only tool_results, all dropped.
          // Drop the whole message — an empty user message is
          // a no-op the protocol rejects.
          continue;
        }
        out.add({...m, 'content': kept});
      } else {
        out.add(m);
      }
    }
    return out;
  }

  /// Collect the `tool_use` block ids from an assistant message's
  /// content. Returns an empty set when [content] isn't a list (the
  /// string/null branch — text-only or pre-block assistant rows) or
  /// when there are no `tool_use` blocks in the list. Used only by
  /// `_enforceToolUsePairing`'s pass 1.
  static Set<String> _collectToolUseIds(dynamic content) {
    if (content is! List) return const <String>{};
    final ids = <String>{};
    for (final block in content) {
      if (block is Map && block['type'] == 'tool_use') {
        final id = block['id'];
        if (id is String) ids.add(id);
      }
    }
    return ids;
  }
}
