import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/auxiliary_prompts.dart';
import '../services/plan_mode_controller.dart';
import '../services/provider_service.dart';
import '../services/recent_projects_store.dart';
import '../services/web_provider_registry.dart';
import '../storage/session_store.dart';
import '../storage/shell_monitor_log_store.dart';
import '../commands/registry.dart';
import '../components/ui/toast.dart';
import '../theme/theme_controller.dart';
import '../i18n/app_locale.dart';
import '../i18n/locale_controller.dart';
import '../i18n/strings.dart';
import 'command_debug.dart';
import 'cmd_model.dart';
import 'cmd_auxiliary.dart';
import 'cmd_session.dart';
import 'cmd_new.dart';
import 'cmd_chat.dart';
import 'cmd_plan.dart';
import 'cmd_provider.dart';
import 'cmd_web_provider.dart';
import 'cmd_theme.dart';
import 'cmd_language.dart';
import 'cmd_reply_language.dart';
import 'cmd_think.dart';
import 'cmd_view.dart';
import 'cmd_temperature.dart';
import 'cmd_project.dart';
import 'cmd_tldr.dart';
import 'cmd_compact.dart';
import 'cmd_help.dart';
import 'cmd_continue.dart';
import 'cmd_retry.dart';
import 'cmd_undo.dart';
import 'cmd_btw.dart';
import 'cmd_archive.dart';
import 'cmd_unarchive.dart';
import 'cmd_rename.dart';
import 'cmd_quit.dart';
import 'cmd_home.dart';
import 'cmd_setup.dart';

typedef ShowToastCallback = void Function(String message, {ToastMode mode});

/// Opens the ChatGPT Codex device-login pane and returns a callback that
/// dismisses this specific instance. Keeping the dismiss callback scoped to
/// the instance prevents a completed login from closing a different pane the
/// user opened while the OAuth request was in flight.
typedef ShowCodexLoginPaneCallback = VoidCallback Function(
  String userCode,
  String verificationUrl,
);

class CommandContext {
  final SessionStore store;
  final ProviderService providerService;
  final bool providerServiceReady;
  final WebProviderRegistry webProviderRegistry;
  final Session currentSession;
  final int? currentSessionId;
  final List<Session> sessions;
  final List<Message> currentMessages;
  final String projectPath;
  final void Function() refresh;
  final ShowToastCallback showToast;
  final ShowCodexLoginPaneCallback? showCodexLoginPane;
  final Future<void> Function(int) switchSession;
  final Future<void> Function() initSessions;
  final Future<void> Function() createNewSession;

  /// Creates a Chat-mode session and switches to it. Wired by the
  /// chat panel to [SessionController.createChatSession]; null in
  /// tests/legacy harnesses, in which case `/chat` reports
  /// "not available".
  final Future<void> Function()? createChatSession;
  final SessionRuntimeState Function(int) runtime;
  final void Function(SessionRuntimeState) persistThinkingLevel;
  final void Function(SessionRuntimeState) persistChatDisplayMode;
  final Future<void> Function(SessionRuntimeState) persistTemperature;
  final void Function() resolveAuxiliaryModel;
  final void Function(int, Message, TldrDetail, String?)? triggerTldr;
  final ThemeController? themeController;

  /// The UI-language controller. Null in tests and legacy harnesses, in
  /// which case `/language` reports "unavailable" instead of failing.
  final LocaleController? localeController;

  /// Rebuild the system prompt for a session. Used by `/reply-language` to
  /// apply the reply-language change immediately (the prompt's language
  /// section is cached on the session row). Null in tests / legacy
  /// harnesses, in which case the change still applies to new sessions.
  final Future<void> Function(int sessionId)? rebuildSystemPrompt;

  /// A string lookup bound to the active UI language, for localizing
  /// command feedback (toasts) and descriptions. Falls back to English
  /// when no [localeController] is wired.
  Strings get strings =>
      Strings(AppLocale.fromCode(localeController?.activeCode));
  final Future<void> Function({String? text}) sendTurn;
  final Future<void> Function()? compactSession;
  final Future<Message?> Function() findLastUserMessage;
  final Future<void> Function(int fromId) deleteMessagesFrom;
  final Future<void> Function(String prompt) sendBtwTurn;
  final void Function(int sessionId) clearBtwTurns;
  final void Function(String text)? setInputText;
  final VoidCallback? quitApp;
  final VoidCallback? showFullpane;
  final VoidCallback? showHome;
  final VoidCallback? showSetup;
  final RecentProjectsStore? recentProjectsStore;

