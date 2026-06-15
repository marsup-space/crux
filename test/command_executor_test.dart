// Tests for [CommandExecutor] that don't require a full chat pipeline.
//
// We construct a [CommandContext] with mock callbacks for
// `sendTurn`, `findLastUserMessage`, and `deleteMessagesFrom` and
// verify the executor routes each scenario through the right
// callback (or rejects it with a toast).
//
// Each test gets its own in-memory database via
// [CruxDatabase.forTesting] so writes don't collide on the
// shared on-disk `crux.db`. Drift will still print a
// "database created multiple times" warning because it counts
// CruxDatabase instances rather than executors; that's harmless
// here because each instance is backed by its own
// NativeDatabase.memory().

import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:crux/src/commands/command_executor.dart';
import 'package:crux/src/components/ui/toast.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/storage/storage.dart';

void main() {
  group('CommandExecutor — /continue', () {
    late Directory tempDir;
    late ProviderService providerService;
    late SessionStore store;
    late Session session;
    late SessionRuntimeState runtime;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_exec_test_');
      providerService = ProviderService(userProvidersDir: tempDir.path);
      final db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      // A real session id is required so `runtime` and friends have
      // a backing SessionRuntimeState to mutate. The DB is in
      // memory so the test stays isolated.
      session = await store.create(
        title: 'Test Session',
        model: '',
        projectPath: tempDir.path,
      );
      runtime = SessionRuntimeState(sessionId: session.id);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    CommandContext buildContext({
      required List<Message> currentMessages,
      required Future<void> Function({String? text}) sendTurnImpl,
      Future<Message?> Function()? findLastUserMessageImpl,
      Future<void> Function(int)? deleteMessagesFromImpl,
      Future<void> Function(String prompt)? sendBtwTurnImpl,
      void Function(int sessionId)? clearBtwTurnsImpl,
    }) {
      return CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        currentSession: session,
        currentSessionId: session.id,
        sessions: [session],
        currentMessages: currentMessages,
        projectPath: tempDir.path,
        refresh: () {},
        showToast: (message, {ToastMode? mode}) {},
        switchSession: (_) async {},
        initSessions: () async {},
        createNewSession: () async {},
        runtime: (id) => runtime,
        persistThinkingLevel: (_) {},
        resolveAuxiliaryModel: () => {},
        sendTurn: sendTurnImpl,
        findLastUserMessage: findLastUserMessageImpl ??
            () async => null,
        deleteMessagesFrom: deleteMessagesFromImpl ??
            (_) async {},
        sendBtwTurn: sendBtwTurnImpl ?? (_) async {},
        clearBtwTurns: clearBtwTurnsImpl ?? (_) {},
      );
    }

    test(
      'resubmits context verbatim when last segment is a tool result',
      () async {
        // Simulate the typical "interrupted after a tool call
        // returned but before the AI produced its final answer"
        // case. The LLM APIs accept a trailing tool turn, so
        // /continue should round-trip the history with no nudge.
        final messages = <Message>[
          Message(
            id: 1,
            sessionId: session.id,
            role: 'user',
            content: 'list the files',
          ),
          Message(
            id: 2,
            sessionId: session.id,
            role: 'ai',
            content: '',
            toolCalls: const [],
          ),
          Message(
            id: 3,
            sessionId: session.id,
            role: 'tool',
            content: 'README.md\nlib/\ntest/',
            toolCallId: 'call_1',
          ),
        ];

        var sendTurnCalls = 0;
        String? lastTextSent;
        var sendCalledWithText = false;
        await CommandExecutor().execute(
          '/continue',
          buildContext(
            currentMessages: messages,
            sendTurnImpl: ({String? text}) async {
              sendTurnCalls++;
              lastTextSent = text;
              sendCalledWithText = text != null;
            },
          ),
        );

        expect(sendTurnCalls, equals(1),
            reason: 'should drive exactly one turn');
        expect(sendCalledWithText, isFalse,
            reason:
                'no nudge should be appended when the last segment '
                'is a tool result — the wire format already ends on '
                'a valid trailing turn');
        expect(lastTextSent, isNull);
      },
    );

    test(
      'resubmits context verbatim when last segment is a bare user message',
      () async {
        // The user submitted a message and the AI was interrupted
        // before producing any output. Resubmitting as-is ends on
        // `role: user` which the API also accepts, so no nudge
        // is needed.
        final messages = <Message>[
          Message(
            id: 1,
            sessionId: session.id,
            role: 'user',
            content: 'build me a TUI',
          ),
        ];

        var sendTurnCalls = 0;
        String? lastTextSent;
        await CommandExecutor().execute(
          '/continue',
          buildContext(
            currentMessages: messages,
            sendTurnImpl: ({String? text}) async {
              sendTurnCalls++;
              lastTextSent = text;
            },
          ),
        );

        expect(sendTurnCalls, equals(1));
        expect(lastTextSent, isNull,
            reason:
                'resubmitting a bare user message is fine — the '
                'API accepts a trailing user turn, so no nudge.');
      },
    );

    test(
      'appends a 请继续 nudge when last segment is an AI response',
      () async {
        // The previous round completed normally. Resubmitting
        // as-is would end on `role: assistant` which the LLM APIs
        // reject, so /continue must append a small user turn.
        final messages = <Message>[
          Message(
            id: 1,
            sessionId: session.id,
            role: 'user',
            content: 'explain monads',
          ),
          Message(
            id: 2,
            sessionId: session.id,
            role: 'ai',
            content: 'A monad is a monoid in the category of...',
          ),
        ];

        var sendTurnCalls = 0;
        String? lastTextSent;
        await CommandExecutor().execute(
          '/continue',
          buildContext(
            currentMessages: messages,
            sendTurnImpl: ({String? text}) async {
              sendTurnCalls++;
              lastTextSent = text;
            },
          ),
        );

        expect(sendTurnCalls, equals(1));
        expect(lastTextSent, isNotNull,
            reason: 'must append a user turn to satisfy the '
                'role-alternation rule');
        expect(lastTextSent, equals('请继续。'));
      },
    );

    test(
      'is a no-op when the AI is already responding',
      () async {
        // A second concurrent chat turn would race the in-flight
        // stream, so /continue must bail out and surface a toast.
        runtime.isResponding = true;

        var sendTurnCalls = 0;
        await CommandExecutor().execute(
          '/continue',
          buildContext(
            currentMessages: const <Message>[],
            sendTurnImpl: ({String? text}) async {
              sendTurnCalls++;
            },
          ),
        );

        expect(sendTurnCalls, equals(0),
            reason: 'must not drive a turn while one is in flight');
      },
    );

        test(
      'also works for the Chinese alias /继续',
      () async {
        // Make sure the dispatch table in `execute()` routes the
        // alias to the same handler as the canonical name.
        final messages = <Message>[
          Message(
            id: 1,
            sessionId: session.id,
            role: 'ai',
            content: 'hello',
          ),
        ];

        var sendTurnCalls = 0;
        String? lastTextSent;
        await CommandExecutor().execute(
          '/继续',
          buildContext(
            currentMessages: messages,
            sendTurnImpl: ({String? text}) async {
              sendTurnCalls++;
              lastTextSent = text;
            },
          ),
        );

        expect(sendTurnCalls, equals(1));
        expect(lastTextSent, equals('请继续。'));
      },
    );

    test(
      'is a no-op with a toast when the session is empty',
      () async {
        // A brand-new, empty session has no prior context for the
        // LLM to continue from. The executor must reject this up
        // front (with a toast) instead of firing a synthetic
        // "请继续。" user turn against an empty history — there is
        // nothing meaningful to send, and on most LLM APIs the
        // resulting call (a single user turn with no system
        // prompt context) would just confuse the model.
        var sendTurnCalls = 0;
        String? lastToast;
        await CommandExecutor().execute(
          '/continue',
          CommandContext(
            store: store,
            providerService: providerService,
            providerServiceReady: false,
            currentSession: session,
            currentSessionId: session.id,
            sessions: [session],
            currentMessages: const <Message>[],
            projectPath: tempDir.path,
            refresh: () {},
            showToast: (message, {ToastMode? mode}) {
              lastToast = message;
            },
            switchSession: (_) async {},
            initSessions: () async {},
            createNewSession: () async {},
            runtime: (id) => runtime,
            persistThinkingLevel: (_) {},
            resolveAuxiliaryModel: () {},
            sendTurn: ({String? text}) async {
              sendTurnCalls++;
            },
            findLastUserMessage: () async => null,
            deleteMessagesFrom: (_) async {},
            sendBtwTurn: (_) async {},
            clearBtwTurns: (_) {},
          ),
        );

        expect(sendTurnCalls, equals(0),
            reason: 'must not drive a turn when there is nothing '
                'to continue');
        expect(lastToast, isNotNull,
            reason: 'should surface a toast explaining the rejection');
        expect(lastToast, contains('empty'),
            reason: 'toast should mention the session is empty');
      },
    );
  });

  group('CommandExecutor — /retry', () {
    late Directory tempDir;
    late ProviderService providerService;
    late SessionStore store;
    late Session session;
    late SessionRuntimeState runtime;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_retry_test_');
      providerService = ProviderService(userProvidersDir: tempDir.path);
      final db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      session = await store.create(
        title: 'Test Session',
        model: '',
        projectPath: tempDir.path,
      );
      runtime = SessionRuntimeState(sessionId: session.id);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'wipes the last round and re-sends the original user text',
      () async {
        // The user submitted "build me a TUI", the AI responded
        // with a plan, and the user now hits /retry. We expect:
        //   1. findLastUserMessage returns the real user message
        //   2. deleteMessagesFrom is called with that id
        //   3. sendTurn is called with the original user content
        // The order matters — the wipe must complete before the
        // re-send so we don't briefly render a duplicate.
        const userText = 'build me a TUI';
        final userMsg = await store.messageStore.addMessage(
          session.id,
          role: 'user',
          content: userText,
        );
        await store.messageStore.addMessage(
          session.id,
          role: 'ai',
          content: 'Sure, let me plan this out...',
        );
        final currentMessages = await store.messageStore.getMessages(session.id);

        final events = <String>[];
        await CommandExecutor().execute(
          '/retry',
          CommandContext(
            store: store,
            providerService: providerService,
            providerServiceReady: false,
            currentSession: session,
            currentSessionId: session.id,
            sessions: [session],
            currentMessages: currentMessages,
            projectPath: tempDir.path,
            refresh: () {},
            showToast: (message, {ToastMode? mode}) {},
            switchSession: (_) async {},
            initSessions: () async {},
            createNewSession: () async {},
            runtime: (id) => runtime,
            persistThinkingLevel: (_) {},
            resolveAuxiliaryModel: () {},
            sendTurn: ({String? text}) async {
              events.add('sendTurn:${text ?? '<null>'}');
            },
            findLastUserMessage: () async {
              events.add('findLastUserMessage');
              return userMsg;
            },
            deleteMessagesFrom: (fromId) async {
              events.add('deleteMessagesFrom:$fromId');
            },
            sendBtwTurn: (_) async {},
            clearBtwTurns: (_) {},
          ),
        );

        expect(events, equals(<String>[
          'findLastUserMessage',
          'deleteMessagesFrom:${userMsg.id}',
          'sendTurn:$userText',
        ]));
      },
    );

    test(
      'is a no-op when the AI is already responding',
      () async {
        runtime.isResponding = true;

        var deleteCalls = 0;
        var sendTurnCalls = 0;
        await CommandExecutor().execute(
          '/retry',
          CommandContext(
            store: store,
            providerService: providerService,
            providerServiceReady: false,
            currentSession: session,
            currentSessionId: session.id,
            sessions: [session],
            currentMessages: const <Message>[],
            projectPath: tempDir.path,
            refresh: () {},
            showToast: (message, {ToastMode? mode}) {},
            switchSession: (_) async {},
            initSessions: () async {},
            createNewSession: () async {},
            runtime: (id) => runtime,
            persistThinkingLevel: (_) {},
            resolveAuxiliaryModel: () {},
            sendTurn: ({String? text}) async {
              sendTurnCalls++;
            },
            findLastUserMessage: () async => null,
            deleteMessagesFrom: (fromId) async {
              deleteCalls++;
            },
            sendBtwTurn: (_) async {},
            clearBtwTurns: (_) {},
          ),
        );

        expect(deleteCalls, equals(0));
        expect(sendTurnCalls, equals(0));
      },
    );

    test(
      'is a no-op when there is no user message to retry',
      () async {
        var deleteCalls = 0;
        var sendTurnCalls = 0;
        await CommandExecutor().execute(
          '/retry',
          CommandContext(
            store: store,
            providerService: providerService,
            providerServiceReady: false,
            currentSession: session,
            currentSessionId: session.id,
            sessions: [session],
            currentMessages: const <Message>[],
            projectPath: tempDir.path,
            refresh: () {},
            showToast: (message, {ToastMode? mode}) {},
            switchSession: (_) async {},
            initSessions: () async {},
            createNewSession: () async {},
            runtime: (id) => runtime,
            persistThinkingLevel: (_) {},
            resolveAuxiliaryModel: () {},
            sendTurn: ({String? text}) async {
              sendTurnCalls++;
            },
            findLastUserMessage: () async => null,
            deleteMessagesFrom: (fromId) async {
              deleteCalls++;
            },
            sendBtwTurn: (_) async {},
            clearBtwTurns: (_) {},
          ),
        );

        expect(deleteCalls, equals(0));
        expect(sendTurnCalls, equals(0));
      },
    );

    test(
      'also works for the Chinese alias /重试',
      () async {
        const userText = 'hello world';
        final userMsg = await store.messageStore.addMessage(
          session.id,
          role: 'user',
          content: userText,
        );
        final currentMessages = await store.messageStore.getMessages(session.id);

        var sendTurnCalls = 0;
        String? lastTextSent;
        var deleteFromId = -1;
        await CommandExecutor().execute(
          '/重试',
          CommandContext(
            store: store,
            providerService: providerService,
            providerServiceReady: false,
            currentSession: session,
            currentSessionId: session.id,
            sessions: [session],
            currentMessages: currentMessages,
            projectPath: tempDir.path,
            refresh: () {},
            showToast: (message, {ToastMode? mode}) {},
            switchSession: (_) async {},
            initSessions: () async {},
            createNewSession: () async {},
            runtime: (id) => runtime,
            persistThinkingLevel: (_) {},
            resolveAuxiliaryModel: () {},
            sendTurn: ({String? text}) async {
              sendTurnCalls++;
              lastTextSent = text;
            },
            findLastUserMessage: () async => userMsg,
            deleteMessagesFrom: (fromId) async {
              deleteFromId = fromId;
            },
            sendBtwTurn: (_) async {},
            clearBtwTurns: (_) {},
          ),
        );

        expect(sendTurnCalls, equals(1));
        expect(lastTextSent, equals(userText));
        expect(deleteFromId, equals(userMsg.id));
      },
    );
  });

  group('CommandExecutor — /btw', () {
    late Directory tempDir;
    late ProviderService providerService;
    late SessionStore store;
    late Session session;
    late SessionRuntimeState runtime;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_btw_test_');
      providerService = ProviderService(userProvidersDir: tempDir.path);
      final db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      session = await store.create(
        title: 'Test Session',
        model: '',
        projectPath: tempDir.path,
      );
      runtime = SessionRuntimeState(sessionId: session.id);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'drives sendBtwTurn with the full prompt text',
      () async {
        // `/btw how do I rename a file in bash?` should be
        // forwarded to sendBtwTurn as a single string. The
        // executor re-joins parts[1..] with spaces (rather than
        // passing just parts[1]) so prompts that contain spaces
        // round-trip verbatim.
        String? capturedPrompt;
        var sendCalls = 0;
        await CommandExecutor().execute(
          '/btw how do I rename a file in bash?',
          CommandContext(
            store: store,
            providerService: providerService,
            providerServiceReady: false,
            currentSession: session,
            currentSessionId: session.id,
            sessions: [session],
            currentMessages: const <Message>[],
            projectPath: tempDir.path,
            refresh: () {},
            showToast: (message, {ToastMode? mode}) {},
            switchSession: (_) async {},
            initSessions: () async {},
            createNewSession: () async {},
            runtime: (id) => runtime,
            persistThinkingLevel: (_) {},
            resolveAuxiliaryModel: () {},
            sendTurn: ({String? text}) async {},
            findLastUserMessage: () async => null,
            deleteMessagesFrom: (_) async {},
            sendBtwTurn: (prompt) async {
              capturedPrompt = prompt;
              sendCalls++;
            },
            clearBtwTurns: (_) {},
          ),
        );

        expect(sendCalls, equals(1),
            reason: 'should drive exactly one btw turn');
        expect(capturedPrompt, equals('how do I rename a file in bash?'),
            reason: 'prompt must round-trip with internal spaces intact');
      },
    );

    test(
      'shows a usage toast when called without a prompt',
      () async {
        // Bare `/btw` and `/btw ` (with trailing space, trimmed to
        // empty) should both surface a usage toast and never call
        // sendBtwTurn.
        for (final invocation in <String>['/btw', '/btw ', '/btw   ']) {
          var sendCalls = 0;
          String? lastToast;
          await CommandExecutor().execute(
            invocation,
            CommandContext(
              store: store,
              providerService: providerService,
              providerServiceReady: false,
              currentSession: session,
              currentSessionId: session.id,
              sessions: [session],
              currentMessages: const <Message>[],
              projectPath: tempDir.path,
              refresh: () {},
              showToast: (message, {ToastMode? mode}) {
                lastToast = message;
              },
              switchSession: (_) async {},
              initSessions: () async {},
              createNewSession: () async {},
              runtime: (id) => runtime,
              persistThinkingLevel: (_) {},
              resolveAuxiliaryModel: () {},
              sendTurn: ({String? text}) async {},
              findLastUserMessage: () async => null,
              deleteMessagesFrom: (_) async {},
              sendBtwTurn: (_) async {
                sendCalls++;
              },
              clearBtwTurns: (_) {},
            ),
          );

          expect(sendCalls, equals(0),
              reason: 'must not fire a btw turn with no prompt '
                  '(input: "$invocation")');
          expect(lastToast, isNotNull,
              reason: 'should surface a usage toast');
          expect(lastToast, contains('Usage'),
              reason: 'toast should explain the correct usage');
        }
      },
    );

    test(
      'is a no-op when the AI is already responding',
      () async {
        // A second concurrent turn would race the in-flight
        // stream (either a normal turn or a prior btw), so /btw
        // must bail out and surface a toast.
        runtime.isResponding = true;

        var sendCalls = 0;
        String? lastToast;
        await CommandExecutor().execute(
          '/btw hello?',
          CommandContext(
            store: store,
            providerService: providerService,
            providerServiceReady: false,
            currentSession: session,
            currentSessionId: session.id,
            sessions: [session],
            currentMessages: const <Message>[],
            projectPath: tempDir.path,
            refresh: () {},
            showToast: (message, {ToastMode? mode}) {
              lastToast = message;
            },
            switchSession: (_) async {},
            initSessions: () async {},
            createNewSession: () async {},
            runtime: (id) => runtime,
            persistThinkingLevel: (_) {},
            resolveAuxiliaryModel: () {},
            sendTurn: ({String? text}) async {},
            findLastUserMessage: () async => null,
            deleteMessagesFrom: (_) async {},
            sendBtwTurn: (_) async {
              sendCalls++;
            },
            clearBtwTurns: (_) {},
          ),
        );

        expect(sendCalls, equals(0),
            reason: 'must not drive a btw turn while one is in flight');
        expect(lastToast, isNotNull);
      },
    );

    test(
      'rejects with a toast when there is no active session',
      () async {
        // The CommandContext's currentSessionId is null (we
        // construct it that way). The executor should bail out
        // with a toast rather than calling sendBtwTurn.
        var sendCalls = 0;
        String? lastToast;
        await CommandExecutor().execute(
          '/btw hi',
          CommandContext(
            store: store,
            providerService: providerService,
            providerServiceReady: false,
            currentSession: Session(id: 0, title: 'New Session'),
            currentSessionId: null,
            sessions: const <Session>[],
            currentMessages: const <Message>[],
            projectPath: tempDir.path,
            refresh: () {},
            showToast: (message, {ToastMode? mode}) {
              lastToast = message;
            },
            switchSession: (_) async {},
            initSessions: () async {},
            createNewSession: () async {},
            runtime: (id) => runtime,
            persistThinkingLevel: (_) {},
            resolveAuxiliaryModel: () {},
            sendTurn: ({String? text}) async {},
            findLastUserMessage: () async => null,
            deleteMessagesFrom: (_) async {},
            sendBtwTurn: (_) async {
              sendCalls++;
            },
            clearBtwTurns: (_) {},
          ),
        );

        expect(sendCalls, equals(0));
        expect(lastToast, isNotNull);
      },
    );
  });

  group('CommandExecutor — /rename', () {
    late Directory tempDir;
    late ProviderService providerService;
    late SessionStore store;
    late Session session;
    late SessionRuntimeState runtime;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_exec_test_');
      providerService = ProviderService(userProvidersDir: tempDir.path);
      final db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      session = await store.create(
        title: 'Old Title',
        model: '',
        projectPath: tempDir.path,
      );
      runtime = SessionRuntimeState(sessionId: session.id);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    CommandContext buildContext({
      void Function(String, {ToastMode? mode})? showToastImpl,
      void Function()? refreshImpl,
    }) {
      return CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        currentSession: session,
        currentSessionId: session.id,
        sessions: [session],
        currentMessages: const <Message>[],
        projectPath: tempDir.path,
        refresh: refreshImpl ?? () {},
        showToast: showToastImpl ?? (message, {ToastMode? mode}) {},
        switchSession: (_) async {},
        initSessions: () async {},
        createNewSession: () async {},
        runtime: (id) => runtime,
        persistThinkingLevel: (_) {},
        resolveAuxiliaryModel: () => {},
        sendTurn: ({String? text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
      );
    }

    test('renames the current session and persists to the DB', () async {
      // Happy path: `/rename New Title` writes to the DB, mirrors the
      // change onto the in-memory Session instance, calls refresh
      // exactly once, and emits a success toast.
      var refreshes = 0;
      String? lastToast;
      await CommandExecutor().execute(
        '/rename New Title',
        buildContext(
          refreshImpl: () => refreshes++,
          showToastImpl: (m, {mode}) => lastToast = m,
        ),
      );
      expect(refreshes, equals(1));
      expect(session.title, equals('New Title'));
      // Verify the DB write actually happened (not just the
      // in-memory mirror).
      final reloaded = await store.getById(session.id);
      expect(reloaded, isNotNull);
      expect(reloaded!.title, equals('New Title'));
      expect(lastToast, isNotNull);
      expect(lastToast, contains('New Title'));
      expect(lastToast, contains('Old Title'));
    });

    test('joins multi-word titles with spaces', () async {
      // The executor must re-join parts[1..] with spaces so titles
      // containing spaces round-trip verbatim (mirrors /btw's
      // handling). No quoting should be required.
      await CommandExecutor().execute(
        '/rename Ship the parser today',
        buildContext(),
      );
      expect(session.title, equals('Ship the parser today'));
      final reloaded = await store.getById(session.id);
      expect(reloaded!.title, equals('Ship the parser today'));
    });

    test('trims surrounding whitespace from the title', () async {
      // Leading/trailing whitespace inside the user input should be
      // stripped before both the DB write and the no-op check.
      await CommandExecutor().execute(
        '/rename   Trimmed Title   ',
        buildContext(),
      );
      expect(session.title, equals('Trimmed Title'));
    });

    test('shows a usage toast when called with no title', () async {
      // Bare `/rename` and whitespace-only invocations both surface
      // a usage toast. The DB must not be touched and refresh must
      // not fire.
      for (final invocation in <String>['/rename', '/rename  ', '/rename   ']) {
        var refreshes = 0;
        String? lastToast;
        await CommandExecutor().execute(
          invocation,
          buildContext(
            refreshImpl: () => refreshes++,
            showToastImpl: (m, {mode}) => lastToast = m,
          ),
        );
        expect(session.title, equals('Old Title'),
            reason: 'title must not change (input: "$invocation")');
        expect(refreshes, equals(0),
            reason: 'refresh must not fire on a rejected command');
        expect(lastToast, isNotNull);
        expect(lastToast, contains('Usage'));
      }
    });

    test('is a no-op when the new title equals the current title', () async {
      // `/rename Old Title` is a valid invocation but should not
      // touch the DB or call refresh — emit an informational toast
      // so the user sees that the command was understood.
      var refreshes = 0;
      String? lastToast;
      await CommandExecutor().execute(
        '/rename Old Title',
        buildContext(
          refreshImpl: () => refreshes++,
          showToastImpl: (m, {mode}) => lastToast = m,
        ),
      );
      expect(refreshes, equals(0));
      expect(lastToast, isNotNull);
      expect(lastToast!.toLowerCase(), contains('unchanged'));
      // DB unchanged.
      final reloaded = await store.getById(session.id);
      expect(reloaded!.title, equals('Old Title'));
    });

    test('rejects with a toast when there is no active session', () async {
      // Construct a context with no current session — the executor
      // should bail out with an error toast, not crash, not touch
      // the store.
      var refreshes = 0;
      String? lastToast;
      ToastMode? lastMode;
      await CommandExecutor().execute(
        '/rename Foo',
        CommandContext(
          store: store,
          providerService: providerService,
          providerServiceReady: false,
          currentSession: Session(id: 0, title: 'New Session'),
          currentSessionId: null,
          sessions: const <Session>[],
          currentMessages: const <Message>[],
          projectPath: tempDir.path,
          refresh: () => refreshes++,
          showToast: (message, {ToastMode? mode}) {
            lastToast = message;
            lastMode = mode;
          },
          switchSession: (_) async {},
          initSessions: () async {},
          createNewSession: () async {},
          runtime: (id) => runtime,
          persistThinkingLevel: (_) {},
          resolveAuxiliaryModel: () => {},
          sendTurn: ({String? text}) async {},
          findLastUserMessage: () async => null,
          deleteMessagesFrom: (_) async {},
          sendBtwTurn: (_) async {},
          clearBtwTurns: (_) {},
        ),
      );
      expect(refreshes, equals(0));
      expect(lastToast, isNotNull);
      expect(lastToast, contains('No active session'));
      expect(lastMode, equals(ToastMode.error));
    });

    test('alias /重命名 dispatches to the same executor path', () async {
      // The registry's Chinese alias should hit the same handler.
      // Use a Chinese title to also exercise non-ASCII input.
      await CommandExecutor().execute(
        '/重命名 中文标题',
        buildContext(),
      );
      expect(session.title, equals('中文标题'));
      final reloaded = await store.getById(session.id);
      expect(reloaded!.title, equals('中文标题'));
    });
  });

  group('CommandExecutor — /project', () {
    late Directory tempDir;
    late Directory originalCwd;
    late ProviderService providerService;
    late SessionStore store;
    late Session session;
    late SessionRuntimeState runtime;

    setUp(() async {
      originalCwd = Directory.current;
      tempDir = await Directory.systemTemp.createTemp('crux_project_test_');
      tempDir = Directory(await tempDir.resolveSymbolicLinks());
      providerService = ProviderService(userProvidersDir: tempDir.path);
      final db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      session = await store.create(
        title: 'Test Session',
        model: '',
        projectPath: tempDir.path,
      );
      runtime = SessionRuntimeState(sessionId: session.id);
    });

    tearDown(() async {
      Directory.current = originalCwd;
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    ({
      CommandContext ctx,
      List<String> toasts,
      List<ToastMode?> modes,
      int Function() initSessionsCalls,
    })
    buildContext() {
      final toasts = <String>[];
      final modes = <ToastMode?>[];
      var initSessionsCalls = 0;
      Directory.current = tempDir;
      final ctx = CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        currentSession: session,
        currentSessionId: session.id,
        sessions: [session],
        currentMessages: const [],
        projectPath: tempDir.path,
        refresh: () {},
        showToast: (message, {ToastMode? mode}) {
          toasts.add(message);
          modes.add(mode);
        },
        switchSession: (_) async {},
        initSessions: () async {
          initSessionsCalls++;
        },
        createNewSession: () async {},
        runtime: (id) => runtime,
        persistThinkingLevel: (_) {},
        resolveAuxiliaryModel: () {},
        sendTurn: ({String? text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
      );
      return (
        ctx: ctx,
        toasts: toasts,
        modes: modes,
        initSessionsCalls: () => initSessionsCalls,
      );
    }

    test(r'expands ~/ to HOME and switches project', () async {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) {
        markTestSkipped('No HOME/USERPROFILE in env');
        return;
      }
      final bundle = buildContext();

      await CommandExecutor().execute('/project ~/', bundle.ctx);

      expect(Directory.current.path, equals(home));
      expect(bundle.toasts.last, contains('Switched to'));
      expect(bundle.modes.last, equals(ToastMode.status));
      expect(bundle.initSessionsCalls(), equals(1));
    });

    test(r'expands bare ~ to HOME', () async {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) {
        markTestSkipped('No HOME/USERPROFILE in env');
        return;
      }
      final bundle = buildContext();

      await CommandExecutor().execute('/project ~', bundle.ctx);

      expect(Directory.current.path, equals(home));
      expect(bundle.toasts.last, contains('Switched to'));
    });

    test(r'expands ~/<sub> to HOME/<sub>', () async {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) {
        markTestSkipped('No HOME/USERPROFILE in env');
        return;
      }
      final children = Directory(home)
          .listSync(followLinks: false)
          .whereType<Directory>()
          .toList();
      if (children.isEmpty) {
        markTestSkipped('Home directory has no child directory to target');
        return;
      }
      final realTarget = children.first.path;
      final bundle = buildContext();

      await CommandExecutor().execute(
        '/project ~/${p.basename(realTarget)}',
        bundle.ctx,
      );

      expect(Directory.current.path, equals(realTarget));
      expect(bundle.toasts.last, contains('Switched to'));
    });

    test('reports directory not found for a missing ~/<path>', () async {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) {
        markTestSkipped('No HOME/USERPROFILE in env');
        return;
      }
      final missing = p.join(
        home,
        'crux-nonexistent-${DateTime.now().microsecondsSinceEpoch}',
      );
      final bundle = buildContext();

      await CommandExecutor().execute(
        '/project ~/${p.basename(missing)}',
        bundle.ctx,
      );

      expect(Directory.current.path, equals(tempDir.path));
      expect(bundle.toasts.last, contains('Directory not found'));
      expect(bundle.modes.last, equals(ToastMode.error));
      expect(bundle.initSessionsCalls(), equals(0));
    });

    test('shows usage toast when no path is provided', () async {
      final bundle = buildContext();

      await CommandExecutor().execute('/project', bundle.ctx);

      expect(bundle.toasts.last, contains('Usage: /project'));
      expect(Directory.current.path, equals(tempDir.path));
      expect(bundle.initSessionsCalls(), equals(0));
    });

    test('passes absolute paths through unchanged', () async {
      final bundle = buildContext();

      await CommandExecutor().execute('/project ${tempDir.path}', bundle.ctx);

      expect(Directory.current.path, equals(p.normalize(tempDir.path)));
      expect(bundle.toasts.last, contains('Switched to'));
    });

    test('rejects relative paths that do not exist', () async {
      final bundle = buildContext();

      await CommandExecutor().execute(
        '/project '
        'definitely-not-a-real-dir-${DateTime.now().microsecondsSinceEpoch}',
        bundle.ctx,
      );

      expect(bundle.toasts.last, contains('Directory not found'));
      expect(bundle.modes.last, equals(ToastMode.error));
      expect(Directory.current.path, equals(tempDir.path));
    });
  });
}
