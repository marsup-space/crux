import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../services/provider_service.dart';
import '../storage/session_store.dart';
import '../commands/registry.dart';

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
  final void Function(String) showToast;
  final Future<void> Function(int) switchSession;
  final Future<void> Function() initSessions;
  final Future<void> Function() createNewSession;
  final SessionRuntimeState Function(int) runtime;
  final void Function(SessionRuntimeState) persistThinkingLevel;
  final void Function() resolveAuxiliaryModel;
  final void Function(String) enterBuiltinWizard;
  final void Function() enterCustomWizard;

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
    required this.enterCustomWizard,
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
      case '/project':
        await executeProject(parts, ctx);
      default:
        if (command != null) {
          ctx.showToast('$commandName — not yet implemented');
        } else {
          ctx.showToast('Unknown command: $commandName');
        }
    }
  }

  Future<void> executeModel(List<String> parts, CommandContext ctx) async {
    if (parts.length > 1 && parts[1].isNotEmpty) {
      final modelKey = parts[1];
      if (ctx.providerServiceReady &&
          ctx.providerService.modelByCompositeKey(modelKey) == null) {
        ctx.showToast('Unknown model: $modelKey');
      } else {
        if (ctx.currentSessionId != null) {
          await ctx.store.update(ctx.currentSessionId!, model: modelKey);
          ctx.currentSession.model = modelKey;
        }
        ctx.showToast('Model switched to $modelKey');
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
        ctx.showToast('Auxiliary model disabled');
      } else if (ctx.providerServiceReady &&
          ctx.providerService.modelByCompositeKey(modelKey) == null) {
        ctx.showToast('Unknown model: $modelKey');
      } else {
        await ctx.providerService.setAuxiliaryModel(modelKey);
        ctx.resolveAuxiliaryModel();
        ctx.showToast('Auxiliary model set to $modelKey');
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
    const builtInProviders = {'deepseek', 'infinigence', 'volcengine'};

    if (builtInProviders.contains(subcommand)) {
      ctx.providerService.initialize().then((_) {
        final provider = ctx.providerService.providerByName(subcommand);
        if (provider == null) {
          ctx.showToast('Provider "$subcommand" not found in config');
          return;
        }
        ctx.enterBuiltinWizard(subcommand);
      });
    } else if (subcommand == 'custom') {
      ctx.providerService.initialize().then((_) {
        ctx.enterCustomWizard();
      });
    } else {
      ctx.showToast(
        'Usage: /provider <deepseek|infinigence|volcengine|custom>',
      );
    }
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
        ctx.showToast('Thinking mode: off');
      case 'normal':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'normal';
        ctx.persistThinkingLevel(rt);
        ctx.showToast('Thinking mode: normal');
      case 'high':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'high';
        ctx.persistThinkingLevel(rt);
        ctx.showToast('Thinking mode: high');
      case 'max':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'max';
        ctx.persistThinkingLevel(rt);
        ctx.showToast('Thinking mode: max');
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
        ctx.showToast('Directory not found: $target');
      } else {
        Directory.current = dir;
        await ctx.initSessions();
        ctx.showToast('Switched to $target');
      }
    } else {
      ctx.showToast('Usage: /project <path> (current: ${ctx.projectPath})');
    }
  }
}