  /// Store for `shell_monitor_logs` (one row per aux-monitor event).
  /// Null in tests and legacy harnesses; `/d-monitor` reports
  /// "unavailable" when null instead of failing.
  final ShellMonitorLogStore? shellMonitorLogStore;

  /// Appends a local, UI-only info message to the *visible* chat
  /// history. The wired implementation persists the sheet under the
  /// `info` role (never sent to the LLM — see cmd_help.dart) and
  /// refreshes the on-screen history in one step. `null` in tests
  /// and legacy harnesses, in which case `/help` falls back to
  /// persisting through [SessionStore.messageStore] directly.
  final Future<void> Function(String markdown)? appendLocalMessage;

  /// The per-session plan-mode controller, so `/plan` can enter/exit
  /// plan mode. Null in tests and legacy harnesses (the command then
  /// reports unavailable).
  final PlanModeController? planModeController;

  CommandContext({
    required this.store,
    required this.providerService,
    required this.providerServiceReady,
    required this.webProviderRegistry,
    required this.currentSession,
    required this.currentSessionId,
    required this.sessions,
    required this.currentMessages,
    required this.projectPath,
    required this.refresh,
    required this.showToast,
    this.showCodexLoginPane,
    required this.switchSession,
    required this.initSessions,
    required this.createNewSession,
    this.createChatSession,
    required this.runtime,
    required this.persistThinkingLevel,
    required this.persistChatDisplayMode,
    required this.persistTemperature,
    required this.resolveAuxiliaryModel,
    this.triggerTldr,
    this.themeController,
    this.localeController,
    this.rebuildSystemPrompt,
    required this.sendTurn,
    this.compactSession,
    required this.findLastUserMessage,
    required this.deleteMessagesFrom,
    required this.sendBtwTurn,
    required this.clearBtwTurns,
    this.setInputText,
    this.quitApp,
    this.showFullpane,
    this.showHome,
    this.showSetup,
    this.recentProjectsStore,
    this.appendLocalMessage,
    this.shellMonitorLogStore,
    this.planModeController,
  });
}

class CommandExecutor {
  final CommandDebug _debug = CommandDebug();

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
      case '/chat':
        await executeChat(ctx);
      case '/provider':
        await executeProvider(parts, ctx);
      case '/web-provider':
        await executeWebProvider(parts, ctx);
      case '/theme':
        await executeTheme(parts, ctx);
      case '/language':
        await executeLanguage(parts, ctx);
      case '/reply-language':
        await executeReplyLanguage(parts, ctx);
      case '/think':
        await executeThink(parts, ctx);
      case '/view':
        await executeView(parts, ctx);
      case '/plan':
        await executePlan(parts, ctx);
      case '/temperature':
        await executeTemperature(parts, ctx);
      case '/tldr':
        await executeTldr(parts, ctx);
      case '/compact':
        await executeCompact(ctx);
      case '/help':
        await executeHelp(ctx);
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
      case '/home':
        await executeHome(ctx);
      case '/setup':
        await executeSetup(ctx);
      case '/project':
        await executeProject(parts, ctx);
      case '/debug':
        await _debug.executeDebug(parts, ctx);
      case '/d-state':
        await _debug.executeDebugState(ctx);
      case '/d-messages':
        await _debug.executeDebugMessages(ctx);
      case '/d-context':
        await _debug.executeDebugContext(ctx);
      case '/d-runtime':
        await _debug.executeDebugRuntime(ctx);
      case '/d-monitor':
        await _debug.executeDebugMonitor(parts, ctx);
      case '/d-providers':
        await _debug.executeDebugProviders(ctx);
      case '/d-tools':
        await _debug.executeDebugTools(ctx);
      case '/d-paths':
        await _debug.executeDebugPaths(ctx);
      case '/d-env':
        await _debug.executeDebugEnv(ctx);
      case '/d-toast':
        await _debug.executeDebugToast(parts, ctx);
      case '/d-fullpane':
        await _debug.executeDebugFullpane(ctx);
      case '/d-profiler':
        await _debug.executeDebugProfiler(parts, ctx);
      default:
        if (command != null) {
          ctx.showToast(
            ctx.strings.t('toast.notImplemented', {'cmd': commandName}),
            mode: ToastMode.error,
          );
        } else {
          ctx.showToast(
            ctx.strings.t('toast.unknownCommand', {'cmd': commandName}),
            mode: ToastMode.error,
          );
        }
    }
  }
}
