import '../providers/openai_compatible_provider.dart';

class DeepSeekProvider extends OpenAICompatibleProvider {
  @override
  String get name => 'deepseek';

  @override
  String mapEffort(String? effort) {
    switch (effort) {
      case 'normal':
        return 'high';
      case 'high':
        return 'xhigh';
      case 'max':
        return 'max';
      default:
        return 'high';
    }
  }

  /// Compose two sanitizers for the DeepSeek wire format:
  ///
  ///   1. **Inherited from [OpenAICompatibleProvider.sanitizeMessages]**
  ///      — enforces the OpenAI tool_call ↔ tool message pairing
  ///      invariant. Repairs orphan `tool_calls` (e.g. from a
  ///      mid-round interruption or a wire-family switch from
  ///      MiniMax's Anthropic shape) so the request doesn't get
  ///      rejected with the 400 "an assistant message with tool_call
  ///      must be followed by tool messages responding to each
  ///      tool_call_id" error.
  ///   2. **DeepSeek-specific** — backfill `reasoning_content: ''`
  ///      on every `assistant` message that lacks the field. When a
  ///      session switches the active model from a non-DeepSeek
  ///      provider to DeepSeek, the prior `assistant` messages in
  ///      the wire-format history were serialized without a
  ///      `reasoning_content` field — Crux's OpenAI-compatible wire
  ///      emitters don't emit one, and the Anthropic emitter uses a
  ///      different shape (`thinking` content block). DeepSeek's
  ///      API requires every prior `assistant` message to include
  ///      a `reasoning_content` field when the request is in
  ///      thinking mode and a previous turn involved a tool call:
  ///      "If your code does not correctly pass back
  ///      `reasoning_content`, the API will return a 400 error."
  ///      ([source](https://api-docs.deepseek.com/guides/thinking_mode))
  ///      Per the same docs, the field is ignored for turns that
  ///      didn't perform a tool call, so always backfilling is
  ///      safe.
  ///
  /// The backfill runs after the pairing repair so that messages
  /// touched by step 1 (e.g. an assistant message that had its
  /// `tool_calls` array emptied) still get a `reasoning_content`
  /// key, matching what a DeepSeek-produced assistant message
  /// would have looked like.
  ///
  /// Returns the original list reference when neither step changes
  /// anything, so the common case (DeepSeek-produced history) is
  /// free.
  @override
  List<Map<String, dynamic>> sanitizeMessages(
    List<Map<String, dynamic>> messages,
  ) {
    final paired = super.sanitizeMessages(messages);
    return _backfillReasoningContent(paired);
  }

  List<Map<String, dynamic>> _backfillReasoningContent(
    List<Map<String, dynamic>> messages,
  ) {
    var modified = false;
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m['role'] == 'assistant' && m['reasoning_content'] == null) {
        out.add({...m, 'reasoning_content': ''});
        modified = true;
      } else {
        out.add(m);
      }
    }
    return modified ? out : messages;
  }
}
