// Tests for the prune-based / chat-log compaction builder.
//
// Focus: tldr substitution. When an `role: 'ai'` message has a tldr
// (populated by [ChatTurnOrchestrator.maybeGenerateTldr] right after
// the AI turn completes for responses above the threshold), the chat
// log should render the tldr as the `crux:` preamble — same compression
// ratio the user already accepted in the TldrBubble, and avoids
// undoing the win compaction just bought.

import 'package:test/test.dart';

import 'package:crux/src/models/message.dart';
import 'package:crux/src/services/compaction/chat_log_builder.dart';
import 'package:crux/src/tools/edit_tool.dart';
import 'package:crux/src/tools/read_tool.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/tools/write_tool.dart';

Message _ai({
  required int id,
  String content = 'long response',
  String tldr = '',
}) {
  return Message(
    id: id,
    sessionId: 1,
    role: 'ai',
    content: content,
    tldr: tldr,
  );
}

Message _user({required int id, String content = 'hi'}) {
  return Message(id: id, sessionId: 1, role: 'user', content: content);
}

Message _toolCall({
  required int id,
  required String toolName,
  required Map<String, dynamic> input,
}) {
  return Message(
    id: id,
    sessionId: 1,
    role: 'tool_call',
    content: '',
    toolCalls: [ToolCallData(callId: 'call_$id', name: toolName, input: input)],
  );
}

Message _toolResult({required int id, String content = 'ok'}) {
  return Message(
    id: id,
    sessionId: 1,
    role: 'tool',
    content: content,
    toolCallId: 'call_${id - 1}',
  );
}

/// Stub tool whose `extractPruneSummary` always returns a fixed
/// contribution. The optional [name] lets tests register multiple
/// stubs under distinct tool names — needed because
/// [ToolRegistry.register] overwrites by name, so two stub reads
/// of the same name would collide. Tests that want N distinct
/// stub read tools pass `name: 'read_$i'` and rely on
/// [_StubReadTool] to emit the right inline marker for whichever
/// name was passed.
class _StubReadTool extends ToolDef {
  final SummaryContribution contribution;
  final String _name;

  _StubReadTool(this.contribution, {this._name = 'read'});

  @override
  String get name => _name;

  @override
  String get description => 'stub';

  @override
  Map<String, dynamic> get parametersSchema => const {};

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    throw UnimplementedError();
  }

  @override
  String renderPruneInline({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
  }) {
    final path = call.input['filePath']?.toString() ?? '?';
    if (isError) return '$name $path → $pairedResult';
    return '$name $path';
  }

  @override
  SummaryContribution? extractPruneSummary({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
    required String workingDirectory,
  }) => contribution;
}

/// Stub `write` tool. Same shape as [_StubReadTool] but with a
/// different default name so per-tool routing in the chat log
/// still works (we want the file to be routed into the "write
/// files:" section — write contributions are categorised
/// separately from read contributions).
class _StubWriteTool extends ToolDef {
  final SummaryContribution contribution;
  final String _name;

  _StubWriteTool(this.contribution, {this._name = 'write'});

  @override
  String get name => _name;

  @override
  String get description => 'stub';

  @override
  Map<String, dynamic> get parametersSchema => const {};

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    throw UnimplementedError();
  }

  @override
  String renderPruneInline({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
  }) {
    final path = call.input['filePath']?.toString() ?? '?';
    return 'write $path';
  }

  @override
  SummaryContribution? extractPruneSummary({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
    required String workingDirectory,
  }) => contribution;
}

/// Stub `skill` tool. `extractPruneSummary` returns the fixed
/// [SummaryContribution] (category `skill-bodies`), mirroring the
/// real [SkillTool]. Registered under the name `skill` so the
/// chat log's inline grouping renders the `skill {name}` line.
class _StubSkillTool extends ToolDef {
  final SummaryContribution contribution;

  _StubSkillTool(this.contribution);

  @override
  String get name => 'skill';

  @override
  String get description => 'stub';

  @override
  Map<String, dynamic> get parametersSchema => const {};

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    throw UnimplementedError();
  }

  @override
  String renderPruneInline({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
  }) {
    final skillName = call.input['name']?.toString() ?? '';
    if (isError) return 'skill {$skillName} → $pairedResult';
    return 'skill {$skillName}';
  }

  @override
  SummaryContribution? extractPruneSummary({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
    required String workingDirectory,
  }) => contribution;
}

