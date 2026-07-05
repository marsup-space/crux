import 'dart:async';
import 'dart:io';
import '../models/image_attachment.dart';
import '../models/message.dart';
import '../models/message_queue.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/chat_service.dart';
import '../services/provider_service.dart';
import '../storage/message_store.dart';
import '../storage/session_store.dart';
import 'btw_cubit.dart';
import 'chat_turn_cubit.dart';
import 'metrics_cubit.dart';
import 'session_cubit.dart';
import 'streaming_cubit.dart';
import 'turn_registry.dart';

export 'btw_cubit.dart' show BtwTurn;

class SessionController {
  final SessionStore _store;
  final MessageStore _messageStore;
  final ProviderService _providerService;
  final ChatService _chatService;
  final void Function() _refresh;

  /// Passive mirror of the controller's session/navigation state. Every
  /// mutation on this controller also calls the matching cubit method,
  /// so widgets can subscribe via `BlocBuilder` while older code keeps
  /// reading from the controller's fields. The cubit is owned by the
  /// controller for the lifetime of the controller — close it with
  /// [dispose] or let the controller get GC'd.
  final SessionCubit cubit = SessionCubit();

  /// Passive mirror of the per-session `/btw` chains. Mirrors the
  /// same `Map<int, List<BtwTurn>>` shape as the cubit's state, so
  /// the chat panel can either keep reading from [btwTurnsFor] or
  /// subscribe via `BlocBuilder<BtwCubit>` in a future slice.
  final BtwCubit btwCubit = BtwCubit();

  /// Passive mirror of the per-session live metrics — context
  /// target, cache-hit percentage, generation duration, and so on.
  /// Mirrors the same `Map<int, MetricsSessionState>` shape as the
  /// cubit's state. Today's slice only establishes the lifecycle
  /// (controller owns the cubit and seeds `contextTargetTokens` /
  /// teardown on session removal); future slices will replace the
  /// controller's direct `runtime` reads with `BlocSelector`s and
  /// migrate more fields into the cubit.
  final MetricsCubit metricsCubit = MetricsCubit();

  /// Passive mirror of the per-session turn-phase lifecycle —
  /// `isResponding`, `btwMode`, `isGeneratingTldr`, `interrupted`.
  /// ChatTurnCubit owns the structured `ChatTurnSessionState` with
  /// `phase` + `kind` fields; the controller's legacy
  /// `SessionRuntimeState` keeps the same flags as flat booleans.
  /// [mirrorTurnFlags] bridges the two so subscribers see the
  /// current value of each lifecycle flag at every meaningful
  /// state transition (turn start, normal completion, error,
  /// interrupt, btw start/end).
  final ChatTurnCubit chatTurnCubit = ChatTurnCubit();

  /// Passive mirror of the per-session in-flight streaming state
  /// — accumulated response text, accumulated reasoning, waiting-
  /// for-model timer, executing-tools rows, streaming tool-use
  /// chunks, and the tool-input token estimate. Future slices
  /// move the write side (StreamingController's per-session
  /// mutators) over to this cubit; for now StreamingController
  /// remains the canonical writer and the cubit is a parallel
  /// structure. The seed is created by [runtime] when a
  /// session is first touched; teardown is via [dispose].
  final StreamingCubit streamingCubit = StreamingCubit();

  List<Session> sessions = [];
  int? currentSessionId;
  int archivedCount = 0;
  final Map<int, SessionRuntimeState> _runtimeStates = {};
  final Map<int, List<Message>> messageCache = {};
  String auxiliaryModelShortName = 'auxiliary';

  // ─── Switch-session loading state ───────────────────────────
  //
  // When a session switch happens, [beginSwitchSession] flips the
  // current session id synchronously and adds the target id to this
  // set so the chat history's empty-state branch can show a progress
  // indicator instead of "No messages yet.". [completeSwitchSession]
  // updates [_loadingTotalCounts] (set after the COUNT(*) query) and
  // [_loadingLoadedCounts] (after each chunk arrives) and clears all
  // three maps in its `finally` block so the loading UI is gone
  // before the chat panel does its final post-load setState.
  final Set<int> _loadingSessionIds = {};
  final Map<int, int> _loadingTotalCounts = {};
  final Map<int, int> _loadingLoadedCounts = {};

  /// Per-session pending image attachments. When the user runs `/image`,
  /// the image is loaded and stored here. When the user sends their next
  /// message, the pending images are attached to it and cleared.
  final Map<int, List<ImageAttachment>> pendingImages = {};

  /// Per-session stashed input text. When the user switches away from a
  /// session, the current input box content is saved here keyed by session
  /// id. When they switch back, the stash is restored so they don't lose
  /// work-in-progress text. Cleared when a session is deleted.
  final Map<int, String> inputTextStash = {};

  /// Per-session chain of `/btw` rounds that the user has issued since
  /// the last "real" turn. Kept in memory only — never written to disk
  /// (so a process restart drops them cleanly) and never mixed into the
  /// persisted history. Used by the chat panel to (a) re-feed prior
  /// btw rounds into the LLM context for the *next* btw call, and
  /// (b) render the boxed btw UI without going through the regular
  /// message bubble machinery.
  final Map<int, List<BtwTurn>> btwBuffer = {};

