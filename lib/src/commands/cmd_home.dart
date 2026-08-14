import '../components/ui/toast.dart';
import 'command_executor.dart';

/// `/home` — open (or re-open) the home screen overlay.
///
/// Wired through [CommandContext.showHome], which the chat panel
/// binds to a callback that flips `OverlayController.showHome`.
/// `availableDuringResponse: true` in the registry because opening
/// the dashboard never touches the in-flight stream — the chat body
/// keeps rendering underneath the pane.
Future<void> executeHome(CommandContext ctx) async {
  if (ctx.showHome == null) {
    ctx.showToast(ctx.strings.t('toast.homeUnavailable'), mode: ToastMode.error);
    return;
  }
  ctx.showHome!();
}
