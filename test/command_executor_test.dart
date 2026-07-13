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
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/services/recent_projects_store.dart';
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
      Future<void> Function()? compactSessionImpl,
    }) {
      return CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        webProviderRegistry: WebProviderRegistry(),
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
        persistTemperature: (_) async {},
        resolveAuxiliaryModel: () => {},
        sendTurn: sendTurnImpl,
        compactSession: compactSessionImpl,
        findLastUserMessage: findLastUserMessageImpl ?? () async => null,
        deleteMessagesFrom: deleteMessagesFromImpl ?? (_) async {},
        sendBtwTurn: sendBtwTurnImpl ?? (_) async {},
        clearBtwTurns: clearBtwTurnsImpl ?? (_) {},
      );
    }

    test('/compact routes to the compaction callback', () async {
      var called = false;
      final ctx = buildContext(
        currentMessages: [
          Message(
            id: 1,
            sessionId: session.id,
            role: 'user',
            content: 'please build something',
          ),
        ],
        sendTurnImpl: ({String? text}) async {},
        compactSessionImpl: () async {
          called = true;
        },
      );

      await CommandExecutor().execute('/compact', ctx);

      expect(called, isTrue);
    });

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

        expect(
          sendTurnCalls,
          equals(1),
          reason: 'should drive exactly one turn',
        );
        expect(
          sendCalledWithText,
          isFalse,
          reason:
              'no nudge should be appended when the last segment '
              'is a tool result — the wire format already ends on '
              'a valid trailing turn',
        );
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
        expect(
          lastTextSent,
          isNull,
          reason:
              'resubmitting a bare user message is fine — the '
              'API accepts a trailing user turn, so no nudge.',
        );
      },
    );

    test('appends a 请继续 nudge when last segment is an AI response', () async {
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
      expect(
        lastTextSent,
        isNotNull,
        reason:
            'must append a user turn to satisfy the '
            'role-alternation rule',
      );
      expect(lastTextSent, equals('请继续。'));
    });

    test('is a no-op when the AI is already responding', () async {
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

      expect(
        sendTurnCalls,
        equals(0),
        reason: 'must not drive a turn while one is in flight',
      );
    });

    test('also works for the Chinese alias /继续', () async {
      // Make sure the dispatch table in `execute()` routes the
      // alias to the same handler as the canonical name.
      final messages = <Message>[
        Message(id: 1, sessionId: session.id, role: 'ai', content: 'hello'),
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
    });

    test('is a no-op with a toast when the session is empty', () async {
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
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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

      expect(
        sendTurnCalls,
        equals(0),
        reason:
            'must not drive a turn when there is nothing '
            'to continue',
      );
      expect(
        lastToast,
        isNotNull,
        reason: 'should surface a toast explaining the rejection',
      );
      expect(
        lastToast,
        contains('empty'),
        reason: 'toast should mention the session is empty',
      );
    });
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

    test('wipes the last round and re-sends the original user text', () async {
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
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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

      expect(
        events,
        equals(<String>[
          'findLastUserMessage',
          'deleteMessagesFrom:${userMsg.id}',
          'sendTurn:$userText',
        ]),
      );
    });

    test('is a no-op when the AI is already responding', () async {
      runtime.isResponding = true;

      var deleteCalls = 0;
      var sendTurnCalls = 0;
      await CommandExecutor().execute(
        '/retry',
        CommandContext(
          store: store,
          providerService: providerService,
          providerServiceReady: false,
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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
    });

    test('is a no-op when there is no user message to retry', () async {
      var deleteCalls = 0;
      var sendTurnCalls = 0;
      await CommandExecutor().execute(
        '/retry',
        CommandContext(
          store: store,
          providerService: providerService,
          providerServiceReady: false,
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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
    });

    test('also works for the Chinese alias /重试', () async {
      const userText = 'hello world';
      final userMsg = await store.messageStore.addMessage(
        session.id,
        role: 'user',
        content: userText,
      );
      await store.messageStore.addMessage(
        session.id,
        role: 'ai',
        content: 'Sure, hello to you too.',
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
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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
    });
  });

  group('CommandExecutor — /undo', () {
    late Directory tempDir;
    late ProviderService providerService;
    late SessionStore store;
    late Session session;
    late SessionRuntimeState runtime;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_undo_test_');
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

    test('wipes the last round and copies the user text into the input box',
        () async {
      // Mirrors the /retry happy-path test, but expects setInputText
      // to fire with the original user text instead of sendTurn. The
      // user wanted to edit their prompt before resending, so we
      // never kick off a new turn.
      const userText = 'reword this for me';
      final userMsg = await store.messageStore.addMessage(
        session.id,
        role: 'user',
        content: userText,
      );
      await store.messageStore.addMessage(
        session.id,
        role: 'ai',
        content: 'Sure, here is a rewrite...',
      );
      final currentMessages = await store.messageStore.getMessages(session.id);

      final events = <String>[];
      String? inputText;
      await CommandExecutor().execute(
        '/undo',
        CommandContext(
          store: store,
          providerService: providerService,
          providerServiceReady: false,
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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
          setInputText: (text) {
            events.add('setInputText:$text');
            inputText = text;
          },
        ),
      );

      expect(
        events,
        equals(<String>[
          'findLastUserMessage',
          'deleteMessagesFrom:${userMsg.id}',
          'setInputText:$userText',
        ]),
      );
      // Critical: /undo must NOT call sendTurn, otherwise we'd
      // race the freshly-cleared message cache with a re-fire of
      // the same prompt.
      expect(events, isNot(contains(matches(RegExp(r'^sendTurn:')))));
      expect(inputText, equals(userText));
    });

    test('is a no-op (no wipe, no input change) when AI is responding',
        () async {
      runtime.isResponding = true;

      var deleteCalls = 0;
      var sendTurnCalls = 0;
      String? inputText;
      await CommandExecutor().execute(
        '/undo',
        CommandContext(
          store: store,
          providerService: providerService,
          providerServiceReady: false,
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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
          setInputText: (text) {
            inputText = text;
          },
        ),
      );

      expect(deleteCalls, equals(0));
      expect(sendTurnCalls, equals(0));
      // No prior user message was found, so the input box should
      // not be touched at all (the responding-state toast wins).
      expect(inputText, isNull);
    });

    test('is a no-op when there is no user message to undo', () async {
      var deleteCalls = 0;
      var sendTurnCalls = 0;
      String? inputText;
      await CommandExecutor().execute(
        '/undo',
        CommandContext(
          store: store,
          providerService: providerService,
          providerServiceReady: false,
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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
          setInputText: (text) {
            inputText = text;
          },
        ),
      );

      expect(deleteCalls, equals(0));
      expect(sendTurnCalls, equals(0));
      expect(inputText, isNull);
    });

    test('also works for the Chinese alias /撤销', () async {
      const userText = '请帮我重写一下';
      final userMsg = await store.messageStore.addMessage(
        session.id,
        role: 'user',
        content: userText,
      );
      await store.messageStore.addMessage(
        session.id,
        role: 'ai',
        content: '好的,这是改写后的版本...',
      );
      final currentMessages = await store.messageStore.getMessages(session.id);

      var deleteFromId = -1;
      String? inputText;
      var sendTurnCalls = 0;
      await CommandExecutor().execute(
        '/撤销',
        CommandContext(
          store: store,
          providerService: providerService,
          providerServiceReady: false,
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
          resolveAuxiliaryModel: () {},
          sendTurn: ({String? text}) async {
            sendTurnCalls++;
          },
          findLastUserMessage: () async => userMsg,
          deleteMessagesFrom: (fromId) async {
            deleteFromId = fromId;
          },
          sendBtwTurn: (_) async {},
          clearBtwTurns: (_) {},
          setInputText: (text) {
            inputText = text;
          },
        ),
      );

      expect(deleteFromId, equals(userMsg.id));
      expect(inputText, equals(userText));
      expect(sendTurnCalls, equals(0));
    });

    test('still wipes and restores the input when setInputText is null',
        () async {
      // Backwards-compat: a caller that doesn't wire setInputText
      // (e.g. a legacy test harness) should still get the DB wipe
      // and the btw-chain clear. The input-box side-effect simply
      // becomes a no-op, mirroring how other optional callbacks
      // degrade.
      const userText = 'draft me a release note';
      final userMsg = await store.messageStore.addMessage(
        session.id,
        role: 'user',
        content: userText,
      );
      await store.messageStore.addMessage(
        session.id,
        role: 'ai',
        content: 'Here is your release note...',
      );
      final currentMessages = await store.messageStore.getMessages(session.id);

      var deleteFromId = -1;
      var clearBtwCalls = 0;
      await CommandExecutor().execute(
        '/undo',
        CommandContext(
          store: store,
          providerService: providerService,
          providerServiceReady: false,
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
          resolveAuxiliaryModel: () {},
          sendTurn: ({String? text}) async {},
          findLastUserMessage: () async => userMsg,
          deleteMessagesFrom: (fromId) async {
            deleteFromId = fromId;
          },
          sendBtwTurn: (_) async {},
          clearBtwTurns: (_) {
            clearBtwCalls++;
          },
          // setInputText intentionally omitted.
        ),
      );

      expect(deleteFromId, equals(userMsg.id));
      expect(clearBtwCalls, equals(1));
    });
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

    test('drives sendBtwTurn with the full prompt text', () async {
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
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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

      expect(sendCalls, equals(1), reason: 'should drive exactly one btw turn');
      expect(
        capturedPrompt,
        equals('how do I rename a file in bash?'),
        reason: 'prompt must round-trip with internal spaces intact',
      );
    });

    test('shows a usage toast when called without a prompt', () async {
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
            webProviderRegistry: WebProviderRegistry(),
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
            persistTemperature: (_) async {},
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

        expect(
          sendCalls,
          equals(0),
          reason:
              'must not fire a btw turn with no prompt '
              '(input: "$invocation")',
        );
        expect(lastToast, isNotNull, reason: 'should surface a usage toast');
        expect(
          lastToast,
          contains('Usage'),
          reason: 'toast should explain the correct usage',
        );
      }
    });

    test('is a no-op when the AI is already responding', () async {
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
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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

      expect(
        sendCalls,
        equals(0),
        reason: 'must not drive a btw turn while one is in flight',
      );
      expect(lastToast, isNotNull);
    });

    test('rejects with a toast when there is no active session', () async {
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
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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
    });
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
        webProviderRegistry: WebProviderRegistry(),
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
        persistTemperature: (_) async {},
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
        expect(
          session.title,
          equals('Old Title'),
          reason: 'title must not change (input: "$invocation")',
        );
        expect(
          refreshes,
          equals(0),
          reason: 'refresh must not fire on a rejected command',
        );
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
          webProviderRegistry: WebProviderRegistry(),
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
          persistTemperature: (_) async {},
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
      await CommandExecutor().execute('/重命名 中文标题', buildContext());
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
        webProviderRegistry: WebProviderRegistry(),
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
        persistTemperature: (_) async {},
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

      expect(p.equals(Directory.current.path, home), isTrue);
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

      expect(p.equals(Directory.current.path, home), isTrue);
      expect(bundle.toasts.last, contains('Switched to'));
    });

    test(r'expands ~/<sub> to HOME/<sub>', () async {
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) {
        markTestSkipped('No HOME/USERPROFILE in env');
        return;
      }
      // Filter out directories whose basename contains
      // whitespace — the executor splits the command line on
      // /\s+/, so a path with spaces would be split before
      // reaching `_expandHome` and the test would fail for
      // reasons unrelated to ~ expansion (e.g. on macOS where
      // `~/Unity user templates` exists out of the box).
      final children = Directory(home)
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where((d) => !p.basename(d.path).contains(RegExp(r'\s')))
          .toList();
      if (children.isEmpty) {
        markTestSkipped(
          'Home directory has no child directory '
          '(with a whitespace-free basename) to target',
        );
        return;
      }
      final realTarget = children.first.path;
      final bundle = buildContext();

      await CommandExecutor().execute(
        '/project ~/${p.basename(realTarget)}',
        bundle.ctx,
      );

      expect(p.equals(Directory.current.path, realTarget), isTrue);
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

      expect(p.equals(Directory.current.path, tempDir.path), isTrue);
      expect(bundle.toasts.last, contains('Directory not found'));
      expect(bundle.modes.last, equals(ToastMode.error));
      expect(bundle.initSessionsCalls(), equals(0));
    });

    test('shows usage toast when no path is provided', () async {
      final bundle = buildContext();

      await CommandExecutor().execute('/project', bundle.ctx);

      expect(bundle.toasts.last, contains('Usage: /project'));
      expect(p.equals(Directory.current.path, tempDir.path), isTrue);
      expect(bundle.initSessionsCalls(), equals(0));
    });

    test('passes absolute paths through unchanged', () async {
      final bundle = buildContext();

      await CommandExecutor().execute('/project ${tempDir.path}', bundle.ctx);

      expect(p.equals(Directory.current.path, tempDir.path), isTrue);
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
      expect(p.equals(Directory.current.path, tempDir.path), isTrue);
    });

    test('records the switched-to directory in the recent-projects '
        'store on success', () async {
      final recentsFile = File(p.join(tempDir.path, 'recent_projects.json'));
      final recents = RecentProjectsStore.forTesting(recentsFile.path);
      final toasts = <String>[];
      final modes = <ToastMode?>[];
      Directory.current = tempDir;
      final ctx = CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        webProviderRegistry: WebProviderRegistry(),
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
        initSessions: () async {},
        createNewSession: () async {},
        runtime: (id) => runtime,
        persistThinkingLevel: (_) {},
        persistTemperature: (_) async {},
        resolveAuxiliaryModel: () {},
        sendTurn: ({String? text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
        recentProjectsStore: recents,
      );

      await CommandExecutor().execute('/project ${tempDir.path}', ctx);

      expect(recents.entries, hasLength(1));
      expect(
        p.equals(recents.entries.first.path, tempDir.path),
        isTrue,
        reason: 'expected ${recents.entries.first.path} == ${tempDir.path}',
      );
    });

    test('does not record a recent entry when the switch fails', () async {
      final recentsFile = File(p.join(tempDir.path, 'recent_projects.json'));
      final recents = RecentProjectsStore.forTesting(recentsFile.path);
      final ctx = CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        webProviderRegistry: WebProviderRegistry(),
        currentSession: session,
        currentSessionId: session.id,
        sessions: [session],
        currentMessages: const [],
        projectPath: tempDir.path,
        refresh: () {},
        showToast: (message, {ToastMode? mode}) {},
        switchSession: (_) async {},
        initSessions: () async {},
        createNewSession: () async {},
        runtime: (id) => runtime,
        persistThinkingLevel: (_) {},
        persistTemperature: (_) async {},
        resolveAuxiliaryModel: () {},
        sendTurn: ({String? text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
        recentProjectsStore: recents,
      );

      await CommandExecutor().execute(
        '/project '
        'definitely-not-a-real-dir-${DateTime.now().microsecondsSinceEpoch}',
        ctx,
      );

      expect(recents.entries, isEmpty);
    });
  });

  group('CommandExecutor — /quit', () {
    late Directory tempDir;
    late ProviderService providerService;
    late SessionStore store;
    late Session session;
    late SessionRuntimeState runtime;
    // Capture every toast the executor fires so a test can
    // assert on its text + mode (most importantly: that an
    // attempted quit while the agent is busy was rejected
    // with the "press Ctrl+C×2" message rather than
    // actually calling the quit callback).
    final List<({String message, ToastMode? mode})> toasts = [];

    setUp(() async {
      toasts.clear();
      tempDir = await Directory.systemTemp.createTemp('crux_quit_test_');
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

    CommandContext buildContext({
      required bool quitAppInvoked,
      required void Function() onQuitApp,
    }) {
      return CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        webProviderRegistry: WebProviderRegistry(),
        currentSession: session,
        currentSessionId: session.id,
        sessions: [session],
        currentMessages: const [],
        projectPath: tempDir.path,
        refresh: () {},
        showToast: (message, {ToastMode? mode}) {
          toasts.add((message: message, mode: mode));
        },
        switchSession: (_) async {},
        initSessions: () async {},
        createNewSession: () async {},
        runtime: (id) => runtime,
        persistThinkingLevel: (_) {},
        persistTemperature: (_) async {},
        resolveAuxiliaryModel: () {},
        sendTurn: ({String? text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
        quitApp: onQuitApp,
      );
    }

    test('invokes quitApp when the session is idle', () async {
      var quitCalls = 0;
      final ctx = buildContext(
        quitAppInvoked: false,
        onQuitApp: () => quitCalls++,
      );
      // Runtime is not responding (default) — /quit should
      // call back immediately.
      await CommandExecutor().execute('/quit', ctx);
      expect(quitCalls, 1, reason: 'quitApp should fire when idle');
      expect(toasts, isEmpty, reason: 'no toast on the happy path');
    });

    test('also accepts the /exit alias', () async {
      var quitCalls = 0;
      final ctx = buildContext(
        quitAppInvoked: false,
        onQuitApp: () => quitCalls++,
      );
      await CommandExecutor().execute('/exit', ctx);
      expect(quitCalls, 1);
    });

    test('rejects /quit while the agent is responding', () async {
      var quitCalls = 0;
      // Mark the session as `SessionStatus.running` — the executor
      // now keys off session status (any session), not the runtime's
      // `isResponding` flag, so it covers background sessions and the
      // windows between token flushes where the agent is still working
      // but `isResponding` is briefly false.
      session.status = SessionStatus.running;
      final ctx = buildContext(
        quitAppInvoked: false,
        onQuitApp: () => quitCalls++,
      );
      await CommandExecutor().execute('/quit', ctx);
      expect(quitCalls, 0, reason: 'must not quit while a session is running');
      expect(toasts, hasLength(1));
      expect(toasts.first.message, contains('Ctrl+C'));
      expect(toasts.first.mode, ToastMode.error);
    });

    test(
        'rejects /quit when a *background* session is running, even '
        'if the current one is idle (regression test for the bug '
        'where /quit slipped through on a different session)',
        () async {
      // Build a second session and mark *it* as running while the
      // current one is idle. The old check only looked at the
      // current session's `isResponding`, so this case used to let
      // `/quit` sneak through and exit the app.
      var quitCalls = 0;
      final other = await store.create(
        title: 'Background',
        model: '',
        projectPath: tempDir.path,
      );
      other.status = SessionStatus.running;

      final ctx = CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        webProviderRegistry: WebProviderRegistry(),
        currentSession: session, // idle
        currentSessionId: session.id,
        sessions: [session, other],
        currentMessages: const [],
        projectPath: tempDir.path,
        refresh: () {},
        showToast: (message, {ToastMode? mode}) {
          toasts.add((message: message, mode: mode));
        },
        switchSession: (_) async {},
        initSessions: () async {},
        createNewSession: () async {},
        runtime: (id) => runtime,
        persistThinkingLevel: (_) {},
        persistTemperature: (_) async {},
        resolveAuxiliaryModel: () {},
        sendTurn: ({String? text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
        quitApp: () => quitCalls++,
      );
      await CommandExecutor().execute('/quit', ctx);
      expect(quitCalls, 0,
          reason: 'must not quit when any background session is running');
      expect(toasts, hasLength(1));
      expect(toasts.first.message, contains('Ctrl+C'));
      expect(toasts.first.mode, ToastMode.error);
    });

    test('surfaces an error toast when quitApp is not bound', () async {
      // Build a context with quitApp omitted (null) —
      // mirrors the legacy test harness / --doctor path
      // where no TUI panel is mounted.
      final ctx = CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        webProviderRegistry: WebProviderRegistry(),
        currentSession: session,
        currentSessionId: session.id,
        sessions: [session],
        currentMessages: const [],
        projectPath: tempDir.path,
        refresh: () {},
        showToast: (message, {ToastMode? mode}) {
          toasts.add((message: message, mode: mode));
        },
        switchSession: (_) async {},
        initSessions: () async {},
        createNewSession: () async {},
        runtime: (id) => runtime,
        persistThinkingLevel: (_) {},
        persistTemperature: (_) async {},
        resolveAuxiliaryModel: () {},
        sendTurn: ({String? text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
        // quitApp intentionally omitted → null
      );
      await CommandExecutor().execute('/quit', ctx);
      expect(toasts, hasLength(1));
      expect(toasts.first.message, contains('Quit unavailable'));
      expect(toasts.first.mode, ToastMode.error);
    });
  });

  group('CommandExecutor — /temperature', () {
    late Directory tempDir;
    late ProviderService providerService;
    late SessionStore store;
    late Session session;
    late SessionRuntimeState runtime;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_temp_test_');
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

    CommandContext buildContext(
      List<({String message, ToastMode? mode})> toasts,
    ) {
      return CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        webProviderRegistry: WebProviderRegistry(),
        currentSession: session,
        currentSessionId: session.id,
        sessions: [session],
        currentMessages: const <Message>[],
        projectPath: tempDir.path,
        refresh: () {},
        showToast: (message, {ToastMode? mode}) {
          toasts.add((message: message, mode: mode));
        },
        switchSession: (_) async {},
        initSessions: () async {},
        createNewSession: () async {},
        runtime: (_) => runtime,
        persistThinkingLevel: (_) {},
        persistTemperature: (_) async {},
        resolveAuxiliaryModel: () {},
        sendTurn: ({String? text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
      );
    }

    test('stores an in-range override on the runtime', () async {
      final toasts = <({String message, ToastMode? mode})>[];
      final ctx = buildContext(toasts);
      await CommandExecutor().execute('/temperature 0.7', ctx);
      expect(runtime.temperatureOverride, 0.7);
      expect(toasts, hasLength(1));
      // Success-path toast is `info` mode with an explicit 4s
      // duration override — see the comment in `cmd_temperature.dart`
      // for why (default `status` 2s is shorter than the message's
      // read time on a fast eye).
      expect(toasts.first.mode, ToastMode.info);
      expect(toasts.first.message, contains('Temperature set to 0.7'));
      expect(toasts.first.message, isNot(contains('clamped')));
      // Override is session-wide, not per-turn — make sure the
      // wording matches the actual persistence model.
      expect(toasts.first.message, contains('for the session'));
      expect(toasts.first.message, isNot(contains('next turn')));
    });

    test('clamps values above 1.0 and reports the original', () async {
      final toasts = <({String message, ToastMode? mode})>[];
      final ctx = buildContext(toasts);
      await CommandExecutor().execute('/temperature 1.5', ctx);
      // Clamped to the user-facing max, not silently dropped.
      expect(runtime.temperatureOverride, 1.0);
      expect(toasts.first.message, contains('Temperature set to 1'));
      expect(toasts.first.message, contains('clamped from 1.5'));
      expect(toasts.first.message, contains('0.0–1.0'));
    });

    test('clamps negative values to 0.0', () async {
      final toasts = <({String message, ToastMode? mode})>[];
      final ctx = buildContext(toasts);
      await CommandExecutor().execute('/temperature -0.2', ctx);
      expect(runtime.temperatureOverride, 0.0);
      expect(toasts.first.message, contains('clamped from -0.2'));
    });

    test('rejects non-numeric input with an error toast', () async {
      final toasts = <({String message, ToastMode? mode})>[];
      final ctx = buildContext(toasts);
      await CommandExecutor().execute('/temperature hot', ctx);
      // Runtime is left untouched.
      expect(runtime.temperatureOverride, isNull);
      expect(toasts, hasLength(1));
      expect(toasts.first.mode, ToastMode.error);
      expect(toasts.first.message, contains('Invalid temperature'));
      expect(toasts.first.message, contains('"hot"'));
    });

    test('rejects NaN and infinity', () async {
      // Use explicit non-finite strings. `double.tryParse` returns
      // null for these so behavior should be the same as a garbage
      // string, but this guards against future changes that try to
      // accept them (e.g. `.toString()` of an Infinity double).
      for (final bad in ['NaN', 'Infinity', '-Infinity']) {
        final toasts = <({String message, ToastMode? mode})>[];
        final ctx = buildContext(toasts);
        await CommandExecutor().execute('/temperature $bad', ctx);
        expect(runtime.temperatureOverride, isNull,
            reason: 'bad input "$bad" must not mutate runtime');
        expect(toasts.last.mode, ToastMode.error,
            reason: 'bad input "$bad" must produce error toast');
      }
    });

    test('with no argument reports current state and does not mutate',
        () async {
      final toasts = <({String message, ToastMode? mode})>[];
      final ctx = buildContext(toasts);
      // No override set yet.
      await CommandExecutor().execute('/temperature', ctx);
      expect(toasts, hasLength(1));
      expect(toasts.first.message, contains('model default'));
      // Bare-call toast is informational state, not an error or a
      // transient status change — must render as `info`.
      expect(toasts.first.mode, ToastMode.info);
      expect(runtime.temperatureOverride, isNull);

      // With an override set, the same command reports the override.
      toasts.clear();
      runtime.temperatureOverride = 0.4;
      await CommandExecutor().execute('/temperature', ctx);
      expect(toasts, hasLength(1));
      expect(toasts.first.message, contains('0.4'));
      expect(toasts.first.message, contains('override'));
      expect(toasts.first.mode, ToastMode.info);
      // `executeTemperature` only reports when called with no arg;
      // it should not write the runtime back.
      expect(runtime.temperatureOverride, 0.4);
    });

    test('persists the override through the supplied callback',
        () async {
      final toasts = <({String message, ToastMode? mode})>[];
      SessionRuntimeState? persistedFor;
      double? persistedValue;
      final ctx = CommandContext(
        store: store,
        providerService: providerService,
        providerServiceReady: false,
        webProviderRegistry: WebProviderRegistry(),
        currentSession: session,
        currentSessionId: session.id,
        sessions: [session],
        currentMessages: const <Message>[],
        projectPath: tempDir.path,
        refresh: () {},
        showToast: (message, {ToastMode? mode}) {
          toasts.add((message: message, mode: mode));
        },
        switchSession: (_) async {},
        initSessions: () async {},
        createNewSession: () async {},
        runtime: (_) => runtime,
        persistThinkingLevel: (_) {},
        persistTemperature: (rt) async {
          persistedFor = rt;
          persistedValue = rt.temperatureOverride;
        },
        resolveAuxiliaryModel: () {},
        sendTurn: ({String? text}) async {},
        findLastUserMessage: () async => null,
        deleteMessagesFrom: (_) async {},
        sendBtwTurn: (_) async {},
        clearBtwTurns: (_) {},
      );
      await CommandExecutor().execute('/temperature 0.55', ctx);
      expect(persistedFor, same(runtime));
      expect(persistedValue, 0.55);
    });

    test(
      'with no argument surfaces the model-configured default when '
      'provider service is ready',
      () async {
        // Drop a minimal OpenAI-compatible provider into a separate
        // subdir, register a model with a non-zero TOML temperature,
        // and point the session at it. The no-arg toast should
        // include the resolved value, not just the abstract
        // "model default" string.
        final providersDir =
            await Directory.systemTemp.createTemp('crux_temp_prov_');
        addTearDown(() async {
          if (await providersDir.exists()) {
            await providersDir.delete(recursive: true);
          }
        });
        await File(p.join(providersDir.path, 'tmpl.toml')).writeAsString('''
type = "openai_compatible"
endpoint_url = "http://localhost:65535/v1"

[[models]]
id = "tmpl-model"
name = "Test Model"
context_size = 8000
image_support = false
thinking = false
reasoning_effort = "none"
temperature = 0.6
stream_lerp = false
''');
        final liveService = ProviderService(
          userProvidersDir: providersDir.path,
        );
        await liveService.initialize();
        // Reassign so buildContext picks up the live service.
        providerService = liveService;
        session = await store.update(
          session.id,
          model: 'tmpl/tmpl-model',
        );

        // No-arg, no override — should include the resolved default.
        final toasts = <({String message, ToastMode? mode})>[];
        final ctx = CommandContext(
          store: store,
          providerService: providerService,
          providerServiceReady: true,
          webProviderRegistry: WebProviderRegistry(),
          currentSession: session,
          currentSessionId: session.id,
          sessions: [session],
          currentMessages: const <Message>[],
          projectPath: tempDir.path,
          refresh: () {},
          showToast: (message, {ToastMode? mode}) {
            toasts.add((message: message, mode: mode));
          },
          switchSession: (_) async {},
          initSessions: () async {},
          createNewSession: () async {},
          runtime: (_) => runtime,
          persistThinkingLevel: (_) {},
          persistTemperature: (_) async {},
          resolveAuxiliaryModel: () {},
          sendTurn: ({String? text}) async {},
          findLastUserMessage: () async => null,
          deleteMessagesFrom: (_) async {},
          sendBtwTurn: (_) async {},
          clearBtwTurns: (_) {},
        );
        await CommandExecutor().execute('/temperature', ctx);
        expect(toasts, hasLength(1));
        expect(toasts.first.message, contains('model default'));
        expect(toasts.first.message, contains('0.6'));
        expect(toasts.first.message, contains('no override'));
        expect(toasts.first.mode, ToastMode.info);

        // With an override in place, the same toast should still
        // surface the resolved default — that's the comparison
        // signal users want when they're deciding what to pick.
        toasts.clear();
        runtime.temperatureOverride = 0.85;
        await CommandExecutor().execute('/temperature', ctx);
        expect(toasts, hasLength(1));
        expect(toasts.first.message, contains('0.85'));
        expect(toasts.first.message, contains('override'));
        expect(toasts.first.message, contains('default 0.6'));
        expect(toasts.first.mode, ToastMode.info);
      },
    );
  });
}
