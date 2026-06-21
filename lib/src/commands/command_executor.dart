import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/auxiliary_prompts.dart';
import '../services/chat_service.dart';
import '../services/provider_service.dart';
import '../services/recent_projects_store.dart';
import '../storage/session_store.dart';
import '../utils/terminal_symbols.dart';
import '../utils/user_data_directory.dart';
import '../commands/registry.dart';
import '../components/ui/toast.dart';
import '../theme/theme_controller.dart';
import '../utils/frame_profiler.dart';

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
  /// Trigger a TLDR summary for [aiMsg]. The fourth positional
  /// argument is the user-role message that preceded [aiMsg] —
  /// surfaced to the auxiliary model so the summary can prioritize
  /// what the user actually asked and match their language. May
  /// be null when [aiMsg] has no real preceding user turn.
  final void Function(int, Message, TldrDetail, String?)? triggerTldr;
  final ThemeController? themeController;

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

  /// Compact the current session into a child session and switch to it.
  final Future<void> Function()? compactSession;

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

  /// Drive a `/btw` turn. The chat panel implementation is
  /// responsible for (a) rendering a transient boxed bubble for
  /// the user prompt and AI response, (b) calling the LLM with the
  /// persisted history + the in-memory btw chain + the new prompt
  /// (and *no* tools, since btw is a pure text side-question), and
  /// (c) appending the resulting `(userText, aiText)` pair to the
  /// session's in-memory btw chain so the next `/btw` sees it as
  /// context. Must be a no-op (with a toast) when the session is
  /// already responding, and must not persist anything to the DB.
  final Future<void> Function(String prompt) sendBtwTurn;

  /// Drop the in-memory `/btw` chain for [sessionId]. Called by the
  /// chat panel when the user issues any non-`/btw` input, so the
  /// btw context is guaranteed to never leak into a "real" turn.
  final void Function(int sessionId) clearBtwTurns;

  /// Replace the contents of the chat input box with [text]. Used
  /// by `/undo` to drop the user's previous prompt back into the
  /// input box after wiping the round from the session, so the user
  /// can edit it before resubmitting. Implementation is owned by the
  /// chat panel (the executor doesn't know about the text
  /// controller). Optional so legacy test harnesses can omit it —
  /// `/undo` treats `null` as a no-op for the input side-effect and
  /// still performs the DB wipe, mirroring how other callbacks
  /// degrade gracefully when not mounted.
  final void Function(String text)? setInputText;

  /// Tear down the TUI and exit. Wired by `ChatPanel` to
  /// `shutdownApp()` from nocterm — when the executor calls
  /// this, the alt-screen is restored, `runApp()` returns, and
  /// `bin/crux.dart` prints the per-run summary. Optional
  /// because legacy test harnesses and the `--doctor` path
  /// don't mount a panel; the executor treats `null` as a
  /// no-op (with an error toast) so the command surfaces
  /// something useful even in those environments.
  final VoidCallback? quitApp;

  /// Open the fullpane overlay. Implemented by ChatPanel via
  /// setState + overlayController.showFullpane.
  final VoidCallback? showFullpane;

  /// Store of recently-opened project directories. Used by `/project`
  /// to remember every directory the user has switched into (whether
  /// from the in-app command or by launching `crux <path>`) so the
  /// chat input can auto-suggest the next time the user types
  /// `/project`. Optional so callers that don't care (legacy tests,
  /// debug harnesses) can omit it; the executor treats `null` as a
  /// no-op for the bookkeeping side-effect.
  final RecentProjectsStore? recentProjectsStore;

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
    this.triggerTldr,
    this.themeController,
    required this.sendTurn,
    this.compactSession,
    required this.findLastUserMessage,
    required this.deleteMessagesFrom,
    required this.sendBtwTurn,
    required this.clearBtwTurns,
    this.setInputText,
    this.quitApp,
    this.showFullpane,
    this.recentProjectsStore,
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
      case '/theme':
        await executeTheme(parts, ctx);
      case '/think':
        await executeThink(parts, ctx);
      case '/tldr':
        await executeTldr(parts, ctx);
      case '/compact':
        await executeCompact(ctx);
      case '/continue':
      case '/继续':
        await executeContinue(ctx);
      case '/retry':
      case '/重试':
        await executeRetry(ctx);
      case '/undo':
      case '/撤销':
        await executeUndo(ctx);
      case '/btw':
        await executeBtw(parts, ctx);
      case '/archive':
        await executeArchive(parts, ctx);
      case '/unarchive':
        await executeUnarchive(parts, ctx);
      case '/rename':
      case '/重命名':
        await executeRename(parts, ctx);
      case '/quit':
      case '/exit':
        await executeQuit(ctx);
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
      case '/d-fullpane':
        await executeDebugFullpane(ctx);
      case '/d-profiler':
        await executeDebugProfiler(parts, ctx);
      default:
        if (command != null) {
          ctx.showToast(
            '$commandName — not yet implemented',
            mode: ToastMode.error,
          );
        } else {
          ctx.showToast('Unknown command: $commandName', mode: ToastMode.error);
        }
    }
  }

  Future<void> executeTheme(List<String> parts, CommandContext ctx) async {
    final controller = ctx.themeController;
    if (controller == null) {
      ctx.showToast('Theme service is unavailable', mode: ToastMode.error);
      return;
    }

    final id = parts.length > 1 ? parts[1].trim() : '';
    if (id.isEmpty) {
      ctx.showToast(
        'Current theme: ${controller.activeId}. Usage: /theme <name>',
      );
      return;
    }

    final result = await controller.switchTheme(id);
    if (!result.found) {
      ctx.showToast(
        'Unknown theme "$id". Available: ${controller.availableIds.join(", ")}',
        mode: ToastMode.error,
      );
      return;
    }

    if (!result.persisted) {
      ctx.showToast(
        'Theme switched to $id, but config could not be saved',
        mode: ToastMode.error,
      );
      return;
    }
    ctx.showToast('Theme switched to $id', mode: ToastMode.status);
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
        ctx.showToast(
          'Auxiliary model set to $modelKey',
          mode: ToastMode.status,
        );
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

  /// `/provider [<name> [<key>|remove]]`
  ///
  /// Inline provider / API-key management. The full-screen key-entry
  /// wizard is gone — setting a key is a one-liner. Add a new
  /// provider by `cp`ing the bundled `example.provider.toml` to
  /// `~/.config/crux/providers/<name>.toml` and editing the fields.
  ///
  /// Forms accepted:
  /// - `/provider`                    → list registered providers
  /// - `/provider <name>`             → show that provider's status
  ///                                   (key set? endpoint? models?)
  /// - `/provider <name> <key>`       → persist the API key (writes
  ///                                   to `auth.toml` with `0o600`)
  /// - `/provider <name> remove`      → delete the persisted key
  Future<void> executeProvider(List<String> parts, CommandContext ctx) async {
    final name = parts.length > 1 ? parts[1].trim() : '';
    final arg = parts.length > 2 ? parts[2].trim() : '';

    if (name.isEmpty) {
      final names = ctx.providerService.providerNames();
      ctx.showToast(
        'Providers: ${names.join(", ")}. '
        'Usage: /provider <name> [<key>|remove]',
      );
      return;
    }

    final provider = ctx.providerService.providerByName(name);
    if (provider == null) {
      final names = ctx.providerService.providerNames();
      ctx.showToast(
        'Provider "$name" not found. Available: ${names.join(", ")}. '
        'To add it, copy ~/.config/crux/providers/example.provider.toml '
        'to ~/.config/crux/providers/$name.toml and edit it.',
        mode: ToastMode.error,
      );
      return;
    }

    if (arg.isEmpty) {
      // /provider <name> — show status.
      final hasKey = ctx.providerService.getApiKey(name) != null;
      final models = provider.models.map((m) => m.name).join(', ');
      ctx.showToast(
        '$name  [${provider.type}]  '
        'endpoint=${provider.endpointUrl}  '
        'key=${hasKey ? "set" : "missing"}  '
        'models=$models',
      );
      return;
    }

    if (arg == 'remove' || arg == '--remove' || arg == 'rm') {
      await ctx.providerService.removeApiKey(name);
      ctx.showToast(
        '${terminalSymbol('✓', '+')} Removed API key for $name',
        mode: ToastMode.status,
      );
      return;
    }

    // /provider <name> <key> — persist.
    await ctx.providerService.setApiKey(name, arg);
    ctx.showToast(
      '${terminalSymbol('✓', '+')} Saved API key for $name',
      mode: ToastMode.status,
    );
  }

  Future<void> executeThink(List<String> parts, CommandContext ctx) async {
    if (ctx.currentSessionId == null) return;
    final rt = ctx.runtime(ctx.currentSessionId!);
    final effort = parts.length > 1 ? parts[1] : '';

    // Resolve the provider's reasoning presets so display labels are
    // consistent with the chat panel toolbar. Any provider can override
    // labels — e.g. MiniMax M3 shows "adaptive" instead of "normal".
    final modelKey = ctx.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : '';
    final modelId = slashIdx > 0 ? modelKey.substring(slashIdx + 1) : modelKey;
    final provider = ctx.providerServiceReady
        ? ctx.providerService.providerByName(providerName)
        : null;
    final modelConfig = provider?.modelById(modelId);
    final llm = ctx.providerServiceReady
        ? ctx.providerService.llmProviderByName(providerName)
        : null;
    final presets =
        llm?.reasoningPresetsFor(
          modelId,
          providerLabels: provider?.reasoningLabels ?? const {},
          modelLabels: modelConfig?.reasoningLabels ?? const {},
        ) ??
        const [];

    // Map a display label back to its internal value (e.g. "adaptive" →
    // "normal"). If the user types a display label that differs from
    // the internal value, resolve it. If they type an internal value
    // directly, that works too.
    String resolveInput(String input) {
      for (final p in presets) {
        if (p.displayLabel == input) return p.internalValue;
      }
      return input;
    }

    // Map an internal value to its display label using the provider's
    // presets — same mapping the chat panel toolbar uses.
    String displayEffort(String internal) {
      for (final p in presets) {
        if (p.internalValue == internal) return p.displayLabel;
      }
      return internal;
    }

    final internalEffort = resolveInput(effort);

    switch (internalEffort) {
      case 'off':
        rt.thinkingMode = 'disabled';
        rt.reasoningEffort = null;
        ctx.persistThinkingLevel(rt);
        ctx.showToast('Thinking mode: off', mode: ToastMode.status);
      case 'low':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'low';
        ctx.persistThinkingLevel(rt);
        ctx.showToast('Thinking mode: low', mode: ToastMode.status);
      case 'normal':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'normal';
        ctx.persistThinkingLevel(rt);
        ctx.showToast(
          'Thinking mode: ${displayEffort('normal')}',
          mode: ToastMode.status,
        );
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
            : displayEffort(rt.reasoningEffort ?? 'normal');
        final levelLabels = presets.map((p) => p.displayLabel).toList();
        final levels = levelLabels.isNotEmpty
            ? '<${levelLabels.join('|')}>'
            : '<off|low|normal|high|max>';
        ctx.showToast('Usage: /think $levels (current: $current)');
    }
  }

  Future<void> executeProject(List<String> parts, CommandContext ctx) async {
    if (parts.length > 1 && parts[1].isNotEmpty) {
      final expanded = _expandHome(parts[1]);
      final target = p.normalize(p.absolute(expanded));
      final dir = Directory(target);
      if (!dir.existsSync()) {
        ctx.showToast('Directory not found: $target', mode: ToastMode.error);
      } else {
        Directory.current = dir;
        // Record the switch *before* `initSessions` so a slow
        // session-init (it touches the DB) can't race with the file
        // write — the recent-projects file will already reflect the
        // new cwd by the time the user sees the toast. The store
        // swallows write errors so a failed flush doesn't poison
        // the session reload that follows.
        await ctx.recentProjectsStore?.add(target);
        await ctx.initSessions();
        ctx.showToast('Switched to $target', mode: ToastMode.status);
      }
    } else {
      ctx.showToast('Usage: /project <path> (current: ${ctx.projectPath})');
    }
  }

  String _expandHome(String path) {
    final hasHomePrefix =
        path == '~' || path.startsWith('~/') || path.startsWith(r'~\');
    if (!hasHomePrefix) return path;
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return path;
    if (path == '~' || path.length == 2) return home;
    return p.join(home, path.substring(2));
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

    // Find the user message that immediately precedes lastAi so the
    // summarizer knows what was being asked. Walk currentMessages
    // backwards from lastAi and stop at the first user-role row —
    // any user rows *after* lastAi are unrelated to this turn.
    String? lastUserContent;
    final lastAiIndex = ctx.currentMessages.indexOf(lastAi);
    if (lastAiIndex > 0) {
      for (var i = lastAiIndex - 1; i >= 0; i--) {
        if (ctx.currentMessages[i].role == 'user') {
          lastUserContent = ctx.currentMessages[i].content;
          break;
        }
      }
    }

    if (ctx.triggerTldr != null) {
      ctx.triggerTldr!(ctx.currentSessionId!, lastAi, detail, lastUserContent);
    }
  }

  Future<void> executeCompact(CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    final compact = ctx.compactSession;
    if (compact == null) {
      ctx.showToast('Compaction unavailable', mode: ToastMode.error);
      return;
    }
    await compact();
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
  /// A brand-new, empty session has no context to continue and is
  /// rejected up front with a toast — firing a synthetic "请继续。"
  /// turn in that case would just be a meaningless LLM call. This
  /// mirrors how `/retry` rejects an empty session.
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
    // Empty session → nothing to continue. Reject up front so we
    // don't send a synthetic "请继续。" turn to the LLM with no
    // surrounding context (which would either be a no-op or, worse,
    // a confusing user message in a fresh session).
    if (ctx.currentMessages.isEmpty) {
      ctx.showToast('Nothing to continue — session is empty');
      return;
    }
    final lastRole = ctx.currentMessages.last.role;
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
        // Round finished on a role the API won't accept as the
        // trailing turn; append a small "please continue" nudge
        // so the LLM keeps elaborating.
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
    // Retry is the explicit signal that the user wants a fresh
    // attempt at the *real* conversation — any in-memory `/btw`
    // scratch space from before the failed attempt is also no
    // longer relevant. Drop it so the retry's LLM call (and the
    // stream of any subsequent turns) starts from a clean slate.
    ctx.clearBtwTurns(sessionId);
    await ctx.sendTurn(text: lastUser.content);
  }

  /// `/undo` (alias `/撤销`) — discard the last agent round (user
  /// message + AI response + tool calls/result) and put the user's
  /// original prompt back into the input box for editing, instead
  /// of re-sending it like `/retry` does.
  ///
  /// "Discard" uses the same persistence path as `/retry`: locate
  /// the most recent user-role message, ask the orchestrator to
  /// delete every persisted message with id `>=` that row, and
  /// reload the in-memory cache so the UI reflects the wipe before
  /// the input is repopulated. After the wipe we hand the user
  /// text back via [CommandContext.setInputText] — at that point
  /// the previous prompt is sitting in the chat input box, ready
  /// for the user to tweak and resend.
  ///
  /// Mirrors `/retry`'s safety guards: rejected when the session
  /// is currently responding (would race the in-flight stream) and
  /// when there is no user message to undo. The btw chain is also
  /// cleared for the same reason as `/retry` — any scratch space
  /// from before the round we're undoing is no longer relevant.
  Future<void> executeUndo(CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    final sessionId = ctx.currentSessionId!;
    final rt = ctx.runtime(sessionId);
    if (rt.isResponding) {
      ctx.showToast('Cannot undo while AI is responding', mode: ToastMode.error);
      return;
    }
    final lastUser = await ctx.findLastUserMessage();
    if (lastUser == null) {
      ctx.showToast('Nothing to undo — no user message yet', mode: ToastMode.info);
      return;
    }
    // Wipe the last round first, then copy the prompt into the
    // input box. Doing it in this order (rather than the reverse)
    // means the in-memory message cache is already clean by the
    // time the chat panel re-renders the now-populated input —
    // there's no flash of the old bubbles staying on screen
    // alongside the restored draft text.
    await ctx.deleteMessagesFrom(lastUser.id);
    ctx.clearBtwTurns(sessionId);
    ctx.setInputText?.call(lastUser.content);
    ctx.showToast(
      'Undone — edit the prompt and press Enter to resend',
      mode: ToastMode.status,
    );
  }

  /// `/btw <prompt>` — fire a one-shot, ephemeral AI response.
  ///
  /// The AI's reply is rendered in a dim, bordered bubble and lives
  /// only in [SessionController.btwBuffer]. Nothing is written to the
  /// database, and the chain evaporates on the user's next non-`/btw`
  /// input (or session switch, or `/retry`). Consecutive `/btw` calls
  /// chain: the next `/btw` sees every prior btw round (in this
  /// session) as context for the LLM call, so a user can ask a
  /// follow-up like "/btw what about edge cases?" and the model has
  /// the previous answer to draw on.
  ///
  /// The executor only handles prompt validation and the
  /// "is the AI already responding" guard; the actual streaming,
  /// rendering, and buffer mutation live in
  /// [CommandContext.sendBtwTurn].
  Future<void> executeBtw(List<String> parts, CommandContext ctx) async {
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
    if (parts.length < 2 || parts[1].trim().isEmpty) {
      ctx.showToast('Usage: /btw <prompt>');
      return;
    }
    // Re-join the rest of the line (instead of just parts[1]) so
    // prompts can contain spaces verbatim, e.g.
    //   /btw how do I rename a file in bash?
    final prompt = parts.skip(1).join(' ').trim();
    if (prompt.isEmpty) {
      ctx.showToast('Usage: /btw <prompt>');
      return;
    }
    await ctx.sendBtwTurn(prompt);
  }

  /// `/archive` — archive the current session so it disappears from
  /// the sidebar. The session is not deleted; it is simply hidden by
  /// setting [Session.archivedAt]. The sidebar's session list already
  /// filters out archived sessions. After archiving, the chat panel
  /// switches to the next available session (or creates a new one if
  /// none remain), just like [SessionController.deleteSession] does
  /// when the current session is deleted.
  Future<void> executeArchive(List<String> parts, CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    final sessionId = ctx.currentSessionId!;
    final session = ctx.sessions.where((s) => s.id == sessionId).firstOrNull;
    final title = session?.title ?? '#$sessionId';
    await ctx.store.archiveSession(sessionId);
    // Reload the session list and switch to another session.
    await ctx.initSessions();
    ctx.showToast('Archived "$title"', mode: ToastMode.status);
  }

  /// `/unarchive #<id>` — restore an archived session so it
  /// reappears in the sidebar.
  Future<void> executeUnarchive(List<String> parts, CommandContext ctx) async {
    if (parts.length > 1 && parts[1].isNotEmpty) {
      final idStr = parts[1].replaceFirst('#', '');
      final id = int.tryParse(idStr);
      if (id != null) {
        final session = await ctx.store.getById(id);
        if (session == null) {
          ctx.showToast('Session #$id not found', mode: ToastMode.error);
          return;
        }
        if (session.archivedAt == null) {
          ctx.showToast('Session #$id is not archived');
          return;
        }
        await ctx.store.unarchiveSession(id);
        await ctx.initSessions();
        ctx.showToast('Unarchived "${session.title}"', mode: ToastMode.status);
      } else {
        ctx.showToast('Usage: /unarchive #<id>');
      }
    } else {
      // Show archived sessions when no id is given.
      final archived = await ctx.store.list(
        projectPath: ctx.projectPath,
        includeArchived: true,
        limit: 100,
      );
      final onlyArchived = archived.where((s) => s.archivedAt != null).toList();
      if (onlyArchived.isEmpty) {
        ctx.showToast('No archived sessions');
        return;
      }
      final lines = <String>['Archived sessions:'];
      for (final s in onlyArchived) {
        lines.add('  #${s.id} ${s.title}');
      }
      ctx.showToast(lines.join('\n'));
    }
  }

  /// `/rename <new title>` (alias `/重命名`) — set a new title for the
  /// current session.
  ///
  /// Reuses the same persistence path as the rename overlay in the
  /// session-management panel (`SessionController.renameSession` →
  /// `SessionStore.update(title: …)` plus an in-memory `Session.title`
  /// mirror, then `refresh`): the DB row is updated, the in-memory
  /// `Session` instance is mutated in place so the sidebar picks up
  /// the new title on the next redraw, and `refresh` is called so the
  /// TUI re-renders.
  ///
  /// Titles can contain spaces (the executor joins `parts[1..]` with
  /// spaces, like `/btw`), so e.g. `/rename Ship the parser today`
  /// works verbatim — no quoting needed. An empty or whitespace-only
  /// title is rejected with a usage toast; renaming to the current
  /// title is a no-op with an informational toast so the user sees
  /// that the command was understood but nothing actually changed.
  ///
  /// Safe to invoke during an active response: it touches only the
  /// session row, not the in-flight chat stream.
  Future<void> executeRename(List<String> parts, CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    // Re-join parts[1..] so multi-word titles round-trip verbatim.
    // Re-check the empty case after trimming so a bare `/rename` or
    // a trailing-whitespace-only invocation both surface the usage
    // toast rather than silently writing an empty title.
    final newTitle = parts.skip(1).join(' ').trim();
    if (newTitle.isEmpty) {
      ctx.showToast('Usage: /rename <new title>');
      return;
    }
    if (newTitle == ctx.currentSession.title) {
      ctx.showToast('Title unchanged');
      return;
    }
    final oldTitle = ctx.currentSession.title;
    await ctx.store.update(ctx.currentSessionId!, title: newTitle);
    // `currentSession` is the same object held in `ctx.sessions`
    // (both go through `SessionController.findSession` /
    // `SessionController.currentSession`), so mutating its `title`
    // updates the sidebar entry too — no separate lookup needed.
    ctx.currentSession.title = newTitle;
    ctx.refresh();
    ctx.showToast('Renamed "$oldTitle" → "$newTitle"', mode: ToastMode.status);
  }

  /// `/quit` (alias `/exit`) — cleanly exit Crux and print the
  /// per-run summary to stdout.
  ///
  /// "Cleanly" means: defer the actual `shutdownApp()` call
  /// until the current agent turn (if any) is done streaming,
  /// so the user doesn't lose a half-written response just
  /// because they ran `/quit` a moment too early. Same
  /// affordance as the in-input Ctrl+C×2 guard: when any
  /// session is busy, surface a toast that points the user at
  /// the force-quit path instead of yanking the rug out from
  /// under an in-flight LLM call (in any session — a
  /// background agent running while the user is browsing a
  /// different session still deserves the same protection).
  ///
  /// When nothing is running, the callback fires
  /// synchronously; `shutdownApp()` causes `runApp()` to
  /// return and `bin/crux.dart` then prints the summary to
  /// the now-restored main buffer.
  ///
  /// Note: the previous version scoped this check to
  /// `currentSessionId` + `isResponding`, which let `/quit`
  /// sneak through whenever a non-current session was the
  /// one still working, or while the current session was
  /// between token flushes (tool calls, awaited tool
  /// results, etc.). Mirrors the bug fixed in `chat_input.dart`
  /// for the Ctrl+C handler.
  Future<void> executeQuit(CommandContext ctx) async {
    final anyRunning = ctx.sessions.any(
      (s) => s.status == SessionStatus.running,
    );
    if (anyRunning) {
      ctx.showToast(
        'A session is running — press Ctrl+C×2 to force quit',
        mode: ToastMode.error,
      );
      return;
    }
    if (ctx.quitApp == null) {
      ctx.showToast('Quit unavailable (no TUI bound)', mode: ToastMode.error);
      return;
    }
    ctx.quitApp!();
  }

  // ─────────────────────────────────────────────────────────────────────
  // /debug — toggles registration of debug commands.
  // ─────────────────────────────────────────────────────────────────────

  Future<void> executeDebug(List<String> parts, CommandContext ctx) async {
    // Bare `/debug` — toggles registration of the `/d-*` command set.
    final registry = CommandRegistry.instance;
    final on = registry.toggleDebug();
    if (on) {
      final count = registry.all.where((c) => c.name.startsWith('/d-')).length;
      ctx.showToast(
        'Debug mode ON — $count debug commands registered',
        mode: ToastMode.status,
      );
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
    buf.writeln('  archivedAt:      ${s.archivedAt?.toIso8601String() ?? "—"}');
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
    final session = ctx.currentSessionId == null
        ? null
        : ctx.sessions.firstWhere(
            (s) => s.id == ctx.currentSessionId,
            orElse: () => ctx.currentSession,
          );
    final buf = StringBuffer();
    buf.writeln('Context:');
    buf.writeln('  session.contextTokens:  ${session?.contextTokens ?? 0}');
    buf.writeln('  session.tokensIn:       ${session?.tokensIn ?? 0}');
    buf.writeln('  session.tokensOut:      ${session?.tokensOut ?? 0}');
    buf.writeln('  turnBaseTokens:         ${rt.turnBaseTokens}');
    buf.writeln('  accumulatedToolTokens:  ${rt.accumulatedToolTokens}');
    buf.writeln('  contextTargetTokens:    ${rt.contextTargetTokens}');
    buf.writeln(
      '  contextDisplayTokens:   ${rt.contextDisplayTokens.toStringAsFixed(0)}',
    );
    buf.writeln(
      '  effectiveStreamingMs:   ${rt.effectiveStreamingMs.toStringAsFixed(1)}',
    );
    buf.writeln(
      '  thinkingDurationMs:     ${rt.thinkingDurationMs.toStringAsFixed(1)}',
    );
    // Auto-compaction state. `modelConfig` and `systemPrompt` live
    // on the provider/model config; pull them through the session's
    // composite key so this dump works without a live LLM client.
    final modelKey = session?.model ?? '';
    final modelEntry = modelKey.isEmpty
        ? null
        : ctx.providerService.modelByCompositeKey(modelKey);
    final contextSize = modelEntry?.contextSize;
    final maxTokens = modelEntry?.maxTokens;
    if (contextSize != null) {
      final rt2 = ChatService.computeCompactionReserveAndThreshold(
        contextSize: contextSize,
      );
      buf.writeln('  modelConfig.contextSize: $contextSize');
      buf.writeln('  modelConfig.maxTokens:   ${maxTokens ?? "—"}');
      buf.writeln('  compaction.reserve:      ${rt2.reserve}');
      buf.writeln('  compaction.threshold:    ${rt2.threshold}');
    } else {
      buf.writeln('  modelConfig.contextSize: (model not resolved)');
    }
    buf.writeln('  turnsSinceLastCompact:   ${rt.turnsSinceLastCompact}');
    buf.writeln('  compactFailures:         ${rt.consecutiveCompactionFailures}');
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
    buf.writeln(
      '  tokPerSec:                 ${rt.tokPerSec.toStringAsFixed(2)}',
    );
    buf.writeln(
      '  tokCount:                  ${rt.tokCount.toStringAsFixed(0)}',
    );
    buf.writeln(
      '  streamingDurationMs:       ${rt.streamingDurationMs.toStringAsFixed(1)}',
    );
    buf.writeln(
      '  cumulativeGenMs:           ${rt.cumulativeGenMs.toStringAsFixed(1)}',
    );
    buf.writeln(
      '  cumulativeCompletionTokens: ${rt.cumulativeCompletionTokens}',
    );
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
      '  roundStartTime:            ${rt.roundStartTime?.toIso8601String() ?? "—"}',
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
    buf.writeln(
      'Auxiliary model: ${ctx.providerService.auxiliaryModel ?? "—"}',
    );
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
    final dataDir = resolveUserDataDirectory();
    final buf = StringBuffer();
    buf.writeln('Paths:');
    buf.writeln('  projectPath:    ${ctx.projectPath}');
    buf.writeln('  providersDir:   ${ctx.providerService.providersDir}');
    buf.writeln(
      '  builtInProvDir: ${ctx.providerService.builtInProvidersDir ?? "—"}',
    );
    buf.writeln('  authTomlPath:   ${ctx.providerService.authTomlPath}');
    buf.writeln('  authJsonPath:   ${ctx.providerService.authJsonPath}');
    buf.writeln('  dataDir:        $dataDir');
    buf.writeln('  databaseFile:   ${p.join(dataDir, "crux.db")}');
    buf.writeln('  recentProjects: ${p.join(dataDir, "recent_projects.toml")}');
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

  /// `/d-fullpane` — open the fullpane (near-full-screen modal) overlay.
  Future<void> executeDebugFullpane(CommandContext ctx) async {
    if (ctx.showFullpane != null) {
      ctx.showFullpane!();
    } else {
      ctx.showToast('Fullpane not available', mode: ToastMode.error);
    }
  }

  /// `/d-profiler [<secs> [<path>]]` — record per-frame
  /// scheduler timings and dump a TOML report.
  ///
  /// Forms:
  /// - `/d-profiler` (no args)           → show status
  ///   (recording? frames captured so far? requested duration?)
  /// - `/d-profiler <secs>`              → start a recording
  ///   that runs for `<secs>` seconds, then auto-dumps the
  ///   report under the user data dir. `<secs>` accepts
  ///   integers or floats (e.g. `0.5` is fine for a quick
  ///   smoke test).
  /// - `/d-profiler <secs> <path>`       → same, but write
  ///   the report to `<path>` instead of the default
  ///   `profile-<iso>.toml` location.
  /// - `/d-profiler stop`                → stop the active
  ///   recording immediately and dump the report.
  ///
  /// The recording is hooked into the chat panel via a
  /// snapshot provider registered in [ChatPanel.initState]
  /// (see [FrameProfiler.registerSnapshotProvider]); if the
  /// snapshot provider isn't there (e.g. because the chat
  /// panel hasn't been mounted yet), the report still
  /// captures frame timings but the per-frame `features`
  /// field will be empty.
  Future<void> executeDebugProfiler(
    List<String> parts,
    CommandContext ctx,
  ) async {
    final profiler = FrameProfiler.instance;
    final first = parts.length > 1 ? parts[1].trim() : '';
    final second = parts.length > 2 ? parts[2].trim() : '';

    // No args → status.
    if (first.isEmpty) {
      if (!profiler.isRecording) {
        ctx.showToast(
          'Profiler idle. Usage: /d-profiler <secs> [path], '
          '/d-profiler stop',
        );
        return;
      }
      final elapsed = profiler.startedAt == null
          ? 0
          : DateTime.now().difference(profiler.startedAt!).inSeconds;
      final requested = profiler.requestedDuration.inSeconds;
      ctx.showToast(
        'Profiler recording: ${elapsed}s / ${requested}s, '
        '${profiler.capturedFrameCount} frames so far',
      );
      return;
    }

    // `/d-profiler stop` → stop now and dump.
    if (first == 'stop' || first == '--stop') {
      if (!profiler.isRecording) {
        ctx.showToast('Profiler is not recording');
        return;
      }
      final report = profiler.stop();
      final path = second.isEmpty ? _profilerDefaultPath() : second;
      await FrameProfiler.writeReport(path, report);
      _showProfilerSummary(ctx, report, path);
      return;
    }

    // `/d-profiler <secs> [path]` → start a recording.
    final secs = double.tryParse(first);
    if (secs == null || secs <= 0) {
      ctx.showToast(
        'Invalid duration: "$first". Usage: /d-profiler <secs> [path]',
        mode: ToastMode.error,
      );
      return;
    }
    if (profiler.isRecording) {
      ctx.showToast('Profiler is already recording');
      return;
    }

    final path = second.isEmpty ? _profilerDefaultPath() : second;
    final duration = Duration(
      microseconds: (secs * Duration.microsecondsPerSecond).round(),
    );
    ctx.showToast(
      '${terminalSymbol('●', '*')} Profiler recording for '
      '${secs}s → $path',
      mode: ToastMode.status,
    );
    // Fire-and-forget the timed recording. The future is
    // intentionally not awaited so the command can return
    // immediately and the user can interact with the UI
    // while the recording runs.
    unawaited(
      profiler
          .recordFor(duration, outputPath: path)
          .then((result) {
            // Show a toast with the summary once the recording
            // completes. The toast will be no-op if the chat
            // panel has been disposed by then, which is fine.
            _showProfilerSummary(ctx, result.report, result.path);
          })
          .catchError((Object e, StackTrace st) {
            ctx.showToast('Profiler failed: $e', mode: ToastMode.error);
          }),
    );
  }

  static String _profilerDefaultPath() {
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    return p.join(resolveUserDataDirectory(), 'profile-$ts.toml');
  }

  /// Compact one-screen summary of a profiler report, rendered
  /// as a toast. The full report is on disk — this is just
  /// enough to tell whether a recording was worth keeping.
  static void _showProfilerSummary(
    CommandContext ctx,
    Map<String, dynamic> report,
    String path,
  ) {
    if (report.containsKey('error')) {
      ctx.showToast('Profiler: ${report['error']}', mode: ToastMode.error);
      return;
    }
    final frames = report['frameCount'] ?? 0;
    final fps = report['observedFps'] ?? '0.00';
    final totals = report['percentilesUs']?['total'] as Map?;
    final p99 = totals?['p99'] ?? 0;
    final maxUs = totals?['max'] ?? 0;
    final byReason = (report['byReason'] as Map?)?.length ?? 0;

    // Surface the top layout hotspot (the render object type
    // that consumed the most layout time during the recording)
    // right in the toast. The full per-type breakdown is on
    // disk in the report; this gives a one-liner that points
    // straight at the suspect when the user comes back from
    // an "FPS dropped to 2" report.
    final byLayout = report['byLayout'] as Map?;
    final byType = byLayout?['byType'] as Map?;
    String layoutHotspot = '';
    if (byType != null && byType.isNotEmpty) {
      final first = byType.entries.first;
      final name = first.key;
      // Strip the "Render" prefix for readability.
      final short = name.startsWith('Render') ? name.substring(6) : name;
      final totalUs = (first.value as Map)['totalUs'] ?? 0;
      layoutHotspot = ' layoutHot=$short(${totalUs ~/ 1000}ms)';
    }

    ctx.showToast(
      'Profiler: $frames frames, ${fps}fps, '
      'p99=${p99}us max=${maxUs}us, '
      '$byReason reason(s)$layoutHotspot. Report: $path',
    );
  }

  String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}
