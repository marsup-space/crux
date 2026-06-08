import 'dart:io';
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/chat_service.dart';
import '../services/provider_service.dart';
import '../storage/session_store.dart';
import '../utils/token_estimate.dart';

/// One `/btw` round: the user's ephemeral prompt and the AI's ephemeral
/// reply. Both strings live only in memory (and only in [SessionController];
/// the chat service never sees them) and are wiped on the next non-`/btw`
/// user input, and on `/retry`. They survive session switches (each
/// session has its own independent chain). They are never persisted
/// to the database.
class BtwTurn {
  final String userText;
  final String aiText;
  const BtwTurn({required this.userText, required this.aiText});
}

class SessionController {
  final SessionStore _store;
  final ProviderService _providerService;
  final ChatService _chatService;
  final void Function() _refresh;

  List<Session> sessions = [];
  int? currentSessionId;
  int archivedCount = 0;
  final Map<int, SessionRuntimeState> _runtimeStates = {};
  final Map<int, List<Message>> messageCache = {};
  String auxiliaryModelShortName = 'auxiliary';

  /// Per-session chain of `/btw` rounds that the user has issued since
  /// the last "real" turn. Kept in memory only — never written to disk
  /// (so a process restart drops them cleanly) and never mixed into the
  /// persisted history. Used by the chat panel to (a) re-feed prior
  /// btw rounds into the LLM context for the *next* btw call, and
  /// (b) render the boxed btw UI without going through the regular
  /// message bubble machinery.
  final Map<int, List<BtwTurn>> btwBuffer = {};

  /// Read-only view of the in-memory btw chain for [sessionId]. Returns
  /// an empty list when the session has never seen a `/btw`, or when
  /// the chain has just been cleared.
  List<BtwTurn> btwTurnsFor(int sessionId) =>
      List.unmodifiable(btwBuffer[sessionId] ?? const <BtwTurn>[]);

  /// Append a completed btw round (user prompt + AI response) to the
  /// in-memory chain for [sessionId]. Caller is the chat panel's
  /// btw stream completion handler.
  void appendBtwTurn(int sessionId, BtwTurn turn) {
    btwBuffer.putIfAbsent(sessionId, () => <BtwTurn>[]).add(turn);
  }

  /// Append a "pending" btw round to the in-memory chain — a pair
  /// whose `aiText` is still empty because the LLM has not
  /// finished responding. Used by the chat panel at the start of
  /// `_sendBtwTurn` so the user's prompt is rendered as a
  /// `BtwBubble.user` immediately, before the first delta arrives.
  /// The chat panel then calls [updateLastBtwTurnAiText] as the
  /// stream progresses so the AI side of the bubble updates in
  /// place without a list mutation (which would force a re-render
  /// of every prior turn as well).
  void appendPendingBtwTurn(int sessionId, String userText) {
    btwBuffer
        .putIfAbsent(sessionId, () => <BtwTurn>[])
        .add(BtwTurn(userText: userText, aiText: ''));
  }

  /// Update the AI-side text of the *last* btw turn in [sessionId]'s
  /// chain. Called by the chat panel as the LLM streams, so the
  /// `BtwBubble.ai` for the in-flight round updates in place rather
  /// than being re-created. No-op when the chain is empty (which
  /// would mean the chat panel and the controller are out of sync).
  void updateLastBtwTurnAiText(int sessionId, String aiText) {
    final list = btwBuffer[sessionId];
    if (list == null || list.isEmpty) return;
    final last = list.last;
    list[list.length - 1] = BtwTurn(userText: last.userText, aiText: aiText);
  }

  /// Drop every accumulated btw round for [sessionId] and leave an
  /// empty chain in its place. Called whenever the user issues a
  /// non-`/btw` input or runs `/retry` — i.e. the conditions under
  /// which a subsequent LLM call must NOT see the prior btw
  /// context. The chat panel triggers this through the explicit
  /// `clearBtwTurnsOnNextRealTurn` path used by `_sendMessage`
  /// and `/retry`. Note that `switchSession` does NOT clear —
  /// each session keeps its own chain across navigation.
  void clearBtwTurnsFor(int sessionId) {
    btwBuffer[sessionId] = <BtwTurn>[];
  }

  SessionController({
    required SessionStore store,
    required ProviderService providerService,
    required ChatService chatService,
    required void Function() refresh,
  }) : _store = store,
       _providerService = providerService,
       _chatService = chatService,
       _refresh = refresh;

