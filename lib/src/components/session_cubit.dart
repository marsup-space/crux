import 'package:bloc/bloc.dart';

import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/message_queue.dart';
import '../models/session.dart';

class SessionCubitState {
  SessionCubitState({
    List<Session> sessions = const [],
    this.currentSessionId,
    this.archivedCount = 0,
    Map<int, List<Message>> messageCache = const {},
    Set<int> loadingSessionIds = const {},
    Map<int, int> loadingTotalCounts = const {},
    Map<int, int> loadingLoadedCounts = const {},
    Map<int, List<QueuedMessage>> messageQueues = const {},
    Map<int, List<ImageAttachment>> pendingImages = const {},
    Map<int, String> inputTextStash = const {},
    this.isGeneratingTitle = false,
    this.auxiliaryModelShortName = 'auxiliary',
    this.revision = 0,
  }) : sessions = List.unmodifiable(sessions),
       messageCache = _deepUnmodifiableMessageMap(messageCache),
       loadingSessionIds = Set.unmodifiable(loadingSessionIds),
       loadingTotalCounts = Map.unmodifiable(loadingTotalCounts),
       loadingLoadedCounts = Map.unmodifiable(loadingLoadedCounts),
       messageQueues = _deepUnmodifiableQueueMap(messageQueues),
       pendingImages = _deepUnmodifiableImageMap(pendingImages),
       inputTextStash = Map.unmodifiable(inputTextStash);

  final List<Session> sessions;
  final int? currentSessionId;
  final int archivedCount;
  final Map<int, List<Message>> messageCache;
  final Set<int> loadingSessionIds;
  final Map<int, int> loadingTotalCounts;
  final Map<int, int> loadingLoadedCounts;
  final Map<int, List<QueuedMessage>> messageQueues;
  final Map<int, List<ImageAttachment>> pendingImages;
  final Map<int, String> inputTextStash;
  final bool isGeneratingTitle;
  final String auxiliaryModelShortName;
  final int revision;

