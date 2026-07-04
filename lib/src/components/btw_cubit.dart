import 'package:bloc/bloc.dart';

/// One `/btw` round: the user's ephemeral prompt and the AI's ephemeral
/// reply. Both strings live only in memory and are wiped on the next
/// non-`/btw` user input, and on `/retry`.
class BtwTurn {
  final String userText;
  final String aiText;

  const BtwTurn({required this.userText, required this.aiText});

  BtwTurn copyWith({String? userText, String? aiText}) {
    return BtwTurn(
      userText: userText ?? this.userText,
      aiText: aiText ?? this.aiText,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is BtwTurn &&
        other.userText == userText &&
        other.aiText == aiText;
  }

  @override
  int get hashCode => Object.hash(userText, aiText);
}

class BtwCubitState {
  BtwCubitState({Map<int, List<BtwTurn>> turns = const {}})
    : turns = _deepUnmodifiableTurnMap(turns);

  final Map<int, List<BtwTurn>> turns;

  List<BtwTurn> turnsFor(int sessionId) {
    return turns[sessionId] ?? const <BtwTurn>[];
  }

  BtwCubitState copyWith({Map<int, List<BtwTurn>>? turns}) {
    return BtwCubitState(turns: turns ?? this.turns);
  }

  @override
  bool operator ==(Object other) {
    return other is BtwCubitState && _mapListEquals(other.turns, turns);
  }

  @override
  int get hashCode => _mapListHash(turns);
}

class BtwCubit extends Cubit<BtwCubitState> {
  BtwCubit({BtwCubitState? initialState})
    : super(initialState ?? BtwCubitState());

  void appendTurn(int sessionId, BtwTurn turn) {
    emit(
      state.copyWith(
        turns: {
          ...state.turns,
          sessionId: [...state.turnsFor(sessionId), turn],
        },
      ),
    );
  }

  void appendPendingTurn(int sessionId, String userText) {
    appendTurn(sessionId, BtwTurn(userText: userText, aiText: ''));
  }

  void updateLastAiText(int sessionId, String aiText) {
    final current = state.turnsFor(sessionId);
    if (current.isEmpty) return;
    emit(
      state.copyWith(
        turns: {
          ...state.turns,
          sessionId: [
            ...current.take(current.length - 1),
            current.last.copyWith(aiText: aiText),
          ],
        },
      ),
    );
  }

  void clearTurnsFor(int sessionId) {
    emit(state.copyWith(turns: {...state.turns, sessionId: const <BtwTurn>[]}));
  }

  void removeSession(int sessionId) {
    emit(state.copyWith(turns: _withoutKey(state.turns, sessionId)));
  }

  void clearAll() {
    emit(BtwCubitState());
  }
}

Map<int, List<BtwTurn>> _deepUnmodifiableTurnMap(
  Map<int, List<BtwTurn>> source,
) {
  return Map.unmodifiable({
    for (final entry in source.entries)
      entry.key: List<BtwTurn>.unmodifiable(entry.value),
  });
}

Map<K, V> _withoutKey<K, V>(Map<K, V> source, K key) {
  final next = Map<K, V>.from(source)..remove(key);
  return next;
}

bool _mapListEquals<K, V>(Map<K, List<V>> a, Map<K, List<V>> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    final other = b[entry.key];
    if (other == null || !_listEquals(entry.value, other)) return false;
  }
  return true;
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _mapListHash<K, V>(Map<K, List<V>> map) {
  return Object.hashAllUnordered(
    map.entries.map(
      (entry) => Object.hash(entry.key, Object.hashAll(entry.value)),
    ),
  );
}
