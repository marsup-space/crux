import 'command_executor.dart';

/// `/chat` — create a Chat-mode session and switch to it.
///
/// Chat mode is a workspace-free conversation: the session row gets
/// `kind='chat'` and `projectPath=''`, the system prompt is the
/// minimal [kChatSystemPrompt] (no project notes, no skills), and it
/// appears in the global "Chats" sidebar section of every Crux
/// instance rather than the project "Sessions" list.
Future<void> executeChat(CommandContext ctx) async {
  final createChat = ctx.createChatSession;
  if (createChat == null) {
    ctx.showToast(ctx.strings.t('toast.chatUnavailable'));
    return;
  }
  // If the current session is already a brand-new, untouched chat,
  // don't stack another one — mirror /new's "Already on a new
  // session" guard so repeated /chat taps don't spam empty chats.
  final isCurrentEmptyChat =
      ctx.currentSession.isChat &&
      ctx.currentMessages.isEmpty &&
      ctx.currentSession.title == 'New Chat';
  if (isCurrentEmptyChat) {
    ctx.showToast(ctx.strings.t('toast.alreadyNewChat'));
    return;
  }
  await createChat();
}
