// Inspect and drive the workspace-level spec plugins.
//
// Plugins are TOML files at `<project>/.crux/plugins/*.toml` (plus the
// legacy `.crux/widgets/` and the global `~/.crux/plugins/` roots) —
// the same specs the side panel and home grid render. This tool gives
// the agent the same visibility and control the human gets from the
// UI:
//
//   list                  → every plugin, its placement, live status, actions
//   inspect <id>          → one plugin's spec + full status JSON + actions
//   trigger <id> <action> → execute one of the plugin's actions
//
// The "status" the tool reports is the same computed status the
// renderers show (`evaluatePluginStatus`): alive/stale/absent + the
// rendered label. The project path comes from the tool context's
// working directory, so the tool is naturally keyed on the workspace —
// exactly like the UI.

library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/plugin.dart';
import '../services/plugin_registry.dart';
import 'tool_def.dart';

class PluginsTool extends ToolDef {
  /// Overridable launcher for [PluginActionKind.launch] actions —
  /// tests inject a fake instead of opening a real terminal.
  final Future<bool> Function(PluginAction action, String projectPath)?
      launchFn;

  /// Override for the user's home directory — passed straight to
  /// [PluginRegistry]. Tests inject an empty temp dir so the global
  /// scan roots (`~/.crux/plugins/`) don't leak the developer's real
  /// global plugins into the expected plugin counts.
  final String? homeOverride;

  PluginsTool({this.launchFn, this.homeOverride});

  @override
  String get name => 'plugins';

