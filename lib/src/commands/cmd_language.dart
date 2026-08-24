import '../components/ui/toast.dart';
import '../i18n/reply_language.dart';
import 'command_executor.dart';

/// The `/language` command — switch the UI language (`en` / `zh`).
///
/// Mirrors `cmd_theme.dart`. The success/partial-failure toasts are looked
/// up *after* the switch so they render in the language the user just
/// selected (switch to Chinese → the confirmation is in Chinese).
Future<void> executeLanguage(List<String> parts, CommandContext ctx) async {
  final controller = ctx.localeController;
  if (controller == null) {
    ctx.showToast('Language service is unavailable', mode: ToastMode.error);
    return;
  }

  final code = parts.length > 1 ? parts[1].trim() : '';
  if (code.isEmpty) {
    ctx.showToast(
      controller.strings.t('lang.current', {'lang': controller.activeLocale.label}),
    );
    return;
  }

  final result = await controller.switchLocale(code);
  if (!result.found) {
    final list = controller.availableLocales.map((l) => l.code).join(', ');
    ctx.showToast(
      controller.strings.t('lang.unknown', {'lang': code, 'list': list}),
      mode: ToastMode.error,
    );
    return;
  }

  // The switch succeeded (the active locale changed), so re-read strings
  // for the feedback — otherwise the confirmation would be in the *old*
  // language. The label is the new locale's own name ("中文" / "English").
  final strings = controller.strings;
  final label = result.locale!.label;
  if (!result.persisted) {
    ctx.showToast(
      strings.t('lang.persistFailed', {'lang': label}),
      mode: ToastMode.error,
    );
    return;
  }
  ctx.showToast(
    strings.t('lang.switched', {'lang': label}),
    mode: ToastMode.status,
  );

  // When the agent replies in the UI language (`follow` mode), the cached
  // system prompt's language section still names the *old* locale — rebuild
  // it so the switch takes effect on the next turn.
  //
  // Only rebuild when the session has no cached prompt yet (i.e. it's a
  // brand-new session that hasn't sent its first message). Rebuilding an
  // existing session's prompt would silently overwrite the env block's
  // model info with the *current* model — even if the session was created
  // with a different model and the user never switched.
  if (controller.replyLanguageMode == ReplyLanguageMode.follow) {
    final sid = ctx.currentSessionId;
    if (sid != null) {
      final session = await ctx.store.getById(sid);
      if (session?.systemPrompt == null) {
        await ctx.rebuildSystemPrompt?.call(sid);
      }
    }
  }
}
