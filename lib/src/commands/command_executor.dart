import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/auxiliary_prompts.dart';
import '../services/provider_service.dart';
import '../storage/session_store.dart';
import '../commands/registry.dart';
import '../components/ui/toast.dart';

// Signature for the toast callback used by commands.
typedef ShowToastCallback = void Function(String message, {ToastMode mode});

class CommandContext {
  final SessionStore store;
  final ProviderService providerService;
  final bool providerServiceReady;
  final Session currentSession;
  final int? currentSessionId;
  final List<Session> sessions;
  final List<Message> currentMessages;
  final String projectPath;
  final void Function() refresh;
  final ShowToastCallback showToast;
  final Future<void> Function(int) switchSession;
  final Future<void> Function() initSessions;
  final Future<void> Function() createNewSession;
  final SessionRuntimeState Function(int) runtime;
  final void Function(SessionRuntimeState) persistThinkingLevel;
  final void Function() resolveAuxiliaryModel;
  final void Function(String) enterBuiltinWizard;
  final void Function(int, Message, TldrDetail)? triggerTldr;

  /// Re-trigger the chat pipeline for a single turn. When [text] is
  /// non-null, it's treated as the new user prompt: persisted to the
  /// DB and prepended to the in-memory cache, then the LLM is called.
  /// When [text] is omitted, the existing conversation history is
  /// re-submitted as-is — no new user message is added, the
  /// in-memory cache is left alone, and the LLM is called with
  /// whatever the persisted wire-format history currently ends on.
  /// The omitted form is used by `/continue` to round-trip a
  /// trailing tool result cleanly without injecting an artificial
  /// user turn. Used by `/continue` and `/retry` so they don't have
  /// to drive the text controller or the internal state machine
  /// directly. Implementations should be no-ops (and surface a
  /// toast) when the session is already responding.
  final Future<void> Function({String? text}) sendTurn;

  /// Return the most recent user-role message in the current session,
  /// or `null` if no such message exists. The implementation must
  /// return the real DB id for the message (not the in-memory
  /// placeholder id), because the executor uses it as the boundary
  /// for [deleteMessagesFrom] (in `/retry`) and to decide whether
  /// the last round is still in progress (in `/continue`). Async
  /// because the implementation may need to re-read the DB to get
  /// the real id.
  final Future<Message?> Function() findLastUserMessage;

  /// Wipe every persisted message in the current session whose id is
  /// `>=` [fromId] and reload the in-memory message cache so the UI
  /// reflects the deletion. Used by `/retry` to discard the last
  /// round (user prompt + AI response + tool calls) before
  /// re-sending. The [fromId] is the id of the last user message,
  /// which itself is removed so the retry can re-add it as a fresh
  /// attempt.
  final Future<void> Function(int fromId) deleteMessagesFrom;

  CommandContext({
    required this.store,
    required this.providerService,
    required this.providerServiceReady,
    required this.currentSession,
    required this.currentSessionId,
    required this.sessions,
    required this.currentMessages,
    required this.projectPath,
    required this.refresh,
    required this.showToast,
    required this.switchSession,
    required this.initSessions,
    required this.createNewSession,
    required this.runtime,
    required this.persistThinkingLevel,
    required this.resolveAuxiliaryModel,
    required this.enterBuiltinWizard,
    this.triggerTldr,
    required this.sendTurn,
    required this.findLastUserMessage,
    required this.deleteMessagesFrom,
  });
}

class CommandExecutor {
  Future<void> execute(String text, CommandContext ctx) async {
    final parts = text.split(' ');
    final commandName = parts[0];
    final command = findCommand(commandName);

    switch (commandName) {
      case '/model':
        await executeModel(parts, ctx);
      case '/auxiliary':
        await executeAuxiliary(parts, ctx);
      case '/session':
        await executeSession(parts, ctx);
      case '/new':
        await executeNew(ctx);
      case '/provider':
        await executeProvider(parts, ctx);
      case '/think':
        await executeThink(parts, ctx);
      case '/tldr':
        await executeTldr(parts, ctx);
      case '/continue':
      case '/继续':
        await executeContinue(ctx);
      case '/retry':
      case '/重试':
        await executeRetry(ctx);
      case '/project':
        await executeProject(parts, ctx);
      case '/debug':
        await executeDebug(parts, ctx);
      case '/d-state':
        await executeDebugState(ctx);
      case '/d-messages':
        await executeDebugMessages(ctx);
      case '/d-context':
        await executeDebugContext(ctx);
      case '/d-runtime':
        await executeDebugRuntime(ctx);
      case '/d-providers':
        await executeDebugProviders(ctx);
      case '/d-tools':
        await executeDebugTools(ctx);
      case '/d-paths':
        await executeDebugPaths(ctx);
      case '/d-env':
        await executeDebugEnv(ctx);
      case '/d-toast':
        await executeDebugToast(parts, ctx);
      default:
        if (command != null) {
          ctx.showToast('$commandName — not yet implemented', mode: ToastMode.error);
        } else {
          ctx.showToast('Unknown command: $commandName', mode: ToastMode.error);
        }
    }
  }

