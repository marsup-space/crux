import '../components/ui/toast.dart';
import '../i18n/strings.dart';
import 'command_executor.dart';

/// The `/reply-language` command — switch the agent's reply-language
/// policy (`follow` / `auto`).
///
/// Mirrors `cmd_language.dart`: the success toasts are looked up *after*
/// the switch so they render in the active UI language. Also rebuilds the
/// current session's system prompt (the prompt caches its language section)
/// so the change takes effect on the very next turn.
Future<void> executeReplyLanguage(List<String> parts, CommandContext ctx) async {
  final controller = ctx.localeController;
  if (controller == null) {
    ctx.showToast(
      kEnglishStrings.t('replylang.unavailable'),
      mode: ToastMode.error,
    );
    return;
  }

  final code = parts.length > 1 ? parts[1].trim() : '';
  if (code.isEmpty) {
    final label =
        controller.strings.t('replylang.${controller.replyLanguageCode}');
    ctx.showToast(
      controller.strings.t('replylang.current', {'mode': label}),
    );
    return;
  }

  final result = await controller.switchReplyLanguage(code);
  if (!result.found) {
    final list =
        controller.availableReplyLanguageModes.map((m) => m.code).join(', ');
    ctx.showToast(
      controller.strings.t('replylang.unknown', {'mode': code, 'list': list}),
      mode: ToastMode.error,
    );
    return;
  }

  // Re-read strings after the switch (the active mode changed), and resolve
  // the new mode's own localized label for the feedback.
  final strings = controller.strings;
  final label = strings.t('replylang.${result.mode!.code}');
  if (!result.persisted) {
    ctx.showToast(
      strings.t('replylang.persistFailed', {'mode': label}),
      mode: ToastMode.error,
    );
    return;
  }
  ctx.showToast(
    strings.t('replylang.switched', {'mode': label}),
    mode: ToastMode.status,
  );

  // The system prompt's language section is cached on the session row, so
  // rebuild it now to pick up the new policy on the next turn.
  //
  // Only rebuild when the session has no cached prompt yet (i.e. it's a
  // brand-new session that hasn't sent its first message). Rebuilding an
  // existing session's prompt would silently overwrite the env block's
  // model info with the *current* model — even if the session was created
  // with a different model and the user never switched.
  final sid = ctx.currentSessionId;
  if (sid != null) {
    final session = await ctx.store.getById(sid);
    if (session?.systemPrompt == null) {
      await ctx.rebuildSystemPrompt?.call(sid);
    }
  }
}
