import 'package:nocterm/nocterm.dart';

import 'app_locale.dart';
import 'locale_config_store.dart';
import 'reply_language.dart';
import 'strings.dart';

/// The outcome of a [LocaleController.switchLocale] call.
class LocaleSwitchResult {
  final AppLocale? locale;
  final Object? persistenceError;

  const LocaleSwitchResult({this.locale, this.persistenceError});

  /// Whether [locale] is a known locale (an unknown code yields a result
  /// with a null locale and no error).
  bool get found => locale != null;

  /// Whether the switch was also persisted (no `config.toml` write error).
  bool get persisted => found && persistenceError == null;
}

/// The outcome of a [LocaleController.switchReplyLanguage] call.
class ReplyLanguageSwitchResult {
  final ReplyLanguageMode? mode;
  final Object? persistenceError;

  const ReplyLanguageSwitchResult({this.mode, this.persistenceError});

  /// Whether [mode] is a known reply-language mode (an unknown code yields
  /// a result with a null mode and no error).
  bool get found => mode != null;

  /// Whether the switch was also persisted (no `config.toml` write error).
  bool get persisted => found && persistenceError == null;
}

/// The live UI-language + reply-language settings.
///
/// Mirrors `ThemeController`: holds the active [AppLocale] and
/// [ReplyLanguageMode], persists both via [LocaleConfigStore] to
/// `config.toml`, and notifies listeners on switch so any already-mounted
/// UI that reads either re-renders.
class LocaleController extends ChangeNotifier {
  final LocaleConfigStore configStore;
  final String? startupWarning;

  AppLocale _activeLocale;
  ReplyLanguageMode _replyLanguageMode;

  LocaleController._({
    required this.configStore,
    required this._activeLocale,
    required this._replyLanguageMode,
    this.startupWarning,
  });

  static Future<LocaleController> create({
    required LocaleConfigStore configStore,
    AppLocale defaultLocale = AppLocale.fallback,
    ReplyLanguageMode defaultReplyLanguage = ReplyLanguageMode.fallback,
  }) async {
    String? configured;
    String? warning;
    try {
      configured = await configStore.readLocale();
    } catch (error) {
      configured = null;
      warning = 'Could not read language configuration: $error';
    }

    String? configuredReply;
    try {
      configuredReply = await configStore.readReplyLanguage();
    } catch (_) {
      configuredReply = null;
      // An unreadable reply-language key falls back to the default without
      // clobbering an existing language warning.
    }

    // Null → the runtime default (currently always `en`). Unknown code →
    // fall back to English with a warning (mirrors an unknown theme id).
    final AppLocale active;
    if (configured == null) {
      active = defaultLocale;
    } else if (AppLocale.tryFromCode(configured) == null) {
      warning =
          'Configured language "$configured" is unavailable; using English';
      active = AppLocale.en;
    } else {
      active = AppLocale.tryFromCode(configured)!;
    }

    final replyMode =
        ReplyLanguageMode.tryFromCode(configuredReply) ?? defaultReplyLanguage;

    return LocaleController._(
      configStore: configStore,
      activeLocale: active,
      replyLanguageMode: replyMode,
      startupWarning: warning,
    );
  }

  AppLocale get activeLocale => _activeLocale;
  String get activeCode => _activeLocale.code;
  List<AppLocale> get availableLocales => AppLocale.values;

  ReplyLanguageMode get replyLanguageMode => _replyLanguageMode;
  String get replyLanguageCode => _replyLanguageMode.code;
  List<ReplyLanguageMode> get availableReplyLanguageModes =>
      ReplyLanguageMode.values;

  /// The resolved reply-language policy used to render the system prompt's
  /// language section. Follows the active locale in `follow` mode.
  ReplyLanguageSettings get replyLanguageSettings =>
      ReplyLanguageSettings(mode: _replyLanguageMode, locale: _activeLocale);

  /// A [Strings] bound to the *current* active locale, for looking up UI
  /// chrome text at render/execution time.
  Strings get strings => Strings(_activeLocale);

  /// Switch to the locale with [code] (`en` / `zh`). Returns a result with
  /// a null [LocaleSwitchResult.locale] for unknown codes (no state change).
  Future<LocaleSwitchResult> switchLocale(String code) async {
    final locale = AppLocale.tryFromCode(code);
    if (locale == null) return const LocaleSwitchResult();
    _activeLocale = locale;
    notifyListeners();
    try {
      await configStore.writeLocale(code);
      return LocaleSwitchResult(locale: locale);
    } catch (error) {
      return LocaleSwitchResult(locale: locale, persistenceError: error);
    }
  }

  /// Switch to the reply-language mode with [code] (`follow` / `auto`).
  /// Returns a result with a null [ReplyLanguageSwitchResult.mode] for
  /// unknown codes (no state change).
  Future<ReplyLanguageSwitchResult> switchReplyLanguage(String code) async {
    final mode = ReplyLanguageMode.tryFromCode(code);
    if (mode == null) return const ReplyLanguageSwitchResult();
    _replyLanguageMode = mode;
    notifyListeners();
    try {
      await configStore.writeReplyLanguage(code);
      return ReplyLanguageSwitchResult(mode: mode);
    } catch (error) {
      return ReplyLanguageSwitchResult(mode: mode, persistenceError: error);
    }
  }
}
