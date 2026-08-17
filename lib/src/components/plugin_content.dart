// Shared content renderer for a spec-driven plugin — used by BOTH the
// sidebar row (PluginSidebarBox) and the home dashboard box
// (PluginHomeWidget), so a plugin renders and behaves identically
// wherever it's placed.
//
// Renders the plugin's live status (polled from its status file on the
// spec's refresh cadence) plus its actions:
//
//   alive + rule hit:  ⟳ crux dev · ✓ 16:53     hover → reload | remount | close
//   alive + no rule:   ⟳ crux dev · ●
//   stale:             ⟳ crux dev · stale       (no service segments)
//   absent:            ⟳ crux dev · not running (start segment only)
//
// The host supplies the wiring the location needs: prompt/shell/screen
// action handlers and the todo-toggle callback (all optional — absent
// handlers hide those affordances). This component never draws a
// border; the sidebar box and the home grid each supply their own
// chrome.

library;

import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../services/plugin.dart';
import '../theme/crux_theme.dart';
import '../i18n/strings.dart';
import 'ui/button.dart';
import 'ui/clickable_todo_list.dart';
import 'ui/multi_button.dart';

/// Wiring a plugin host provides. Shared by the sidebar and home
/// renderers — identical semantics everywhere.
class PluginHost {
  /// Submit a `prompt`-kind action's rendered template as a user
  /// message to the current session. Null → prompt segments hidden.
  final void Function(PluginAction action, String renderedPrompt)?
      onPromptAction;

  /// Run a `shell`-kind action's command in the project root, toast
  /// the outcome, and record it into the session context. Null → the
  /// renderer runs the command itself with no session record.
  final Future<void> Function(PluginAction action, String renderedCommand)?
      onShellAction;

  /// Open the in-process fullpane a `screen`-kind action names. Null →
  /// screen segments hidden.
  final void Function(PluginAction action)? onScreenAction;

  /// Toggle a todo row (the status JSON's `todos` array) in its
  /// backing document. Null → todo rows render as plain text.
  final void Function(String text, int line, bool done)? onTodoToggle;

  /// Record an action into the session context (agent visibility).
  final Future<void> Function(String note)? onAction;

  /// The project root the plugin's status file and commands resolve
  /// against. For global plugins this is the CURRENT project, not the
  /// spec's home-directory location.
  final String projectPath;

  const PluginHost({
    this.onPromptAction,
    this.onShellAction,
    this.onScreenAction,
    this.onTodoToggle,
    this.onAction,
    required this.projectPath,
  });
}

/// Renders one plugin's live content: status label + action buttons +
/// todo rows. Borderless — the host wraps it in chrome.
class PluginContent extends StatefulComponent {
  final Plugin plugin;
  final PluginHost host;
  final Strings strings;

  /// How long a checked todo row stays visible before disappearing.
  final Duration todoCheckedTtl;

  const PluginContent({
    super.key,
    required this.plugin,
    required this.host,
    this.todoCheckedTtl = const Duration(seconds: 10),
    this.strings = kEnglishStrings,
  });

  @override
  State<PluginContent> createState() => _PluginContentState();
}

