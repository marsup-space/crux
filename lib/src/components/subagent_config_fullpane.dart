import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import '../models/subagent.dart';
import '../services/subagent/subagent_config_store.dart';
import '../services/subagent/subagent_controller.dart';
import '../services/subagent/worker_name_localizer.dart';
import '../theme/crux_theme.dart';
import '../utils/terminal_symbols.dart';
import 'ui/button.dart';
import 'ui/fullpane.dart';
import 'ui/hoverable.dart';
import 'ui/multi_button.dart';

/// The subagent configuration fullpane — opened from the home
/// `subagent-pool` box (Enter) or the `subagent-config` plugin's
/// `screen` action.
///
/// Layout (nocterm components throughout — buttons, hoverable rows,
/// bordered titled containers; no hand-rolled key handling):
///
///   ┌                          ● unsaved  [Save] ⏎ ┐
///   ├───────────────────────────────────────────────┤
///   │ ┌ ✎ workers pool (2) ─┐  ┌ ✦ experts pool ─┐   │
///   │ │ model ×N  − + del  │  │ model ×N  − + del│  │
///   │ │ [+ add model]      │  │ [+ add model]    │  │
///   │ └────────────────────┘  └──────────────────┘  │
///   ├───────────────────────────────────────────────┤
///   │ Roster — one hoverable row per agent, `delete` segment │
///   └───────────────────────────────────────────────┘
///
/// The workers / experts MODE SWITCHES are deliberately absent here:
/// they are per-session state (sessions.subagent_workers_on /
/// subagent_experts_on) with their own always-mounted home in the agent
/// bar above the toolbar (`SubagentBar`) and in the home
/// `subagent-pool` box. This pane owns only the global model pools — the
/// one thing that is genuinely config.toml — plus the roster.
///
/// Pool edits are copy-on-edit: the in-editor lists diverge from the
/// persisted config until `Ctrl+S` / the Save button, so a
/// half-edited pool never reaches hire's model picker.
class SubagentConfigFullpane extends StatefulComponent {
  final SubagentController controller;

  /// Save path for the model pools — the same config.toml whose
  /// `[subagent]` section holds the global default switches.
  final SubagentConfigStore configStore;

  /// Configured providers' models as `provider/model` composite keys
  /// with display labels — the add-entry picker's options.
  final List<({String key, String label})> availableModels;

  /// Read-only roster rows (agents table + live busy flags). Read on
  /// open and after each save / delete.
  final Future<List<SubagentRosterEntry>> Function() loadRoster;

  /// Deletes one roster row by name (refuses busy agents at the UI
  /// layer; the fullpane only calls it for non-busy rows).
  final Future<void> Function(String name) deleteAgent;

  final VoidCallback onClose;
  final Strings strings;

  const SubagentConfigFullpane({
    super.key,
    required this.controller,
    required this.configStore,
    required this.availableModels,
    required this.loadRoster,
    required this.deleteAgent,
    required this.onClose,
    this.strings = kEnglishStrings,
  });

  @override
  State<SubagentConfigFullpane> createState() => _SubagentConfigFullpaneState();
}

class _SubagentConfigFullpaneState extends State<SubagentConfigFullpane> {
  /// The in-editor pool lists (copy-on-edit; Save persists).
  final Map<SubagentRole, List<SubagentModelEntry>> _pools = {
    SubagentRole.worker: [],
    SubagentRole.expert: [],
  };

  /// Which pool the model picker is open for, if any.
  SubagentRole? _pickingFor;

  /// Keyboard cursor row inside the picker (mouse clicks bypass it).
  int _pickRow = 0;

  bool _dirty = false;
  bool _savedFlash = false;
  List<SubagentRosterEntry> _roster = const [];

