import 'package:nocterm/nocterm.dart';

import '../../../theme/crux_theme.dart';
import '../../../utils/text_width.dart';
import '../home_widgets.dart';

/// One row in the settings box.
class _Setting {
  final String label;
  final String value;

  /// The slash-command prefix seeded into the chat input when the row is
  /// activated (the user completes the arguments there). Null for a
  /// read-only row.
  final String? seedText;

  const _Setting(this.label, this.value, this.seedText);
}

/// The `settings` box — the current value of each live setting, one row
/// per setting.
///
/// Rows are informational: each shows `label  value`. Activating a row
/// seeds the matching slash command into the chat input (so the user can
/// finish the command there after `esc`) but stays on home — no abrupt
/// jump to chat. The `language` row is read-only — it renders the active
/// locale code (`en`/`zh`, read from `HomeContext.localeId`; falls back to
/// `en` when no locale controller is wired).
///
/// The box uses the same selectable-item chrome as quick-actions: ↑↓
/// moves the highlight, Enter/click activates the focused row.
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
  int heightFor(int span) => 4;

  /// A list of rows reads top-down, not centered in a stretched box.
  @override
  bool get verticallyCenter => false;

  List<_Setting> _items(HomeContext ctx) {
    return [
      _Setting(ctx.strings.t('home.settings.theme'), ctx.themeId() ?? '—', '/theme '),
      _Setting(
        ctx.strings.t('home.settings.auxiliary'),
        ctx.auxModelName() ?? 'none',
        '/auxiliary ',
      ),
      _Setting(ctx.strings.t('home.settings.view'), ctx.viewMode() ?? '—', '/view '),
      // Language switching is wired via `/language`; the row shows the
      // active locale and stays read-only (seed via `/language ` instead).
      _Setting(ctx.strings.t('home.settings.language'), ctx.localeId() ?? 'en', null),
      // Reply-language switching is wired via `/reply-language`; the row
      // shows the localized mode label and seeds the command on activate.
      _Setting(
        ctx.strings.t('home.settings.replyLanguage'),
        _replyLanguageLabel(ctx),
        '/reply-language ',
      ),
    ];
  }

  /// Map the raw mode code to a localized label (e.g. `auto` → "Auto" /
  /// "自动"), falling back to `follow` when no controller is wired.
  String _replyLanguageLabel(HomeContext ctx) {
    final id = ctx.replyLanguageId() ?? 'follow';
    return ctx.strings.t('replylang.$id');
  }

  // ── Item selection ────────────────────────────────────────────────

  int _selectedIndex = 0;

  @override
  int get itemCount => 5;

  @override
  int get selectedIndex => _selectedIndex;

  @override
  void moveSelection(int delta) {
    _selectedIndex = (_selectedIndex + delta) % itemCount;
    if (_selectedIndex < 0) _selectedIndex += itemCount;
  }

  @override
  bool selectItemAt(int index) {
    if (index < 0 || index >= itemCount) return false;
    _selectedIndex = index;
    return true;
  }

  @override
  void resetSelection() => _selectedIndex = 0;

  @override
  void Function()? activateItem(HomeContext ctx, int index) {
    final items = _items(ctx);
    if (index < 0 || index >= items.length) return null;
    final seed = items[index].seedText;
    if (seed == null) return null; // read-only row
    // Seed the command into the chat input but stay on home — the user
    // finishes it after `esc` (the footer's "esc chat"). Closing here
    // would yank them out of the dashboard on a single click.
    return () => ctx.seedInput(seed);
  }

  @override
  void Function()? activate(HomeContext ctx) =>
      activateItem(ctx, _selectedIndex);

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
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          _SettingsRow(
            item: items[i],
            labelWidth: maxLabel,
            selected: focused && i == _selectedIndex,
            theme: theme,
            onTap: () {
              _selectedIndex = i;
              activateItem(ctx, i)?.call();
            },
          ),
      ],
    );
  }
}

/// One settings row: a dim label (padded to [labelWidth]) and the
/// current value. Highlighted when it's the box's selected item and the
/// box is focused — same pattern as quick-actions / setup.
class _SettingsRow extends StatelessComponent {
  final _Setting item;
  final int labelWidth;
  final bool selected;
  final CruxThemeData theme;
  final VoidCallback onTap;

  const _SettingsRow({
    required this.item,
    required this.labelWidth,
    required this.selected,
    required this.theme,
    required this.onTap,
  });

  @override
  Component build(BuildContext context) {
    final labelColor = selected ? theme.selectedText : theme.onSurfaceDim;
    final valueColor = selected
        ? theme.selectedText
        : (item.seedText == null ? theme.onSurfaceDim : theme.onSurfaceVariant);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: selected ? theme.selection : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              padToWidth(item.label, labelWidth),
              style: TextStyle(color: labelColor),
            ),
            Text(
              '  ${item.value}',
              style: TextStyle(color: valueColor),
            ),
          ],
        ),
      ),
    );
  }
}
