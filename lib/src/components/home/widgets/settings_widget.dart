import 'package:nocterm/nocterm.dart';

import '../../../theme/crux_theme.dart';
import '../../../utils/text_width.dart';
import '../../ui/button.dart';
import '../home_widgets.dart';

/// One informational row in the settings box.
class _Setting {
  final String label;
  final String value;

  const _Setting(this.label, this.value);
}

/// The `settings` box — the current value of each live setting, one row
/// per setting.
///
/// Rows are informational: each shows `label  value` and deliberately has
/// no mouse or keyboard activation. The in-box upper-right button opens
/// `/setup`, which replaces home with the setup guide.
class SettingsHomeWidget extends HomeWidget {
  @override
  String get id => 'settings';

  @override
  String get title => 'Settings';

  @override
  String titleFor(HomeContext ctx) => ctx.strings.t('home.title.settings');

  @override
  Set<int> get supportedSpans => const {1, 2};

  @override
  int heightFor(int span) => 5;

  /// A list of rows reads top-down, not centered in a stretched box.
  @override
  bool get verticallyCenter => false;

  List<_Setting> _items(HomeContext ctx) {
    return [
      _Setting(ctx.strings.t('home.settings.theme'), ctx.themeId() ?? '—'),
      _Setting(
        ctx.strings.t('home.settings.auxiliary'),
        ctx.auxModelName() ?? 'none',
      ),
      _Setting(ctx.strings.t('home.settings.view'), ctx.viewMode() ?? '—'),
      _Setting(ctx.strings.t('home.settings.language'), ctx.localeId() ?? 'en'),
      _Setting(
        ctx.strings.t('home.settings.replyLanguage'),
        _replyLanguageLabel(ctx),
      ),
    ];
  }

  /// Map the raw mode code to a localized label (e.g. `auto` → "Auto" /
  /// "自动"), falling back to `follow` when no controller is wired.
  String _replyLanguageLabel(HomeContext ctx) {
    final id = ctx.replyLanguageId() ?? 'follow';
    return ctx.strings.t('replylang.$id');
  }

  @override
  void Function()? activate(HomeContext ctx) => null;

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    final theme = CruxTheme.of(context);
    final items = _items(ctx);

    // Pad the label column (in terminal *columns*, not code units) so the
    // values line up vertically — width comes from nocterm's UnicodeWidth.
    var maxLabel = 0;
    for (final item in items) {
      final w = stringWidth(item.label);
      if (w > maxLabel) maxLabel = w;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _SettingsRow(
                item: items.first,
                labelWidth: maxLabel,
                theme: theme,
              ),
            ),
            Button(
              label: ctx.strings.t('home.settings.openSetup'),
              onPressed: () {
                ctx.runCommand('/setup');
              },
              color: theme.accent,
              hoverColor: theme.buttonTextHover,
              bgColor: theme.surfaceVariant,
              hoverBgColor: theme.buttonBackgroundHover,
              padding: const EdgeInsets.symmetric(horizontal: 1),
            ),
          ],
        ),
        for (final item in items.skip(1))
          _SettingsRow(item: item, labelWidth: maxLabel, theme: theme),
      ],
    );
  }
}

/// One passive settings row: a dim label (padded to [labelWidth]) and
/// its current value.
class _SettingsRow extends StatelessComponent {
  final _Setting item;
  final int labelWidth;
  final CruxThemeData theme;

  const _SettingsRow({
    required this.item,
    required this.labelWidth,
    required this.theme,
  });

  @override
  Component build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          padToWidth(item.label, labelWidth),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
        Text(
          '  ${item.value}',
          style: TextStyle(color: theme.onSurfaceVariant),
        ),
      ],
    );
  }
}