  Future<void> executeModel(List<String> parts, CommandContext ctx) async {
    if (parts.length > 1 && parts[1].isNotEmpty) {
      final modelKey = parts[1];
      if (ctx.providerServiceReady &&
          ctx.providerService.modelByCompositeKey(modelKey) == null) {
        ctx.showToast('Unknown model: $modelKey', mode: ToastMode.error);
      } else {
        if (ctx.currentSessionId != null) {
          await ctx.store.update(ctx.currentSessionId!, model: modelKey);
          ctx.currentSession.model = modelKey;
        }
        ctx.showToast('Model switched to $modelKey', mode: ToastMode.status);
        ctx.providerService.setLastUsedModel(modelKey);
      }
    } else {
      ctx.showToast('Usage: /model <name>');
    }
  }

  Future<void> executeAuxiliary(List<String> parts, CommandContext ctx) async {
    if (parts.length > 1 && parts[1].isNotEmpty) {
      final modelKey = parts[1];
      if (modelKey == 'none') {
        await ctx.providerService.setAuxiliaryModel('none');
        ctx.resolveAuxiliaryModel();
        ctx.showToast('Auxiliary model disabled', mode: ToastMode.status);
      } else if (ctx.providerServiceReady &&
          ctx.providerService.modelByCompositeKey(modelKey) == null) {
        ctx.showToast('Unknown model: $modelKey', mode: ToastMode.error);
      } else {
        await ctx.providerService.setAuxiliaryModel(modelKey);
        ctx.resolveAuxiliaryModel();
        ctx.showToast('Auxiliary model set to $modelKey', mode: ToastMode.status);
      }
    } else {
      ctx.showToast('Usage: /auxiliary <name>');
    }
  }

  Future<void> executeSession(List<String> parts, CommandContext ctx) async {
    if (parts.length > 1 && parts[1].isNotEmpty) {
      final idStr = parts[1].replaceFirst('#', '');
      final id = int.tryParse(idStr);
      if (id != null) {
        await ctx.switchSession(id);
      } else {
        ctx.showToast('Usage: /session #<id>');
      }
    } else {
      ctx.showToast('Usage: /session #<id>');
    }
  }

  Future<void> executeNew(CommandContext ctx) async {
    final isCurrentEmpty =
        ctx.currentMessages.isEmpty &&
        ctx.currentSession.title == 'New Session';
    if (isCurrentEmpty) {
      ctx.showToast('Already on a new session');
    } else {
      await ctx.createNewSession();
    }
  }

  Future<void> executeProvider(List<String> parts, CommandContext ctx) async {
    final subcommand = parts.length > 1 ? parts[1] : '';

    if (subcommand.isEmpty) {
      final names = ctx.providerService.providerNames();
      ctx.showToast('Usage: /provider <${names.join("|")}>');
      return;
    }

    ctx.providerService.initialize().then((_) {
      final provider = ctx.providerService.providerByName(subcommand);
      if (provider == null) {
        final names = ctx.providerService.providerNames();
        ctx.showToast('Provider "$subcommand" not found. Available: ${names.join(", ")}', mode: ToastMode.error);
        return;
      }
      ctx.enterBuiltinWizard(subcommand);
    });
  }

