import 'package:nocterm/nocterm.dart';

import 'app_locale.dart';
import 'locale_config_store.dart';
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

/// The live UI-language setting.
///
/// Mirrors `ThemeController`: holds the active [AppLocale], persists it via
/// [LocaleConfigStore] to `config.toml`, and notifies listeners on switch so
/// any already-mounted UI that reads the locale re-renders.
class LocaleController extends ChangeNotifier {
  final LocaleConfigStore configStore;
  final String? startupWarning;

  AppLocale _activeLocale;

  LocaleController._({
    required this.configStore,
    required this._activeLocale,
    this.startupWarning,
  });

  static Future<LocaleController> create({
    required LocaleConfigStore configStore,
    AppLocale defaultLocale = AppLocale.fallback,
  }) async {
    String? configured;
    String? warning;
    try {
      configured = await configStore.readLocale();
    } catch (error) {
      configured = null;
      warning = 'Could not read language configuration: $error';
    }

    // Null → the runtime default (currently always `en`). Unknown code →
    // fall back to English with a warning (mirrors an unknown theme id).
    final AppLocale active;
    if (configured == null) {
      active = defaultLocale;
    } else if (AppLocale.tryFromCode(configured) == null) {
      warning = 'Configured language "$configured" is unavailable; using English';
      active = AppLocale.en;
    } else {
      active = AppLocale.tryFromCode(configured)!;
    }

    return LocaleController._(
      configStore: configStore,
      activeLocale: active,
      startupWarning: warning,
    );
  }

  AppLocale get activeLocale => _activeLocale;
  String get activeCode => _activeLocale.code;
  List<AppLocale> get availableLocales => AppLocale.values;

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
}
