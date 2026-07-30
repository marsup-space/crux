import 'command_executor.dart';

Future<void> executeNew(CommandContext ctx) async {
  final isCurrentEmpty =
      ctx.currentMessages.isEmpty && ctx.currentSession.title == 'New Session';
  if (isCurrentEmpty) {
    ctx.showToast('Already on a new session');
  } else {
    await ctx.createNewSession();
  }
}