class _PluginContentState extends State<PluginContent> {
  Timer? _timer;
  PluginStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(component.plugin.refresh, (_) => _refresh());
  }

  @override
  void didUpdateComponent(PluginContent oldComponent) {
    super.didUpdateComponent(oldComponent);
    // A different spec (registry rescan) → re-poll on its cadence.
    if (oldComponent.plugin != component.plugin) {
      _refresh();
      _timer?.cancel();
      _timer = Timer.periodic(component.plugin.refresh, (_) => _refresh());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  void _refresh() {
    final plugin = component.plugin;
    final next = evaluatePluginStatus(
      plugin,
      File(p.join(component.host.projectPath, plugin.statusPath)),
      DateTime.now(),
    );
    if (_status != null &&
        _status!.label == next.label &&
        _status!.alive == next.alive &&
        _status!.color == next.color) {
      return;
    }
    setState(() => _status = next);
  }

  Future<void> _runAction(PluginAction action) async {
    final status = _status;
    if (status == null || _busy) return;
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await sendPluginAction(action, status.data);
    } catch (_) {
      // sendPluginAction never throws; defensive.
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refresh();
      }
    }
    final url = renderActionUrl(action, status.data);
    if (action.record) {
      await component.host.onAction?.call(
        'clicked `${action.label}` on plugin `${component.plugin.id}` '
        '(POST $url → ${ok ? 'succeeded' : 'FAILED — target unreachable '
        'or non-200'})',
      );
    }
  }

  Future<void> _runLaunch(PluginAction action) async {
    final ok = await launchPluginAction(action, component.host.projectPath);
    // The service heartbeat flips the status on the next poll; refresh
    // now so the label catches up promptly.
    if (mounted) _refresh();
    if (action.record) {
      await component.host.onAction?.call(
        'clicked `${action.label}` on plugin `${component.plugin.id}` '
        '(launch `${action.command}` in a new terminal → '
        '${ok ? 'terminal opened' : 'FAILED — needs macOS + Ghostty'})',
      );
    }
  }

  Future<void> _runShell(PluginAction action) async {
    // The shell handler records its own rich result (exit code +
    // output tail); this note is just a tap marker.
    if (action.record) {
      await component.host.onAction?.call(
        'ran `${action.label}` on plugin `${component.plugin.id}` '
        '(shell: `${action.command}`)',
      );
    }
    final handler = component.host.onShellAction;
    if (handler != null) {
      final rendered = renderActionCommand(action, _status?.data ?? {});
      await handler(action, rendered);
      if (mounted) _refresh();
      return;
    }
    // No session wiring: run inline and just refresh. (Direct test
    // mounts and non-chat contexts take this path.)
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await runPluginShellAction(
        action,
        _status?.data ?? {},
        component.host.projectPath,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refresh();
      }
    }
  }

  void _fire(PluginAction action) {
    switch (action.kind) {
      case PluginActionKind.http:
        unawaited(_runAction(action));
      case PluginActionKind.launch:
        unawaited(_runLaunch(action));
      case PluginActionKind.shell:
        unawaited(_runShell(action));
      case PluginActionKind.prompt:
        final status = _status;
        final rendered = renderActionPrompt(action, status?.data ?? {});
        component.host.onPromptAction?.call(action, rendered);
      case PluginActionKind.screen:
        if (action.record) {
          unawaited(
            component.host.onAction?.call(
              'clicked `${action.label}` on plugin '
              '`${component.plugin.id}` (open screen `${action.screen}`)',
            ),
          );
        }
        component.host.onScreenAction?.call(action);
    }
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final status = _status;
    final alive = status?.alive == PluginAlive.alive && !_busy;

    String label;
    final Color color;
    if (_busy) {
      label = component.plugin.labelTemplate
          .replaceAll('{state}', '')
          .trimRight();
      label = label.isEmpty ? '…' : '$label …';
      color = theme.onSurfaceVariant;
    } else if (status == null) {
      label = component.plugin.labelTemplate;
      color = theme.onSurfaceDim;
    } else {
      label = status.label;
      color = switch (status.color) {
        PluginStateColor.normal => theme.onSurfaceVariant,
        PluginStateColor.warning => theme.warningColor,
        PluginStateColor.error => theme.errorColor,
        PluginStateColor.dim => theme.onSurfaceDim,
      };
    }

    // Actions split by kind: http actions control a *running* service
    // (reload/remount/close), launch actions start a *dead* one, and
    // prompt/shell/screen actions (quick actions) are available in any
    // liveness state.
    final launchActions = component.plugin.actions
        .where((a) => a.kind == PluginActionKind.launch)
        .toList();
    final controlActions = component.plugin.actions
        .where((a) => a.kind == PluginActionKind.http)
        .toList();
    final promptActions = component.host.onPromptAction == null
        ? const <PluginAction>[]
        : component.plugin.actions
            .where((a) => a.kind == PluginActionKind.prompt)
            .toList();
    final shellActions = component.plugin.actions
        .where((a) => a.kind == PluginActionKind.shell)
        .toList();
    final screenActions = component.host.onScreenAction == null
        ? const <PluginAction>[]
        : component.plugin.actions
            .where((a) => a.kind == PluginActionKind.screen)
            .toList();

    MultiButtonSegment segmentFor(PluginAction action) =>
        MultiButtonSegment(
          label: component.strings.t(action.label),
          onPressed: () => _fire(action),
        );

    // Screen actions are pure UI entry points (open a fullpane), not
    // controls on a running service. Rendering them as hover-reveal
    // MultiButton segments would hide the label's content lines on
    // hover and make the button undiscoverable at rest — so they get
    // permanent, always-visible [Button]s instead. Service-control
    // kinds (http/launch/prompt/shell) keep the hover-morph MultiButton.
    final hasMorphActions = launchActions.isNotEmpty ||
        controlActions.isNotEmpty ||
        promptActions.isNotEmpty ||
        shellActions.isNotEmpty;

    // The label's first line feeds the MultiButton (when there are
    // morph actions) so a single-line service plugin renders exactly
    // as before; continuation lines render below. When there are NO
    // morph actions the label renders entirely as static text (the
    // common case for a content plugin like notes), so nothing is ever
    // collapsed by a hover morph.
    final labelLines = status?.labelLines ?? const <String>[];
    final firstLine = labelLines.isEmpty ? label : labelLines.first;
    final extraLines =
        labelLines.length > 1 ? labelLines.sublist(1) : const <String>[];

    final Component inner;
    if (_busy) {
      inner = Text(label, style: TextStyle(color: color));
    } else if (hasMorphActions) {
      final segments = <MultiButtonSegment>[
        if (!alive)
          for (final action in launchActions) segmentFor(action),
        if (alive)
          for (final action in controlActions) segmentFor(action),
        for (final action in promptActions) segmentFor(action),
        for (final action in shellActions) segmentFor(action),
      ];
      inner = MultiButton(
        label: firstLine,
        color: color,
        hoverColor: theme.foreground,
        segments: segments,
      );
    } else {
      // No morph actions: the label's first line is plain text. (Any
      // continuation lines are appended below, next to the button row.)
      inner = Text(firstLine, style: TextStyle(color: color));
    }

    // Always-visible screen-action buttons, one per `screen` action.
    final screenButtons = <Component>[
      for (final action in screenActions)
        Padding(
          padding: const EdgeInsets.only(right: 1),
          child: Button(
            label: component.strings.t(action.label),
            onPressed: () => _fire(action),
            color: theme.accent,
            hoverColor: theme.buttonTextHover,
            bgColor: theme.surfaceVariant,
            hoverBgColor: theme.buttonBackgroundHover,
            padding: const EdgeInsets.symmetric(horizontal: 1),
          ),
        ),
    ];

    // Clickable todo rows, driven by the status JSON's `todos` array
    // (`[{text, line}]`). Reuses the shared [ClickableTodoList]:
    // clicking an open row marks it done (flips to checked locally,
    // stays for the undo window), clicking a checked row restores it.
    final todos = <({String text, int line})>[];
    final rawTodos = status?.data['todos'];
    if (rawTodos is List) {
      for (final raw in rawTodos) {
        if (raw is! Map) continue;
        final text = raw['text']?.toString() ?? '';
        final line = raw['line'] is num ? (raw['line'] as num).toInt() : -1;
        if (text.isEmpty) continue;
        todos.add((text: text, line: line));
      }
    }
    final todoList = ClickableTodoList(
      todos: todos,
      onToggle: component.host.onTodoToggle,
      undoWindow: component.todoCheckedTtl,
      color: color,
    );

    // First row: with morph actions the MultiButton is the row; with a
    // plain label the count text and any screen buttons share one line
    // (e.g. `1 todo` … `open`), keeping the box compact.
    final Component firstRow;
    if (_busy || hasMorphActions) {
      firstRow = inner;
    } else if (screenButtons.isNotEmpty) {
      firstRow = Row(
        children: [
          inner,
          const Spacer(),
          ...screenButtons,
        ],
      );
    } else {
      firstRow = inner;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        firstRow,
        todoList,
        for (final line in extraLines)
          Text(line, style: TextStyle(color: color)),
        if (hasMorphActions && screenButtons.isNotEmpty)
          Row(children: screenButtons),
      ],
    );
  }
}
