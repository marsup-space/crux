// Tests for [CommandExecutor] that don't require a full chat pipeline.
//
// We construct a [CommandContext] with mock callbacks for
// `sendTurn`, `findLastUserMessage`, and `deleteMessagesFrom` and
// verify the executor routes each scenario through the right
// callback (or rejects it with a toast).
//
// Note: drift logs a "database created multiple times" warning
// because each test re-instantiates CruxDatabase. The warning is
// harmless here — each instance uses its own NativeDatabase
// pointing at a fresh in-memory file under the test's temp dir, so
// there is no shared state to race on. We just ignore the noise.

import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/commands/command_executor.dart';
import 'package:crux/src/components/ui/toast.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/storage/session_store.dart';
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
      final db = CruxDatabase();
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
      final db = CruxDatabase();
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
        final userMsg = await store.addMessage(
          session.id,
          role: 'user',
          content: userText,
        );
        await store.addMessage(
          session.id,
          role: 'ai',
          content: 'Sure, let me plan this out...',
        );
        final currentMessages = await store.getMessages(session.id);

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
        final userMsg = await store.addMessage(
          session.id,
          role: 'user',
          content: userText,
        );
        final currentMessages = await store.getMessages(session.id);

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
      final db = CruxDatabase();
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
}
