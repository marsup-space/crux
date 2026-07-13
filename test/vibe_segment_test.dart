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

    test('consecutive ai rows emit one segment per row, anchored to the same user', () {
      // Per spec rule 3 (`role: 'ai'` closes the segment) and the
      // "one segment per response body" summary: each `role: 'ai'`
      // row in the message list emits a [VibeSegment]. When two
      // close-emitting rows land back to back without a fresh
      // `role: 'user'` between them, both segments anchor to the
      // same user and the walker does NOT clear `currentUser` on
      // close (so the second ai is anchored and emitted, not
      // silently dropped).
      //
      // Boxes are window-scoped: the first close resets the
      // accumulators, so any tools accumulated between the two
      // ais would land in seg[1]'s window — but in this scenario
      // there are none, so seg[1] is prose-only.
      final messages = [
        _userMsg('explain', id: 1),
        _toolCallMsg(
          id: 2,
          reasoningContent: 'thinking...',
          reasoningTokens: 300,
          thinkingDurationMs: 2000,
          toolCalls: [
            ToolCallData(callId: 'c1', name: 'read', input: {}),
          ],
        ),
        _toolResultMsg(id: 3, toolCallId: 'c1', content: 'data'),
        _aiMsg('First answer.', id: 4),
        _aiMsg('Second answer.', id: 5),
      ];
      final resultsByCallId = {'c1': messages[2]};
      final segments = walkSegments(messages, resultsByCallId, ToolRegistry());

      expect(segments.length, 2);
      // First segment: window-bounded boxes + first ai's prose.
      expect(segments[0].userMessage.content, 'explain');
      expect(segments[0].showUserMessage, isTrue);
      expect(segments[0].think, isNotNull);
      expect(segments[0].think!.tokens, 300);
      expect(segments[0].tools, isNotNull);
      expect(segments[0].tools!.entries.length, 1);
      expect(segments[0].tools!.entries[0].name, 'read');
      expect(segments[0].prose!.content, 'First answer.');
      // Second segment: same user anchor, no boxes (the reset
      // between closes left them empty), no repeated user line.
      expect(segments[1].userMessage.content, 'explain');
      expect(segments[1].showUserMessage, isFalse);
      expect(segments[1].think, isNull);
      expect(segments[1].tools, isNull);
      expect(segments[1].prose!.content, 'Second answer.');
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

    test('tool_call with non-empty content closes the segment (mixed round)', () {
      // Per spec rule 2.3: a `role: 'tool_call'` row whose
      // embedded `content` is non-empty is itself a prose
      // boundary — its `content` becomes the segment's prose.
      // Combined with rule 3 (a subsequent `role: 'ai'` closes
      // again), this scenario produces two segments within the
      // first user turn (the mixed-round close + the next user
      // boundary doesn't emit anything new; the second user +
      // ai close yields the second segment).
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
      // First segment: closed by the tool_call's prose; the
      // mixed-round content is the closing prose, the tools
      // box comes from the same row.
      expect(segments[0].userMessage.content, 'mixed round');
      expect(segments[0].showUserMessage, isTrue);
      expect(segments[0].prose, isNotNull);
      expect(segments[0].prose!.content,
          'Here is some prose alongside tools.');
      expect(segments[0].tools, isNotNull);
      expect(segments[0].tools!.entries.length, 1);
      expect(segments[0].tools!.entries[0].name, 'read');
      // Second segment: clean — user boundary resets state, the
      // ai close lands the next segment.
      expect(segments[1].userMessage.content, 'next turn');
      expect(segments[1].showUserMessage, isTrue);
      expect(segments[1].prose!.content, 'answer');
      expect(segments[1].tools, isNull);
      expect(segments[1].think, isNull);
    });

    test('tool_call content followed by ai message produces two segments', () {
      // Each prose boundary in the message list emits a segment.
      // The mixed-round tool_call's prose becomes segment #0's
      // prose; the ai's prose becomes segment #1's prose. Boxes
      // between the two are scoped to seg[0] because the close
      // resets the accumulators before the ai lands.
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

      expect(segments.length, 2);
      // Segment #0: closed by the mixed-round tool_call. Round 1's
      // bash + round 2's bash both belong to this segment's
      // window (the close fires AFTER the second bash is
      // accumulated), so the tools box lists bash x2.
      expect(segments[0].userMessage.content, 'show me the log');
      expect(segments[0].prose!.content,
          'Yes — all 4 fixes are committed. Confirmed just now:');
      expect(segments[0].think, isNotNull);
      expect(segments[0].think!.duration.inMilliseconds, 3000);
      expect(segments[0].tools, isNotNull);
      expect(segments[0].tools!.entries.length, 1);
      expect(segments[0].tools!.entries[0].name, 'bash');
      expect(segments[0].tools!.entries[0].callCount, 2);
      // Segment #1: closed by the ai. Reset on the previous close
      // means no boxes here; only the ai's prose.
      expect(segments[1].userMessage.content, 'show me the log');
      expect(segments[1].prose!.content,
          'Four atomic commits on top of 3622efb...');
      expect(segments[1].think, isNull);
      expect(segments[1].tools, isNull);
      expect(segments[1].showUserMessage, isFalse);
    });

    test('formatTokens formats correctly', () {
      expect(formatTokens(543), '543 tokens');
      expect(formatTokens(2100), '2.1k tokens');
      expect(formatTokens(12000), '12k tokens');
      expect(formatTokens(0), '0 tokens');
    });
  });
}
