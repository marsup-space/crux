import 'package:crux/src/components/vibe_box_data.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/utils/tool_meta.dart';
import 'package:test/test.dart';

/// Build a tool_call message carrying a single call named [toolName].
Message _toolCallMsg(String callId, String toolName) => Message(
  id: 3,
  sessionId: 1,
  role: 'tool_call',
  content: '',
  toolCalls: [
    ToolCallData(callId: callId, name: toolName, input: const {}),
  ],
);

/// Build a tool-result message with a persisted `meta` blob.
Message _toolResultMsg(String callId, String meta) => Message(
  id: 4,
  sessionId: 1,
  role: 'tool',
  content: '',
  toolCallId: callId,
  meta: meta,
);

/// Build a user + closing ai pair so walkSegments emits one segment.
List<Message> _wrap(List<Message> middle) => [
  Message(id: 1, sessionId: 1, role: 'user', content: 'go'),
  ...middle,
  Message(id: 99, sessionId: 1, role: 'ai', content: 'done'),
];

void main() {
  group('parseLspState', () {
    test('returns none for empty / missing meta', () {
      expect(parseLspState(''), LspState.none);
      expect(parseLspState(null), LspState.none);
      expect(parseLspState('{}'), LspState.none);
    });

    test('parses each persisted state value', () {
      expect(parseLspState('{"lsp":"clean"}'), LspState.clean);
      expect(parseLspState('{"lsp":"errors"}'), LspState.errors);
      expect(parseLspState('{"lsp":"failed"}'), LspState.failed);
    });

    test('returns none for unrecognised values', () {
      expect(parseLspState('{"lsp":"bogus"}'), LspState.none);
      expect(parseLspState('{"lsp":""}'), LspState.none);
    });

    test('composes with routing in the same blob', () {
      expect(
        parseLspState('{"routing":"system-proxy","lsp":"errors"}'),
        LspState.errors,
      );
    });
  });

  group('lspStateSeverity (worst-state-wins ranking)', () {
    test('orders errors > failed > clean > none', () {
      expect(lspStateSeverity(LspState.errors), greaterThan(lspStateSeverity(LspState.failed)));
      expect(lspStateSeverity(LspState.failed), greaterThan(lspStateSeverity(LspState.clean)));
      expect(lspStateSeverity(LspState.clean), greaterThan(lspStateSeverity(LspState.none)));
    });
  });

  group('walkSegments LSP state fold', () {
    test('single clean write → entry is clean', () {
      final segments = walkSegments(
        _wrap([
          _toolCallMsg('c1', 'write'),
          _toolResultMsg('c1', '{"lsp":"clean"}'),
        ]),
        {'c1': _toolResultMsg('c1', '{"lsp":"clean"}')},
        ToolRegistry(),
      );
      final entry = segments.single.tools!.entries.single;
      expect(entry.name, 'write');
      expect(entry.lspState, LspState.clean);
    });

    test('two writes, clean then errors → worst-state-wins errors', () {
      final messages = _wrap([
        _toolCallMsg('c1', 'write'),
        _toolResultMsg('c1', '{"lsp":"clean"}'),
        _toolCallMsg('c2', 'write'),
        _toolResultMsg('c2', '{"lsp":"errors"}'),
      ]);
      final segments = walkSegments(
        messages,
        {
          'c1': _toolResultMsg('c1', '{"lsp":"clean"}'),
          'c2': _toolResultMsg('c2', '{"lsp":"errors"}'),
        },
        ToolRegistry(),
      );
      final entry = segments.single.tools!.entries.single;
      expect(entry.callCount, 2);
      expect(entry.lspState, LspState.errors);
    });

    test('errors then clean still resolves to errors', () {
      final segments = walkSegments(
        _wrap([
          _toolCallMsg('c1', 'write'),
          _toolResultMsg('c1', '{"lsp":"errors"}'),
          _toolCallMsg('c2', 'write'),
          _toolResultMsg('c2', '{"lsp":"clean"}'),
        ]),
        {
          'c1': _toolResultMsg('c1', '{"lsp":"errors"}'),
          'c2': _toolResultMsg('c2', '{"lsp":"clean"}'),
        },
        ToolRegistry(),
      );
      expect(segments.single.tools!.entries.single.lspState, LspState.errors);
    });

    test('failed outranks clean but not errors', () {
      final segments = walkSegments(
        _wrap([
          _toolCallMsg('c1', 'edit'),
          _toolResultMsg('c1', '{"lsp":"clean"}'),
          _toolCallMsg('c2', 'edit'),
          _toolResultMsg('c2', '{"lsp":"failed"}'),
        ]),
        {
          'c1': _toolResultMsg('c1', '{"lsp":"clean"}'),
          'c2': _toolResultMsg('c2', '{"lsp":"failed"}'),
        },
        ToolRegistry(),
      );
      expect(segments.single.tools!.entries.single.lspState, LspState.failed);
    });

    test('no lsp meta → entry stays none (no glyph)', () {
      final segments = walkSegments(
        _wrap([
          _toolCallMsg('c1', 'write'),
          _toolResultMsg('c1', ''),
        ]),
        {'c1': _toolResultMsg('c1', '')},
        ToolRegistry(),
      );
      expect(segments.single.tools!.entries.single.lspState, LspState.none);
    });
  });
}
