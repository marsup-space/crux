import 'package:crux/src/components/vibe_box_data.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:test/test.dart';

/// Helper to build a simple user message.
Message _userMsg(String content, {int id = 1}) => Message(
      id: id,
      sessionId: 1,
      role: 'user',
      content: content,
    );

/// Helper to build a simple AI message.
Message _aiMsg(String content, {int id = 2}) => Message(
      id: id,
      sessionId: 1,
      role: 'ai',
      content: content,
    );

/// Helper to build a tool_call message with reasoning + tool calls.
Message _toolCallMsg({
  int id = 3,
  String reasoningContent = '',
  int reasoningTokens = 0,
  int thinkingDurationMs = 0,
  String? reasoningEffort,
  List<ToolCallData> toolCalls = const [],
  String content = '',
}) =>
    Message(
      id: id,
      sessionId: 1,
      role: 'tool_call',
      content: content,
      reasoningContent: reasoningContent,
      reasoningTokens: reasoningTokens,
      thinkingDurationMs: thinkingDurationMs,
      reasoningEffort: reasoningEffort,
      toolCalls: toolCalls,
    );

/// Helper to build a tool result message.
Message _toolResultMsg({
  int id = 4,
  String toolCallId = 'call-1',
  String content = '',
  int tokensIn = 0,
  int tokensOut = 0,
}) =>
    Message(
      id: id,
      sessionId: 1,
      role: 'tool',
      content: content,
      toolCallId: toolCallId,
      tokensIn: tokensIn,
      tokensOut: tokensOut,
    );

