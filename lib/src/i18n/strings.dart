import 'app_locale.dart';

/// A small hand-rolled message catalog for UI chrome strings.
///
/// Deliberately *not* the `intl` message system: for a pure-Dart TUI the
/// catalog is a pair of `Map<String, String>` per locale, looked up by key
/// with `{name}` placeholder substitution. Chinese has no plural
/// morphology, so the first pass needs none of `intl`'s plural/gender
/// machinery — and if number/date formatting is ever needed, `intl` can be
/// pulled in later for *just* its `NumberFormat`/`DateFormat`.
class Strings {
  final AppLocale locale;

  const Strings(this.locale);

  /// Look up [key] in the active locale, falling back to English, then to
  /// the key itself (so a missing key renders visibly instead of throwing).
  /// `{name}` placeholders in the value are replaced from [args].
  String t(String key, [Map<String, String> args = const {}]) {
    final raw = _catalog[locale]?[key] ?? _catalog[AppLocale.en]?[key] ?? key;
    if (args.isEmpty) return raw;
    return args.entries.fold<String>(
      raw,
      (s, e) => s.replaceAll('{${e.key}}', e.value),
    );
  }
}

const Map<AppLocale, Map<String, String>> _catalog = {
  AppLocale.en: _en,
  AppLocale.zh: _zh,
};

const Map<String, String> _en = {
  'lang.unavailable': 'Language service is unavailable',
  'lang.current': 'Current language: {lang}. Usage: /language <en|zh>',
  'lang.unknown': 'Unknown language "{lang}". Available: {list}',
  'lang.switched': 'Language switched to {lang}',
  'lang.persistFailed': 'Language switched to {lang}, but config could not be saved',
};

const Map<String, String> _zh = {
  'lang.unavailable': '语言服务不可用',
  'lang.current': '当前语言：{lang}。用法：/language <en|zh>',
  'lang.unknown': '未知语言 "{lang}"。可用：{list}',
  'lang.switched': '语言已切换为 {lang}',
  'lang.persistFailed': '语言已切换为 {lang}，但配置保存失败',
};