  @override
  String get description =>
      'Inspect and drive the workspace plugins declared in '
      '`.crux/plugins/*.toml` (the same plugins the sidebar and home '
      'grid render). Use `list` to see every plugin with its placement, '
      'live status and actions, `inspect <id>` for one plugin\'s full '
      'status JSON and action list, and `trigger <id> <action>` to '
      'execute an action (an HTTP POST to the URL the plugin declares '
      '— e.g. reloading the hot-reload harness). Plugins are keyed on '
      'the project directory; global plugins from `~/.crux/plugins/` '
      'work in every project. To CREATE a plugin, write a TOML spec '
      'into `.crux/plugins/` — load the `plugin` skill for the schema, '
      'placement options and authoring conventions';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['list', 'inspect', 'trigger'],
            'description': 'What to do.',
          },
          'id': {
            'type': 'string',
            'description': 'Plugin id (required for inspect and trigger).',
          },
          'action_label': {
            'type': 'string',
            'description': 'Action label from the spec (required for '
                'trigger), e.g. "reload".',
          },
        },
        'required': ['action'],
      };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final action = args['action'] as String? ?? 'list';
    final projectPath = ctx.workingDirectory;
    final plugins = _loadPlugins(projectPath);

    switch (action) {
      case 'list':
        return _list(plugins, projectPath);
      case 'inspect':
        return _inspect(plugins, projectPath, args['id'] as String?);
      case 'trigger':
        return await _trigger(
          plugins,
          projectPath,
          args['id'] as String?,
          args['action_label'] as String?,
        );
      default:
        return ToolResult.error(
          'Unknown action "$action" — use list, inspect, or trigger.',
        );
    }
  }

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final action = args['action'] as String? ?? 'list';
    final n = result.metadata['plugins'] as int?;
    final suffix = n == null ? '' : ' ($n)';
    return CollapsedSummary(
      text: 'plugins $action$suffix',
      argsTokens: 0,
      totalTokens: 0,
    );
  }

  // ── Loading ──────────────────────────────────────────────────────

  /// Scan the same roots the UI registry scans (project plugins +
  /// legacy widgets + the two global roots), with the same
  /// precedence, so the tool always agrees with what's on screen.
  List<Plugin> _loadPlugins(String projectPath) {
    final registry = PluginRegistry(
      projectPath: projectPath,
      homeOverride: homeOverride,
    );
    registry.scan();
    return registry.plugins;
  }

  PluginStatus _statusOf(Plugin plugin, String projectPath) =>
      evaluatePluginStatus(
        plugin,
        File(p.join(projectPath, plugin.statusPath)),
        DateTime.now(),
      );

  // ── Actions ─────────────────────────────────────────────────────

  ToolResult _list(List<Plugin> plugins, String projectPath) {
    final buf = StringBuffer()
      ..writeln('Plugins for $projectPath:')
      ..writeln();
    if (plugins.isEmpty) {
      buf.writeln(
        '(none — drop a TOML into .crux/plugins/ to add one; '
        '~/.crux/plugins/ for a global one)',
      );
    }
    for (final plugin in plugins) {
      final status = _statusOf(plugin, projectPath);
      final actions = plugin.actions.map((a) => a.label).join(', ');
      final origin = plugin.isGlobal ? ' (global)' : '';
      buf.writeln(
        '  ${plugin.id.padRight(16)} ${plugin.placement.name.padRight(7)} '
        '${status.alive.name.padRight(6)} ${status.label}$origin',
      );
      if (actions.isNotEmpty) {
        buf.writeln('      actions: $actions');
      }
    }
    return ToolResult(
      title: 'plugins list',
      output: buf.toString(),
      metadata: {'plugins': plugins.length},
    );
  }

  ToolResult _inspect(
    List<Plugin> plugins,
    String projectPath,
    String? id,
  ) {
    final plugin = _byId(plugins, id);
    if (plugin == null) {
      return ToolResult.error(
        'No plugin "$id" — available: '
        '${plugins.map((s) => s.id).join(', ')}',
      );
    }
    final status = _statusOf(plugin, projectPath);
    final buf = StringBuffer()
      ..writeln('plugin: ${plugin.id}${plugin.isGlobal ? ' (global)' : ''}')
      ..writeln('  placement: ${plugin.placement.name}')
      ..writeln('  status file: ${plugin.statusPath}')
      ..writeln('  alive: ${status.alive.name}')
      ..writeln('  label: ${status.label}')
      ..writeln('  status JSON:')
      ..writeln(_prettyJson(status.data))
      ..writeln('  actions:');
    if (plugin.actions.isEmpty) {
      buf.writeln('    (none)');
    }
    for (final action in plugin.actions) {
      switch (action.kind) {
        case PluginActionKind.prompt:
          buf.writeln('    ${action.label}: prompt → ${action.prompt}');
        case PluginActionKind.launch:
          buf.writeln('    ${action.label}: launch → ${action.command}');
        case PluginActionKind.shell:
          buf.writeln('    ${action.label}: shell → ${action.command}');
        case PluginActionKind.screen:
          buf.writeln('    ${action.label}: screen → ${action.screen}');
        case PluginActionKind.http:
          buf.writeln('    ${action.label}: ${action.url}');
      }
    }
    return ToolResult(
      title: 'plugins inspect ${plugin.id}',
      output: buf.toString(),
      metadata: {'plugins': 1},
    );
  }

  /// The status file for a plugin resolves against the project root —
  /// even for global plugins (their spec lives in `~/.crux/` but they
  /// monitor the current project).
  Future<ToolResult> _trigger(
    List<Plugin> plugins,
    String projectPath,
    String? id,
    String? actionLabel,
  ) async {
    final plugin = _byId(plugins, id);
    if (plugin == null) {
      return ToolResult.error(
        'No plugin "$id" — available: '
        '${plugins.map((s) => s.id).join(', ')}',
      );
    }
    final action = plugin.actions
        .where((a) => a.label == actionLabel)
        .firstOrNull;
    if (action == null) {
      return ToolResult.error(
        'No action "$actionLabel" on ${plugin.id} — available: '
        '${plugin.actions.map((a) => a.label).join(', ')}',
      );
    }

    // Launch actions start a dead service; http actions drive a live
    // one; prompt actions render the quick-action message for the
    // calling agent (no liveness gate — a prompt is always runnable).
    if (action.kind == PluginActionKind.launch) {
      final ok = await (launchFn ?? launchPluginAction)(action, projectPath);
      return ToolResult(
        title: 'plugins trigger ${plugin.id}.$actionLabel',
        output: ok
            ? 'Launched ${plugin.id}.$actionLabel → ${action.command} '
                '(new terminal in $projectPath)'
            : 'Failed to launch ${plugin.id}.$actionLabel — launch actions '
                'need macOS + Ghostty',
        metadata: {'plugins': 1, 'ok': ok},
      );
    }

    if (action.kind == PluginActionKind.prompt) {
      final status = _statusOf(plugin, projectPath);
      final rendered = renderActionPrompt(action, status.data);
      return ToolResult(
        title: 'plugins trigger ${plugin.id}.$actionLabel',
        output: 'Quick action ${plugin.id}.$actionLabel renders as:\n\n'
            '$rendered\n\n'
            'This is the message the user\'s button-click would submit '
            'to the session. Act on it directly (or refine it first if '
            'the current task needs a variant).',
        metadata: {'plugins': 1, 'ok': true, 'prompt': rendered},
      );
    }

    // Screen actions are pure UI — they open a fullpane in the running
    // TUI. There's no in-process screen to open from a tool call, so
    // report what the button would do rather than performing it.
    if (action.kind == PluginActionKind.screen) {
      return ToolResult(
        title: 'plugins trigger ${plugin.id}.$actionLabel',
        output: '${plugin.id}.$actionLabel is a `screen` action — clicking '
            'it opens the `${action.screen}` fullpane in the running Crux '
            'TUI. There is no agent-side effect to trigger from here.',
        metadata: {'plugins': 1, 'ok': false, 'screen': action.screen},
      );
    }

    if (action.kind == PluginActionKind.shell) {
      final status = _statusOf(plugin, projectPath);
      final rendered = renderActionCommand(action, status.data);
      final result = await runPluginShellAction(
        action,
        status.data,
        projectPath,
      );
      final buf = StringBuffer()
        ..writeln('Ran ${plugin.id}.$actionLabel → `$rendered`')
        ..writeln('Exit code: ${result.exitCode}');
      if (result.tail.isNotEmpty) {
        buf
          ..writeln('Output (tail):')
          ..writeln(result.tail);
      }
      return ToolResult(
        title: 'plugins trigger ${plugin.id}.$actionLabel',
        output: buf.toString().trimRight(),
        metadata: {
          'plugins': 1,
          'ok': result.ok,
          'exitCode': result.exitCode,
        },
      );
    }

    final status = _statusOf(plugin, projectPath);
    if (status.alive != PluginAlive.alive) {
      return ToolResult.error(
        '${plugin.id} is ${status.alive.name} (${status.label}) — http '
        'actions only run while the plugin is alive.',
      );
    }
    final url = renderActionUrl(action, status.data);
    final ok = await sendPluginAction(action, status.data);
    return ToolResult(
      title: 'plugins trigger ${plugin.id}.$actionLabel',
      output: ok
          ? 'Triggered ${plugin.id}.$actionLabel → POST $url → ok'
          : 'Failed to trigger ${plugin.id}.$actionLabel → POST $url '
              '(target unreachable or non-200)',
      metadata: {'plugins': 1, 'ok': ok},
    );
  }

  Plugin? _byId(List<Plugin> plugins, String? id) {
    if (id == null) return null;
    for (final plugin in plugins) {
      if (plugin.id == id) return plugin;
    }
    return null;
  }

  static String _prettyJson(Map<String, dynamic> data) {
    if (data.isEmpty) return '    (empty — status file missing or invalid)';
    final indent = StringBuffer();
    final lines = const JsonEncoder.withIndent('  ').convert(data).split('\n');
    for (final line in lines) {
      indent.writeln('    $line');
    }
    return indent.toString().trimRight();
  }
}
