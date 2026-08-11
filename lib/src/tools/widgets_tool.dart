// Inspect and drive the workspace-level spec sidebar widgets (Phase B).
//
// Spec widgets are `.crux/widgets/*.toml` files at the project root —
// the same ones the side panel renders. This tool gives the agent the
// same visibility and control the human gets from the UI:
//
//   list                → every widget, its live status label, and its actions
//   inspect <id>        → one widget's spec + full status JSON + actions
//   trigger <id> <action> → execute one of the widget's actions (HTTP POST)
//
// The "status" the tool reports is the same computed status the
// renderer shows (`evaluateSpecStatus`): alive/stale/absent + the
// rendered label. The project path comes from the tool context's
// working directory, so the tool is naturally keyed on the workspace —
// exactly like the UI.

library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/spec_widget.dart';
import 'tool_def.dart';

class WidgetsTool extends ToolDef {
  /// Overridable launcher for [SpecActionKind.launch] actions — tests
  /// inject a fake instead of opening a real terminal.
  final Future<bool> Function(SpecAction action, String projectPath)?
      launchFn;

  WidgetsTool({this.launchFn});

  @override
  String get name => 'widgets';

  @override
  String get description =>
      'Inspect and drive the workspace-level sidebar widgets declared in '
      '`.crux/widgets/*.toml` (the same widgets the side panel renders). '
      'Use `list` to see every widget with its live status and actions, '
      '`inspect <id>` for one widget\'s full status JSON and action list, '
      'and `trigger <id> <action>` to execute an action (an HTTP POST to '
      'the URL the widget declares — e.g. reloading the hot-reload '
      'harness). Widgets are keyed on the project (workspace) directory. '
      'To CREATE a widget, write a TOML spec into `.crux/widgets/` — '
      'load the `widget` skill for the schema and conventions.';

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
            'description': 'Widget id (required for inspect and trigger).',
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
    final specs = _loadSpecs(projectPath);

    switch (action) {
      case 'list':
        return _list(specs, projectPath);
      case 'inspect':
        return _inspect(specs, projectPath, args['id'] as String?);
      case 'trigger':
        return await _trigger(
          specs,
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
    final n = result.metadata['widgets'] as int?;
    final suffix = n == null ? '' : ' ($n)';
    return CollapsedSummary(text: 'widgets $action$suffix', argsTokens: 0, totalTokens: 0);
  }

  // ── Loading ──────────────────────────────────────────────────────

  List<SpecWidget> _loadSpecs(String projectPath) {
    final dir = Directory(p.join(projectPath, '.crux', 'widgets'));
    final specs = <SpecWidget>[];
    try {
      if (!dir.existsSync()) return specs;
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.toml')) continue;
        final spec = SpecWidget.parse(entity);
        if (spec != null) specs.add(spec);
      }
    } catch (_) {
      // Unreadable widgets dir → treat as empty.
    }
    specs.sort((a, b) => a.id.compareTo(b.id));
    return specs;
  }

  SpecWidgetStatus _statusOf(SpecWidget spec, String projectPath) =>
      evaluateSpecStatus(
        spec,
        File(p.join(projectPath, spec.statusPath)),
        DateTime.now(),
      );

  // ── Actions ─────────────────────────────────────────────────────

  ToolResult _list(List<SpecWidget> specs, String projectPath) {
    final buf = StringBuffer()
      ..writeln('Spec widgets for $projectPath:')
      ..writeln();
    if (specs.isEmpty) {
      buf.writeln('(none — drop a TOML into .crux/widgets/ to add one)');
    }
    for (final spec in specs) {
      final status = _statusOf(spec, projectPath);
      final actions = spec.actions
          .map((a) => a.label)
          .join(', ');
      buf.writeln(
        '  ${spec.id.padRight(16)} ${status.alive.name.padRight(6)} '
        '${status.label}',
      );
      if (actions.isNotEmpty) {
        buf.writeln('      actions: $actions');
      }
    }
    return ToolResult(
      title: 'widgets list',
      output: buf.toString(),
      metadata: {'widgets': specs.length},
    );
  }

  ToolResult _inspect(
    List<SpecWidget> specs,
    String projectPath,
    String? id,
  ) {
    final spec = _byId(specs, id);
    if (spec == null) {
      return ToolResult.error(
        'No widget "$id" — available: ${specs.map((s) => s.id).join(', ')}',
      );
    }
    final status = _statusOf(spec, projectPath);
    final buf = StringBuffer()
      ..writeln('spec: ${spec.id}')
      ..writeln('  status file: ${spec.statusPath}')
      ..writeln('  alive: ${status.alive.name}')
      ..writeln('  label: ${status.label}')
      ..writeln('  status JSON:')
      ..writeln(_prettyJson(status.data))
      ..writeln('  actions:');
    if (spec.actions.isEmpty) {
      buf.writeln('    (none)');
    }
    for (final action in spec.actions) {
      switch (action.kind) {
        case SpecActionKind.prompt:
          buf.writeln('    ${action.label}: prompt → ${action.prompt}');
        case SpecActionKind.launch:
          buf.writeln('    ${action.label}: launch → ${action.command}');
        case SpecActionKind.shell:
          buf.writeln('    ${action.label}: shell → ${action.command}');
        case SpecActionKind.screen:
          buf.writeln('    ${action.label}: screen → ${action.screen}');
        case SpecActionKind.http:
          buf.writeln('    ${action.label}: ${action.url}');
      }
    }
    return ToolResult(
      title: 'widgets inspect ${spec.id}',
      output: buf.toString(),
      metadata: {'widgets': 1},
    );
  }

