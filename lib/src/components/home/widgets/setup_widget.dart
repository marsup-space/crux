import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../../../theme/crux_theme.dart';
import '../home_widgets.dart';

/// One row in the setup checklist.
class SetupItem {
  /// Short label rendered after the status marker (e.g. `provider key`).
  final String label;

  /// Whether the item is done. Done rows render a `✓` and [detail];
  /// pending rows render `›` and the [seedText] hint.
  final bool done;

  /// What to show after a done item's label (e.g. the aux model's name).
  final String detail;

  /// The slash-command prefix seeded into the chat input when a pending
  /// row is activated (the user completes the arguments there). Empty
  /// for the workspace row, which needs no command.
  final String seedText;

  const SetupItem({
    required this.label,
    required this.done,
    this.detail = '',
    this.seedText = '',
  });
}

/// The `setup` box ("Quick Start") — a first-run checklist reminding the
/// user to connect a provider key, pick an auxiliary model, configure a
/// web provider, and open a real project directory.
///
/// Each row is computed live from [HomeContext] on every build, so the
/// checklist ticks itself off as the user completes items elsewhere in
/// the app. Pending rows are actionable: Enter/click seeds the matching
/// slash command into the chat input (via [HomeContext.seedInput]) and
/// closes home so the user finishes typing the key/model there. Done
/// rows and the always-done-style workspace row are inert.
///
/// It's the top-most, full-width box on the dashboard — it's the first
/// thing a new user should see. Once every item is done the box *hides
/// itself* ([visibleWhen] returns false): it drops out of the grid and
/// keyboard navigation entirely, freeing the cell, and reappears in its
/// original position if an item ever becomes pending again (e.g. the
/// user removes their web-provider key).
class SetupHomeWidget extends HomeWidget {
  /// Injectable items for tests. When null (the default), items are
  /// computed from the [HomeContext] on each build.
  final List<SetupItem> Function(HomeContext ctx)? itemsOverride;

  SetupHomeWidget({this.itemsOverride});

  @override
  String get id => 'setup';

  @override
  String get title => 'Quick Start';

  @override
  String titleFor(HomeContext ctx) => ctx.strings.t('home.title.setup');

  /// Full-width: the box always takes the whole row ({1,2,4} covers the
  /// 1/2/4-column layouts; the packer clamps to the actual column
  /// count). It's the first-run to-do list — it should be unmissable,
  /// not tucked into a span-1 cell.
  @override
  Set<int> get supportedSpans => const {1, 2, 4};

  /// Hide once the checklist is complete. Home filters invisible boxes
  /// out of the rendered grid (they stay in the placement list), so an
  /// all-set Quick Start takes no cell and no keyboard focus.
  @override
  bool visibleWhen(HomeContext ctx) => !_allDone(itemsFor(ctx));

  /// The checklist as it stands right now. The workspace row is last:
  List<SetupItem> itemsFor(HomeContext ctx) {
    final override = itemsOverride;
    if (override != null) return override(ctx);
    final auxName = ctx.auxModelName();
    return [
      SetupItem(
        label: ctx.strings.t('home.setup.providerKey'),
        done: ctx.hasProviderKey(),
        detail: ctx.strings.t('home.setup.connected'),
        seedText: '/provider ',
      ),
      SetupItem(
        label: ctx.strings.t('home.setup.auxModel'),
        done: auxName != null,
        detail: auxName ?? '',
        seedText: '/auxiliary ',
      ),
      SetupItem(
        label: ctx.strings.t('home.setup.webProvider'),
        done: ctx.hasWebProvider(),
        detail: ctx.strings.t('home.setup.configured'),
        seedText: '/web-provider ',
      ),
      SetupItem(
        label: ctx.strings.t('home.setup.workspace'),
        done: ctx.projectPath.isNotEmpty,
        detail: ctx.projectPath.isNotEmpty
            ? p.basename(ctx.projectPath)
            : ctx.strings.t('home.setup.openProject'),
      ),
    ];
  }

  bool _allDone(List<SetupItem> items) => items.every((i) => i.done);

  @override
  int heightFor(int span) => 4;

  // ── Item selection ────────────────────────────────────────────────

  int _selectedIndex = 0;

  /// The item count for the *current* build. Home asks this before every
  /// build, so the override-less path has no context yet — report the
  /// full row count (the all-set state renders one row but is passive,
  /// and home treats the box as passive then because every row is done
  /// anyway — see [activateItem]).
  @override
  int get itemCount => 4;

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
    final items = itemsFor(ctx);
    if (index < 0 || index >= items.length) return null;
    final item = items[index];
    // Done rows and rows without a command (the workspace reminder) do
    // nothing — the checklist is informational once an item is handled.
    if (item.done || item.seedText.isEmpty) return null;
    return () {
      ctx.seedInput(item.seedText);
      ctx.close();
    };
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
    final items = itemsFor(ctx);

    // Note: the all-done state never reaches here on the real home
    // screen — visibleWhen() hides the box first. (The debug screen in
    // tool/ renders every state directly, so it builds the checklist
    // rows even when they're all done.)
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          _SetupRow(
            item: items[i],
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

/// One checklist row: a status marker, the label, and a trailing detail
/// (done) or command hint (pending). Highlighted when it's the box's
/// selected item and the box is focused — same pattern as quick-actions.
class _SetupRow extends StatelessComponent {
  final SetupItem item;
  final bool selected;
  final CruxThemeData theme;
  final VoidCallback onTap;

  const _SetupRow({
    required this.item,
    required this.selected,
    required this.theme,
    required this.onTap,
  });

  @override
  Component build(BuildContext context) {
    final markerColor = item.done
        ? (selected ? theme.selectedText : theme.onSurfaceDim)
        : (selected ? theme.selectedText : theme.warning);
    final labelColor = item.done
        ? (selected ? theme.selectedText : theme.onSurfaceDim)
        : (selected ? theme.selectedText : theme.accent);
    final hintColor = selected ? theme.selectedText : theme.onSurfaceDim;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        color: selected ? theme.selection : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(item.done ? '✓ ' : '› ', style: TextStyle(color: markerColor)),
            Text(
              item.label,
              style: TextStyle(
                color: labelColor,
                fontWeight: item.done ? FontWeight.normal : FontWeight.bold,
              ),
            ),
            Expanded(
              child: Text(
                '  ${item.done ? item.detail : item.seedText.trim()}',
                style: TextStyle(color: hintColor),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
