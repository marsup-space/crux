import '../components/ui/toast.dart';
import '../models/message.dart';
import '../services/auxiliary_prompts.dart';
import 'command_executor.dart';

Future<void> executeTldr(List<String> parts, CommandContext ctx) async {
  if (ctx.currentSessionId == null) {
    ctx.showToast(ctx.strings.t('toast.noSession'), mode: ToastMode.error);
    return;
  }
  final lastAi = ctx.currentMessages.lastWhere(
    (m) => m.role == 'ai',
    orElse: () => Message(id: -1, sessionId: 0, role: 'ai', content: ''),
  );
  if (lastAi.id <= 0 || lastAi.content.isEmpty) {
    ctx.showToast(ctx.strings.t('toast.tldrNoResponse'));
    return;
  }
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
        ctx.strings.t('toast.tldrUnknownLevel', {'level': rawLevel}),
      );
      return;
  }
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
