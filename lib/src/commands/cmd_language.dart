import '../components/ui/toast.dart';
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
}