  /// Per-session message queue. When the agent is streaming (running
  /// an agentic loop with tool calls), new user messages are enqueued
  /// here instead of being sent immediately. The queue is drained at
  /// the next safe insertion point (after a tool round completes, or
  /// after the final response). Multiple queued messages are merged
  /// into a single user turn with a system prefix.
  final Map<int, MessageQueue> _messageQueues = {};

  /// Route-through access to the per-session input text stash. Stores
  /// [text] under [sessionId], or removes the entry when [text] is
  /// empty. Mirrors the same change into [cubit] so subscribed
  /// listeners stay in sync — this is the only place callers should
  /// mutate `inputTextStash` directly (the controller maps are kept
  /// for backward compatibility with older widget code).
  void stashInputText(int sessionId, String text) {
    if (text.isEmpty) {
      inputTextStash.remove(sessionId);
    } else {
      inputTextStash[sessionId] = text;
    }
    cubit.stashInputText(sessionId, text);
  }

  /// Read-only view of the message queue for [sessionId]. Returns an
  /// empty queue (not stored) when the session has never queued a
  /// message.
  MessageQueue messageQueueFor(int sessionId) {
    return _messageQueues.putIfAbsent(
      sessionId,
      () => MessageQueue(sessionId: sessionId),
    );
  }

  /// Enqueue a user message for [sessionId]. Returns the queue id
  /// for the new message (used for discarding). Creates the queue
  /// if this is the first queued message for the session.
  int enqueueMessage(int sessionId, String content) {
    final queue = _messageQueues.putIfAbsent(
      sessionId,
      () => MessageQueue(sessionId: sessionId),
    );
    final id = queue.enqueue(content);
    cubit.setQueuedMessages(sessionId, queue.messages);
    return id;
  }

  /// Discard a queued message by its queue id. Returns true if found.
  bool discardQueuedMessage(int sessionId, int queueId) {
    final queue = _messageQueues[sessionId];
    if (queue == null) return false;
    final discarded = queue.discard(queueId);
    if (discarded) cubit.setQueuedMessages(sessionId, queue.messages);
    return discarded;
  }

  /// Drain the message queue for [sessionId], returning the merged
  /// user message string (with the system prefix), or null if the
  /// queue is empty. Clears the queue after draining.
  String? drainMessageQueue(int sessionId) {
    final queue = _messageQueues[sessionId];
    if (queue == null || queue.isEmpty) return null;
    final result = queue.drain();
    cubit.setQueuedMessages(sessionId, queue.messages);
    return result.isEmpty ? null : result;
  }

  /// Clear the message queue for [sessionId] without draining.
  void clearMessageQueue(int sessionId) {
    _messageQueues[sessionId]?.clear();
    cubit.setQueuedMessages(sessionId, const []);
  }

  /// Add a pending image attachment for [sessionId]. The image will be
  /// attached to the next user message and then cleared.
  void addPendingImage(int sessionId, ImageAttachment image) {
    final list = pendingImages
        .putIfAbsent(sessionId, () => <ImageAttachment>[])
      ..add(image);
    cubit.setPendingImages(sessionId, List<ImageAttachment>.unmodifiable(list));
  }

  /// Replace all pending image attachments for [sessionId].
  void setPendingImages(int sessionId, List<ImageAttachment> images) {
    if (images.isEmpty) {
      pendingImages.remove(sessionId);
    } else {
      pendingImages[sessionId] = List<ImageAttachment>.from(images);
    }
    cubit.setPendingImages(sessionId, images);
  }

  /// Remove a single pending image by its 1-based index (the number
  /// shown in the `[ image N ]` text marker). Returns true if the
  /// image was found and removed.
  bool removePendingImage(int sessionId, int oneBasedIndex) {
    final list = pendingImages[sessionId];
    if (list == null) return false;
    if (oneBasedIndex < 1 || oneBasedIndex > list.length) return false;
    list.removeAt(oneBasedIndex - 1);
    if (list.isEmpty) pendingImages.remove(sessionId);
    cubit.setPendingImages(
      sessionId,
      pendingImages[sessionId] ?? const <ImageAttachment>[],
    );
    return true;
  }

  /// Get the pending images for [sessionId] (read-only).
  List<ImageAttachment> pendingImagesFor(int sessionId) =>
      List.unmodifiable(pendingImages[sessionId] ?? const <ImageAttachment>[]);

  /// Drain and clear the pending images for [sessionId], returning them.
  List<ImageAttachment> drainPendingImages(int sessionId) {
    final images = pendingImages.remove(sessionId) ?? const <ImageAttachment>[];
    cubit.drainPendingImages(sessionId);
    return images;
  }

