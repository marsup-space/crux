/// Locale-aware display names for Worker constellation identities.
library;

import '../../i18n/app_locale.dart';
import '../../utils/worker_constellations.dart';

/// Renders the persisted constellation id in the active UI language.
///
/// Unknown legacy names remain readable unchanged. This keeps workers created
/// before constellation IDs were introduced inspectable after an upgrade.
class WorkerNameLocalizer {
  const WorkerNameLocalizer();

  String display(String persistedName, AppLocale locale) {
    final constellation = constellationForPersistedName(persistedName);
    if (constellation == null) return persistedName;
    return switch (locale) {
      AppLocale.en => constellation.englishName,
      AppLocale.zh => constellation.chineseName,
    };
  }

  String englishDisplay(String persistedName) =>
      display(persistedName, AppLocale.en);
}
