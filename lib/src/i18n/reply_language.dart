import 'app_locale.dart';

/// How Crux decides which language the agent replies in.
///
/// [code] is what's persisted to `config.toml` under `ui.reply_language`
/// and what `/reply-language <code>` accepts (`follow` / `auto`).
enum ReplyLanguageMode {
  /// Reply in the configured UI language (`ui.language`), regardless of
  /// what language the user writes in. The default.
  follow('follow'),

  /// Match the user's input language turn by turn (the historical
  /// behaviour: reply in whatever language the user writes in).
  auto('auto');

  final String code;

  const ReplyLanguageMode(this.code);

  /// The mode whose [code] matches exactly, or null for any unknown /
  /// null code. Case-sensitive on purpose — mirrors [AppLocale.tryFromCode].
  static ReplyLanguageMode? tryFromCode(String? code) {
    for (final mode in ReplyLanguageMode.values) {
      if (mode.code == code) return mode;
    }
    return null;
  }

  /// Resolves a persisted/typed code to a mode, falling back to
  /// [ReplyLanguageMode.follow] for anything unknown (including null).
  static ReplyLanguageMode fromCode(String? code) =>
      tryFromCode(code) ?? fallback;

  /// The default applied when the user has not configured one.
  static const ReplyLanguageMode fallback = ReplyLanguageMode.follow;
}

/// The resolved reply-language policy passed into the system-prompt
/// builder: a [mode] plus the UI [locale] to follow in `follow` mode.
///
/// Kept as a plain value object so the prompt builder (service layer)
/// doesn't depend on the live [LocaleController] — callers resolve the
/// current policy at build time and hand it in.
class ReplyLanguageSettings {
  final ReplyLanguageMode mode;
  final AppLocale locale;

  const ReplyLanguageSettings({required this.mode, required this.locale});

  /// The policy used when no controller is wired (tests / legacy
  /// harnesses): follow the fallback locale (`en`).
  static const ReplyLanguageSettings fallback = ReplyLanguageSettings(
    mode: ReplyLanguageMode.follow,
    locale: AppLocale.fallback,
  );
}

/// A live read of the current reply-language policy. A function rather
/// than a snapshot so prompt builders pick up `/reply-language` and
/// `/language` changes made after the owning service was constructed.
typedef ReplyLanguageProvider = ReplyLanguageSettings Function();
