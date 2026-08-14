// Generic renderer for a spec-driven sidebar widget (Phase B).
//
// Renders one row per [SpecWidget]: a status label plus a [MultiButton]
// whose segments come from the spec's actions. The widget polls the
// spec's status source on its own refresh cadence and recomputes the
// label from the spec's state rules, so a spec file written by any
// session renders live — no crux rebuild, no restart.
//
//   alive + rule hit:  ⟳ crux dev · ✓ 16:53     hover → reload | remount | close
//   alive + no rule:   ⟳ crux dev · ●
//   stale:             ⟳ crux dev · stale       (no segments)
//   absent:            ⟳ crux dev · not running (no segments)

library;

import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../services/spec_widget.dart';
import '../theme/crux_theme.dart';
import '../i18n/strings.dart';
import 'ui/button.dart';
import 'ui/clickable_todo_list.dart';
import 'ui/multi_button.dart';

class SpecSidebarWidget extends StatefulComponent {
  final SpecWidget spec;
  final String projectPath;

  /// Called when the user clicks a [SpecActionKind.prompt] segment —
  /// the chat panel submits the rendered message to the current
  /// session. When null, prompt segments are not rendered (tests /
  /// contexts with no chat to submit to).
  final void Function(SpecAction action, String renderedPrompt)?
      onPromptAction;

  /// Called when the user clicks a [SpecActionKind.shell] segment —
  /// the chat panel runs [renderedCommand] in the project root,
  /// surfaces the result as a toast, and records it into the session
  /// context. When null, the widget runs the command itself and shows
  /// no session record (tests / contexts with no chat wiring).
  final Future<void> Function(SpecAction action, String renderedCommand)?
      onShellAction;

  /// Called when the user clicks a [SpecActionKind.screen] segment —
  /// the host opens the named in-process fullpane (e.g. the notes
  /// editor). When null, screen segments are not rendered (tests /
  /// contexts with no fullpane host).
  final void Function(SpecAction action)? onScreenAction;

  /// Called when the user clicks a todo row rendered from the status
  /// JSON's `todos` array (each entry `{text, line}` — the todo's text
  /// and its source line index in the note). [done] is `true` when the
  /// row was clicked to mark it done, `false` when it was clicked again
  /// inside the undo window to restore it. The host persists the change;
  /// the row flips to checked locally ([todoCheckedTtl] later removes
  /// it). When null, todo rows render as plain (non-clickable) text.
  final void Function(String text, int line, bool done)? onTodoToggle;

  /// How long a checked todo row stays visible in the widget before
  /// disappearing, giving the user time to undo an accidental click.
  /// Clicking the checked row again inside this window restores it.
  final Duration todoCheckedTtl;

  /// Called after ANY action fires (http / launch / shell / prompt) —
  /// a human-readable description of what the user did AND how it
  /// went, for recording into the session context. Awaited: http and
  /// launch call it after the action resolves so the note carries the
  /// outcome; shell and prompt have their own richer records and use
  /// this only as a lightweight tap marker. When null, nothing is
  /// recorded.
  final Future<void> Function(String note)? onAction;
  final Strings strings;

  const SpecSidebarWidget({
    super.key,
    required this.spec,
    required this.projectPath,
    this.onPromptAction,
    this.onShellAction,
    this.onScreenAction,
    this.onTodoToggle,
    this.todoCheckedTtl = const Duration(seconds: 10),
    this.onAction,
    this.strings = kEnglishStrings,
  });

  @override
  State<SpecSidebarWidget> createState() => _SpecSidebarWidgetState();
}

