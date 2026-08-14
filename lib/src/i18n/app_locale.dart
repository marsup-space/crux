/// A supported UI language.
///
/// [code] is what's persisted to `config.toml` under `ui.language` and
/// what `/language <code>` accepts (`en` / `zh`). [label] is the
/// human-readable name shown when listing available locales (used in the
/// `/language` toasts so switching to Chinese reports it in Chinese).
enum AppLocale {
  en('en', 'English'),
  zh('zh', '中文');

  final String code;
  final String label;

  const AppLocale(this.code, this.label);

  /// The locale whose [code] matches exactly, or null for any unknown /
  /// null code. Case-sensitive on purpose — `en` and `EN` are different.
  static AppLocale? tryFromCode(String? code) {
    for (final locale in AppLocale.values) {
      if (locale.code == code) return locale;
    }
    return null;
  }

  /// Resolves a persisted/typed code to a locale, falling back to
  /// [AppLocale.en] for anything unknown (including null).
  static AppLocale fromCode(String? code) => tryFromCode(code) ?? AppLocale.en;

  /// The default applied when the user has not configured one.
  static const AppLocale fallback = AppLocale.en;
}
