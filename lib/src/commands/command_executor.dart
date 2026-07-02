import 'dart:async';
import 'package:nocterm/nocterm.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/auxiliary_prompts.dart';
import '../services/provider_service.dart';
import '../services/recent_projects_store.dart';
import '../services/web_provider_registry.dart';
import '../storage/session_store.dart';
import '../commands/registry.dart';
import '../components/ui/toast.dart';
import '../theme/theme_controller.dart';
import 'command_debug.dart';
import 'cmd_model.dart';
import 'cmd_auxiliary.dart';
import 'cmd_session.dart';
import 'cmd_new.dart';
import 'cmd_provider.dart';
import 'cmd_web_provider.dart';
import 'cmd_theme.dart';
import 'cmd_think.dart';
import 'cmd_project.dart';
import 'cmd_tldr.dart';
import 'cmd_compact.dart';
import 'cmd_continue.dart';
import 'cmd_retry.dart';
import 'cmd_undo.dart';
import 'cmd_btw.dart';
import 'cmd_archive.dart';
import 'cmd_unarchive.dart';
import 'cmd_rename.dart';
import 'cmd_quit.dart';

typedef ShowToastCallback = void Function(String message, {ToastMode mode});

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
  final Future<void> Function(int) switchSession;
  final Future<void> Function() initSessions;
  final Future<void> Function() createNewSession;
  final SessionRuntimeState Function(int) runtime;
  final void Function(SessionRuntimeState) persistThinkingLevel;
  final void Function() resolveAuxiliaryModel;
  final void Function(int, Message, TldrDetail, String?)? triggerTldr;
  final ThemeController? themeController;
  final Future<void> Function({String? text}) sendTurn;
  final Future<void> Function()? compactSession;
  final Future<Message?> Function() findLastUserMessage;
  final Future<void> Function(int fromId) deleteMessagesFrom;
  final Future<void> Function(String prompt) sendBtwTurn;
  final void Function(int sessionId) clearBtwTurns;
  final void Function(String text)? setInputText;
  final VoidCallback? quitApp;
  final VoidCallback? showFullpane;
  final RecentProjectsStore? recentProjectsStore;

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
      case '/provider':
        await executeProvider(parts, ctx);
      case '/web-provider':
        await executeWebProvider(parts, ctx);
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
        await _debug.executeDebug(parts, ctx);
      case '/d-state':
        await _debug.executeDebugState(ctx);
      case '/d-messages':
        await _debug.executeDebugMessages(ctx);
      case '/d-context':
        await _debug.executeDebugContext(ctx);
      case '/d-runtime':
        await _debug.executeDebugRuntime(ctx);
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
            '$commandName — not yet implemented',
            mode: ToastMode.error,
          );
        } else {
          ctx.showToast('Unknown command: $commandName', mode: ToastMode.error);
        }
    }
  }
}