  Future<void> executeThink(List<String> parts, CommandContext ctx) async {
    if (ctx.currentSessionId == null) return;
    final rt = ctx.runtime(ctx.currentSessionId!);
    final effort = parts.length > 1 ? parts[1] : '';
    switch (effort) {
      case 'off':
        rt.thinkingMode = 'disabled';
        rt.reasoningEffort = null;
        ctx.persistThinkingLevel(rt);
        ctx.showToast('Thinking mode: off', mode: ToastMode.status);
      case 'normal':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'normal';
        ctx.persistThinkingLevel(rt);
        ctx.showToast('Thinking mode: normal', mode: ToastMode.status);
      case 'high':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'high';
        ctx.persistThinkingLevel(rt);
        ctx.showToast('Thinking mode: high', mode: ToastMode.status);
      case 'max':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'max';
        ctx.persistThinkingLevel(rt);
        ctx.showToast('Thinking mode: max', mode: ToastMode.status);
      default:
        final current = rt.thinkingMode == 'disabled'
            ? 'off'
            : rt.reasoningEffort ?? 'normal';
        ctx.showToast(
          'Usage: /think <off|normal|high|max> (current: $current)',
        );
    }
  }

  Future<void> executeProject(List<String> parts, CommandContext ctx) async {
    if (parts.length > 1 && parts[1].isNotEmpty) {
      final target = p.normalize(p.absolute(parts[1]));
      final dir = Directory(target);
      if (!dir.existsSync()) {
        ctx.showToast('Directory not found: $target', mode: ToastMode.error);
      } else {
        Directory.current = dir;
        await ctx.initSessions();
        ctx.showToast('Switched to $target', mode: ToastMode.status);
      }
    } else {
      ctx.showToast('Usage: /project <path> (current: ${ctx.projectPath})');
    }
  }

  Future<void> executeTldr(List<String> parts, CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    final lastAi = ctx.currentMessages.lastWhere(
      (m) => m.role == 'ai',
      orElse: () => Message(id: -1, sessionId: 0, role: 'ai', content: ''),
    );
    if (lastAi.id <= 0 || lastAi.content.isEmpty) {
      ctx.showToast('No AI response to summarize');
      return;
    }

    // Optional level param. Missing or "default" → TldrDetail.defaultLevel.
    final rawLevel = parts.length > 1 ? parts[1].trim().toLowerCase() : '';
    final TldrDetail detail;
    switch (rawLevel) {
      case '':
      case 'default':
        detail = TldrDetail.defaultLevel;
      case 'concise':
        detail = TldrDetail.concise;
      case 'detailed':
        detail = TldrDetail.detailed;
      default:
        ctx.showToast(
          'Unknown /tldr level "$rawLevel". Use concise, default, or detailed.',
        );
        return;
    }

    if (ctx.triggerTldr != null) {
      ctx.triggerTldr!(ctx.currentSessionId!, lastAi, detail);
    }
  }

  /// `/continue` (alias `/继续`) — resubmit the current conversation
  /// context to the LLM so it can keep generating.
  ///
  /// What "resubmit the context" means depends on what the last
  /// persisted segment looks like, because the LLM APIs require the
  /// trailing turn to satisfy a role-alternation rule:
  ///
  /// - If the last segment is a `tool` result, the wire-format
  ///   conversation already ends on a valid trailing turn (a `tool`
  ///   role on the OpenAI wire, or a `user` turn carrying
  ///   `tool_result` blocks on the Anthropic wire). Resubmit as-is —
  ///   no nudge, no extra user message — and the LLM picks up from
  ///   the in-flight tool flow.
  /// - If the last segment is a bare `user` message (e.g. the AI
  ///   was interrupted before producing any output), resubmitting
  ///   as-is ends on `user`, which the API also accepts; the LLM
  ///   will simply respond to the user's question again. No nudge
  ///   needed.
  /// - If the last segment is `ai` (round completed normally), the
  ///   wire format ends on `assistant`, which the API rejects. We
  ///   append a tiny "请继续" user turn so alternation is valid and
  ///   the LLM sees a clear "keep going" intent.
  /// - Anything else (e.g. a half-written `tool_call` that the AI
  ///   was interrupted mid-emit) falls through to the nudge case —
  ///   safe, even if it's a slightly weird prompt.
  ///
  /// In all cases the executor refuses to run while the AI is
  /// already responding, since launching a second concurrent turn
  /// against the same session would race the in-flight stream.
  Future<void> executeContinue(CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    final sessionId = ctx.currentSessionId!;
    final rt = ctx.runtime(sessionId);
    if (rt.isResponding) {
      ctx.showToast('AI is already responding');
      return;
    }
    final lastRole =
        ctx.currentMessages.isEmpty ? null : ctx.currentMessages.last.role;
    switch (lastRole) {
      case 'tool':
      case 'user':
        // Wire format already ends on a valid trailing turn;
        // resubmit the existing context verbatim. The LLM
        // continues from where it left off (or re-responds to
        // the user question, in the bare-user case).
        await ctx.sendTurn();
      case 'ai':
      case 'tool_call':
      case null:
        // Round finished (or never started) on a role the API
        // won't accept as the trailing turn; append a small
        // "please continue" nudge so the LLM keeps elaborating.
        await ctx.sendTurn(text: '请继续。');
      default:
        // Future-proof: any new role falls back to the nudge
        // path. Same as the `ai` case above.
        await ctx.sendTurn(text: '请继续。');
    }
  }

