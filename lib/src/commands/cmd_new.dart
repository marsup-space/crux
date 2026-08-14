import 'command_executor.dart';

Future<void> executeNew(CommandContext ctx) async {
  final isCurrentEmpty =
      ctx.currentMessages.isEmpty && ctx.currentSession.title == 'New Session';
  if (isCurrentEmpty) {
    ctx.showToast(ctx.strings.t('toast.alreadyNewSession'));
  } else {
    await ctx.createNewSession();
  }
}