void main() {
  group('walkSegments', () {
    test('empty messages → empty segments', () {
      final segments = walkSegments([], {}, ToolRegistry());
      expect(segments, isEmpty);
    });

    test('single user→ai round produces one segment', () {
      final messages = [
        _userMsg('fix the bug', id: 1),
        _aiMsg('Fixed it.', id: 2),
      ];
      final segments = walkSegments(messages, {}, ToolRegistry());

      expect(segments.length, 1);
      expect(segments[0].userMessage.content, 'fix the bug');
      expect(segments[0].prose!.content, 'Fixed it.');
      expect(segments[0].think, isNull);
      expect(segments[0].tools, isNull);
      expect(segments[0].mods, isNull);
    });

    test('pending segment emitted when user types but no response yet', () {
      final messages = [
        _userMsg('hello?', id: 1),
      ];
      final segments = walkSegments(messages, {}, ToolRegistry());

      // A pending segment should be emitted so the user's input
      // appears immediately, even before the agent responds.
      expect(segments.length, 1);
      expect(segments[0].userMessage.content, 'hello?');
      expect(segments[0].showUserMessage, isTrue);
      expect(segments[0].prose, isNull);
    });

    test('user message shown only once across multi-segment turn', () {
      final callId = 'call-1';
      final messages = [
        _userMsg('show me', id: 1),
        _toolCallMsg(
          id: 2,
          content: 'Let me check that for you.',
          toolCalls: [
            ToolCallData(callId: callId, name: 'bash', input: {}),
          ],
        ),
        _toolResultMsg(id: 3, toolCallId: callId, content: 'result'),
        _aiMsg('Here is the full answer.', id: 4),
      ];
      final resultsByCallId = {callId: messages[2]};
      final segments = walkSegments(messages, resultsByCallId, ToolRegistry());

      expect(segments.length, 2);
      // First segment shows the user message.
      expect(segments[0].showUserMessage, isTrue);
      // Second segment (from the ai message) does NOT repeat the user message.
      expect(segments[1].showUserMessage, isFalse);
    });

    test('reasoning is accumulated into think box', () {
      final messages = [
        _userMsg('think hard', id: 1),
        _toolCallMsg(
          id: 2,
          reasoningContent: 'Let me think...',
          reasoningTokens: 1200,
          thinkingDurationMs: 8200,
          reasoningEffort: 'high',
        ),
        _aiMsg('Done.', id: 3),
      ];
      final segments = walkSegments(messages, {}, ToolRegistry());

      expect(segments.length, 1);
      final think = segments[0].think;
      expect(think, isNotNull);
      expect(think!.duration.inMilliseconds, 8200);
      expect(think.tokens, 1200);
      expect(think.effort, 'high');
    });

    test('tool calls are aggregated into tools box', () {
      final callId1 = 'call-1';
      final callId2 = 'call-2';
      final messages = [
        _userMsg('read and grep', id: 1),
        _toolCallMsg(
          id: 2,
          toolCalls: [
            ToolCallData(callId: callId1, name: 'read', input: {'filePath': 'foo.dart'}),
            ToolCallData(callId: callId2, name: 'grep', input: {'pattern': 'foo'}),
          ],
        ),
        _toolResultMsg(id: 3, toolCallId: callId1, content: 'line1\nline2\nline3'),
        _toolResultMsg(id: 4, toolCallId: callId2, content: 'match1\nmatch2'),
        _aiMsg('Done.', id: 5),
      ];
      final resultsByCallId = {
        callId1: messages[2],
        callId2: messages[3],
      };
      final segments = walkSegments(messages, resultsByCallId, ToolRegistry());

      expect(segments.length, 1);
      final tools = segments[0].tools;
      expect(tools, isNotNull);
      expect(tools!.entries.length, 2);
      expect(tools.entries[0].name, 'read');
      expect(tools.entries[0].callCount, 1);
      expect(tools.entries[1].name, 'grep');
      expect(tools.entries[1].callCount, 1);
    });

    test('system-role messages are skipped entirely', () {
      final messages = [
        _userMsg('hello', id: 1),
        Message(id: 2, sessionId: 1, role: 'parallel_praise', content: '', parallelCount: 3),
        Message(id: 3, sessionId: 1, role: 'lsp_diagnostics', content: ''),
        _aiMsg('Hi!', id: 4),
      ];
      final segments = walkSegments(messages, {}, ToolRegistry());

      expect(segments.length, 1);
      expect(segments[0].userMessage.content, 'hello');
      expect(segments[0].prose!.content, 'Hi!');
    });

    test('multi-round turn: two reasoning rounds collapse into one think box', () {
      final messages = [
        _userMsg('refactor', id: 1),
        _toolCallMsg(
          id: 2,
          reasoningContent: 'First thought...',
          reasoningTokens: 2400,
          thinkingDurationMs: 12000,
          reasoningEffort: 'high',
        ),
        _toolCallMsg(
          id: 3,
          reasoningContent: 'Second thought...',
          reasoningTokens: 600,
          thinkingDurationMs: 4000,
          reasoningEffort: 'high',
        ),
        _aiMsg('Done.', id: 4),
      ];
      final segments = walkSegments(messages, {}, ToolRegistry());

      expect(segments.length, 1);
      final think = segments[0].think;
      expect(think, isNotNull);
      expect(think!.duration.inMilliseconds, 16000);
      expect(think.tokens, 3000);
      expect(think.effort, 'high');
    });

    test('multiple user turns produce multiple segments', () {
      final messages = [
        _userMsg('first question', id: 1),
        _aiMsg('first answer', id: 2),
        _userMsg('second question', id: 3),
        _aiMsg('second answer', id: 4),
      ];
      final segments = walkSegments(messages, {}, ToolRegistry());

      expect(segments.length, 2);
      expect(segments[0].userMessage.content, 'first question');
      expect(segments[0].prose!.content, 'first answer');
      expect(segments[1].userMessage.content, 'second question');
      expect(segments[1].prose!.content, 'second answer');
    });

    test('tool_call with non-empty content closes segment (mixed round)', () {
      final messages = [
        _userMsg('mixed round', id: 1),
        _toolCallMsg(
          id: 2,
          content: 'Here is some prose alongside tools.',
          toolCalls: [
            ToolCallData(callId: 'c1', name: 'read', input: {'filePath': 'x.dart'}),
          ],
        ),
        _userMsg('next turn', id: 3),
        _aiMsg('answer', id: 4),
      ];
      final segments = walkSegments(messages, {}, ToolRegistry());

      expect(segments.length, 2);
      expect(segments[0].prose!.content, 'Here is some prose alongside tools.');
      expect(segments[1].userMessage.content, 'next turn');
    });

    test('tool_call with content followed by ai message produces two segments', () {
      // Regression: the tool_call's content was closing the segment
      // and clearing currentUser, so the ai message's full response
      // was silently lost in vibe mode.
      final callId = 'call-1';
      final messages = [
        _userMsg('show me the log', id: 1),
        _toolCallMsg(
          id: 2,
          reasoningContent: 'Let me check...',
          reasoningTokens: 500,
          thinkingDurationMs: 3000,
          toolCalls: [
            ToolCallData(callId: callId, name: 'bash', input: {'command': 'git log'}),
          ],
        ),
        _toolResultMsg(id: 3, toolCallId: callId, content: 'commit abc...'),
        _toolCallMsg(
          id: 4,
          content: 'Yes — all 4 fixes are committed. Confirmed just now:',
          toolCalls: [
            ToolCallData(callId: 'call-2', name: 'bash', input: {'command': 'git log --oneline'}),
          ],
        ),
        _toolResultMsg(id: 5, toolCallId: 'call-2', content: '3cb9579\n1ff07c5'),
        _aiMsg('Four atomic commits on top of 3622efb...', id: 6),
      ];
      final resultsByCallId = {
        callId: messages[2],
        'call-2': messages[4],
      };
      final segments = walkSegments(messages, resultsByCallId, ToolRegistry());

      // Both the tool_call content AND the ai content should produce
      // segments — the ai message must not be lost.
      expect(segments.length, 2);
      expect(segments[0].prose!.content,
          'Yes — all 4 fixes are committed. Confirmed just now:');
      expect(segments[1].prose!.content,
          'Four atomic commits on top of 3622efb...');
      // Both segments share the same user message.
      expect(segments[0].userMessage.content, 'show me the log');
      expect(segments[1].userMessage.content, 'show me the log');
    });

    test('formatTokens formats correctly', () {
      expect(formatTokens(543), '543 tokens');
      expect(formatTokens(2100), '2.1k tokens');
      expect(formatTokens(12000), '12k tokens');
      expect(formatTokens(0), '0 tokens');
    });
  });
}
