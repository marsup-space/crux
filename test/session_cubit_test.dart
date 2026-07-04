import 'package:bloc_test/bloc_test.dart';
import 'package:crux/src/components/session_cubit.dart';
import 'package:crux/src/models/image_attachment.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/message_queue.dart';
import 'package:crux/src/models/session.dart';
import 'package:test/test.dart';

void main() {
  group('SessionCubit', () {
    blocTest<SessionCubit, SessionCubitState>(
      'replaces sessions and selects current session',
      build: SessionCubit.new,
      act: (cubit) => cubit.replaceSessions(
        sessions: [_session(1), _session(2)],
        archivedCount: 3,
        currentSessionId: 2,
      ),
      expect: () => [
        isA<SessionCubitState>()
            .having((s) => s.sessions.length, 'session count', 2)
            .having((s) => s.archivedCount, 'archived count', 3)
            .having((s) => s.currentSession?.id, 'current session', 2),
      ],
    );

    blocTest<SessionCubit, SessionCubitState>(
      'tracks chunked message loading progress',
      build: SessionCubit.new,
      act: (cubit) {
        cubit.beginLoadingMessages(7);
        cubit.updateLoadingProgress(sessionId: 7, loaded: 50);
        cubit.updateLoadingProgress(sessionId: 7, total: 120);
        cubit.finishLoadingMessages(7);
      },
      expect: () => [
        isA<SessionCubitState>().having(
          (s) => s.isLoadingMessages(7),
          'loading',
          isTrue,
        ),
        isA<SessionCubitState>().having(
          (s) => s.loadingMessageLoaded(7),
          'loaded',
          50,
        ),
        isA<SessionCubitState>()
            .having((s) => s.loadingMessageTotal(7), 'total', 120)
            .having((s) => s.loadingMessageLoaded(7), 'loaded', 50),
        isA<SessionCubitState>()
            .having((s) => s.isLoadingMessages(7), 'loading', isFalse)
            .having((s) => s.loadingMessageTotal(7), 'total', isNull)
            .having((s) => s.loadingMessageLoaded(7), 'loaded', isNull),
      ],
    );

    test('stores immutable message snapshots', () {
      final cubit = SessionCubit();
      addTearDown(cubit.close);
      final messages = [_message(1, sessionId: 1)];

      cubit.putMessages(1, messages);
      messages.add(_message(2, sessionId: 1));

      expect(cubit.state.messagesFor(1), hasLength(1));
      expect(
        () => cubit.state.messagesFor(1).add(_message(3, sessionId: 1)),
        throwsUnsupportedError,
      );
    });

    test('emits when mutable session objects are re-snapshotted', () async {
      final cubit = SessionCubit();
      addTearDown(cubit.close);
      final session = _session(1);
      final emissions = <SessionCubitState>[];
      final subscription = cubit.stream.listen(emissions.add);
      addTearDown(subscription.cancel);

      cubit.replaceSessions(
        sessions: [session],
        archivedCount: 0,
        currentSessionId: 1,
      );
      session.title = 'Renamed';
      cubit.replaceSessions(
        sessions: [session],
        archivedCount: 0,
        currentSessionId: 1,
      );

      await pumpEventQueue();

      expect(emissions, hasLength(2));
      expect(emissions.last.revision, greaterThan(emissions.first.revision));
      expect(emissions.last.currentSession?.title, 'Renamed');
    });

    test('drains pending images and clears the session entry', () {
      final cubit = SessionCubit();
      addTearDown(cubit.close);
      const image = ImageAttachment(
        mediaType: 'image/png',
        base64Data: 'abc',
        label: 'clipboard',
      );

      cubit.setPendingImages(1, const [image]);
      final drained = cubit.drainPendingImages(1);

      expect(drained, const [image]);
      expect(cubit.state.pendingImagesFor(1), isEmpty);
    });

    test('stashes and clears input text', () {
      final cubit = SessionCubit();
      addTearDown(cubit.close);

      cubit.stashInputText(4, 'draft');
      expect(cubit.state.inputTextStash[4], 'draft');

      cubit.stashInputText(4, '');
      expect(cubit.state.inputTextStash.containsKey(4), isFalse);
    });

    test('stores immutable queued message snapshots', () {
      final cubit = SessionCubit();
      addTearDown(cubit.close);
      final queued = [QueuedMessage(id: 1, content: 'later')];

      cubit.setQueuedMessages(4, queued);
      queued.add(QueuedMessage(id: 2, content: 'after that'));

      expect(cubit.state.queuedMessagesFor(4), hasLength(1));
      expect(cubit.state.queuedMessagesFor(4).single.content, 'later');
      expect(
        () => cubit.state
            .queuedMessagesFor(4)
            .add(QueuedMessage(id: 3, content: 'nope')),
        throwsUnsupportedError,
      );

      cubit.setQueuedMessages(4, const []);
      expect(cubit.state.queuedMessagesFor(4), isEmpty);
    });

    test('tracks title generation state', () {
      final cubit = SessionCubit();
      addTearDown(cubit.close);

      cubit.setGeneratingTitle(true);
      expect(cubit.state.isGeneratingTitle, isTrue);

      cubit.setGeneratingTitle(false);
      expect(cubit.state.isGeneratingTitle, isFalse);
    });

    test('tracks auxiliary model label', () {
      final cubit = SessionCubit();
      addTearDown(cubit.close);

      expect(cubit.state.auxiliaryModelShortName, 'auxiliary');

      cubit.setAuxiliaryModelShortName('MiniMax');
      expect(cubit.state.auxiliaryModelShortName, 'MiniMax');
    });

    test('removeSessionState drops all per-session state', () {
      final cubit = SessionCubit();
      addTearDown(cubit.close);

      cubit.replaceSessions(
        sessions: [_session(1), _session(2)],
        archivedCount: 0,
        currentSessionId: 1,
      );
      cubit.putMessages(1, [_message(1, sessionId: 1)]);
      cubit.setQueuedMessages(1, [QueuedMessage(id: 1, content: 'queued')]);
      cubit.beginLoadingMessages(1);
      cubit.updateLoadingProgress(sessionId: 1, total: 10, loaded: 5);
      cubit.stashInputText(1, 'draft');
      cubit.setPendingImages(1, const [
        ImageAttachment(
          mediaType: 'image/png',
          base64Data: 'abc',
          label: 'clipboard',
        ),
      ]);

      cubit.removeSessionState(1);

      expect(cubit.state.currentSessionId, isNull);
      expect(cubit.state.sessions.map((s) => s.id), [2]);
      expect(cubit.state.messagesFor(1), isEmpty);
      expect(cubit.state.queuedMessagesFor(1), isEmpty);
      expect(cubit.state.isLoadingMessages(1), isFalse);
      expect(cubit.state.loadingMessageTotal(1), isNull);
      expect(cubit.state.pendingImagesFor(1), isEmpty);
      expect(cubit.state.inputTextStash.containsKey(1), isFalse);
    });
  });
}

Session _session(int id) {
  return Session(id: id, title: 'Session $id', model: 'test-model');
}

Message _message(int id, {required int sessionId}) {
  return Message(
    id: id,
    sessionId: sessionId,
    role: 'user',
    content: 'message $id',
  );
}
