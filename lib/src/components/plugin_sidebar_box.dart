// Bordered sidebar chrome around a [PluginContent] — one full-width
// boxed row per sidebar plugin, title inlined on the border. The
// content/polling/interaction logic lives in [PluginContent]; this is
// the presentation wrapper only.

library;

import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import '../services/plugin.dart';
import '../theme/crux_theme.dart';
import 'plugin_content.dart';

/// One plugin's boxed row in the side panel. The panel lays these out
/// above the auxiliary / git / project controls.
class PluginSidebarBox extends StatelessComponent {
  final Plugin plugin;
  final PluginHost host;
  final Strings strings;

  /// Passed through to [PluginContent] — how long a checked todo row
  /// stays visible before disappearing (the undo window).
  final Duration todoCheckedTtl;

  const PluginSidebarBox({
    super.key,
    required this.plugin,
    required this.host,
    this.strings = kEnglishStrings,
    this.todoCheckedTtl = const Duration(seconds: 10),
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _titleIntrinsicWidth(plugin, strings);
        return Container(
          width: width,
          decoration: BoxDecoration(
            color: theme.surface,
            border: BoxBorder.all(
              color: theme.outline,
              style: BoxBorderStyle.rounded,
            ),
            title: BorderTitle(
              text: strings.t(plugin.title),
              style: TextStyle(
                color: theme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: PluginContent(
            plugin: plugin,
            host: host,
            strings: strings,
            todoCheckedTtl: todoCheckedTtl,
          ),
        );
      },
    );
  }

  /// Fallback intrinsic width for the bordered box when the parent
  /// leaves the width unconstrained (direct test mounts).
  static double _titleIntrinsicWidth(Plugin plugin, Strings strings) =>
      strings.t(plugin.title).runes.length + 2; // +2 border columns
}