class _SpecSidebarWidgetState extends State<SpecSidebarWidget> {
  Timer? _timer;
  SpecWidgetStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(component.spec.refresh, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  void _refresh() {
    final spec = component.spec;
    final next = evaluateSpecStatus(
      spec,
      File(p.join(component.projectPath, spec.statusPath)),
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

  Future<void> _runAction(SpecAction action) async {
    final status = _status;
    if (status == null || _busy) return;
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await sendSpecAction(action, status.data);
    } catch (_) {
      // sendSpecAction never throws; defensive.
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refresh();
      }
    }
    final url = renderActionUrl(action, status.data);
    if (action.record) {
      await component.onAction?.call(
        'clicked `${action.label}` on widget `${component.spec.id}` '
        '(POST $url → ${ok ? 'succeeded' : 'FAILED — target unreachable '
        'or non-200'})',
      );
    }
  }

  Future<void> _runLaunch(SpecAction action) async {
    final ok = await launchSpecAction(action, component.projectPath);
    // The harness heartbeat will flip the status to alive on the next
    // poll; refresh now so the label catches up promptly.
    if (mounted) _refresh();
    if (action.record) {
      await component.onAction?.call(
        'clicked `${action.label}` on widget `${component.spec.id}` '
        '(launch `${action.command}` in a new terminal → '
        '${ok ? 'terminal opened' : 'FAILED — needs macOS + Ghostty'})',
      );
    }
  }

  Future<void> _runShell(SpecAction action) async {
    // The shell handler records its own rich result (exit code +
    // output tail); this note is just a tap marker. The inline
    // no-handler path has no session to record into anyway.
    if (action.record) {
      await component.onAction?.call(
        'ran `${action.label}` on widget `${component.spec.id}` '
        '(shell: `${action.command}`)',
      );
    }
    final handler = component.onShellAction;
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
      await runSpecShellAction(
        action,
        _status?.data ?? {},
        component.projectPath,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _refresh();
      }
    }
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final status = _status;
    final alive = status?.alive == SpecAlive.alive && !_busy;

    String label;
    final Color color;
    if (_busy) {
      label = component.spec.labelTemplate
          .replaceAll('{state}', '')
          .trimRight();
      label = label.isEmpty ? '…' : '$label …';
      color = theme.onSurfaceVariant;
    } else if (status == null) {
      label = component.spec.labelTemplate;
      color = theme.onSurfaceDim;
    } else {
      label = status.label;
      color = switch (status.color) {
        SpecStateColor.normal => theme.onSurfaceVariant,
        SpecStateColor.warning => theme.warningColor,
        SpecStateColor.error => theme.errorColor,
        SpecStateColor.dim => theme.onSurfaceDim,
      };
    }

    // Actions split by kind: http actions control a *running* service
    // (reload/remount/close), launch actions start a *dead* one, and
    // prompt actions (quick actions) submit a message to the current
    // session — available in any liveness state. Alive shows http +
    // prompt segments; dead shows launch + prompt; a monitor with only
    // prompt actions always shows its buttons.
    final launchActions = component.spec.actions
        .where((a) => a.kind == SpecActionKind.launch)
        .toList();
    final controlActions = component.spec.actions
        .where((a) => a.kind == SpecActionKind.http)
        .toList();
    final promptActions = component.onPromptAction == null
        ? const <SpecAction>[]
        : component.spec.actions
            .where((a) => a.kind == SpecActionKind.prompt)
            .toList();
    final shellActions = component.spec.actions
        .where((a) => a.kind == SpecActionKind.shell)
        .toList();
    final screenActions = component.onScreenAction == null
        ? const <SpecAction>[]
        : component.spec.actions
            .where((a) => a.kind == SpecActionKind.screen)
            .toList();

    MultiButtonSegment promptSegment(SpecAction action) =>
        MultiButtonSegment(
          label: component.strings.t(action.label),
          onPressed: () {
            final status = _status;
            final rendered = renderActionPrompt(action, status?.data ?? {});
            component.onPromptAction?.call(action, rendered);
          },
        );

    MultiButtonSegment shellSegment(SpecAction action) =>
        MultiButtonSegment(
          label: component.strings.t(action.label),
          onPressed: () => unawaited(_runShell(action)),
        );

    void fireScreen(SpecAction action) {
      // Opening a screen is a pure-UI action; only record the tap when
      // the spec asked for it (`record = true`, the default). The notes
      // widget sets `record = false` so the click stays silent.
      if (action.record) {
        unawaited(
          component.onAction?.call(
            'clicked `${action.label}` on widget '
            '`${component.spec.id}` (open screen `${action.screen}`)',
          ),
        );
      }
      component.onScreenAction?.call(action);
    }

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
    // morph actions) so a single-line service widget renders exactly as
    // before; continuation lines render below. When there are NO morph
    // actions the label renders entirely as static text (the common
    // case for a content widget like notes), so nothing is ever
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
          for (final action in launchActions)
            MultiButtonSegment(
          label: component.strings.t(action.label),
              onPressed: () => unawaited(_runLaunch(action)),
            ),
        if (alive)
          for (final action in controlActions)
            MultiButtonSegment(
          label: component.strings.t(action.label),
              onPressed: () => unawaited(_runAction(action)),
            ),
        for (final action in promptActions) promptSegment(action),
        for (final action in shellActions) shellSegment(action),
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
            onPressed: () => fireScreen(action),
            color: theme.accent,
            hoverColor: theme.buttonTextHover,
            bgColor: theme.surfaceVariant,
            hoverBgColor: theme.buttonBackgroundHover,
            padding: const EdgeInsets.symmetric(horizontal: 1),
          ),
        ),
    ];

    // Clickable todo rows, driven by the status JSON's `todos` array
    // (`[{text, line}]` — the todo's text and its source line index in
    // the underlying document). Reuses the shared [ClickableTodoList]
    // (identical interaction to the home dashboard box): clicking an
    // open row marks it done (flips to checked locally, stays for
    // [SpecSidebarWidget.todoCheckedTtl] as the undo window), clicking
    // a checked row restores it.
    final todos = <({String text, int line})>[];
    final rawTodos = status?.data['todos'];
    if (rawTodos is List) {
      for (final raw in rawTodos) {
        if (raw is! Map) continue;
        final text = raw['text']?.toString() ?? '';
        final line =
            raw['line'] is num ? (raw['line'] as num).toInt() : -1;
        if (text.isEmpty) continue;
        todos.add((text: text, line: line));
      }
    }
    final todoRows = <Component>[
      ClickableTodoList(
        todos: todos,
        onToggle: component.onTodoToggle,
        undoWindow: component.todoCheckedTtl,
        color: color,
      ),
    ];

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

    // Every spec widget renders as its own full-width bordered box
    // with the title inlined on the border (same chrome as the home
    // grid's boxes), using theme colors throughout.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _labelIntrinsicWidth(label);
        return Container(
          width: width,
          decoration: BoxDecoration(
            color: theme.surface,
            border: BoxBorder.all(
              color: theme.outline,
              style: BoxBorderStyle.rounded,
            ),
            title: BorderTitle(
              text: component.strings.t(component.spec.title),
              style: TextStyle(
                color: theme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              firstRow,
              ...todoRows,
              for (final line in extraLines)
                Text(line, style: TextStyle(color: color)),
              if (hasMorphActions && screenButtons.isNotEmpty)
                Row(children: screenButtons),
            ],
          ),
        );
      },
    );
  }

  /// Fallback intrinsic width for the bordered box when the parent
  /// leaves the width unconstrained (direct test mounts).
  static double _labelIntrinsicWidth(String label) =>
      label.runes.length + 2; // +2 for the border columns
}
