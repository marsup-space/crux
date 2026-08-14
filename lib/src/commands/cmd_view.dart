import '../components/ui/toast.dart';
import '../models/session_runtime_state.dart';
import 'command_executor.dart';

/// `/view` — switch or report the chat log display mode.
///
///   `/view`          → toast current mode
///   `/view verbose`  → switch to verbose (per-call detail, the default)
///   `/view vibe`     → switch to vibe (aggregated metadata boxes)
///
/// `availableDuringResponse: true` because flipping modes is a viewer
/// operation; it never touches an in-flight stream.
Future<void> executeView(List<String> parts, CommandContext ctx) async {
  if (ctx.currentSessionId == null) return;
  final rt = ctx.runtime(ctx.currentSessionId!);

  // `/view` with no argument — report the current mode.
  if (parts.length <= 1 || parts[1].isEmpty) {
    final current = rt.chatDisplayMode == ChatDisplayMode.vibe
        ? 'vibe'
        : 'verbose';
    ctx.showToast(ctx.strings.t('toast.displayMode', {'mode': current}), mode: ToastMode.info);
    return;
  }

  final mode = parts[1].toLowerCase();
  switch (mode) {
    case 'verbose':
      rt.chatDisplayMode = ChatDisplayMode.verbose;
      ctx.persistChatDisplayMode(rt);
      ctx.refresh();
      ctx.showToast(ctx.strings.t('toast.displayMode', {'mode': 'verbose'}), mode: ToastMode.status);
    case 'vibe':
      rt.chatDisplayMode = ChatDisplayMode.vibe;
      ctx.persistChatDisplayMode(rt);
      ctx.refresh();
      ctx.showToast(ctx.strings.t('toast.displayMode', {'mode': 'vibe'}), mode: ToastMode.status);
    default:
      ctx.showToast(
        ctx.strings.t('toast.viewUnknown', {'mode': mode}),
        mode: ToastMode.error,
      );
  }
}