  SubagentController get _controller => component.controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await component.configStore.readPools();
    if (!mounted) return;
    setState(() {
      _pools[SubagentRole.worker] = [...config.workers.models];
      _pools[SubagentRole.expert] = [...config.experts.models];
      _dirty = false;
    });
    await _reloadRoster();
  }

  Future<void> _reloadRoster() async {
    final roster = await component.loadRoster();
    if (!mounted) return;
    setState(() => _roster = roster);
  }

  Future<void> _save() async {
    await component.configStore.writePools(
      SubagentConfig(
        workers: SubagentModelConfig(models: _pools[SubagentRole.worker]!),
        experts: SubagentModelConfig(models: _pools[SubagentRole.expert]!),
      ),
    );
    // The manager's hire path reads pools through the controller's
    // cache — refresh it so new pools are dispatchable immediately.
    await _controller.reloadPools();
    if (!mounted) return;
    setState(() {
      _dirty = false;
      _savedFlash = true;
    });
    // Let the flash fade on the next interaction batch; a Timer adds
    // import churn for little value — the flag resets on any edit.
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _savedFlash = false);
    });
    await _reloadRoster();
  }

  // ── pool edits (each marks dirty; Save persists) ─────────────

  void _addModel(SubagentRole role, String key) {
    setState(() {
      _pools[role]!.add(SubagentModelEntry(model: key, concurrency: 2));
      _dirty = true;
      _pickingFor = null;
    });
  }

  void _removeEntry(SubagentRole role, int index) {
    setState(() {
      _pools[role]!.removeAt(index);
      _dirty = true;
    });
  }

  void _bumpConcurrency(SubagentRole role, int index, int delta) {
    final list = _pools[role]!;
    final entry = list[index];
    final next = entry.concurrency + delta;
    if (next < 1 || next > 64) return;
    setState(() {
      list[index] = SubagentModelEntry(model: entry.model, concurrency: next);
      _dirty = true;
    });
  }

  Future<void> _deleteRosterEntry(SubagentRosterEntry entry) async {
    if (entry.busy) return;
    await component.deleteAgent(entry.name);
    await _reloadRoster();
  }

  // ── keyboard (picker navigation only — everything else is UI) ─

  bool _handleKey(KeyboardEvent event) {
    if (_pickingFor == null) return false;
    final options = component.availableModels;
    final key = event.logicalKey;
    if (key == LogicalKey.escape) {
      setState(() => _pickingFor = null);
      return true;
    }
    if (key == LogicalKey.arrowUp && _pickRow > 0) {
      setState(() => _pickRow--);
      return true;
    }
    if (key == LogicalKey.arrowDown && _pickRow < options.length - 1) {
      setState(() => _pickRow++);
      return true;
    }
    if (key == LogicalKey.enter && options.isNotEmpty) {
      _addModel(
        _pickingFor!,
        options[_pickRow.clamp(0, options.length - 1)].key,
      );
      return true;
    }
    return false;
  }

  // ── render ─────────────────────────────────────────────────────

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final s = component.strings;
    return Fullpane(
      title: s.t('subagent.config.title'),
      onClose: component.onClose,
      strings: s,
      onKeyEvent: _handleKey,
      shortcuts: [
        FullpaneShortcut(
          label: s.t('subagent.config.save'),
          keyHint: 'Ctrl+S',
          matches: (e) => e.logicalKey == LogicalKey.keyS && e.isControlPressed,
          onActivate: () {
            if (_dirty) _save();
          },
        ),
      ],
      contentBuilder: (context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _actionsRow(theme, s),
              Divider(color: theme.outline, height: 1),
              _pickingFor == null
                  ? _poolsRow(theme, s)
                  : _pickerPanel(theme, s),
              Divider(color: theme.outline, height: 1),
              _rosterSection(theme, s),
            ],
          ),
        ),
      ),
    );
  }

  /// Top row: dirty/saved indicator + the Save button. The mode
  /// switches live in the agent bar (per-session, always mounted), so
  /// this pane does not mirror them.
  Component _actionsRow(CruxThemeData theme, Strings s) {
    return Row(
      children: [
        const Spacer(),
        if (_dirty)
          Text(
            s.t('subagent.config.unsaved'),
            style: TextStyle(color: theme.warning),
          )
        else if (_savedFlash)
          Text(
            s.t('subagent.config.saved'),
            style: TextStyle(color: theme.success),
          ),
        const SizedBox(width: 1),
        Button(
          label: _dirty
              ? '⏎ ${s.t('subagent.config.save')}'
              : s.t('subagent.config.save'),
          onPressed: _dirty ? _save : null,
          color: _dirty ? theme.success : theme.onSurfaceDim,
          hoverColor: theme.foreground,
          bgColor: theme.surface,
          hoverBgColor: theme.buttonBackgroundHover,
        ),
      ],
    );
  }

  /// The two pool columns, side by side — workers left, experts
  /// right. Each column is a bordered titled container listing its
  /// model entries as MultiButtons (hover exposes `− + del`) plus an
  /// add-model button at the bottom.
  Component _poolsRow(CruxThemeData theme, Strings s) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _poolColumn(
            theme,
            s,
            role: SubagentRole.worker,
            glyph: '✎',
            title: s.t('subagent.bar.workers'),
          ),
        ),
        const SizedBox(width: 1),
        Expanded(
          child: _poolColumn(
            theme,
            s,
            role: SubagentRole.expert,
            glyph: '✦',
            title: s.t('subagent.bar.experts'),
          ),
        ),
      ],
    );
  }

  Component _poolColumn(
    CruxThemeData theme,
    Strings s, {
    required SubagentRole role,
    required String glyph,
    required String title,
  }) {
    final entries = _pools[role]!;
    return Container(
      decoration: BoxDecoration(
        color: theme.surface,
        border: BoxBorder.all(
          color: theme.outline,
          style: BoxBorderStyle.rounded,
        ),
        title: BorderTitle(
          text: '$glyph $title (${entries.length})',
          style: TextStyle(
            color: theme.onSurfaceDim,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (entries.isEmpty)
            Text(
              s.t('subagent.config.poolEmpty'),
              style: TextStyle(color: theme.onSurfaceDim),
            )
          else
            // Entry rows sit flush against each other — the hover pills
            // are the visual separators, so per-row bottom padding would
            // only scatter blank lines through the pool.
            for (var i = 0; i < entries.length; i++)
              _poolEntryRow(theme, s, role: role, index: i),
          // One blank row separates the entry list from the add button.
          const SizedBox(height: 1),
          Button(
            label: '+ ${s.t('subagent.config.addModel')}',
            onPressed: () => setState(() {
              _pickingFor = role;
              _pickRow = 0;
            }),
            color: theme.accent,
            hoverColor: theme.foreground,
            bgColor: theme.surface,
            hoverBgColor: theme.buttonBackgroundHover,
          ),
        ],
      ),
    );
  }

  /// One model entry: `provider/model ×N` with hover segments to
  /// decrement / increment concurrency and remove the entry.
  Component _poolEntryRow(
    CruxThemeData theme,
    Strings s, {
    required SubagentRole role,
    required int index,
  }) {
    final entry = _pools[role]![index];
    return MultiButton(
      label: '${entry.model} ×${entry.concurrency}',
      color: theme.onSurface,
      hoverColor: theme.foreground,
      bgColor: theme.surface,
      hoverBgColor: theme.buttonBackgroundHover,
      segments: [
        MultiButtonSegment(
          label: '−',
          onPressed: () => _bumpConcurrency(role, index, -1),
        ),
        MultiButtonSegment(
          label: '+',
          onPressed: () => _bumpConcurrency(role, index, 1),
        ),
        MultiButtonSegment(
          label: s.t('subagent.config.remove'),
          onPressed: () => _removeEntry(role, index),
        ),
      ],
    );
  }

  /// Full-width model picker (replaces the pools row while open):
  /// one hoverable clickable row per configured model, a cancel
  /// button, and keyboard ↑↓/Enter/Esc for terminal purists.
  Component _pickerPanel(CruxThemeData theme, Strings s) {
    final options = component.availableModels;
    final role = _pickingFor!;
    final roleLabel = role == SubagentRole.worker
        ? '✎ ${s.t('subagent.bar.workers')}'
        : '✦ ${s.t('subagent.bar.experts')}';
    return Container(
      decoration: BoxDecoration(
        color: theme.surface,
        border: BoxBorder.all(
          color: theme.accent,
          style: BoxBorderStyle.rounded,
        ),
        title: BorderTitle(
          text: '${s.t('subagent.config.pickModel')} → $roleLabel',
          style: TextStyle(color: theme.accent, fontWeight: FontWeight.bold),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (options.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 1),
              child: Text(
                s.t('subagent.config.noModels'),
                style: TextStyle(color: theme.onSurfaceDim),
              ),
            )
          else
            for (var i = 0; i < options.length; i++)
              _pickerRow(
                theme,
                index: i,
                label: options[i].label.isEmpty
                    ? options[i].key
                    : '${options[i].label}  (${options[i].key})',
                onPick: () => _addModel(role, options[i].key),
              ),
          Button(
            label: '✕ ${s.t('chat.notes.close')}',
            onPressed: () => setState(() => _pickingFor = null),
            color: theme.hintText,
            hoverColor: theme.foreground,
            bgColor: theme.surface,
            hoverBgColor: theme.buttonBackgroundHover,
          ),
        ],
      ),
    );
  }

  Component _pickerRow(
    CruxThemeData theme, {
    required int index,
    required String label,
    required VoidCallback onPick,
  }) {
    final selected = index == _pickRow;
    return Hoverable(
      onTap: onPick,
      builder: (context, hovered) {
        // Reading _pickRow via the closure keeps hover cheap; the
        // keyboard cursor just recolors the row via selected.
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          color: hovered
              ? theme.buttonBackgroundHover
              : (selected ? theme.buttonBackgroundFocused : null),
          child: Row(
            children: [
              Text(
                selected ? '▸ ' : '  ',
                style: TextStyle(color: theme.accent),
              ),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: hovered || selected
                        ? theme.foreground
                        : theme.onSurface,
                    fontWeight: hovered || selected ? FontWeight.bold : null,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Roster row label: role glyph + localized constellation name, the
  /// same language as the agent bar / chat chip (`✎ 天燕座`). The glyph
  /// goes through [terminalSymbol] so 7-bit terminals degrade like the
  /// chip; the name is localized via [WorkerNameLocalizer] (unknown
  /// legacy names pass through unchanged). Status/domain/model follow.
  String _rosterLabel(SubagentRosterEntry entry, Strings s) {
    final expert = entry.role == 'expert';
    final glyph = terminalSymbol(expert ? '✦' : '✎', expert ? '*' : '>');
    final name = const WorkerNameLocalizer().display(entry.name, s.locale);
    final status = entry.busy
        ? s.t('subagent.pool.busy')
        : s.t('subagent.pool.ready');
    return '$glyph $name · $status · ${entry.domain} · ${entry.model}';
  }

  /// Bottom section: every roster agent as a hoverable row with a
  /// `delete` segment. Busy agents show a disabled delete (the run
  /// owns them until it ends).
  Component _rosterSection(CruxThemeData theme, Strings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 1),
          child: Text(
            s.t('subagent.config.roster'),
            style: TextStyle(
              color: theme.onSurfaceDim,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (_roster.isEmpty)
          Text(
            s.t('subagent.pool.empty'),
            style: TextStyle(color: theme.onSurfaceDim),
          )
        else
          // Roster rows are flush: no blank line between agents, only
          // the header keeps its own gap above the list.
          for (final entry in _roster)
            MultiButton(
              label: _rosterLabel(entry, s),
              color: entry.busy ? theme.success : theme.onSurface,
              hoverColor: theme.foreground,
              disabledColor: theme.onSurfaceDim,
              bgColor: theme.surface,
              hoverBgColor: theme.buttonBackgroundHover,
              segments: [
                MultiButtonSegment(
                  label: s.t('subagent.config.delete'),
                  onPressed: entry.busy
                      ? null
                      : () => _deleteRosterEntry(entry),
                ),
              ],
            ),
      ],
    );
  }
}