  Future<ToolResult> _trigger(
    List<SpecWidget> specs,
    String projectPath,
    String? id,
    String? actionLabel,
  ) async {
    final spec = _byId(specs, id);
    if (spec == null) {
      return ToolResult.error(
        'No widget "$id" — available: ${specs.map((s) => s.id).join(', ')}',
      );
    }
    final action = spec.actions
        .where((a) => a.label == actionLabel)
        .firstOrNull;
    if (action == null) {
      return ToolResult.error(
        'No action "$actionLabel" on ${spec.id} — available: '
        '${spec.actions.map((a) => a.label).join(', ')}',
      );
    }

    // Launch actions start a dead service; http actions drive a live
    // one; prompt actions render the quick-action message for the
    // calling agent (no liveness gate — a prompt is always runnable).
    if (action.kind == SpecActionKind.launch) {
      final ok =
          await (launchFn ?? launchSpecAction)(action, projectPath);
      return ToolResult(
        title: 'widgets trigger ${spec.id}.$actionLabel',
        output: ok
            ? 'Launched ${spec.id}.$actionLabel → ${action.command} '
                '(new terminal in $projectPath)'
            : 'Failed to launch ${spec.id}.$actionLabel — launch actions '
                'need macOS + Ghostty',
        metadata: {'widgets': 1, 'ok': ok},
      );
    }

    if (action.kind == SpecActionKind.prompt) {
      final status = _statusOf(spec, projectPath);
      final rendered = renderActionPrompt(action, status.data);
      return ToolResult(
        title: 'widgets trigger ${spec.id}.$actionLabel',
        output: 'Quick action ${spec.id}.$actionLabel renders as:\n\n'
            '$rendered\n\n'
            'This is the message the user\'s button-click would submit '
            'to the session. Act on it directly (or refine it first if '
            'the current task needs a variant).',
        metadata: {'widgets': 1, 'ok': true, 'prompt': rendered},
      );
    }

    // Screen actions are pure UI — they open a fullpane in the running
    // TUI. There's no in-process screen to open from a tool call, so
    // report what the button would do rather than performing it.
    if (action.kind == SpecActionKind.screen) {
      return ToolResult(
        title: 'widgets trigger ${spec.id}.$actionLabel',
        output: '${spec.id}.$actionLabel is a `screen` action — clicking '
            'it in the sidebar opens the `${action.screen}` fullpane in '
            'the running Crux TUI. There is no agent-side effect to '
            'trigger from here.',
        metadata: {'widgets': 1, 'ok': false, 'screen': action.screen},
      );
    }

    if (action.kind == SpecActionKind.shell) {
      final status = _statusOf(spec, projectPath);
      final rendered = renderActionCommand(action, status.data);
      final result = await runSpecShellAction(action, status.data, projectPath);
      final buf = StringBuffer()
        ..writeln('Ran ${spec.id}.$actionLabel → `$rendered`')
        ..writeln('Exit code: ${result.exitCode}');
      if (result.tail.isNotEmpty) {
        buf
          ..writeln('Output (tail):')
          ..writeln(result.tail);
      }
      return ToolResult(
        title: 'widgets trigger ${spec.id}.$actionLabel',
        output: buf.toString().trimRight(),
        metadata: {
          'widgets': 1,
          'ok': result.ok,
          'exitCode': result.exitCode,
        },
      );
    }

    final status = _statusOf(spec, projectPath);
    if (status.alive != SpecAlive.alive) {
      return ToolResult.error(
        '${spec.id} is ${status.alive.name} (${status.label}) — actions '
        'only run while the widget is alive.',
      );
    }
    final url = renderActionUrl(action, status.data);
    final ok = await sendSpecAction(action, status.data);
    return ToolResult(
      title: 'widgets trigger ${spec.id}.$actionLabel',
      output: ok
          ? 'Triggered ${spec.id}.$actionLabel → POST $url → ok'
          : 'Failed to trigger ${spec.id}.$actionLabel → POST $url '
              '(harness unreachable or non-200)',
      metadata: {'widgets': 1, 'ok': ok},
    );
  }

  SpecWidget? _byId(List<SpecWidget> specs, String? id) {
    if (id == null) return null;
    for (final spec in specs) {
      if (spec.id == id) return spec;
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
