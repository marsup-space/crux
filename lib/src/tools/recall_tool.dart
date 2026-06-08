import '../storage/session_store.dart';
import 'tool_def.dart';

/// Retrieve the full content of a previously off-loaded tool call.
///
/// The chat service replaces large arguments on `LargePayloadTool`
/// calls (e.g. `write.content`) with a stand-in pointer of the
/// form `[N lines, B bytes; recall: <callId>]` at the persist
/// boundary; the full bytes are written to the
/// `offloaded_content` table. This tool is the recovery path:
///
/// - When called with a known `(sessionId, callId)`, returns the
///   full content as the tool result.
/// - When called with an unknown or cleaned-up callId, returns a
///   non-fatal fallback message asking the LLM to use the `read`
///   tool on the file on disk instead.
///
/// The LLM should generally not need this for `write` calls — once
/// a file is on disk, `read` is the cheaper path. The escape
/// hatch is for cases where the LLM genuinely needs to recall the
/// exact bytes of an `edit.oldString` / `edit.newString` pair, or
/// where the underlying file has since been deleted.
class RecallTool extends ToolDef {
  final SessionStore _store;

  RecallTool(this._store);

  @override
  String get name => 'recall';

  @override
  String get description =>
      'Retrieve the full content of a previously compressed tool call '
      'from the current session. Use only when you need the exact bytes '
      '— for most cases, the read tool on the file at the path you '
      'wrote is enough. Off-loaded bytes are tied to the session '
      'lifetime and may be cleaned up by /archive or future /compact '
      'operations; if recall fails, fall back to read on the file on disk.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'callId': {
        'type': 'string',
        'description':
            'Call ID from a prior write or edit whose content was compressed.',
      },
    },
    'required': ['callId'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final callId = args['callId'] as String?;
    if (callId == null || callId.isEmpty) {
      return ToolResult.error('Missing required parameter: callId');
    }
    final content = await _store.getOffloadedContent(ctx.sessionId, callId);
    if (content == null) {
      return ToolResult(
        title: 'recall: not found',
        output:
            'No off-loaded content for call $callId in this session. '
            'It may have been cleaned up by /archive (or a future '
            '/compact), or the callId may be wrong. Use the read tool '
            'on the relevant file at the path you wrote or edited — '
            'the file on disk is still the source of truth.',
      );
    }
    return ToolResult(
      title: 'recall: $callId',
      output: content,
      metadata: {
        'byteSize': content.length,
        'source': 'offloaded',
        'callId': callId,
      },
    );
  }
}