  /// `/retry` (alias `/重试`) — re-send the last user prompt from
  /// scratch, discarding whatever the previous round produced.
  ///
  /// "Discards" means: delete every persisted message from the last
  /// user message onwards (the user message itself, the AI response,
  /// any tool calls and tool results), reload the in-memory message
  /// cache so the UI reflects the wipe, and then re-trigger the
  /// chat pipeline with the same user text. The user gets a single
  /// fresh attempt and the conversation anchor stays put.
  ///
  /// Like `/continue`, this is only valid when the session is not
  /// currently responding — otherwise we'd race with the in-flight
  /// stream. The command is also rejected when there is no user
  /// message to retry.
  Future<void> executeRetry(CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    final sessionId = ctx.currentSessionId!;
    final rt = ctx.runtime(sessionId);
    if (rt.isResponding) {
      ctx.showToast('Cannot retry while AI is responding');
      return;
    }
    final lastUser = await ctx.findLastUserMessage();
    if (lastUser == null) {
      ctx.showToast('Nothing to retry — no user message yet');
      return;
    }
    // Wipe the last round and reload the cache before re-sending so
    // the chat panel doesn't briefly show a duplicate of the old
    // user message while the new turn kicks off.
    await ctx.deleteMessagesFrom(lastUser.id);
    await ctx.sendTurn(text: lastUser.content);
  }

  // ─────────────────────────────────────────────────────────────────────
  // /debug — toggles registration of debug commands.
  // ─────────────────────────────────────────────────────────────────────