void main() {
  // Empty registry: the cases under test don't involve tool calls, so
  // the per-tool lookup path is never reached. Mirrors how
  // `buildChatLog` is exercised in production for tldr-only responses.
  final registry = ToolRegistry();

  group('buildChatLog — tldr substitution', () {
    test('uses tldr as crux: preamble when present', () {
      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'what does foo do?'),
          _ai(
            id: 2,
            content: 'foo is a 5000-char essay that goes on and on...',
            tldr: 'foo explains X',
          ),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(result.markdown, contains('crux: foo explains X'));
      // The full content MUST be dropped — that's the whole point.
      expect(
        result.markdown,
        isNot(contains('foo is a 5000-char essay')),
        reason: 'full content should be replaced by tldr',
      );
    });

    test('falls back to full content when tldr is the empty string', () {
      final result = buildChatLog(
        messages: [
          _user(id: 1),
          _ai(id: 2, content: 'short reply', tldr: ''),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(result.markdown, contains('crux: short reply'));
    });

    test('falls back to full content when tldr is not set', () {
      // Default `tldr: ''` in [_ai] covers this — make it explicit so
      // a future refactor that flips the default doesn't silently
      // change behavior.
      final result = buildChatLog(
        messages: [
          _user(id: 1),
          _ai(id: 2, content: 'short reply', tldr: ''),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(result.markdown, contains('crux: short reply'));
    });

    test('preserves the user: line alongside the tldr-substituted crux', () {
      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'what does foo do?'),
          _ai(id: 2, content: 'long', tldr: 'short'),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(result.markdown, contains('user: what does foo do?'));
      expect(result.markdown, contains('crux: short'));
    });

    test(
      'tldr substitution applies per turn (each ai checked independently)',
      () {
        // Two AI turns, one with tldr, one without. The first should
        // collapse to its tldr, the second stays verbatim. Catches a
        // buggy "sticky tldr" implementation that caches a previous
        // tldr across the walk.
        final result = buildChatLog(
          messages: [
            _user(id: 1),
            _ai(id: 2, content: 'first long reply', tldr: 'first TLDR'),
            _user(id: 3, content: 'another question'),
            _ai(id: 4, content: 'second short reply'),
          ],
          workingDirectory: '/tmp/proj',
          toolRegistry: registry,
        );

        expect(result.markdown, contains('crux: first TLDR'));
        expect(result.markdown, contains('crux: second short reply'));
        expect(
          result.markdown,
          isNot(contains('first long reply')),
          reason: 'first turn should be replaced by its tldr',
        );
      },
    );
  });

  group('buildChatLog — bottom-of-log summary section', () {
    test('appends "read files:" section when a tool contributes', () {
      // Regression: SummaryCollector.render() was wired up in
      // summary_collector.dart but `buildChatLog` never called it
      // — the read-files block was silently dropped from the
      // markdown even though its fileMarkers were returned. Fix:
      // append summary.render() to the body. This test pins that
      // the on-disk content makes it back into the chat log.
      //
      // Updated for the new model: the contribution's `value` IS
      // what the model saw at read time (no mtime column, no
      // re-read of disk). The chat log preserves the model's
      // memory, not the current file state.
      final registryWithStub = ToolRegistry();
      registryWithStub.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: 'lib/foo.dart',
            content: 'class Foo {}',
          ),
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'look at foo'),
          _toolCall(
            id: 2,
            toolName: 'read',
            input: {'filePath': 'lib/foo.dart'},
          ),
          _toolResult(id: 3, content: 'class Foo {}'),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registryWithStub,
      );

      // The inline per-turn line still renders.
      expect(result.markdown, contains('read: lib/foo.dart'));
      // The bottom-of-log summary section also renders.
      expect(result.markdown, contains('read files:'));
      expect(result.markdown, contains('lib/foo.dart'));
      expect(result.markdown, contains('class Foo {}'));
      // No mtime label anymore — we show what the model saw,
      // and mtime wasn't in the model's view of the file.
      expect(result.markdown, isNot(contains('mtime:')));
    });

    test('appends "write files:" section when a write contributes', () {
      // Mirror of the read test: a write tool's contribution
      // routes into a separate `write files:` section. The
      // content comes from the input `content` argument (what
      // the model wrote), not from a re-read of disk. The
      // `read files:` section stays empty when no read has
      // contributed.
      final registryWithStub = ToolRegistry();
      registryWithStub.register(
        _StubWriteTool(
          SummaryContribution.writtenFile(
            path: 'lib/new.dart',
            content: 'class New {}',
          ),
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'create new.dart'),
          _toolCall(
            id: 2,
            toolName: 'write',
            input: {'filePath': 'lib/new.dart'},
          ),
          _toolResult(id: 3, content: 'File written: lib/new.dart'),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registryWithStub,
      );

      // Inline per-turn line.
      expect(result.markdown, contains('write: lib/new.dart'));
      // Write files section.
      expect(result.markdown, contains('write files:'));
      expect(result.markdown, contains('lib/new.dart'));
      expect(result.markdown, contains('class New {}'));
      // No `read files:` section when no read contributed.
      expect(result.markdown, isNot(contains('read files:')));
    });

    test('omits the summary section when no tool contributes', () {
      // Empty registry + no tool calls → nothing to append. The
      // chat log must NOT contain empty `read files:` /
      // `write files:` headers, nor any of the dropped sections
      // (`searched terms:`, `fetched pages:`) that used to render
      // here.
      final result = buildChatLog(
        messages: [
          _user(id: 1),
          _ai(id: 2, content: 'plain reply'),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(result.markdown, isNot(contains('read files:')));
      expect(result.markdown, isNot(contains('write files:')));
      expect(result.markdown, isNot(contains('searched terms:')));
      expect(result.markdown, isNot(contains('fetched pages:')));
    });

    test('caps total read-files section size to fit budget', () {
      // Regression: a session that touched many large files
      // would accumulate a multi-MB `read files:` section in
      // the compaction chain — making the next compaction's
      // projection `post > pre` and blocking all future
      // compactions. Fix: SummaryCollector caps the whole
      // section at `kInlineSummarySectionMaxChars`, omitting
      // overflow files with a marker.
      final registryWithStub = ToolRegistry();
      // Three read files at 20KB each = 60KB total, well over
      // the 32KB cap. The first fits whole, the second
      // partial-fit, the third gets omitted with a marker.
      // Each stub uses a distinct tool name because
      // [ToolRegistry.register] overwrites by name.
      registryWithStub.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: 'lib/big_a.dart',
            content: 'a' * 20 * 1024,
          ),
          name: 'read_a',
        ),
      );
      registryWithStub.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: 'lib/big_b.dart',
            content: 'b' * 20 * 1024,
          ),
          name: 'read_b',
        ),
      );
      registryWithStub.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: 'lib/big_c.dart',
            content: 'c' * 20 * 1024,
          ),
          name: 'read_c',
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1),
          _toolCall(
            id: 2,
            toolName: 'read_a',
            input: {'filePath': 'lib/big_a.dart'},
          ),
          _toolResult(id: 3),
          _user(id: 4),
          _toolCall(
            id: 5,
            toolName: 'read_b',
            input: {'filePath': 'lib/big_b.dart'},
          ),
          _toolResult(id: 6),
          _user(id: 7),
          _toolCall(
            id: 8,
            toolName: 'read_c',
            input: {'filePath': 'lib/big_c.dart'},
          ),
          _toolResult(id: 9),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registryWithStub,
      );

      final section = result.markdown.split('read files:').last;

      // First file fits whole (its content + header is under
      // the 32KB cap).
      expect(section, contains('lib/big_a.dart'));
      // The third file is dropped (omitted) — its body must
      // not appear, only the path in the marker.
      expect(
        section,
        isNot(contains('c' * 1024)),
        reason: 'c.dart body must not appear when omitted',
      );

      // Overflow marker is present so the LLM knows the file
      // exists but wasn't shown. The path is recoverable from
      // the inline `read:` line in the per-turn chat log, so
      // the marker only needs a count.
      expect(
        section,
        contains('omitted to fit'),
        reason: 'overflow marker must be present',
      );
      expect(section, contains('32KB section cap'));
      expect(section, contains('1 more file'));

      // Total section size is bounded by the cap.
      expect(
        section.length,
        lessThanOrEqualTo(kInlineSummarySectionMaxChars + 200),
        reason:
            'section must not exceed the cap (small slack for the marker line)',
      );
    });

    test('caps total write-files section size to fit budget', () {
      // Mirror of the read cap test for the new `write files:`
      // section. Same cap and overflow behavior; only the
      // section header differs.
      final registryWithStub = ToolRegistry();
      registryWithStub.register(
        _StubWriteTool(
          SummaryContribution.writtenFile(
            path: 'lib/big_a.dart',
            content: 'a' * 20 * 1024,
          ),
          name: 'write_a',
        ),
      );
      registryWithStub.register(
        _StubWriteTool(
          SummaryContribution.writtenFile(
            path: 'lib/big_b.dart',
            content: 'b' * 20 * 1024,
          ),
          name: 'write_b',
        ),
      );
      registryWithStub.register(
        _StubWriteTool(
          SummaryContribution.writtenFile(
            path: 'lib/big_c.dart',
            content: 'c' * 20 * 1024,
          ),
          name: 'write_c',
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1),
          _toolCall(
            id: 2,
            toolName: 'write_a',
            input: {'filePath': 'lib/big_a.dart'},
          ),
          _toolResult(id: 3),
          _user(id: 4),
          _toolCall(
            id: 5,
            toolName: 'write_b',
            input: {'filePath': 'lib/big_b.dart'},
          ),
          _toolResult(id: 6),
          _user(id: 7),
          _toolCall(
            id: 8,
            toolName: 'write_c',
            input: {'filePath': 'lib/big_c.dart'},
          ),
          _toolResult(id: 9),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registryWithStub,
      );

      final section = result.markdown.split('write files:').last;
      expect(section, contains('lib/big_a.dart'));
      expect(
        section,
        isNot(contains('c' * 1024)),
        reason: 'c.dart body must not appear when omitted',
      );
      expect(
        section,
        contains('omitted to fit'),
        reason: 'overflow marker must be present',
      );
      expect(section, contains('1 more file'));
      expect(
        section.length,
        lessThanOrEqualTo(kInlineSummarySectionMaxChars + 200),
        reason: 'section must not exceed the cap',
      );
    });

    test('partial-fit file gets truncated with marker', () {
      // When a single file is too big to fit alongside the
      // prior files, its body is truncated and a "... (truncated,
      // re-read for full content)" marker is appended. The
      // path stays so the LLM knows which file the snippet
      // belongs to.
      final registryWithStub = ToolRegistry();
      registryWithStub.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: 'lib/big_a.dart',
            content: 'a' * 25 * 1024, // 25KB — first file
          ),
          name: 'read_a',
        ),
      );
      registryWithStub.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: 'lib/big_b.dart',
            content: 'b' * 25 * 1024, // 25KB — partial fit
          ),
          name: 'read_b',
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1),
          _toolCall(
            id: 2,
            toolName: 'read_a',
            input: {'filePath': 'lib/big_a.dart'},
          ),
          _toolResult(id: 3),
          _user(id: 4),
          _toolCall(
            id: 5,
            toolName: 'read_b',
            input: {'filePath': 'lib/big_b.dart'},
          ),
          _toolResult(id: 6),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registryWithStub,
      );

      final section = result.markdown.split('read files:').last;
      // b.dart body is truncated — full body (25KB) is not
      // present, but the marker is.
      expect(
        section,
        isNot(contains('b' * 25 * 1024)),
        reason: 'b.dart body must be truncated',
      );
      expect(
        section,
        contains('(truncated, re-read for full content)'),
        reason: 'truncation marker must be present',
      );
      expect(
        section.length,
        lessThanOrEqualTo(kInlineSummarySectionMaxChars + 200),
      );
    });

    test('single small file: no truncation, no marker', () {
      // Sanity: a single file well under the cap renders
      // unchanged. Catches a bug that always truncates.
      final registryWithStub = ToolRegistry();
      registryWithStub.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: 'lib/small.dart',
            content: 'short body',
          ),
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1),
          _toolCall(
            id: 2,
            toolName: 'read',
            input: {'filePath': 'lib/small.dart'},
          ),
          _toolResult(id: 3),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registryWithStub,
      );

      expect(result.markdown, contains('short body'));
      expect(result.markdown, isNot(contains('omitted')));
      expect(result.markdown, isNot(contains('truncated')));
    });

    test('dedupes the same file read multiple times (last-write-wins)', () {
      // Same path read three times across three turns. The chat
      // log's per-turn rendering merges same-tool calls within a
      // single turn, so we split with user messages between reads
      // to force three separate inline entries. The summary
      // section, by contrast, dedupes by (category, key) — only
      // ONE entry for `lib/foo.dart` should survive at the bottom.
      final registryWithStub = ToolRegistry();
      registryWithStub.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: 'lib/foo.dart',
            content: 'final content',
          ),
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1),
          _toolCall(
            id: 2,
            toolName: 'read',
            input: {'filePath': 'lib/foo.dart'},
          ),
          _toolResult(id: 3),
          _user(id: 4),
          _toolCall(
            id: 5,
            toolName: 'read',
            input: {'filePath': 'lib/foo.dart'},
          ),
          _toolResult(id: 6),
          _user(id: 7),
          _toolCall(
            id: 8,
            toolName: 'read',
            input: {'filePath': 'lib/foo.dart'},
          ),
          _toolResult(id: 9),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registryWithStub,
      );

      // Inline: three separate turns each render their own
      // `read: lib/foo.dart` line.
      expect(
        'read: lib/foo.dart'.allMatches(result.markdown).length,
        equals(3),
      );

      // Summary section: split on the `read files:` header so we
      // only count occurrences in the bottom-of-log block.
      // Dedup-by-key means the file path appears once even
      // though three reads contributed.
      final summarySection = result.markdown.split('read files:').last;
      // The value (content body) renders exactly once.
      expect(
        'final content'.allMatches(summarySection).length,
        equals(1),
        reason: 'summary section dedupes same path',
      );
    });
  });

  group('buildChatLog — loaded skills summary', () {
    test('appends "loaded skills:" section when a skill tool contributes', () {
      // The skill tool's `extractPruneSummary` routes the loaded
      // body into the `skill-bodies` category; the collector
      // renders it under `loaded skills:` so a post-compact
      // session keeps the procedure without re-invoking the tool.
      final registryWithStub = ToolRegistry();
      registryWithStub.register(
        _StubSkillTool(
          SummaryContribution(
            category: 'skill-bodies',
            key: 'pr-review',
            value: '<skill_content name="pr-review">\nProcedure body\n</skill_content>',
          ),
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'load the review skill'),
          _toolCall(id: 2, toolName: 'skill', input: {'name': 'pr-review'}),
          _toolResult(id: 3, content: '<skill_content name="pr-review">…'),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registryWithStub,
      );

      expect(result.markdown, contains('loaded skills:'));
      expect(result.markdown, contains('pr-review'));
      expect(result.markdown, contains('Procedure body'));
      // No file sections when only a skill contributed.
      expect(result.markdown, isNot(contains('read files:')));
    });

    test('loaded skills section renders BEFORE read files', () {
      // Skill bodies are instructions the resumed agent must
      // follow while reading the file snapshots — they go first.
      final registryWithStub = ToolRegistry();
      registryWithStub.register(
        _StubSkillTool(
          SummaryContribution(
            category: 'skill-bodies',
            key: 'pr-review',
            value: 'Procedure body',
          ),
        ),
      );
      registryWithStub.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: 'lib/foo.dart',
            content: 'class Foo {}',
          ),
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1),
          _toolCall(id: 2, toolName: 'skill', input: {'name': 'pr-review'}),
          _toolResult(id: 3, content: 'ok'),
          _toolCall(
            id: 4,
            toolName: 'read',
            input: {'filePath': 'lib/foo.dart'},
          ),
          _toolResult(id: 5, content: 'class Foo {}'),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registryWithStub,
      );

      final skillsIdx = result.markdown.indexOf('loaded skills:');
      final readsIdx = result.markdown.indexOf('read files:');
      expect(skillsIdx, greaterThanOrEqualTo(0));
      expect(readsIdx, greaterThanOrEqualTo(0));
      expect(
        skillsIdx,
        lessThan(readsIdx),
        reason: 'loaded skills section renders before read files',
      );
    });

    test('dedupes the same skill loaded multiple times', () {
      // Loading the same skill twice (e.g. once via `$` chip,
      // once via the `skill` tool) contributes two entries with
      // the same (category, key). The collector's last-write-wins
      // dedup collapses them to one — the body must NOT be
      // doubled in the summary.
      final registryWithStub = ToolRegistry();
      registryWithStub.register(
        _StubSkillTool(
          SummaryContribution(
            category: 'skill-bodies',
            key: 'pr-review',
            value: 'Procedure body',
          ),
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1),
          _toolCall(id: 2, toolName: 'skill', input: {'name': 'pr-review'}),
          _toolResult(id: 3, content: 'ok'),
          _user(id: 4),
          _toolCall(id: 5, toolName: 'skill', input: {'name': 'pr-review'}),
          _toolResult(id: 6, content: 'ok'),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registryWithStub,
      );

      final summarySection = result.markdown.split('loaded skills:').last;
      expect(
        'Procedure body'.allMatches(summarySection).length,
        equals(1),
        reason: 'summary section dedupes same skill name',
      );
    });
  });

  group('inline read result is not appended on success', () {
    // Regression for the false positive in `_looksLikeError`.
    //
    // Old behavior: a successful `read` whose tool result happened
    // to contain the substrings `exit code:` AND `failed` ANYWHERE
    // in the file content was misclassified as an error, and the
    // inline line rendered as `read $path → $pairedResult` —
    // embedding the entire file content (358 lines in the
    // production case) into a single chat log line and inflating
    // the post-compaction size by ~14k tokens.
    //
    // The concrete trigger was reading `chat_log_builder.dart`:
    // the file's source contains the literal text
    // `('exit code:') && lower.contains('failed');` (the body of
    // the very function that was misclassifying it). Fix: the
    // heuristic now only scans the first 200 characters of the
    // result, so source code that incidentally contains those
    // trigger strings further down the file no longer trips it.

    test('a successful read of source code with trigger words is '
        'NOT classified as an error', () {
      // The actual `chat_log_builder.dart` source up to the
      // `_looksLikeError` body — line numbers preserved so the
      // simulation matches the real read output exactly.
      final dartSourceThatTrippedTheHeuristic = [
        '1: import \'../../models/message.dart\';',
        '2: import \'../../tools/registry.dart\';',
        '3: import \'../../tools/tool_def.dart\';',
        '4: import \'summary_collector.dart\';',
        '5: ',
        '6: /// Result of [buildChatLog]: the rendered Markdown plus the file',
        '7: /// markers the caller needs to replay through [FileReadTracker] so the',
        '...',
        '350:   return lower.startsWith(\'error\') ||',
        '351:       lower.startsWith(\'path not found\') ||',
        '352:       lower.startsWith(\'[guard]\') ||',
        "353:       lower.contains('exit code:') && lower.contains('failed');",
        '354: }',
      ].join('\n');

      // Sanity: the OLD heuristic would have classified this as
      // an error (the trigger strings appear deep in the file).
      // Document the old behavior so the test makes the contrast
      // explicit. With the new leading-window check, the result
      // starts with `1: import '...'`, so the heuristic correctly
      // returns false.
      expect(
        dartSourceThatTrippedTheHeuristic.contains('exit code:'),
        isTrue,
        reason:
            'fixture includes the trigger substring to prove '
            'the old heuristic would have matched',
      );
      expect(
        dartSourceThatTrippedTheHeuristic.contains('failed'),
        isTrue,
        reason:
            'fixture includes the trigger substring to prove '
            'the old heuristic would have matched',
      );

      // Run the inline rendering and assert the result does NOT
      // contain the result payload.
      final registry = ToolRegistry();
      registry.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: 'lib/src/services/compaction/chat_log_builder.dart',
            content: dartSourceThatTrippedTheHeuristic,
          ),
        ),
      );
      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'read chat_log_builder.dart'),
          _toolCall(
            id: 2,
            toolName: 'read',
            input: {
              'filePath':
                  'lib/src/services/compaction/'
                  'chat_log_builder.dart',
            },
          ),
          _toolResult(id: 3, content: dartSourceThatTrippedTheHeuristic),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      // Inline line must be `read <path>` only — no `→ ...`
      // payload. The presence of `→` means the result got
      // classified as an error and the inline rendering took
      // the error branch.
      expect(
        result.markdown,
        contains(
          'read: lib/src/services/'
          'compaction/chat_log_builder.dart',
        ),
      );
      expect(
        result.markdown,
        isNot(contains('→ 1: import')),
        reason:
            'inline read line must not include tool result '
            'content when the result is a successful read that '
            'happens to contain the trigger substrings',
      );

      // The bottom-of-log `read files:` section MAY include the
      // content (that's its job), so we don't assert on the
      // total markdown — only on the inline line.
    });

    test('real error markers in the leading window still classify '
        'as error', () {
      // Sanity check: the leading-window check shouldn't make
      // the heuristic a no-op. An actual `Error: ...` prefix
      // in the leading 200 chars must still be detected.
      final errorResult =
          'Error: file not found at /tmp/missing.txt\n'
          'This is a simulated error message from the tool layer.';
      final registry = ToolRegistry();
      registry.register(
        _StubReadTool(
          SummaryContribution.readFile(
            path: '/tmp/missing.txt',
            content: errorResult,
          ),
        ),
      );
      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'read missing'),
          _toolCall(
            id: 2,
            toolName: 'read',
            input: {'filePath': '/tmp/missing.txt'},
          ),
          _toolResult(id: 3, content: errorResult),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );
      // Error path: inline line includes the result payload.
      expect(
        result.markdown,
        contains('→ Error: file not found'),
        reason:
            'real error markers must still trigger the '
            'inline result-passthrough so the user sees the '
            'failure context in the chat log',
      );
    });
  });

  group('buildChatLog — no-op filter (guards and aborts)', () {
    // The compaction filter drops edit / write calls whose
    // result indicates the file was NOT mutated:
    //   * `[GUARD]…` (read-before-write, oldString-no-match,
    //     streaming abort — they all reuse the bracketed header)
    //   * `Refusing to overwrite…` (write size-mismatch guard)
    //   * `Tool aborted` (the literal text the tool layer emits
    //     when `ctx.abort.isAborted` fires)
    //
    // Filtered calls disappear from BOTH the inline per-turn
    // line AND the bottom-of-log summary section (the latter
    // because [extractPruneSummary] is never consulted). Auto-
    // reads are NOT filtered — see the next group.
    //
    // Real EditTool / WriteTool (not stubs) — stubs don't
    // implement the new [ToolDef.isNoOpForCompaction] hook.

    test('edit read-before-write guard is dropped from the chat log', () {
      // The production shape of `_doMutation`'s read-before-
      // write guard: header starts with `[GUARD]`, then a
      // blank line, then the current file body. The chat log
      // must not show the inline `edit: foo.dart → [GUARD]…`
      // line (which would be hundreds of chars because the
      // guard embeds the current file).
      final guardResult =
          '[GUARD] Write was BLOCKED — file was modified since '
          'last read. Your write did NOT take effect. The new '
          'content is below; retry your edit with a pattern that '
          'matches this version.\n\nclass Foo {}\n';
      final registry = ToolRegistry();
      registry.register(EditTool());

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'edit foo'),
          _toolCall(
            id: 2,
            toolName: 'edit',
            input: {
              'filePath': 'lib/foo.dart',
              'oldString': 'class Foo {}',
              'newString': 'class Bar {}',
              'intent': 'rename',
            },
          ),
          _toolResult(id: 3, content: guardResult),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      // Inline line gone.
      expect(
        result.markdown,
        isNot(contains('edit: lib/foo.dart')),
        reason:
            'guarded edit must be dropped from the inline '
            'log; the follow-up retry is what matters',
      );
      expect(
        result.markdown,
        isNot(contains('[GUARD]')),
        reason:
            'guard header / file body must not leak into the '
            'compacted log',
      );
      // No summary contribution either — guarded edit never
      // touched the file.
      expect(
        result.markdown,
        isNot(contains('read files:')),
        reason:
            'no read / write-files section when the only '
            'tool call was a guard',
      );
    });

    test('edit streaming abort (mid-stream guard catch) is dropped', () {
      // Streaming-time abort path (`_buildGuardAbortedToolResult`)
      // wraps the guard header + file content + an early-abort
      // marker. Same `[GUARD]` header shape → same filter
      // behaviour.
      final abortResult =
          '[GUARD] Edit was BLOCKED — oldString does not match any '
          'text in the file. Your edit did NOT take effect. The '
          'current file content is below; pick a different oldString '
          'and try again.\n\nclass Foo {}\n\n'
          '[Crux system note — tool-call early abort]\n'
          'Crux stopped this edit tool call while its arguments '
          'were still streaming.';
      final registry = ToolRegistry();
      registry.register(EditTool());

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'edit foo'),
          _toolCall(
            id: 2,
            toolName: 'edit',
            input: {
              'filePath': 'lib/foo.dart',
              'oldString': 'nope',
              'newString': 'class Bar {}',
              'intent': 'rename',
            },
          ),
          _toolResult(id: 3, content: abortResult),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(result.markdown, isNot(contains('edit: lib/foo.dart')));
      expect(result.markdown, isNot(contains('[GUARD]')));
      expect(result.markdown, isNot(contains('tool-call early abort')));
    });

    test('unknown-tool streaming abort is dropped', () {
      // Streaming-time abort path for non-existent tools
      // (`_buildGuardAbortedToolResult` with `isUnknownTool ==
      // true`) emits a different body prefix — `[UNKNOWN TOOL]`
      // instead of `[GUARD]` — but the early-abort marker
      // (and the `_aborted_by_unknown_tool` stub flag) make
      // it behave identically under compaction. The tool
      // call should not appear in the inline log or the
      // summary; the registry's tool list should never leak.
      final abortResult =
          '[UNKNOWN TOOL] Crux stopped this \'ask\' tool call while '
          'its arguments were still streaming — no tool named "ask" '
          'is registered in this Crux session.\n\n'
          'Available tools: bash, edit, read, write\n\n'
          '[Crux system note — tool-call early abort]\n'
          'Crux stopped this ask tool call while its arguments '
          'were still streaming. The tool was not executed. '
          'Reason: unknown-tool.';
      final registry = ToolRegistry();
      registry.register(ReadTool());
      registry.register(EditTool());

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'ask me a question'),
          _toolCall(
            id: 2,
            toolName: 'ask',
            input: {
              '_aborted_by_unknown_tool': true,
              'requestedName': 'ask',
              'availableTools': ['bash', 'edit', 'read', 'write'],
              'question': 'hello',
            },
          ),
          _toolResult(id: 3, content: abortResult),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      // The aborted call should not appear in any of the
      // summary sections — its body is treated like a guard
      // message: dropped wholesale.
      expect(
        result.markdown,
        isNot(contains('[UNKNOWN TOOL]')),
        reason:
            'unknown-tool header must not leak into the '
            'compacted log',
      );
      expect(
        result.markdown,
        isNot(contains('tool-call early abort')),
        reason: 'early-abort marker should not survive compaction',
      );
      expect(
        result.markdown,
        isNot(contains('asked me a question')),
        reason:
            'no surrounding-text or summary contribution '
            'should remain from the aborted round',
      );
    });

    test('edit "Tool aborted" output is dropped', () {
      // The `ctx.abort.isAborted` path emits
      // `ToolResult.error('Tool aborted')` → output is the
      // literal string `Tool aborted`. `_looksLikeError` does
      // NOT catch it (it only knows about `Error: …`,
      // `Path not found: …`, `[GUARD]…`, and `exit code:` +
      // `failed`), so the no-op filter must NOT gate on
      // `isError` — it must detect the pattern directly.
      final registry = ToolRegistry();
      registry.register(EditTool());

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'edit foo'),
          _toolCall(
            id: 2,
            toolName: 'edit',
            input: {
              'filePath': 'lib/foo.dart',
              'oldString': 'class Foo {}',
              'newString': 'class Bar {}',
              'intent': 'rename',
            },
          ),
          _toolResult(id: 3, content: 'Tool aborted'),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(result.markdown, isNot(contains('edit: lib/foo.dart')));
      expect(result.markdown, isNot(contains('Tool aborted')));
    });

    test('write read-before-write guard is dropped', () {
      final guardResult =
          '[GUARD] Write was BLOCKED — file was not read before '
          'write. Your write did NOT take effect. The current '
          'file content is below; call edit or write again now '
          'and it will succeed (the file has been auto-read for '
          'you).\n\nclass Foo {}\n';
      final registry = ToolRegistry();
      registry.register(WriteTool());

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'write foo'),
          _toolCall(
            id: 2,
            toolName: 'write',
            input: {
              'filePath': 'lib/foo.dart',
              'content': 'class Bar {}',
              'intent': 'rename',
            },
          ),
          _toolResult(id: 3, content: guardResult),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(result.markdown, isNot(contains('write: lib/foo.dart')));
      expect(result.markdown, isNot(contains('[GUARD]')));
    });

    test('write size-mismatch guard is dropped', () {
      // The size-mismatch message does NOT start with
      // `[GUARD]` — it has its own UX message ("Refusing to
      // overwrite …"). Same filter must still catch it.
      // `_looksLikeError` doesn't catch this text either, so
      // the no-op filter must rely on the leading phrase
      // alone, not on `isError`.
      final sizeResult =
          'Refusing to overwrite lib/foo.dart: the existing file '
          'is 463 lines / 16.9KB, but the new content is only 1 '
          'line / 19B. This looks like an accidental full-file '
          'rewrite — the `edit` tool merges changes by oldString/'
          'newString, while `write` replaces the whole file. Use '
          '`edit` for in-place changes, or pass `force: true` if '
          'you really want to overwrite the entire file with this '
          'small payload.';
      final registry = ToolRegistry();
      registry.register(WriteTool());

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'rewrite foo'),
          _toolCall(
            id: 2,
            toolName: 'write',
            input: {
              'filePath': 'lib/foo.dart',
              'content': 'x',
              'intent': 'rewrite',
            },
          ),
          _toolResult(id: 3, content: sizeResult),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(result.markdown, isNot(contains('write: lib/foo.dart')));
      expect(result.markdown, isNot(contains('Refusing to overwrite')));
    });

    test('write "Tool aborted" output is dropped', () {
      final registry = ToolRegistry();
      registry.register(WriteTool());

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'write foo'),
          _toolCall(
            id: 2,
            toolName: 'write',
            input: {
              'filePath': 'lib/foo.dart',
              'content': 'class Bar {}',
              'intent': 'rename',
            },
          ),
          _toolResult(id: 3, content: 'Tool aborted'),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(result.markdown, isNot(contains('write: lib/foo.dart')));
      expect(result.markdown, isNot(contains('Tool aborted')));
    });

    test('non-edit/write tools are not affected (read errors are kept)', () {
      // The filter is opt-in per tool — the default
      // `isNoOpForCompaction` returns false, so a `read`
      // failure (e.g. file not found) is still rendered
      // inline with the `→ <error>` tail. The user spec is
      // specifically about edit / write noise; other tools
      // benefit from keeping the error visible in the log.
      final registry = ToolRegistry();
      registry.register(
        _StubReadTool(
          const SummaryContribution(
            category: 'read-files',
            key: 'lib/missing.dart',
            value: '',
          ),
        ),
      );

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'read missing'),
          _toolCall(
            id: 2,
            toolName: 'read',
            input: {'filePath': 'lib/missing.dart'},
          ),
          // Real read-error prefix that `_looksLikeError`
          // catches.
          _toolResult(id: 3, content: 'Path not found: lib/missing.dart'),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      expect(
        result.markdown,
        contains('read: lib/missing.dart → Path not found'),
        reason:
            'read failures must NOT be dropped — the filter '
            'is opt-in per tool, and the default keeps the '
            'error visible',
      );
    });
  });

  group('buildChatLog — auto-read routes into read files section', () {
    // The auto-read path is the one edit result that we KEEP
    // in the chat log: the call DID teach the model the file
    // content, and the resumed agent post-compact still needs
    // that snapshot to make sense of a follow-up edit. The
    // user's spec: "edit and write auto-read should be
    // 'using' the read tool, and count towards the 'all read
    // files' section." Concretely:
    //
    //   * The inline per-turn line stays as `edit: foo.dart
    //     for {intent}` — the tool the model actually called.
    //   * The bottom-of-log `read files:` section gets the
    //     file content (extracted from the auto-read response
    //     body) so the snapshot is preserved verbatim.
    //
    // Write has no auto-read analog (the tool doesn't have a
    // match step to fail on), so there's no mirror test for
    // write.

    test('edit auto-read keeps the inline line and contributes the '
        'file content to read files', () {
      // The exact shape emitted by `_autoReadResult` in
      // edit_tool.dart: `[AUTOREAD]` header line, blank line,
      // hint paragraph, blank line, file content. The test
      // uses a content body that includes internal blank
      // lines to verify the parser joins segments with
      // `\n\n` instead of splitting on every blank line.
      final fileBody =
          'class Foo {\n  void bar() {}\n\n  // blank-line comment\n}\n';
      final autoReadResult =
          '[AUTOREAD] No changes were made — The oldString was '
          'not found in the file.\n\n'
          'We re-read the file for you (saved a round trip). '
          'The current content is below; you can call edit again '
          'now without having to call read first.\n\n'
          '$fileBody';
      final registry = ToolRegistry();
      registry.register(EditTool());

      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'edit foo'),
          _toolCall(
            id: 2,
            toolName: 'edit',
            input: {
              'filePath': 'lib/foo.dart',
              'oldString': 'nope',
              'newString': 'class Bar {}',
              'intent': 'rename',
            },
          ),
          _toolResult(id: 3, content: autoReadResult),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      // Inline line preserved — the tool the model actually
      // called.
      expect(
        result.markdown,
        contains('edit: lib/foo.dart for {rename}'),
        reason:
            'auto-read edit is kept inline as the tool the '
            'model actually called',
      );
      // The auto-read response text is NOT pasted inline.
      expect(
        result.markdown,
        isNot(contains('[AUTOREAD]')),
        reason:
            'auto-read header / hint paragraph must not leak '
            'into the chat log body',
      );
      // File content makes it into the read files section.
      expect(
        result.markdown,
        contains('read files:'),
        reason: 'auto-read contributes to the read files section',
      );
      expect(result.markdown, contains('lib/foo.dart'));
      expect(
        result.markdown,
        contains('class Foo {'),
        reason:
            'file body from the auto-read response is '
            'preserved verbatim in the summary section',
      );
      // The internal blank line in the file body is preserved
      // (the parser joins segments with `\n\n` instead of
      // collapsing them).
      expect(result.markdown, contains('// blank-line comment'));
    });

    test('guard followed by successful edit in the same round: only '
        'the successful edit shows', () {
      // The common LLM streaming pattern: model emits a
      // guarded edit, sees the guard, immediately retries
      // with a corrected oldString. The retry succeeds. The
      // chat log should show ONLY the retry, not the failed
      // attempt. The retry's args are in the model history
      // already (the tool_call was emitted), so the only
      // thing missing post-compact is the inline line.
      final guardResult =
          '[GUARD] Edit was BLOCKED — oldString does not match any '
          'text in the file. Your edit did NOT take effect. The '
          'current file content is below; pick a different '
          'oldString and try again.\n\nclass Foo {}\n';
      final successResult =
          'Edit applied to lib/foo.dart (intent: \'rename\'): '
          'Replaced 1 occurrence of oldString (+1 -1 lines)';
      final registry = ToolRegistry();
      registry.register(EditTool());

      // Single tool_call message with TWO calls (the guarded
      // one and the retry), each with its own tool_result
      // message keyed by callId.
      final result = buildChatLog(
        messages: [
          _user(id: 1, content: 'edit foo'),
          Message(
            id: 2,
            sessionId: 1,
            role: 'tool_call',
            content: '',
            toolCalls: [
              ToolCallData(
                callId: 'call_2_0',
                name: 'edit',
                input: {
                  'filePath': 'lib/foo.dart',
                  'oldString': 'nope',
                  'newString': 'class Bar {}',
                  'intent': 'rename',
                },
              ),
              ToolCallData(
                callId: 'call_2_1',
                name: 'edit',
                input: {
                  'filePath': 'lib/foo.dart',
                  'oldString': 'class Foo {}',
                  'newString': 'class Bar {}',
                  'intent': 'rename',
                },
              ),
            ],
          ),
          Message(
            id: 3,
            sessionId: 1,
            role: 'tool',
            toolCallId: 'call_2_0',
            content: guardResult,
          ),
          Message(
            id: 4,
            sessionId: 1,
            role: 'tool',
            toolCallId: 'call_2_1',
            content: successResult,
          ),
        ],
        workingDirectory: '/tmp/proj',
        toolRegistry: registry,
      );

      // The retry renders inline (success path).
      expect(result.markdown, contains('edit: lib/foo.dart for {rename}'));
      // The guarded call is gone — no [GUARD] / guard header.
      expect(
        result.markdown,
        isNot(contains('[GUARD]')),
        reason:
            'guarded edit is dropped; the successful retry '
            'is the durable signal',
      );
      // No `→` for the retry (success path; error path would
      // append `→ <result>`).
      expect(
        result.markdown,
        isNot(contains('Edit applied to lib/foo.dart →')),
        reason:
            'successful edit renders without the result '
            'payload; the success summary is in the model\'s '
            'tool call history, not the chat log',
      );
    });
  });
}
