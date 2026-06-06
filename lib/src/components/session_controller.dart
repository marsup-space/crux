import 'dart:io';
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/chat_service.dart';
import '../services/provider_service.dart';
import '../storage/session_store.dart';
import '../utils/token_estimate.dart';

class SessionController {
  final SessionStore _store;
  final ProviderService _providerService;
  final ChatService _chatService;
  final void Function() _refresh;

  List<Session> sessions = [];
  int? currentSessionId;
  final Map<int, SessionRuntimeState> _runtimeStates = {};
  final Map<int, List<Message>> messageCache = {};
  String auxiliaryModelShortName = 'auxiliary';

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
                    largePayloadTools.contains(call.name)
                        ? largePayloadExcludedArgs[call.name]
                        : null,
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
    sessions = await _store.list(projectPath: Directory.current.path);
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

    currentSessionId = id;
    await loadMessages(id);
    final rt = runtime(id);
    final base = computeBaseContext(id);
    rt.contextTargetTokens = base;
    rt.contextDisplayTokens = base.toDouble();
    rt.ttftMs = 0;
    rt.ttftReceived = false;
    rt.tokPerSec = 0;
    rt.streamingDurationMs = 0;
    rt.cumulativeGenMs = 0.0;
    rt.cumulativeCompletionTokens = 0;
    rt.roundFirstTokenTime = null;
    rt.roundStreaming = false;
    rt.isResponding = false;

    return null;
  }

  Future<void> deleteSession(int sessionId) async {
    final wasCurrent = sessionId == currentSessionId;
    await _store.deleteSession(sessionId);
    _runtimeStates.remove(sessionId);
    messageCache.remove(sessionId);
    sessions = await _store.list(projectPath: Directory.current.path);

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
  }
}