  Future<void> executeDebug(List<String> parts, CommandContext ctx) async {
    // Bare `/debug` — toggles registration of the `/d-*` command set.
    final registry = CommandRegistry.instance;
    final on = registry.toggleDebug();
    if (on) {
      final count =
          registry.all.where((c) => c.name.startsWith('/d-')).length;
      ctx.showToast('Debug mode ON — $count debug commands registered', mode: ToastMode.status);
    } else {
      ctx.showToast('Debug mode OFF', mode: ToastMode.status);
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // Debug commands — only callable when debug mode is enabled.
  // ─────────────────────────────────────────────────────────────────────

  Future<void> executeDebugState(CommandContext ctx) async {
    final s = ctx.currentSession;
    final buf = StringBuffer();
    buf.writeln('Session:');
    buf.writeln('  id:              ${s.id}');
    buf.writeln('  title:           ${s.title}');
    buf.writeln('  slug:            ${s.slug}');
    buf.writeln('  status:          ${s.status.name}');
    buf.writeln('  model:           ${s.model}');
    buf.writeln('  agent:           ${s.agent}');
    buf.writeln('  parentId:        ${s.parentId}');
    buf.writeln('  projectPath:     ${s.projectPath}');
    buf.writeln('  cost:            ${s.cost.toStringAsFixed(4)}');
    buf.writeln('  tokensIn:        ${s.tokensIn}');
    buf.writeln('  tokensOut:       ${s.tokensOut}');
    buf.writeln('  contextTokens:   ${s.contextTokens}');
    buf.writeln('  ttftMs:          ${s.ttftMs.toStringAsFixed(1)}');
    buf.writeln('  tokPerSec:       ${s.tokPerSec.toStringAsFixed(2)}');
    buf.writeln('  cacheHitTokens:  ${s.promptCacheHitTokens}');
    buf.writeln('  thinkingMode:    ${s.thinkingMode}');
    buf.writeln('  reasoningEffort: ${s.reasoningEffort ?? "—"}');
    buf.writeln('  createdAt:       ${s.createdAt.toIso8601String()}');
    buf.writeln('  updatedAt:       ${s.updatedAt.toIso8601String()}');
    buf.writeln(
      '  archivedAt:      ${s.archivedAt?.toIso8601String() ?? "—"}',
    );
    buf.writeln('  messageCount:    ${ctx.currentMessages.length}');
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugMessages(CommandContext ctx) async {
    if (ctx.currentMessages.isEmpty) {
      ctx.showToast('No messages in current session');
      return;
    }
    final buf = StringBuffer();
    buf.writeln('Messages (${ctx.currentMessages.length}):');
    for (final m in ctx.currentMessages) {
      buf.writeln(
        '  #${m.id} [${m.role}] '
        '${m.model.isEmpty ? "" : "model=${m.model} "}'
        'in=${m.tokensIn} out=${m.tokensOut} '
        'cost=${m.cost.toStringAsFixed(4)} '
        'reason=${m.reasoningTokens}t '
        'thinkMs=${m.thinkingDurationMs} '
        'effort=${m.reasoningEffort ?? "—"} '
        'tldr=${m.tldr.isEmpty ? "—" : "\"${_truncate(m.tldr, 30)}\""} '
        'parent=${m.parentMsgId ?? "—"} '
        'toolCallId=${m.toolCallId.isEmpty ? "—" : m.toolCallId} '
        'toolCalls=${m.toolCalls.length} '
        'err=${m.error ?? "—"}',
      );
    }
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugContext(CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    final rt = ctx.runtime(ctx.currentSessionId!);
    final buf = StringBuffer();
    buf.writeln('Context:');
    buf.writeln('  turnBaseTokens:        ${rt.turnBaseTokens}');
    buf.writeln('  accumulatedToolTokens: ${rt.accumulatedToolTokens}');
    buf.writeln('  contextTargetTokens:   ${rt.contextTargetTokens}');
    buf.writeln(
      '  contextDisplayTokens:  ${rt.contextDisplayTokens.toStringAsFixed(0)}',
    );
    buf.writeln(
      '  effectiveStreamingMs:  ${rt.effectiveStreamingMs.toStringAsFixed(1)}',
    );
    buf.writeln(
      '  thinkingDurationMs:    ${rt.thinkingDurationMs.toStringAsFixed(1)}',
    );
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugRuntime(CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    final rt = ctx.runtime(ctx.currentSessionId!);
    final buf = StringBuffer();
    buf.writeln('Runtime:');
    buf.writeln('  isResponding:              ${rt.isResponding}');
    buf.writeln('  roundStreaming:            ${rt.roundStreaming}');
    buf.writeln('  ttftMs:                    ${rt.ttftMs.toStringAsFixed(1)}');
    buf.writeln('  ttftReceived:              ${rt.ttftReceived}');
    buf.writeln('  tokPerSec:                 ${rt.tokPerSec.toStringAsFixed(2)}');
    buf.writeln('  tokCount:                  ${rt.tokCount.toStringAsFixed(0)}');
    buf.writeln(
      '  streamingDurationMs:       ${rt.streamingDurationMs.toStringAsFixed(1)}',
    );
    buf.writeln('  cumulativeGenMs:           ${rt.cumulativeGenMs.toStringAsFixed(1)}');
    buf.writeln('  cumulativeCompletionTokens: ${rt.cumulativeCompletionTokens}');
    buf.writeln(
      '  responseStartTime:         ${rt.responseStartTime?.toIso8601String() ?? "—"}',
    );
    buf.writeln(
      '  contentStartTime:          ${rt.contentStartTime?.toIso8601String() ?? "—"}',
    );
    buf.writeln(
      '  firstTokenTime:            ${rt.firstTokenTime?.toIso8601String() ?? "—"}',
    );
    buf.writeln(
      '  roundFirstTokenTime:       ${rt.roundFirstTokenTime?.toIso8601String() ?? "—"}',
    );
    buf.writeln('  thinkingMode:              ${rt.thinkingMode}');
    buf.writeln('  reasoningEffort:           ${rt.reasoningEffort ?? "—"}');
    buf.writeln('  cacheHitPct:               ${rt.cacheHitPct ?? "—"}');
    buf.writeln('  isGeneratingTldr:          ${rt.isGeneratingTldr}');
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugProviders(CommandContext ctx) async {
    if (!ctx.providerServiceReady) {
      ctx.showToast('ProviderService not ready', mode: ToastMode.error);
      return;
    }
    final buf = StringBuffer();
    buf.writeln('Providers:');
    for (final name in ctx.providerService.providerNames()) {
      final hasKey = ctx.providerService.getApiKey(name) != null;
      buf.writeln('  $name  key=${hasKey ? "set" : "missing"}');
    }
    buf.writeln('Models:');
    for (final entry in ctx.providerService.allModelEntries()) {
      final ctxStr = entry.model.contextSize >= 1000000
          ? '${(entry.model.contextSize / 1048576).toStringAsFixed(0)}M'
          : '${(entry.model.contextSize / 1000).toStringAsFixed(0)}K';
      final img = entry.model.imageSupport ? ', img' : '';
      final think = entry.model.thinking ? ', think' : '';
      buf.writeln('  ${entry.compositeKey}  ($ctxStr ctx$img$think)');
    }
    buf.writeln('Auxiliary model: ${ctx.providerService.auxiliaryModel ?? "—"}');
    buf.writeln('Last used model: ${ctx.providerService.lastUsedModel ?? "—"}');
    buf.writeln('Tldr threshold:  ${ctx.providerService.tldrThreshold}');
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugTools(CommandContext ctx) async {
    // Tool registry isn't part of CommandContext (it's owned by ChatPanel).
    // Surface a placeholder explaining where to look; if you want a full
    // dump, expose the registry through CommandContext and iterate here.
    ctx.showToast(
      'Tools: see lib/src/tools/. Use /d-paths to locate the providers dir.',
    );
  }

  Future<void> executeDebugPaths(CommandContext ctx) async {
    final xdgData = Platform.environment['XDG_DATA_HOME'];
    final home = Platform.environment['HOME'] ?? '.';
    final dataDir = xdgData != null && xdgData.isNotEmpty
        ? p.join(xdgData, 'crux')
        : p.join(home, '.local', 'share', 'crux');
    final buf = StringBuffer();
    buf.writeln('Paths:');
    buf.writeln('  projectPath:    ${ctx.projectPath}');
    buf.writeln('  providersDir:   ${ctx.providerService.providersDir}');
    buf.writeln(
      '  builtInProvDir: ${ctx.providerService.builtInProvidersDir ?? "—"}',
    );
    buf.writeln('  authJsonPath:   ${ctx.providerService.authJsonPath}');
    buf.writeln('  dataDir:        $dataDir');
    buf.writeln('  databaseFile:   ${p.join(dataDir, "crux.db")}');
    buf.writeln('  cwd:            ${Directory.current.path}');
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugEnv(CommandContext ctx) async {
    final buf = StringBuffer();
    buf.writeln('Environment:');
    buf.writeln(
      '  platform:      ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
    buf.writeln('  dartVersion:   ${Platform.version}');
    buf.writeln('  numProcessors: ${Platform.numberOfProcessors}');
    buf.writeln('  localeName:    ${Platform.localeName}');
    buf.writeln(
      '  XDG_DATA_HOME: ${Platform.environment['XDG_DATA_HOME'] ?? "—"}',
    );
    buf.writeln('  HOME:          ${Platform.environment['HOME'] ?? "—"}');
    buf.writeln(
      '  PATH (first 80): ${_truncate(Platform.environment['PATH'] ?? "—", 80)}',
    );
    ctx.showToast(buf.toString().trimRight());
  }

  /// `/d-toast <message>` — display a toast. The mode is auto-detected
  /// by [detectToastMode] from keywords in the message (e.g. "failed" →
  /// error, "done" → status, "note" → info). Useful for testing the
  /// toast UI in isolation.
  Future<void> executeDebugToast(List<String> parts, CommandContext ctx) async {
    if (parts.length < 2 || parts[1].trim().isEmpty) {
      ctx.showToast('Usage: /d-toast <message>');
      return;
    }
    final message = parts.skip(1).join(' ').trim();
    // No explicit mode → ToastHub's keyword detection runs.
    ctx.showToast(message);
  }

  String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}
