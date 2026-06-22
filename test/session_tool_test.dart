import 'dart:io';

import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/models/message.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/session_tool.dart';
import 'package:crux/src/tools/tool_def.dart';

void main() {
  late CruxDatabase db;
  late SessionStore store;
  late SessionTool tool;
  late Directory tempProject;
  late int sessionA;
  late int sessionB;

  ToolContext ctxOf(int sessionId, {String? workingDirectory}) =>
      ToolContext(
        sessionId: sessionId,
        messageId: 0,
        abort: AbortSignal(),
        workingDirectory: workingDirectory ?? tempProject.path,
      );

  setUp(() async {
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    store = SessionStore(db);
    tool = SessionTool(store: store);

    tempProject = await Directory.systemTemp.createTemp('crux_session_tool_');
    addTearDown(() async {
      if (await tempProject.exists()) {
        await tempProject.delete(recursive: true);
      }
    });

    final a = await store.create(
      title: 'Session A — debug the LSP hang',
      model: 'anthropic/claude-sonnet-4',
      projectPath: tempProject.path,
    );
    sessionA = a.id;

    await store.messageStore.addMessage(sessionA, role: 'user', content: 'the lsp hangs on /Users/developer');
    await store.messageStore.addMessage(
      sessionA,
      role: 'assistant',
      content: 'Let me check the language server status.',
    );
    await store.messageStore.addMessage(
      sessionA,
      role: 'tool_call',
      content: '',
      toolCalls: [
        ToolCallData(
          callId: 'toolu_1',
          name: 'bash',
          input: {'command': 'ps aux | grep dart', 'intent': 'list dart procs'},
        ),
      ],
    );
    await store.messageStore.addMessage(
      sessionA,
      role: 'tool',
      content: 'developer 12345 ... dart --observe bin/crux.dart',
      toolCallId: 'toolu_1',
    );

    // Sleep 2ms so session B's updatedAt is strictly greater than A's,
    // making the "most-recent first" list ordering deterministic.
    await Future<void>.delayed(const Duration(milliseconds: 2));

    final b = await store.create(
      title: 'Session B — write the session tool',
      model: 'anthropic/claude-sonnet-4',
      projectPath: tempProject.path,
    );
    sessionB = b.id;
    await store.messageStore.addMessage(
      sessionB,
      role: 'user',
      content: 'add a new tool, the tool is called session',
    );
    await store.messageStore.addMessage(
      sessionB,
      role: 'assistant',
      content: 'Sure, I will add the session tool now.',
    );
  });

  // ── schema ────────────────────────────────────────────────────────

  test('schema exposes the expected actions', () {
    final schema = tool.parametersSchema;
    final actions = (schema['properties'] as Map)['action'] as Map;
    expect((actions['enum'] as List), containsAll([
      'list', 'show', 'messages', 'search',
    ]));
    // The removed actions must not reappear.
    expect(actions['enum'] as List, isNot(contains('current')));
    expect(actions['enum'] as List, isNot(contains('message')));
    expect(schema['required'], contains('action'));
  });

  // ── action: list ─────────────────────────────────────────────────

  test('action=list hides the current session by default', () async {
    final result = await tool.execute(
      {'action': 'list'},
      ctxOf(sessionB), // sessionB is "current"
    );
    // sessionB is hidden; only sessionA is shown.
    expect(result.output, contains('Session A — debug the LSP hang'));
    expect(result.output, isNot(contains('Session B — write the session tool')));
    expect(result.output, contains('current session ses://$sessionB hidden'));
    expect(result.metadata['returned'], 1);
    expect(result.metadata['hiddenCurrent'], isTrue);
  });

  test('action=list with includeCurrent=true shows the current session too',
      () async {
    final result = await tool.execute(
      {'action': 'list', 'includeCurrent': true},
      ctxOf(sessionB),
    );
    expect(result.output, contains('Session A — debug the LSP hang'));
    expect(result.output, contains('Session B — write the session tool'));
    // Session B is more recent so it appears first.
    final idxA = result.output.indexOf('Session A');
    final idxB = result.output.indexOf('Session B');
    expect(idxB, lessThan(idxA));
    expect(result.metadata['returned'], 2);
    expect(result.metadata['hiddenCurrent'], isFalse);
  });

  test('action=list with no other sessions explains the empty result',
      () async {
    // Archive A so the only remaining session in this project is B
    // (which is current → hidden by default). Both filters apply
    // and the result is empty.
    await store.archiveSession(sessionA);

    final result = await tool.execute(
      {'action': 'list'},
      ctxOf(sessionB),
    );
    expect(result.output, contains('No other sessions found'));
    expect(result.output, contains('current session ses://$sessionB is hidden'));
    expect(result.output, contains('includeCurrent: true'));
  });

  test('action=list respects includeArchived and project filter', () async {
    await store.archiveSession(sessionA);

    final withoutArchived = await tool.execute(
      {'action': 'list', 'includeCurrent': true},
      ctxOf(sessionB),
    );
    expect(withoutArchived.output, isNot(contains('Session A — debug')));

    final withArchived = await tool.execute(
      {'action': 'list', 'includeCurrent': true, 'includeArchived': true},
      ctxOf(sessionB),
    );
    expect(withArchived.output, contains('Session A — debug'));

    final otherProject = await tool.execute(
      {'action': 'list', 'includeCurrent': true, 'project': '/some/other/project'},
      ctxOf(sessionB),
    );
    expect(otherProject.output, contains('No other sessions found'));
  });

  // ── action: show ──────────────────────────────────────────────────

  test('action=show returns metadata + recent messages for another session',
      () async {
    final result = await tool.execute(
      {'action': 'show', 'sessionId': sessionA},
      ctxOf(sessionB),
    );
    expect(result.output, contains('Session ses://$sessionA'));
    expect(result.output, contains('anthropic/claude-sonnet-4'));
    expect(result.output, contains('the lsp hangs'));
    expect(result.output, contains('Recent messages'));
    expect(result.metadata['sessionId'], sessionA);
    expect(result.metadata['totalMessages'], 4);
  });

  test('action=show requires sessionId', () async {
    final result = await tool.execute(
      {'action': 'show'},
      ctxOf(sessionB),
    );
    expect(result.output, contains('Missing required parameter'));
    expect(result.output, contains('sessionId'));
  });

  test('action=show errors on unknown session', () async {
    final result = await tool.execute(
      {'action': 'show', 'sessionId': 99999},
      ctxOf(sessionB),
    );
    expect(result.output, contains('No session with id ses://99999'));
  });

  // ── action: messages ──────────────────────────────────────────────

  test('action=messages returns full message content', () async {
    final result = await tool.execute(
      {'action': 'messages', 'sessionId': sessionA, 'limit': 10},
      ctxOf(sessionB),
    );
    expect(result.output, contains('the lsp hangs on /Users/developer'));
    expect(result.output, contains('Let me check the language server status'));
    expect(result.output, contains('tool_calls:'));
    expect(result.output, contains('bash'));
    expect(result.output, contains('ps aux | grep dart'));
  });

  test('action=messages requires sessionId', () async {
    final result = await tool.execute(
      {'action': 'messages'},
      ctxOf(sessionB),
    );
    expect(result.output, contains('Missing required parameter'));
    expect(result.output, contains('sessionId'));
  });

  test('action=messages filters by role', () async {
    final result = await tool.execute(
      {'action': 'messages', 'sessionId': sessionA, 'role': 'tool'},
      ctxOf(sessionB),
    );
    expect(result.output, contains('developer 12345'));
    expect(result.output, isNot(contains('the lsp hangs')));
  });

  test('action=messages default returns the latest N messages, not the oldest',
      () async {
    // Session A has 4 messages, in this order:
    //   1: user "the lsp hangs..."
    //   2: assistant "Let me check the language server status."
    //   3: tool_call bash with "ps aux | grep dart"
    //   4: tool result "developer 12345 ... dart --observe bin/crux.dart"
    // With limit=2 we expect the LATEST two (ids 3 and 4), not the
    // first two (ids 1 and 2). This locks in the "tail of the
    // session" semantic.
    final tail = await tool.execute(
      {
        'action': 'messages',
        'sessionId': sessionA,
        'limit': 2,
      },
      ctxOf(sessionB),
    );
    expect(tail.metadata['returned'], 2);
    expect(tail.metadata['total'], 4);
    // The earliest two must NOT be present.
    expect(tail.output, isNot(contains('the lsp hangs on /Users/developer')));
    expect(tail.output, isNot(contains('language server status')));
    // The latest two MUST be present.
    expect(tail.output, contains('ps aux | grep dart'));
    expect(tail.output, contains('developer 12345'));
    // And the footer should point the caller at the next page
    // (the oldest id on this page = the cursor to walk back from).
    expect(tail.output, contains('beforeId=3'));
  });

  test('action=messages beforeId excludes the cursor message', () async {
    // `beforeId` is exclusive: returns messages with id < beforeId,
    // still the latest N of that subset, in chronological order.
    // Session A has ids 1..4. With beforeId=3, limit=10 we get
    // everything with id<3 (ids 1 and 2) — and no footer, because
    // we got everything available.
    final head = await tool.execute(
      {
        'action': 'messages',
        'sessionId': sessionA,
        'beforeId': 3,
        'limit': 10,
      },
      ctxOf(sessionB),
    );
    expect(head.metadata['returned'], 2);
    expect(head.output, contains('the lsp hangs on /Users/developer'));
    expect(head.output, contains('Let me check the language server status'));
    expect(head.output, isNot(contains('ps aux | grep dart')));
    // Nothing more to show below the cursor, so no pagination hint.
    expect(head.output, isNot(contains('more messages exist')));
  });

  test('action=messages beforeId + tight limit paginates correctly',
      () async {
    // Same session (ids 1..4). With beforeId=3, limit=1 we get the
    // latest 1 with id<3 → id=2, and the footer points at id=2 so
    // the caller walks back one more step.
    final page = await tool.execute(
      {
        'action': 'messages',
        'sessionId': sessionA,
        'beforeId': 3,
        'limit': 1,
      },
      ctxOf(sessionB),
    );
    expect(page.metadata['returned'], 1);
    expect(page.output, contains('Let me check the language server status'));
    expect(page.output, isNot(contains('the lsp hangs')));
    expect(page.output, isNot(contains('ps aux')));
    // The next-page cursor is the oldest id on this page (the only
    // id), so the next call beforeId=2 returns id=1.
    expect(page.output, contains('beforeId=2'));
  });

  test('action=messages pagination walks a long session correctly', () async {
    // Add 5 more assistant messages. Note that `Messages.id` is a
    // global auto-increment, not per-session, so we can't hard-
    // code the new ids — but we can assert structural invariants
    // across a backward walk.
    for (var i = 0; i < 5; i++) {
      await store.messageStore.addMessage(
        sessionA,
        role: 'assistant',
        content: 'follow-up reply $i',
      );
    }

    // Sanity: sessionA has 9 messages.
    final totalA = await store.messageStore.countBySession(sessionA);
    expect(totalA, 9);

    // Walk the session backwards in pages of 3.
    final seenIds = <int>[];
    int? beforeId;
    while (true) {
      final result = await tool.execute(
        {
          'action': 'messages',
          'sessionId': sessionA,
          'limit': 3,
          // ignore: use_null_aware_elements
          if (beforeId != null) 'beforeId': beforeId,
        },
        ctxOf(sessionB),
      );
      final returned = result.metadata['returned'] as int;
      final idRegex = RegExp(r'\[#(\d+)\]');
      for (final m in idRegex.allMatches(result.output)) {
        seenIds.add(int.parse(m.group(1)!));
      }
      if (returned < 3) break;
      final footerMatch =
          RegExp(r'beforeId=(\d+)').firstMatch(result.output);
      if (footerMatch == null) break;
      beforeId = int.parse(footerMatch.group(1)!);
    }

    // Structural invariants:
    //   - every id was visited exactly once,
    //   - the order within each page is chronological (ascending),
    //   - the first page is the tail (ids strictly decreasing across
    //     page boundaries, so the walk goes from newest to oldest).
    expect(seenIds.length, 9);
    expect(seenIds.toSet().length, 9, reason: 'no duplicate ids');
    for (var i = 0; i < seenIds.length; i += 3) {
      final page = seenIds.skip(i).take(3).toList();
      expect(page, orderedEquals([...page]..sort()),
          reason: 'page $i is chronological: $page');
    }
    for (var i = 3; i < seenIds.length; i += 3) {
      expect(seenIds[i], lessThan(seenIds[i - 1]),
          reason: 'page boundary $i: tail-first walk');
    }
  });

  test('action=show returns the most recent messages, not the oldest',
      () async {
    // Add 3 more assistant messages so the session is long enough
    // that "show" with a tight limit has to truncate, and we can
    // verify it truncates the head, not the tail.
    for (var i = 0; i < 3; i++) {
      await store.messageStore.addMessage(
        sessionA,
        role: 'assistant',
        content: 'tail reply $i',
      );
    }
    final result = await tool.execute(
      {'action': 'show', 'sessionId': sessionA, 'limit': 2},
      ctxOf(sessionB),
    );
    expect(result.metadata['totalMessages'], 7);
    // The two oldest must NOT be present.
    expect(result.output, isNot(contains('the lsp hangs on /Users/developer')));
    expect(result.output, isNot(contains('language server status')));
    // The two latest MUST be present.
    expect(result.output, contains('tail reply 1'));
    expect(result.output, contains('tail reply 2'));
    // The footer should be honest about the truncation and point
    // at the next page (oldest id on the shown page).
    expect(result.output, contains('most recent'));
    final m = RegExp(r'beforeId=(\d+)').firstMatch(result.output);
    expect(m, isNotNull);
    final beforeIdFromFooter = int.parse(m!.group(1)!);
    // Following that cursor should return older messages and NOT
    // the ones we just saw.
    final followup = await tool.execute(
      {
        'action': 'messages',
        'sessionId': sessionA,
        'beforeId': beforeIdFromFooter,
        'limit': 5,
      },
      ctxOf(sessionB),
    );
    expect(followup.output, contains('tail reply 0'));
    expect(followup.output, isNot(contains('tail reply 2')));
  });

  // ── action: search ────────────────────────────────────────────────

  test('action=search finds matches across other sessions', () async {
    final result = await tool.execute(
      {
        'action': 'search',
        'pattern': r'session tool',
        'maxSessions': 10,
      },
      ctxOf(sessionB),
    );
    // The assistant message in B is the only place the literal
    // substring "session tool" appears.
    expect(result.output, contains('add the session tool now'));
    expect(result.metadata['totalMatches'], greaterThanOrEqualTo(1));
    expect(result.metadata['sessionsScanned'], 2);
  });

  test('action=search supports case-insensitive matching', () async {
    final result = await tool.execute(
      {
        'action': 'search',
        'pattern': r'lsp',
        'caseInsensitive': true,
        'maxSessions': 10,
      },
      ctxOf(sessionB),
    );
    expect(result.output, contains('the lsp hangs'));
  });

  test('action=search respects headLimit and reports truncation', () async {
    final result = await tool.execute(
      {
        'action': 'search',
        'pattern': r'.',
        'headLimit': 3,
        'maxSessions': 10,
      },
      ctxOf(sessionB),
    );
    expect(result.truncated, isTrue);
    expect(result.output, contains('truncated'));
  });

  test('action=search within a single session pins to that session', () async {
    final result = await tool.execute(
      {
        'action': 'search',
        'pattern': r'language server',
        'sessionId': sessionA,
      },
      ctxOf(sessionB),
    );
    expect(result.output, contains('language server status'));
    expect(result.metadata['sessionId'], sessionA);
    // And the result should NOT mention content from session B.
    expect(result.output, isNot(contains('write the session tool')));
  });

  test('action=search returns no-match output for absent pattern', () async {
    final result = await tool.execute(
      {
        'action': 'search',
        'pattern': r'zzzzz-no-such-string',
        'maxSessions': 10,
      },
      ctxOf(sessionB),
    );
    expect(result.output, contains('No matches'));
    expect(result.metadata['totalMatches'], 0);
  });

  test('action=search rejects invalid regex', () async {
    final result = await tool.execute(
      {
        'action': 'search',
        'pattern': r'(unclosed',
        'maxSessions': 10,
      },
      ctxOf(sessionB),
    );
    expect(result.output, contains('Invalid regex'));
  });

  // ── edge cases ───────────────────────────────────────────────────

  test('errors on missing action', () async {
    final result = await tool.execute({}, ctxOf(sessionB));
    expect(result.output, contains('Missing required parameter: action'));
  });

  test('errors on unknown action', () async {
    final result = await tool.execute(
      {'action': 'teleport'},
      ctxOf(sessionB),
    );
    expect(result.output, contains('Unknown action'));
    expect(result.output, contains('list, show, messages, search'));
  });
}