  Session get currentSession {
    if (currentSessionId == null) {
      return Session(id: 0, title: 'New Session');
    }
    return sessions.firstWhere(
      (s) => s.id == currentSessionId,
      orElse: () => Session(id: 0, title: 'New Session'),
    );
  }

  List<Message> get currentMessages {
    final all = messageCache[currentSessionId] ?? [];
    return all;
  }

  Session? findSession(int id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  SessionRuntimeState runtime(int sessionId) {
    return _runtimeStates.putIfAbsent(sessionId, () {
      final initial = computeBaseContext(sessionId);
      final session = findSession(sessionId);
      return SessionRuntimeState(
        sessionId: sessionId,
        contextTargetTokens: initial,
        contextDisplayTokens: initial.toDouble(),
        thinkingMode: session?.thinkingMode ?? 'enabled',
        reasoningEffort: session?.reasoningEffort,
      );
    });
  }

  int computeBaseContext(int sessionId) {
    final session = findSession(sessionId);
    if (session != null && session.contextTokens > 0) {
      return session.contextTokens;
    }
    final msgs = messageCache[sessionId];
    if (msgs == null || msgs.isEmpty) return 0;
    var total = 0;
    for (final m in msgs) {
      if (m.tokensIn + m.tokensOut > 0) {
        total = m.tokensIn + m.tokensOut - m.reasoningTokens;
      } else {
        switch (m.role) {
          case 'user':
          case 'system':
          case 'ai':
            if (m.content.isNotEmpty) {
              total += estimateTokens(m.content);
            }
            if (m.reasoningContent.isNotEmpty) {
              total += estimateTokens(m.reasoningContent);
            }
          case 'tool_call':
            if (m.content.isNotEmpty) {
              total += estimateTokens(m.content);
            }
            if (m.reasoningContent.isNotEmpty) {
              total += estimateTokens(m.reasoningContent);
            }
            for (final call in m.toolCalls) {
              total += estimateToolRoundTripTokens(
                toolName: call.name,
                args: call.input,
                resultOutput: '',
                excludeArgsFromEstimate:
                    _chatService.offloadableArgsForTool(call.name),
              );
            }
          case 'tool':
            total += estimateToolRoundTripTokens(
              toolName: '',
              args: {},
              resultOutput: m.content,
            );
        }
      }
    }
    return total;
  }

  Future<void> initSessions() async {
    // Auto-archive sessions not updated in the last 5 days.
    await _store.autoArchive(
      projectPath: Directory.current.path,
      olderThan: const Duration(days: 5),
    );
    sessions = await _store.list(projectPath: Directory.current.path);
    archivedCount = await _store.archivedCount(
      projectPath: Directory.current.path,
    );
    if (sessions.isEmpty) {
      await _providerService.initialize();
      final model = _providerService.resolveDefaultModel() ?? '';
      final session = await _store.create(
        title: 'New Session',
        model: model,
        projectPath: Directory.current.path,
      );
      sessions = [session];
      resolveAuxiliaryModel();
    }
    currentSessionId = sessions.first.id;
    await loadMessages(currentSessionId!);
    _refresh();
  }

  Future<void> loadMessages(int sessionId) async {
    messageCache[sessionId] = await _store.getMessages(sessionId);
  }

  Future<String?> switchSession(int id) async {
    final session = findSession(id);
    if (session == null) {
      return 'Session #$id not found';
    }

    if (session.status == SessionStatus.done) {
      await _store.update(id, status: SessionStatus.idle);
      session.status = SessionStatus.idle;
    }

    // The in-memory `/btw` chain is *per session* and is NOT
    // cleared on session switch. Each session has its own
    // independent chain (keyed by session id), so navigating
    // between sessions doesn't leak one session's scratch space
    // into another's. The chain also survives a session switch:
    // when the user navigates back to a session that has a
    // pending chain, the renderer picks it up from
    // [btwTurnsFor] and the user sees the same boxed bubbles
    // they left behind. The chain is only dropped on a non-`/btw`
    // real turn (see the chat panel's `_sendMessage`) or when
    // the session itself is deleted (see [deleteSession]).

    currentSessionId = id;
    await loadMessages(id);
    final rt = runtime(id);
    final base = computeBaseContext(id);
    rt.contextTargetTokens = base;
    rt.contextDisplayTokens = base.toDouble();

    if (!rt.isResponding) {
      rt.ttftMs = 0;
      rt.ttftReceived = false;
      rt.tokPerSec = 0;
      rt.streamingDurationMs = 0;
      rt.cumulativeGenMs = 0.0;
      rt.cumulativeCompletionTokens = 0;
      rt.roundFirstTokenTime = null;
      rt.roundStreaming = false;
    }

    return null;
  }

  Future<void> deleteSession(int sessionId) async {
    final wasCurrent = sessionId == currentSessionId;
    await _store.deleteSession(sessionId);
    _runtimeStates.remove(sessionId);
    messageCache.remove(sessionId);
    // Drop the deleted session's btw chain alongside its other
    // in-memory state so we don't leak entries for a session that
    // no longer exists. Other sessions' chains are untouched.
    btwBuffer.remove(sessionId);
    sessions = await _store.list(projectPath: Directory.current.path);
    archivedCount = await _store.archivedCount(
      projectPath: Directory.current.path,
    );

    if (wasCurrent) {
      if (sessions.isNotEmpty) {
        currentSessionId = sessions.first.id;
        await loadMessages(currentSessionId!);
        final rt = runtime(currentSessionId!);
        final base = computeBaseContext(currentSessionId!);
        rt.contextTargetTokens = base;
        rt.contextDisplayTokens = base.toDouble();
      } else {
        final model = _providerService.resolveDefaultModel() ?? '';
        final session = await _store.create(
          title: 'New Session',
          model: model,
          projectPath: Directory.current.path,
        );
        sessions = [session];
        currentSessionId = session.id;
        await loadMessages(session.id);
      }
    }

    _refresh();
  }

  Future<void> renameSession(int sessionId, String newTitle) async {
    await _store.update(sessionId, title: newTitle);
    final session = findSession(sessionId);
    if (session != null) {
      session.title = newTitle;
    }
    _refresh();
  }

  bool _isGeneratingTitle = false;

  /// True while a session-title generation is in flight. The chat panel
  /// watches this to flash the auxiliary model label/button so the user
  /// can see which model is working in the background.
  bool get isGeneratingTitle => _isGeneratingTitle;

  Future<void> generateTitle(int sessionId) async {
    if (_isGeneratingTitle) return;
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == null || auxKey == 'none') return;
    final slashIndex = auxKey.indexOf('/');
    final providerName = slashIndex > 0 ? auxKey.substring(0, slashIndex) : '';
    final modelId = slashIndex > 0 ? auxKey.substring(slashIndex + 1) : auxKey;
    final provider = _providerService.providerByName(providerName);
    final apiKey = _providerService.getApiKey(providerName);
    if (provider == null) return;
    if (apiKey == null || apiKey.isEmpty) return;
    _isGeneratingTitle = true;
    _refresh();
    try {
      final title = await _chatService.generateSessionTitle(sessionId);
      if (title == null) return;
      final session = findSession(sessionId);
      if (session == null || session.title != 'New Session') return;
      await _store.update(sessionId, title: title);
      session.title = title;
      _refresh();
    } catch (_) {
    } finally {
      _isGeneratingTitle = false;
      _refresh();
    }
  }

  void resolveAuxiliaryModel() {
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == 'none') {
      auxiliaryModelShortName = 'none';
      return;
    }
    if (auxKey != null) {
      final model = _providerService.modelByCompositeKey(auxKey);
      if (model != null) {
        auxiliaryModelShortName = model.name;
        return;
      }
    }
    final localProvider = _providerService.providerByName('local');
    if (localProvider != null && localProvider.models.isNotEmpty) {
      auxiliaryModelShortName = localProvider.models.first.name;
    }
  }

  void persistThinkingLevel(SessionRuntimeState rt) {
    final sid = currentSessionId;
    if (sid == null) return;
    final session = findSession(sid);
    if (session != null) {
      session.thinkingMode = rt.thinkingMode;
      session.reasoningEffort = rt.reasoningEffort;
    }
    _store.update(
      sid,
      thinkingMode: rt.thinkingMode,
      reasoningEffort: rt.reasoningEffort,
    );
  }

  void dispose() {
    for (final rt in _runtimeStates.values) {
      rt.cancelTimers();
    }
    btwBuffer.clear();
  }
}
