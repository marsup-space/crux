import 'package:nocterm/nocterm.dart';

import 'crux_theme.dart';
import 'terminal_brightness.dart';
import 'theme_config_store.dart';
import 'theme_registry.dart';

class ThemeSwitchResult {
  final CruxThemeData? theme;
  final Object? persistenceError;

  const ThemeSwitchResult({this.theme, this.persistenceError});

  bool get found => theme != null;
  bool get persisted => found && persistenceError == null;
}

class ThemeController extends ChangeNotifier {
  final ThemeRegistry registry;
  final ThemeConfigStore configStore;
  final String? startupWarning;

  CruxThemeData _activeTheme;

  ThemeController._({
    required this.registry,
    required this.configStore,
    required CruxThemeData activeTheme,
    this.startupWarning,
  }) : _activeTheme = activeTheme;

  static Future<ThemeController> create({
    required ThemeRegistry registry,
    required ThemeConfigStore configStore,
    // Default theme applied only when the user has NOT configured one
    // (no `ui.theme` key in config.toml). The caller computes this from
    // terminal background brightness (see terminal_brightness.dart);
    // it is a runtime default and is never written back to config, so
    // it adapts when the user switches terminal profiles. An explicit
    // configured theme always wins. Defaults to the historical
    // [kDefaultDarkThemeId] when omitted or inconclusive.
    String defaultThemeId = kDefaultDarkThemeId,
  }) async {
    String? configured;
    String? warning;
    try {
      configured = await configStore.readThemeId();
    } catch (error) {
      configured = null;
      warning = 'Could not read theme configuration: $error';
    }
    if (configured != null && registry[configured] == null) {
      warning = 'Configured theme "$configured" is unavailable; using Dracula';
    }
    return ThemeController._(
      registry: registry,
      configStore: configStore,
      activeTheme: registry[configured ?? defaultThemeId] ?? registry.dracula,
      startupWarning: warning,
    );
  }

  CruxThemeData get activeTheme => _activeTheme;
  String get activeId => _activeTheme.id;
  List<String> get availableIds => registry.availableIds;

  Future<ThemeSwitchResult> switchTheme(String id) async {
    final theme = registry[id];
    if (theme == null) return const ThemeSwitchResult();
    _activeTheme = theme;
    notifyListeners();
    try {
      await configStore.writeThemeId(id);
      return ThemeSwitchResult(theme: theme);
    } catch (error) {
      return ThemeSwitchResult(theme: theme, persistenceError: error);
    }
  }
}
