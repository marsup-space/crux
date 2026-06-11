import 'crux_theme.dart';

const curatedThemeIds = <String>[
  'dracula',
  'onedarkpro',
  'catppuccin',
  'synthwave84',
  'cobalt2',
  'flexoki',
  'rosepine',
  'github',
];

class ThemeRegistry {
  final Map<String, CruxThemeData> _themes;
  final List<String> _orderedIds;
  final Map<String, String> loadErrors;

  ThemeRegistry({
    required Map<String, CruxThemeData> themes,
    required List<String> orderedIds,
    this.loadErrors = const {},
  }) : _themes = Map.unmodifiable(themes),
       _orderedIds = List.unmodifiable(orderedIds);

  CruxThemeData? operator [](String id) => _themes[id];

  CruxThemeData get dracula =>
      _themes['dracula'] ?? CruxThemeData.draculaFallback;

  List<String> get availableIds => _orderedIds;

  List<CruxThemeData> get themes =>
      _orderedIds.map((id) => _themes[id]!).toList(growable: false);
}
