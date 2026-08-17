import 'command_executor.dart';

Future<void> executeNew(CommandContext ctx) async {
  // An empty title IS the "brand new session" state — never
  // compare against a placeholder literal (locale-fragile, and a
  // user rename to that literal would false-positive).
  final isCurrentEmpty =
      ctx.currentMessages.isEmpty && ctx.currentSession.isUntitled;
  if (isCurrentEmpty) {
    ctx.showToast(ctx.strings.t('toast.alreadyNewSession'));
  } else {
    await ctx.createNewSession();
  }
}