  /// Clear the pending images for [sessionId] without attaching them.
  void clearPendingImages(int sessionId) {
    pendingImages.remove(sessionId);
    cubit.setPendingImages(sessionId, const []);
  }

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
    btwCubit.appendTurn(sessionId, turn);
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
    btwCubit.appendPendingTurn(sessionId, userText);
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
    btwCubit.updateLastAiText(sessionId, aiText);
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
    btwCubit.clearTurnsFor(sessionId);
  }

  SessionController({
    required SessionStore store,
    required ProviderService providerService,
    required ChatService chatService,
    required void Function() refresh,
  }) : _store = store,
       _messageStore = store.messageStore,
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

  /// Centralized session-status setter. Single chokepoint for
  /// any code that wants to move a session to a new status, so
  /// the "active vs background" rule lives in exactly one place
  /// and future callers can't accidentally regress it.
  ///
  /// ## The active-session rule
  ///
  /// When a streaming turn completes, [ChatService] sets the raw
  /// status to [SessionStatus.done] and the orchestrator calls
  /// this setter. We downgrade `done` → `idle` for the session
  /// the user is currently viewing ([currentSessionId]) because
  /// they were watching the response stream in real time — there
  /// is nothing "unread" about it, and showing `idle` is the
  /// correct "ready-for-input" signal. Background sessions, on
  /// the other hand, keep their `done` status so the sidebar
  /// keeps the `✦` ("completed but not yet viewed") indicator
  /// until the user switches to them.
  ///
  /// Switching to a `done` background session is what consumes
  /// the indicator: [completeSwitchSession] flips `done` →
  /// `idle` at that point (so the in-memory cache and the DB
  /// stay consistent), and the sidebar no longer shows `✦`.
  ///
  /// Other target statuses ([SessionStatus.idle] on error,
  /// [SessionStatus.interrupted] on user interrupt, etc.) are
  /// passed through unchanged — the active/background rule only
  /// applies to `done`.
  ///
  /// Updates both the in-memory [Session] and the DB row.
  /// Returns the *effective* status that was actually applied
  /// (which may differ from [target] for the active-session
  /// downgrade path), so the caller can use it for logging or
  /// to drive a follow-up action without re-deriving the rule.
  Future<SessionStatus> setSessionStatus(int sessionId, SessionStatus target) async {
    final session = findSession(sessionId);
    if (session == null) return target;

    final effective =
        (sessionId == currentSessionId && target == SessionStatus.done)
        ? SessionStatus.idle
        : target;

    session.status = effective;
    session.updatedAt = DateTime.now();
    try {
      final updated = await _store.update(sessionId, status: effective);
      session.status = updated.status;
      session.runningOwnerId = updated.runningOwnerId;
      session.runningHeartbeatAt = updated.runningHeartbeatAt;
      session.updatedAt = updated.updatedAt;
    } catch (_) {
      // Keep the in-memory SSoT sane even if persistence fails —
      // callers rely on `session.status` reflecting what they
      // asked for, and the DB write is best-effort (next launch
      // will reconcile any drift via the boot-time orphan sweep).
    }
    return effective;
  }

  SessionRuntimeState runtime(int sessionId) {
    return _runtimeStates.putIfAbsent(sessionId, () {
      final initial = computeBaseContext(sessionId);
      final session = findSession(sessionId);
      final rt = SessionRuntimeState(
        sessionId: sessionId,
        contextTargetTokens: initial,
        contextDisplayTokens: initial.toDouble(),
        thinkingMode: session?.thinkingMode ?? 'enabled',
        reasoningEffort: session?.reasoningEffort,
        temperatureOverride: session?.temperatureOverride,
      );
      // Seed MetricsCubit with the same base context target that the
      // runtime carries, so the cubit has an entry to subscribe to
      // before any caller actually mutates the runtime. The mirror
      // keeps both sources in lockstep at session creation.
      metricsCubit.updateContext(
        sessionId: sessionId,
        targetTokens: initial,
      );
      return rt;
    });
  }

  /// Mirror the runtime's lifecycle flags (isResponding, btwMode,
  /// isGeneratingTldr, interrupted) into ChatTurnCubit for
  /// [sessionId]. The cubit's `ChatTurnSessionState.phase` and
  /// `.kind` get derived from the runtime's flat booleans:
  ///
  ///   rt.isResponding true → phase = responding
  ///   rt.isResponding false, rt.interrupted true → phase = interrupted
  ///   otherwise → phase = idle
  ///   rt.btwMode true (while responding) → kind = TurnKind.btw
  ///   otherwise → kind = null
  ///
  /// Callers: the chat panel / orchestrator / tldr / btw handlers
  /// should call this after every direct mutation of the runtime's
  /// `isResponding`, `btwMode`, or `isGeneratingTldr` fields so the
  /// cubit-driven chat_history subscribers see fresh values without
  /// waiting for the next chat-panel _refresh(). The initial seed
  /// happens implicitly inside [runtime] when a session is first
  /// seen (both fields are `false` defaults there).
  void mirrorTurnFlags(int sessionId) {
    final rt = _runtimeStates[sessionId];
    if (rt == null) {
      chatTurnCubit.replaceSessionState(
        sessionId,
        const ChatTurnSessionState(),
      );
      return;
    }
    final phase = rt.isResponding
        ? ChatTurnPhase.responding
        : (rt.interrupted
              ? ChatTurnPhase.interrupted
              : ChatTurnPhase.idle);
    final kind =
        (rt.isResponding && rt.btwMode) ? TurnKind.btw : null;
    chatTurnCubit.replaceSessionState(
      sessionId,
      ChatTurnSessionState(
        phase: phase,
        kind: kind,
        isGeneratingTldr: rt.isGeneratingTldr,
      ),
    );
  }

  /// True iff at least one session (current or background) is in
  /// [SessionStatus.running]. Use this from anywhere that needs the
  /// "any agent is busy" signal — quit guards, sidebar activity
  /// dots, animation tickers. The previous check in callers was
  /// scoped to `currentSessionId` + `isResponding`, which missed
  /// background sessions entirely and also missed windows between
  /// token flushes while a session was still working (tool calls,
  /// awaited tool results, etc.).
  bool get hasAnyRunningSession =>
      sessions.any((s) => s.status == SessionStatus.running);

  /// Returns the current context size for [sessionId] in
  /// tokens, as the LLM will see it on the next turn. The
  /// single source of truth is
  /// [currentContextTokens]; this method just
  /// routes through the fast path (the cached
  /// `session.contextTokens` from the last successful AI
  /// turn) when available, and falls back to the SSoT for
  /// fresh / failed sessions.
  ///
  /// Used by the context bar's lerp target, the auto-compact
  /// gate, and the `turnBaseTokens` projection at the start of
  /// every new turn — keeping this in lockstep with the SSoT
  /// means a fresh / recovered session doesn't visually jump
  /// when it transitions from "no AI yet" to "AI has reported
  /// tokens".
  int computeBaseContext(int sessionId) {
    final session = findSession(sessionId);
    if (session != null && session.contextTokens > 0) {
      return session.contextTokens;
    }
    final msgs = messageCache[sessionId];
    if (msgs == null || msgs.isEmpty) return 0;
    return currentContextTokens(messages: msgs);
  }

  Future<void> initSessions() async {
    // Auto-archive sessions not updated in the last 3 days.
    await _store.autoArchive(
      projectPath: Directory.current.path,
      olderThan: const Duration(days: 3),
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
    Session? initialSession;
    for (final session in sessions) {
      if (session.status == SessionStatus.idle ||
          session.status == SessionStatus.done) {
        initialSession = session;
        break;
      }
    }
    if (initialSession == null) {
      await _providerService.initialize();
      final model = _providerService.resolveDefaultModel() ?? '';
      final session = await _store.create(
        title: 'New Session',
        model: model,
        projectPath: Directory.current.path,
      );
      sessions = [session, ...sessions];
      currentSessionId = session.id;
      resolveAuxiliaryModel();
    } else {
      currentSessionId = initialSession.id;
    }
    await loadMessages(currentSessionId!);
    cubit.replaceSessions(
      sessions: sessions,
      archivedCount: archivedCount,
      currentSessionId: currentSessionId,
    );
    _refresh();
  }

  bool _isInactiveRunningSession(Session session) {
    if (session.status != SessionStatus.running) return false;
    if (_chatService.isStreaming(session.id)) return false;
    if (_store.isLiveRunningSessionOwnedByAnotherInstance(session)) {
      return false;
    }
    return true;
  }

  Future<bool> reconcileInactiveRunningSessions({bool refresh = true}) async {
    var changed = false;
    for (final session in sessions) {
      if (!_isInactiveRunningSession(session)) continue;

      final current = await _store.getById(session.id);
      if (current == null) continue;
      session.status = current.status;
      session.runningOwnerId = current.runningOwnerId;
      session.runningHeartbeatAt = current.runningHeartbeatAt;
      session.updatedAt = current.updatedAt;

      if (current.status != SessionStatus.running) {
        changed = true;
        continue;
      }
      if (!_isInactiveRunningSession(session)) continue;

      final wasOwnedByThisInstance =
          current.runningOwnerId == _store.instanceId;
      final status = wasOwnedByThisInstance
          ? SessionStatus.idle
          : SessionStatus.interrupted;

      final rt = _runtimeStates[session.id];
      if (rt != null && !rt.isResponding) {
        rt.roundStreaming = false;
        rt.roundStartTime = null;
        rt.roundFirstTokenTime = null;
      }

      session.status = status;
      session.runningOwnerId = null;
      session.runningHeartbeatAt = null;
      session.updatedAt = DateTime.now();

      final updated = await _store.update(session.id, status: status);
      session.status = updated.status;
      session.runningOwnerId = updated.runningOwnerId;
      session.runningHeartbeatAt = updated.runningHeartbeatAt;
      session.updatedAt = updated.updatedAt;
      changed = true;
    }

    if (changed && refresh) {
      _refresh();
    }
    return changed;
  }

  Future<void> loadMessages(int sessionId) async {
    putCachedMessages(sessionId, await _messageStore.getMessages(sessionId));
  }

  /// Single-writer setter for the in-memory message cache. Updates
  /// `messageCache[sessionId]` and mirrors the same list into [cubit]
  /// so any BlocBuilder on [SessionCubit] sees the new snapshot. Both
  /// paths go through here so the cache and cubit can never disagree.
  void putCachedMessages(int sessionId, List<Message> messages) {
    final cached = List<Message>.unmodifiable(messages);
    messageCache[sessionId] = cached;
    cubit.putMessages(sessionId, cached);
  }

  /// Sync the cubit's snapshot from the controller's current
  /// legacy-mutable fields. Used by code paths that bypass the
  /// per-mutation mirror helpers (e.g. the chat_panel boot path
  /// pre-populates the controller directly from `loadChatPanelBootState`
  /// before `initSessions` runs, so the cubit has not yet seen those
  /// assignments). Callers must own the cubit's lifecycle — this
  /// helper overwrites it with a full snapshot.
  ///
  /// Mirrors the bloc branch's `syncCubitFromLegacyState`. New code
  /// should not need this; route mutations through the per-field
  /// helpers (initSessions, switchSession, deleteSession, …) so the
  /// cubit stays in lockstep naturally.
  void syncCubitFromLegacyState() {
    cubit.replaceSessions(
      sessions: sessions,
      archivedCount: archivedCount,
      currentSessionId: currentSessionId,
    );
    for (final entry in messageCache.entries) {
      cubit.putMessages(entry.key, entry.value);
    }
    for (final sessionId in _loadingSessionIds) {
      cubit.beginLoadingMessages(sessionId);
      cubit.updateLoadingProgress(
        sessionId: sessionId,
        total: _loadingTotalCounts[sessionId],
        loaded: _loadingLoadedCounts[sessionId],
      );
    }
  }

  /// True while the message list for [sessionId] is being filled in
  /// by a chunked load (i.e. the user just switched to it and the
  /// first paint hasn't landed yet). The chat history's empty-state
  /// branch uses this to render a progress line instead of
  /// "No messages yet.".
  bool isLoadingMessages(int sessionId) =>
      _loadingSessionIds.contains(sessionId);

  /// Total number of messages that will be loaded for [sessionId], or
  /// null while the COUNT(*) query is still in flight. Capped at
  /// 1000 by [loadMessagesChunked] — sessions with more than 1000
  /// messages report only the count that will actually land in
  /// `messageCache`.
  int? loadingMessageTotal(int sessionId) =>
      _loadingTotalCounts[sessionId];

  /// Number of messages already loaded into the cache for [sessionId]
  /// during the current chunked load. Used by the chat history's
  /// loading line to render `… (NN%)` once at least one chunk has
  /// arrived.
  int? loadingMessageLoaded(int sessionId) =>
      _loadingLoadedCounts[sessionId];

  Future<String?> switchSession(int id) async {
    final error = beginSwitchSession(id);
    if (error != null) return error;
    await completeSwitchSession(id);
    return null;
  }

  /// Synchronous half of [switchSession]: validate the target,
  /// flip [currentSessionId], set the context-bar target to a
  /// sensible placeholder, reset streaming metrics, and mark the
  /// session as "loading messages" so the chat history's empty-state
  /// branch can render a progress line.
  ///
  /// Crucially, **no awaits happen between the `currentSessionId`
  /// flip and the target reset** — the context bar's 16ms lerp
  /// ticker reads both fields on every tick and uses a
  /// `_currentSessionId != sessionId` guard to snap on session
  /// switches. If the id flipped before the target reset, a tick in
  /// that window would snap to the OLD session's `contextTargetTokens`,
  /// then once the reset finally landed the bar would lerp from the
  /// stale snap value toward the new base — the "still seems wrong"
  /// lerp the original [switchSession] was structured to avoid.
  ///
  /// The placeholder target is `session.contextTokens` (the value
  /// persisted on the session row by the last AI turn). For sessions
  /// that have ever reported context tokens, this is exactly what
  /// [computeBaseContext] would return — so the bar's value never
  /// changes between begin and the eventual refine in
  /// [completeSwitchSession]. For sessions where
  /// `session.contextTokens == 0`, [computeBaseContext] may walk the
  /// message cache in [completeSwitchSession] and pick up a
  /// different value (the last AI message's token sum, or 0); the
  /// bar will smoothly move to that final value once the first
  /// chunk lands.
  ///
  /// Returns `null` on success or a human-readable error string.
  /// On error, no state has been mutated.
  String? beginSwitchSession(int id) {
    final session = findSession(id);
    if (session == null) {
      return 'Session #$id not found';
    }

    if (_store.isLiveRunningSessionOwnedByAnotherInstance(session)) {
      return 'Session #$id is running in another Crux instance';
    }

    // Mark loading BEFORE flipping the id so the chat history's
    // first paint (between this return and the first chunk from
    // [completeSwitchSession]) shows a progress line instead of
    // "No messages yet.".
    _loadingSessionIds.add(id);
    cubit.beginLoadingMessages(id);

    final rt = runtime(id);
    rt.contextTargetTokens = session.contextTokens;
    rt.contextDisplayTokens = session.contextTokens.toDouble();

    currentSessionId = id;
    cubit.setCurrentSession(id);

    if (!rt.isResponding) {
      rt.ttftMs = 0;
      rt.ttftReceived = false;
      rt.tokPerSec = 0;
      rt.streamingDurationMs = 0;
      rt.cumulativeGenMs = 0.0;
      rt.cumulativeCompletionTokens = 0;
      rt.roundStartTime = null;
      rt.roundFirstTokenTime = null;
      rt.roundStreaming = false;
    }

    return null;
  }

  /// Async half of [switchSession]: load the new session's messages
  /// in chunks (so the chat history paints the first chunk within a
  /// few ms instead of freezing on a single `SELECT *`), update the
  /// progress counters between chunks, and refine the context-bar
  /// target with the computed base once everything is loaded.
  ///
  /// Must be called only after [beginSwitchSession] returns null for
  /// the same [id]. The `onProgress` callback fires after each chunk
  /// arrives (and once more at the end) so the chat panel can
  /// `setState` between chunks and the user sees the loading line
  /// tick down `… (12%)` → `… (48%)` → `… (100%)`.
  ///
  /// The in-memory `/btw` chain is per-session and intentionally
  /// NOT cleared here — the renderer picks the chain back up via
  /// [btwTurnsFor] when the user returns.
  Future<void> completeSwitchSession(
    int id, {
    void Function()? onProgress,
  }) async {
    try {
      final session = findSession(id);
      if (session != null &&
          (session.status == SessionStatus.done ||
              session.status == SessionStatus.interrupted)) {
        // In-memory flip first so any subsequent reads (e.g. the
        // chat panel's polling loops) see the right status without
        // waiting for the DB. The DB write is best-effort and
        // unawaited — if it fails the worst case is the status
        // drifts back to `done`/`interrupted` on next launch, which
        // [markOrphanedRunningSessionsAsInterrupted] would correct.
        session.status = SessionStatus.idle;
        unawaited(_store.update(id, status: SessionStatus.idle));
      }

      await _loadMessagesChunked(id, onProgress: onProgress);

      // Refine the context-bar target with the computed base now
      // that we have the real messages. For sessions that already
      // reported context tokens, this is a no-op (the placeholder
      // set in [beginSwitchSession] was already the right value).
      final rt = runtime(id);
      final base = computeBaseContext(id);
      rt.contextTargetTokens = base;
      rt.contextDisplayTokens = base.toDouble();
      // Mirror the refined context target into MetricsCubit so any
      // BlocSelector on the cubit sees the fresh value. The runtime
      // is the legacy write-side; the cubit is the read-side for
      // widgets migrated to BlocBuilder / BlocSelector.
      metricsCubit.updateContext(sessionId: id, targetTokens: base);
    } finally {
      _loadingSessionIds.remove(id);
      _loadingTotalCounts.remove(id);
      _loadingLoadedCounts.remove(id);
      cubit.finishLoadingMessages(id);
      onProgress?.call();
    }
  }

  /// Chunked loader behind [completeSwitchSession]. Loads the
  /// latest messages first (so the chat history's bottom — the
  /// most recent conversation — paints within a single DB
  /// round-trip), then walks backwards with `beforeId` to fill in
  /// older history on top.
  ///
  /// Two critical-path optimisations matter for "huge session
  /// switch is sluggish":
  ///
  /// 1. COUNT(*) and the first chunk are issued **in parallel**.
  ///    Both hit the messages table; running them concurrently
  ///    means the first paint is gated by whichever returns last,
  ///    not by the sum of the two. The COUNT is only used for the
  ///    "Loading N messages… (X%)" label, so the user always sees
  ///    *some* content as soon as the first chunk lands — even if
  ///    COUNT is still in flight, the label degrades gracefully
  ///    from "Loading messages…" (initial tick) to "Loading 247
  ///    messages…" (after COUNT) to "Loading 247 messages… (24%)"
  ///    (after each subsequent chunk).
  ///
  /// 2. The first chunk is 4× the size of later chunks (200 vs 50).
  ///    Most sessions fit entirely in one round-trip — the user
  ///    gets the full latest-200 window on first paint, no
  ///    background fill needed. Sessions with >200 messages get
  ///    smaller chunks for the older tail so each round-trip stays
  ///    short and the per-tick event-loop yield (`Duration.zero`)
  ///    keeps the UI responsive.
  ///
  /// Order of messages in the cache is oldest → newest (matching
  /// how [currentMessages] is rendered). Newer chunks are appended
  /// to the right, older chunks are prepended to the left.
  ///
  /// Caps total loaded messages at [_kMessageCap] (1000) — matches
  /// the previous single-fetch behaviour for sessions that fit, and
  /// surfaces `… (loaded / total)` honestly for sessions with more.
  /// Once the cap is hit the loop exits and the chat history shows
  /// the loaded window; older messages stay on disk but aren't
  /// rendered, which is the same behaviour users had before.
  Future<void> _loadMessagesChunked(
    int sessionId, {
    void Function()? onProgress,
  }) async {
    // The boot path ([loadChatPanelBootState]) pre-loads the first
    // chunk synchronously so the splash screen clears fast, then
    // calls [completeSwitchSession] to fill in the rest. If we
    // detect that the cache already has messages for [sessionId],
    // skip the first-chunk fetch and resume from the oldest id in
    // the cache — avoids a wasted ~200ms re-fetching the same rows.
    final preloaded = messageCache[sessionId];
    final resumedFromBoot =
        preloaded != null && preloaded.isNotEmpty;

    // Kick off COUNT(*) and the first chunk (or a no-op if we're
    // resuming from the boot pre-load) concurrently. Both return
    // Futures without waiting — drift will schedule them on its
    // connection pool, and the await below picks up whichever is
    // ready first. The first chunk is the bigger query (more rows
    // → more SQLite work), so it tends to win the race, but even
    // in the worst case we save COUNT's latency from the critical
    // path.
    final firstChunkFuture = resumedFromBoot
        ? Future<List<Message>>.value(const <Message>[])
        : _messageStore.getMessages(
            sessionId,
            limit: _kFirstChunkSize,
          );
    final totalFuture = _messageStore.countBySession(sessionId);

    final firstChunk = await firstChunkFuture;
    // First chunk is the LATEST `_kFirstChunkSize` messages in
    // chronological order (oldest first within). When resuming
    // from the boot pre-load, [preloaded] is already the latest
    // chunk — the empty [firstChunk] just keeps the loop below
    // consistent.
    final accumulated = <Message>[
      if (resumedFromBoot) ...preloaded,
      ...firstChunk,
    ];
    putCachedMessages(sessionId, accumulated);
    _loadingLoadedCounts[sessionId] = accumulated.length;
    cubit.updateLoadingProgress(
      sessionId: sessionId,
      loaded: accumulated.length,
    );
    // First progress tick: the chat history can now render real
    // bubbles instead of the loading label. If COUNT hasn't
    // returned yet, the label still says "Loading messages…"
    // (without a count) — that's the graceful-degradation path.
    onProgress?.call();

    final total = await totalFuture;
    _loadingTotalCounts[sessionId] = total;
    cubit.updateLoadingProgress(sessionId: sessionId, total: total);
    // Second progress tick: now the label can show "Loading N
    // messages…" with the actual total, and the `(X%)` suffix
    // becomes meaningful as subsequent chunks arrive.
    onProgress?.call();

    if (accumulated.length >= total || accumulated.length >= _kMessageCap) {
      // Entire session (or as much as we cap at) loaded in one
      // round-trip. Common case for typical sessions.
      return;
    }

    // Walk backwards from the oldest id in the cache to fill in
    // older messages. When resuming from boot, this starts from the
    // oldest id in the pre-loaded chunk; otherwise from the oldest
    // id in the first chunk we just fetched. Either way, each chunk
    // is prepended so the final list reads oldest → newest, with
    // the latest messages (from the boot pre-load or the first
    // chunk) staying at the bottom of the rendered chat — exactly
    // what the user wants to see first.
    int? beforeId = accumulated.first.id;
    var loaded = accumulated.length;
    while (loaded < total && loaded < _kMessageCap) {
      final remaining =
          loaded + _kLaterChunkSize <= _kMessageCap
              ? _kLaterChunkSize
              : _kMessageCap - loaded;
      final chunk = await _messageStore.getMessages(
        sessionId,
        limit: remaining,
        beforeId: beforeId,
      );
      if (chunk.isEmpty) break;
      accumulated.insertAll(0, chunk);
      loaded += chunk.length;
      // `chunk.first` is the OLDEST id in the chunk (the loader
      // reverses the DESC result back to chronological order), so
      // `beforeId = chunk.first.id` is the right cursor for the
      // next round of older messages.
      beforeId = chunk.first.id;
      _loadingLoadedCounts[sessionId] = loaded;
      putCachedMessages(sessionId, accumulated);
      cubit.updateLoadingProgress(sessionId: sessionId, loaded: loaded);
      onProgress?.call();
      // Yield to the event loop so the chat panel can paint the
      // just-arrived chunk before we queue the next DB round-trip.
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Size of the first message batch. Deliberately small so the
  /// cold-cache disk read for "Loading N messages…" → first-paint
  /// is bounded. With no index on `messages.session_id` (prior to
  /// the v23 migration) and sessions whose message table spans
  /// tens of MB, a 200-row first chunk read ~6MB of data — which
  /// on HDD / NFS / slow USB produced a 6–7s loading flash before
  /// the first paint. 50 rows keeps the cold read under 1.5MB
  /// while still being big enough to show the user the full
  /// bottom-of-chat context on first paint (the 20 or so most
  /// recent bubbles).
  static const int _kFirstChunkSize = 50;

  /// Size of every batch after the first. Larger than the first
  /// because by the time we're past chunk 1, the relevant table
  /// pages are already warm in the OS file cache — the cold-read
  /// cost that motivated the small first chunk doesn't apply. 200
  /// here means a 1000-message session loads in 6 chunks
  /// (50 + 5×200) instead of 17 (50 + 17×50), so the background
  /// fill is ~3× faster once the user sees content.
  static const int _kLaterChunkSize = 200;

  /// Hard cap on total loaded messages per session — matches the
  /// previous single-fetch behaviour. Sessions with more than this
  /// show the latest [_kMessageCap] messages; older rows stay on
  /// disk but aren't rendered.
  static const int _kMessageCap = 1000;

  Future<void> deleteSession(int sessionId) async {
    final wasCurrent = sessionId == currentSessionId;
    await _store.deleteSession(sessionId);
    _runtimeStates.remove(sessionId);
    messageCache.remove(sessionId);
    cubit.removeSessionState(sessionId);
    // Drop the deleted session's input text stash alongside its other
    // in-memory state so we don't leak entries for a session that no
    // longer exists.
    inputTextStash.remove(sessionId);
    // Drop the deleted session's btw chain alongside its other
    // in-memory state so we don't leak entries for a session that
    // no longer exists. Other sessions' chains are untouched.
    btwBuffer.remove(sessionId);
    btwCubit.removeSession(sessionId);
    // Drop the deleted session's metrics mirror so the cubit doesn't
    // retain a stale entry for a session the controller has forgotten.
    metricsCubit.removeSession(sessionId);
    // Same cleanup for the turn-phase mirror so chat_history won't
    // keep rendering per-session state for a deleted session.
    chatTurnCubit.removeSession(sessionId);
    // Also drop the deleted session's message queue.
    _messageQueues.remove(sessionId);
    sessions = await _store.list(projectPath: Directory.current.path);
    archivedCount = await _store.archivedCount(
      projectPath: Directory.current.path,
    );
    cubit.replaceSessions(
      sessions: sessions,
      archivedCount: archivedCount,
      currentSessionId: currentSessionId,
    );

    if (wasCurrent) {
      if (sessions.isNotEmpty) {
        currentSessionId = sessions.first.id;
        cubit.setCurrentSession(currentSessionId);
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
        cubit.replaceSessions(
          sessions: sessions,
          archivedCount: archivedCount,
          currentSessionId: currentSessionId,
        );
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
      cubit.replaceSessions(
        sessions: sessions,
        archivedCount: archivedCount,
        currentSessionId: currentSessionId,
      );
    }
    _refresh();
  }

  bool _isGeneratingTitle = false;

  /// True while a session-title generation is in flight. The chat panel
  /// watches this to flash the auxiliary model label/button so the user
  /// can see which model is working in the background.
  bool get isGeneratingTitle => _isGeneratingTitle;

  Future<void> generateTitle(int sessionId, {String? userContent}) async {
    if (_isGeneratingTitle) return;
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == null || auxKey == 'none') return;
    final slashIndex = auxKey.indexOf('/');
    final providerName = slashIndex > 0 ? auxKey.substring(0, slashIndex) : '';
    final provider = _providerService.providerByName(providerName);
    final apiKey = _providerService.getApiKey(providerName);
    if (provider == null) return;
    if (apiKey == null || apiKey.isEmpty) return;
    _isGeneratingTitle = true;
    cubit.setGeneratingTitle(true);
    _refresh();
    try {
      final title = await _chatService.generateSessionTitle(
        sessionId,
        userContent: userContent,
      );
      if (title == null) return;
      final session = findSession(sessionId);
      if (session == null || session.title != 'New Session') return;
      await _store.update(sessionId, title: title);
      session.title = title;
      cubit.replaceSessions(
        sessions: sessions,
        archivedCount: archivedCount,
        currentSessionId: currentSessionId,
      );
      _refresh();
    } catch (_) {
    } finally {
      _isGeneratingTitle = false;
      cubit.setGeneratingTitle(false);
      _refresh();
    }
  }

  void resolveAuxiliaryModel() {
    String next = auxiliaryModelShortName;
    final auxKey = _providerService.auxiliaryModel;
    if (auxKey == 'none') {
      next = 'none';
    } else if (auxKey != null) {
      final model = _providerService.modelByCompositeKey(auxKey);
      if (model != null) {
        next = model.name;
      } else {
        final localProvider = _providerService.providerByName('local');
        if (localProvider != null && localProvider.models.isNotEmpty) {
          next = localProvider.models.first.name;
        }
      }
    }
    auxiliaryModelShortName = next;
    cubit.setAuxiliaryModelShortName(next);
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

  /// Mirror the in-memory runtime's `temperatureOverride` onto the
  /// `Session` and persist it via `SessionStore.update`. Called by
  /// the `/temperature` slash command — the runtime owns the
  /// authoritative in-memory value (the chat turn executor reads
  /// from it directly), but the row owns the cross-restart value.
  /// Same persistence shape as `persistThinkingLevel`.
  Future<void> persistTemperature(SessionRuntimeState rt) async {
    final sid = currentSessionId;
    if (sid == null) return;
    final session = findSession(sid);
    if (session != null) {
      session.temperatureOverride = rt.temperatureOverride;
    }
    await _store.update(sid, temperatureOverride: rt.temperatureOverride);
  }

  void dispose() {
    for (final rt in _runtimeStates.values) {
      rt.cancelTimers();
    }
    btwBuffer.clear();
    inputTextStash.clear();
    _messageQueues.clear();
    cubit.close();
    btwCubit.close();
    metricsCubit.close();
    chatTurnCubit.close();
    streamingCubit.close();
  }
}