  Session? get currentSession {
    final id = currentSessionId;
    if (id == null) return null;
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  List<Message> messagesFor(int sessionId) {
    return messageCache[sessionId] ?? const <Message>[];
  }

  List<ImageAttachment> pendingImagesFor(int sessionId) {
    return pendingImages[sessionId] ?? const <ImageAttachment>[];
  }

  List<QueuedMessage> queuedMessagesFor(int sessionId) {
    return messageQueues[sessionId] ?? const <QueuedMessage>[];
  }

  bool isLoadingMessages(int sessionId) =>
      loadingSessionIds.contains(sessionId);

  int? loadingMessageTotal(int sessionId) => loadingTotalCounts[sessionId];

  int? loadingMessageLoaded(int sessionId) => loadingLoadedCounts[sessionId];

  SessionCubitState copyWith({
    List<Session>? sessions,
    Object? currentSessionId = _unset,
    int? archivedCount,
    Map<int, List<Message>>? messageCache,
    Set<int>? loadingSessionIds,
    Map<int, int>? loadingTotalCounts,
    Map<int, int>? loadingLoadedCounts,
    Map<int, List<QueuedMessage>>? messageQueues,
    Map<int, List<ImageAttachment>>? pendingImages,
    Map<int, String>? inputTextStash,
    bool? isGeneratingTitle,
    String? auxiliaryModelShortName,
    int? revision,
  }) {
    return SessionCubitState(
      sessions: sessions ?? this.sessions,
      currentSessionId: identical(currentSessionId, _unset)
          ? this.currentSessionId
          : currentSessionId as int?,
      archivedCount: archivedCount ?? this.archivedCount,
      messageCache: messageCache ?? this.messageCache,
      loadingSessionIds: loadingSessionIds ?? this.loadingSessionIds,
      loadingTotalCounts: loadingTotalCounts ?? this.loadingTotalCounts,
      loadingLoadedCounts: loadingLoadedCounts ?? this.loadingLoadedCounts,
      messageQueues: messageQueues ?? this.messageQueues,
      pendingImages: pendingImages ?? this.pendingImages,
      inputTextStash: inputTextStash ?? this.inputTextStash,
      isGeneratingTitle: isGeneratingTitle ?? this.isGeneratingTitle,
      auxiliaryModelShortName:
          auxiliaryModelShortName ?? this.auxiliaryModelShortName,
      revision: revision ?? this.revision + 1,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SessionCubitState &&
        _listEquals(other.sessions, sessions) &&
        other.currentSessionId == currentSessionId &&
        other.archivedCount == archivedCount &&
        _mapListEquals(other.messageCache, messageCache) &&
        _setEquals(other.loadingSessionIds, loadingSessionIds) &&
        _mapEquals(other.loadingTotalCounts, loadingTotalCounts) &&
        _mapEquals(other.loadingLoadedCounts, loadingLoadedCounts) &&
        _mapListEquals(other.messageQueues, messageQueues) &&
        _mapListEquals(other.pendingImages, pendingImages) &&
        _mapEquals(other.inputTextStash, inputTextStash) &&
        other.isGeneratingTitle == isGeneratingTitle &&
        other.auxiliaryModelShortName == auxiliaryModelShortName &&
        other.revision == revision;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(sessions),
    currentSessionId,
    archivedCount,
    _mapListHash(messageCache),
    Object.hashAllUnordered(loadingSessionIds),
    _mapHash(loadingTotalCounts),
    _mapHash(loadingLoadedCounts),
    _mapListHash(messageQueues),
    _mapListHash(pendingImages),
    _mapHash(inputTextStash),
    isGeneratingTitle,
    auxiliaryModelShortName,
    revision,
  );
}

class SessionCubit extends Cubit<SessionCubitState> {
  SessionCubit({SessionCubitState? initialState})
    : super(initialState ?? SessionCubitState());

  void replaceSessions({
    required List<Session> sessions,
    required int archivedCount,
    int? currentSessionId,
  }) {
    emit(
      state.copyWith(
        sessions: sessions,
        archivedCount: archivedCount,
        currentSessionId: currentSessionId,
      ),
    );
  }

  void setCurrentSession(int? sessionId) {
    emit(state.copyWith(currentSessionId: sessionId));
  }

  void putMessages(int sessionId, List<Message> messages) {
    emit(
      state.copyWith(
        messageCache: {
          ...state.messageCache,
          sessionId: List<Message>.unmodifiable(messages),
        },
      ),
    );
  }

  void removeSessionState(int sessionId) {
    emit(
      state.copyWith(
        sessions: [
          for (final session in state.sessions)
            if (session.id != sessionId) session,
        ],
        messageCache: _withoutKey(state.messageCache, sessionId),
        loadingSessionIds: {...state.loadingSessionIds}..remove(sessionId),
        loadingTotalCounts: _withoutKey(state.loadingTotalCounts, sessionId),
        loadingLoadedCounts: _withoutKey(state.loadingLoadedCounts, sessionId),
        messageQueues: _withoutKey(state.messageQueues, sessionId),
        pendingImages: _withoutKey(state.pendingImages, sessionId),
        inputTextStash: _withoutKey(state.inputTextStash, sessionId),
        currentSessionId: state.currentSessionId == sessionId
            ? null
            : state.currentSessionId,
      ),
    );
  }

  void beginLoadingMessages(int sessionId) {
    emit(
      state.copyWith(
        loadingSessionIds: {...state.loadingSessionIds, sessionId},
      ),
    );
  }

  void updateLoadingProgress({
    required int sessionId,
    int? total,
    int? loaded,
  }) {
    final totalCounts = Map<int, int>.from(state.loadingTotalCounts);
    if (total != null) totalCounts[sessionId] = total;
    final loadedCounts = Map<int, int>.from(state.loadingLoadedCounts);
    if (loaded != null) loadedCounts[sessionId] = loaded;
    emit(
      state.copyWith(
        loadingTotalCounts: totalCounts,
        loadingLoadedCounts: loadedCounts,
      ),
    );
  }

  void finishLoadingMessages(int sessionId) {
    emit(
      state.copyWith(
        loadingSessionIds: {...state.loadingSessionIds}..remove(sessionId),
        loadingTotalCounts: _withoutKey(state.loadingTotalCounts, sessionId),
        loadingLoadedCounts: _withoutKey(state.loadingLoadedCounts, sessionId),
      ),
    );
  }

  void setQueuedMessages(int sessionId, List<QueuedMessage> messages) {
    final next = Map<int, List<QueuedMessage>>.from(state.messageQueues);
    if (messages.isEmpty) {
      next.remove(sessionId);
    } else {
      next[sessionId] = List<QueuedMessage>.unmodifiable(messages);
    }
    emit(state.copyWith(messageQueues: next));
  }

  void setPendingImages(int sessionId, List<ImageAttachment> images) {
    final next = Map<int, List<ImageAttachment>>.from(state.pendingImages);
    if (images.isEmpty) {
      next.remove(sessionId);
    } else {
      next[sessionId] = List<ImageAttachment>.unmodifiable(images);
    }
    emit(state.copyWith(pendingImages: next));
  }

  List<ImageAttachment> drainPendingImages(int sessionId) {
    final images = state.pendingImagesFor(sessionId);
    if (images.isEmpty) return const <ImageAttachment>[];
    emit(
      state.copyWith(
        pendingImages: _withoutKey(state.pendingImages, sessionId),
      ),
    );
    return images;
  }

  void stashInputText(int sessionId, String text) {
    final next = Map<int, String>.from(state.inputTextStash);
    if (text.isEmpty) {
      next.remove(sessionId);
    } else {
      next[sessionId] = text;
    }
    emit(state.copyWith(inputTextStash: next));
  }

  void setGeneratingTitle(bool value) {
    emit(state.copyWith(isGeneratingTitle: value));
  }

  void setAuxiliaryModelShortName(String value) {
    emit(state.copyWith(auxiliaryModelShortName: value));
  }
}

const _unset = Object();

Map<int, List<Message>> _deepUnmodifiableMessageMap(
  Map<int, List<Message>> source,
) {
  return Map.unmodifiable({
    for (final entry in source.entries)
      entry.key: List<Message>.unmodifiable(entry.value),
  });
}

Map<int, List<QueuedMessage>> _deepUnmodifiableQueueMap(
  Map<int, List<QueuedMessage>> source,
) {
  return Map.unmodifiable({
    for (final entry in source.entries)
      entry.key: List<QueuedMessage>.unmodifiable(entry.value),
  });
}

Map<int, List<ImageAttachment>> _deepUnmodifiableImageMap(
  Map<int, List<ImageAttachment>> source,
) {
  return Map.unmodifiable({
    for (final entry in source.entries)
      entry.key: List<ImageAttachment>.unmodifiable(entry.value),
  });
}

Map<K, V> _withoutKey<K, V>(Map<K, V> source, K key) {
  return Map<K, V>.from(source)..remove(key);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

bool _mapListEquals<K, V>(Map<K, List<V>> a, Map<K, List<V>> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final other = b[entry.key];
    if (other == null || !_listEquals(entry.value, other)) return false;
  }
  return true;
}

int _mapHash<K, V>(Map<K, V> map) {
  return Object.hashAllUnordered(
    map.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

int _mapListHash<K, V>(Map<K, List<V>> map) {
  return Object.hashAllUnordered(
    map.entries.map(
      (entry) => Object.hash(entry.key, Object.hashAll(entry.value)),
    ),
  );
}
