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

  /// mtime of the watch file at our last touch — micro-throttles the
  /// touch when several surfaces poll in quick succession (e.g. the
  /// sidebar and home boxes of one instance ticking together).
  DateTime? _lastTouch;

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
    _touchWatchFile(plugin);
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

  /// Consumer-driven data collection: bump the plugin's watch file
  /// (if any) on each poll tick. A launchd `WatchPaths` agent turns
  /// that into an on-demand fetch, so the producer only runs while
  /// some Crux instance is actually RENDERING this plugin. Multiple
  /// instances touching the same file merge into one fetch via the
  /// agent's throttle. Errors are silently ignored — the watch file
  /// is an optimization signal, never load-bearing.
  void _touchWatchFile(Plugin plugin) {
    final path = plugin.touchOnPoll;
    if (path == null) return;
    final file = File(p.join(component.host.projectPath, path));
    try {
      final now = DateTime.now();
      if (_lastTouch != null &&
          now.difference(_lastTouch!) < const Duration(seconds: 8)) {
        return;
      }
      _lastTouch = now;
      if (!file.existsSync()) {
        file.createSync(recursive: true);
      }
      // A real `touch`: bump mtime, content stays empty. WatchPaths
      // fires on the metadata change alone.
      file.setLastModifiedSync(now);
    } catch (_) {
      // Unwritable location — polling still works; the producer
      // (if any) keeps its previous cadence.
    }
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
        PluginStateColor.success => theme.successColor,
        PluginStateColor.warning => theme.warningColor,
        PluginStateColor.error => theme.errorColor,
        PluginStateColor.dim => theme.onSurfaceDim,
      };
    }

    MultiButtonSegment segmentFor(PluginAction action) =>
        MultiButtonSegment(
          label: component.strings.t(action.label),
          onPressed: () => _fire(action),
        );

    // Actions available in the CURRENT liveness state (launch is
    // dead-only, http alive-only), split by the spec's chosen button
    // affordance: `segment` actions feed the hover-morph MultiButton,
    // `button` actions render always-visible standalone buttons.
    // Prompt/screen actions additionally need their host handler
    // wired (the affordance is pointless without it).
    bool available(PluginAction a) => switch (a.kind) {
          PluginActionKind.launch => !alive,
          PluginActionKind.http => alive,
          PluginActionKind.prompt => component.host.onPromptAction != null,
          PluginActionKind.screen => component.host.onScreenAction != null,
          _ => true,
        };
    final liveActions = component.plugin.actions
        .where(available)
        .toList();
    final segmentActions = liveActions
        .where((a) =>
            a.style == PluginActionStyle.segment &&
            // Screen actions always render as standalone buttons (the
            // historical behaviour): a hover-morph would hide the
            // label's content lines and make the button undiscoverable.
            a.kind != PluginActionKind.screen)
        .toList();
    final buttonActions = liveActions
        .where((a) =>
            a.style == PluginActionStyle.button ||
            a.kind == PluginActionKind.screen)
        .toList();

    final morphSegments = <MultiButtonSegment>[
      for (final action in segmentActions) segmentFor(action),
    ];
    final hasMorphActions = morphSegments.isNotEmpty;

    final spanLines = status?.spanLines ?? const <List<PluginLabelSpan>>[];
    final hasEmphasis = spanLines.any(
      (line) => line.any((s) => s.emphasize),
    );
    final emphasized = !_busy &&
        hasEmphasis &&
        (status?.color == PluginStateColor.success ||
            status?.color == PluginStateColor.error);
    final List<PluginLabelSpan> firstSpans;
    if (_busy || spanLines.isEmpty) {
      firstSpans = [(text: label, isValue: false, emphasize: false)];
    } else {
      firstSpans = spanLines.first;
    }
    final extraSpansList = spanLines.length > 1
        ? spanLines.sublist(1)
        : const <List<PluginLabelSpan>>[];

    Component spanRow(List<PluginLabelSpan> spans) {
      if (!emphasized) {
        return Text(
          spans.map((s) => s.text).join(),
          style: TextStyle(color: color),
        );
      }
      return RichText(
        text: TextSpan(
          children: [
            for (final s in spans)
              TextSpan(
                text: s.text,
                style: TextStyle(
                  color: s.emphasize ? color : theme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      );
    }

    final Component inner;
    if (_busy) {
      inner = Text(label, style: TextStyle(color: color));
    } else if (hasMorphActions) {
      // Hover-morph row: plain single-color label (the morph replaces
      // it with segments on hover, so per-value coloring buys nothing
      // here).
      inner = MultiButton(
        label: firstSpans.map((s) => s.text).join(),
        color: color,
        hoverColor: theme.foreground,
        segments: morphSegments,
      );
    } else {
      // No morph actions: the label's first line is plain text, offset
      // one column to align with what the MultiButton branch's
      // internal padding produces for ITS first line. (Continuation
      // lines below get the same +1 offset.)
      inner = Padding(
        padding: const EdgeInsets.only(left: 1),
        child: spanRow(firstSpans),
      );
    }

    // Always-visible `button`-style action buttons (spec-chosen
    // affordance via `style = "button"`), alongside the screen-action
    // buttons — all of them standalone [Button]s.
    Component standaloneButton(PluginAction action) => Padding(
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
    );
    final standaloneButtons = <Component>[
      // `buttonActions` already contains every screen action (its filter
      // is `style == button || kind == screen`), so one pass suffices.
      for (final action in buttonActions) standaloneButton(action),
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
    final todoList = _TodoScrollArea(
      todos: todos,
      onToggle: component.host.onTodoToggle,
      undoWindow: component.todoCheckedTtl,
      color: color,
    );

    // First row: with morph actions the MultiButton is the row; with a
    // plain label the content and any standalone buttons share one
    // line (e.g. `Au 4391.90/oz` … `refresh`), keeping the box compact.
    final Component firstRow;
    if (_busy || hasMorphActions) {
      firstRow = inner;
    } else if (standaloneButtons.isNotEmpty) {
      firstRow = Row(
        children: [
          inner,
          const Spacer(),
          ...standaloneButtons,
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
        for (final spans in extraSpansList)
          Padding(
            padding: const EdgeInsets.only(left: 1),
            child: spanRow(spans),
          ),
        if (hasMorphActions && standaloneButtons.isNotEmpty)
          Row(children: standaloneButtons),
      ],
    );
  }
}

/// A scroll-capped [ClickableTodoList]. The sidebar's `my-notes` box is
/// shrink-wrapped to its content, so a long todo list would push the
/// rest of the side panel off screen. This wrapper caps the list at
/// [_maxRows] visible rows and scrolls inside — count line and action
/// buttons above it stay put. The home grid box needs no such cap
/// (home already wraps every box in its own scroll area), so the plain
/// `ClickableTodoList` remains the bare renderer shared by both.
class _TodoScrollArea extends StatefulComponent {
  /// Visible-row cap before the list scrolls.
  static const _maxRows = 10;

  final List<({String text, int line})> todos;
  final void Function(String text, int line, bool done)? onToggle;
  final Duration undoWindow;
  final Color? color;

  const _TodoScrollArea({
    required this.todos,
    this.onToggle,
    required this.undoWindow,
    this.color,
  });

  @override
  State<_TodoScrollArea> createState() => _TodoScrollAreaState();
}

class _TodoScrollAreaState extends State<_TodoScrollArea> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    // Cap visible rows only when the list actually overflows — a short
    // list keeps its natural height and shows no scrollbar chrome.
    final needsScroll = component.todos.length > _TodoScrollArea._maxRows;
    if (!needsScroll) {
      return ClickableTodoList(
        todos: component.todos,
        onToggle: component.onToggle,
        undoWindow: component.undoWindow,
        color: component.color,
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: _TodoScrollArea._maxRows.toDouble()),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        thumbColor: theme.onSurfaceDim.withOpacity(0.4),
        trackColor: theme.surfaceVariant.withOpacity(0.3),
        child: SingleChildScrollView(
          controller: _controller,
          child: ClickableTodoList(
            todos: component.todos,
            onToggle: component.onToggle,
            undoWindow: component.undoWindow,
            color: component.color,
          ),
        ),
      ),
    );
  }
}
