// Home-grid adapter for spec-driven plugins: one [HomeWidget] box per
// `placement = "home"` / `"both"` plugin, rendered by the same
// [PluginContent] core the sidebar uses — identical status label,
// action buttons (mouse), and todo rows everywhere.
//
// Registry rescan flow: the ChatPanel hands the CURRENT plugin list to
// HomeScreen via [HomeContext.plugins]; HomeScreen rebuilds its
// _allById map on each build, so a spec appearing/disappearing
// hot-swaps its box in and out of the grid (after the panel's
// registry-listener refresh, ~2 s worst case).
//
// Keyboard: the box is actionable ([activate] returns a callback that
// fires the plugin's FIRST available action in the current liveness
// state — e.g. `start` while dead, `reload` while alive) so Enter on
// the focused box does something useful. Per-action keyboard picking
// is out of scope for V1 — the mouse segments cover it.

library;

import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../../i18n/strings.dart';
import '../../services/plugin.dart';
import '../plugin_content.dart';
import 'home_widgets.dart';

/// Factory-group for all home plugins: converts the live plugin list
/// into [HomeWidget] boxes for the grid.
class PluginHomeWidgets {
  /// Build the home-box list for [plugins]. [hostOf] supplies each
  /// plugin's wiring (the panel's shared handlers). The host's
  /// projectPath must be the CURRENT project root.
  static List<HomeWidget> build(
    List<Plugin> plugins,
    PluginHost Function() hostOf,
  ) =>
      [
        for (final plugin in plugins)
          PluginHomeWidget(plugin: plugin, hostOf: hostOf),
      ];
}

/// One plugin's box in the home grid.
class PluginHomeWidget extends HomeWidget {
  final Plugin plugin;

  /// Deferred host lookup: the host bundles callbacks owned by the
  /// chat panel (prompt/shell/screen/todo/action handlers +
  /// projectPath). Deferred because [HomeWidget] instances outlive
  /// panel rebuilds — the closure re-reads the live panel state.
  final PluginHost Function() hostOf;

  PluginHomeWidget({required this.plugin, required this.hostOf});

  @override
  String get id => 'plugin-${plugin.id}';

  @override
  String get title => plugin.title;

  @override
  String titleFor(HomeContext ctx) => plugin.title;

  /// Span 1-2 like the notes/skills boxes; a plugin box is compact.
  @override
  Set<int> get supportedSpans => const {1, 2};

  /// Dynamic: 1 label line + up to 3 todo rows + 1 button row, capped
  /// so a long spec can't hog the grid. Clamped to [4, 8].
  @override
  int heightFor(int span) => 4;

  /// Enter on the focused box fires the plugin's first available
  /// action in the current liveness state. Returns null when the
  /// plugin has no runnable action right now (pure monitor).
  @override
  void Function()? activate(HomeContext ctx) {
    return () => _fireFirst(ctx);
  }

  void _fireFirst(HomeContext ctx) {
    final host = hostOf();
    // Ask the content state for its current action list via the host's
    // recorded fire-closure registry (set from PluginContent's build).
    final fire = _firstActionClosures[id];
    if (fire != null) {
      fire();
      return;
    }
    host.onAction?.call(
      'pressed enter on plugin `${plugin.id}` (no action available)',
    );
  }

  /// Content states register their "fire first available action"
  /// closure here, key = home widget id (`plugin-<id>`), so the
  /// keyboard path reuses the exact liveness-gated action list the
  /// mouse path sees. Cleared when the state disposes.
  static final Map<String, void Function()> _firstActionClosures = {};

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    return _PluginHomeView(
      homeId: id,
      plugin: plugin,
      host: hostOf(),
      strings: ctx.strings,
    );
  }
}

/// Stateful wrapper so the box re-renders on the plugin's refresh
/// cadence and can register its keyboard fire-closure.
class _PluginHomeView extends StatefulComponent {
  final String homeId;
  final Plugin plugin;
  final PluginHost host;
  final Strings strings;

  const _PluginHomeView({
    required this.homeId,
    required this.plugin,
    required this.host,
    required this.strings,
  });

  @override
  State<_PluginHomeView> createState() => _PluginHomeViewState();
}

class _PluginHomeViewState extends State<_PluginHomeView> {
  @override
  void initState() {
    super.initState();
    PluginHomeWidget._firstActionClosures[component.homeId] = _fireFirst;
  }

  @override
  void dispose() {
    PluginHomeWidget._firstActionClosures.remove(component.homeId);
    super.dispose();
  }

  void _fireFirst() {
    final snapshot = _statusSnapshot(component.plugin, component.host);
    if (snapshot == null) return;
    final (status, actions) = snapshot;
    if (actions.isEmpty) return;
    _run(actions.first, status);
  }

  (PluginStatus, List<PluginAction>)? _statusSnapshot(
    Plugin plugin,
    PluginHost host,
  ) {
    // Note: reading status here is intentionally cheap (one file read)
    // and only runs on Enter, not per frame.
    final file = File(p.join(host.projectPath, plugin.statusPath));
    final status = evaluatePluginStatus(plugin, file, DateTime.now());
    final alive = status.alive == PluginAlive.alive;
    final actions = [
      for (final a in plugin.actions)
        if (a.kind == PluginActionKind.launch && !alive)
          a
        else if (a.kind == PluginActionKind.http && alive)
          a
        else if (a.kind == PluginActionKind.prompt &&
            host.onPromptAction != null)
          a
        else if (a.kind == PluginActionKind.shell)
          a
        else if (a.kind == PluginActionKind.screen &&
            host.onScreenAction != null)
          a,
    ];
    return (status, actions);
  }

  void _run(PluginAction action, PluginStatus status) {
    switch (action.kind) {
      case PluginActionKind.http:
        sendPluginAction(action, status.data).then((ok) {
          if (action.record) {
            unawaited(
              component.host.onAction?.call(
                'pressed enter on plugin `${component.plugin.id}` → '
                '`${action.label}` (POST ${renderActionUrl(action, status.data)} '
                '→ ${ok ? 'succeeded' : 'FAILED'})',
              ),
            );
          }
        });
      case PluginActionKind.launch:
        launchPluginAction(action, component.host.projectPath).then((ok) {
          if (action.record) {
            unawaited(
              component.host.onAction?.call(
                'pressed enter on plugin `${component.plugin.id}` → '
                '`${action.label}` (launch `${action.command}` → '
                '${ok ? 'terminal opened' : 'FAILED — needs macOS + Ghostty'})',
              ),
            );
          }
        });
      case PluginActionKind.shell:
        // Route through the host handler so the session gets the rich
        // record (exit code + tail), same as the sidebar click path.
        final rendered = renderActionCommand(action, status.data);
        unawaited(component.host.onShellAction?.call(action, rendered));
      case PluginActionKind.prompt:
        final rendered = renderActionPrompt(action, status.data);
        component.host.onPromptAction?.call(action, rendered);
      case PluginActionKind.screen:
        if (action.record) {
          unawaited(
            component.host.onAction?.call(
              'pressed enter on plugin `${component.plugin.id}` → '
              '`${action.label}` (open screen `${action.screen}`)',
            ),
          );
        }
        component.host.onScreenAction?.call(action);
    }
  }

  @override
  Component build(BuildContext context) {
    return PluginContent(
      key: ValueKey('plugin-home-${component.plugin.id}'),
      plugin: component.plugin,
      host: component.host,
      strings: component.strings,
    );
  }
}
