import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../i18n/strings.dart';
import '../models/subagent.dart';
import '../services/subagent/subagent_config_store.dart';
import '../services/subagent/subagent_controller.dart';
import '../theme/crux_theme.dart';
import 'ui/fullpane.dart';

/// The subagent configuration fullpane — model pools + switches +
/// roster, opened from the home `subagent-pool` box (Enter) or the
/// `subagent-config` plugin's `screen` action.
///
/// Layout (three stacked regions; Tab cycles, keys act per region):
///
///   ┌ switches ──────────────┐  `w` / `e` flip workers / experts;
///   │                        │  persists immediately via the controller
///   ├ model pools ───────────┤  BOTH pools visible, stacked:
///   │  ✎ workers             │    one row per model entry
///   │    ▸ provider/m · ×N   │    (`provider/model · ×concurrency`)
///   │  ✦ experts             │  one shared cursor walks workers then
///   │    ▸ provider/m · ×N   │    experts (↓ at the end crosses over);
///   │                        │  `a` add (inline model picker) into the
///   │                        │  cursor's pool, `d` delete the selected
///   │                        │  row, `+`/`-` adjust concurrency,
///   │                        │  `Ctrl+S` saves to config.toml
///   └ roster ────────────────┘  read-only rows (✎/✦ name state domain),
///                               refreshed on open and after each save
///
/// Pool edits are copy-on-edit: the in-editor lists diverge from the
/// persisted config until `Ctrl+S`, so a half-edited pool never
/// reaches hire's model picker.
class SubagentConfigFullpane extends StatefulComponent {
  final SubagentController controller;

  /// Save path for the model pools — the same config.toml the
  /// controller's toggles live in.
  final SubagentConfigStore configStore;

  /// Configured providers' models as `provider/model` composite keys
  /// with display labels — the add-entry picker's options.
  final List<({String key, String label})> availableModels;

  /// Read-only roster rows (agents table + live busy flags). Read on
  /// open and after each pool save.
  final Future<List<SubagentRosterEntry>> Function() loadRoster;

  final VoidCallback onClose;
  final Strings strings;

  const SubagentConfigFullpane({
    super.key,
    required this.controller,
    required this.configStore,
    required this.availableModels,
    required this.loadRoster,
    required this.onClose,
    this.strings = kEnglishStrings,
  });

  @override
  State<SubagentConfigFullpane> createState() => _SubagentConfigFullpaneState();
}

enum _Region { switches, pools, roster }

class _SubagentConfigFullpaneState extends State<SubagentConfigFullpane> {
  _Region _region = _Region.switches;

  /// The in-editor pool lists (copy-on-edit; Ctrl+S persists).
  final Map<SubagentRole, List<SubagentModelEntry>> _pools = {
    SubagentRole.worker: [],
    SubagentRole.expert: [],
  };

  /// The shared pool cursor: which pool the cursor is in, and which
  /// row within it. Arrow-down past the last worker row moves into
  /// the experts pool (and vice versa) — both pools are one list to
  /// the keyboard.
  SubagentRole _cursorRole = SubagentRole.worker;
  int _cursorRow = 0;

  bool _dirty = false;
  bool _picking = false;
  int _pickRow = 0;
  bool _savedFlash = false;
  Timer? _flashTimer;
  List<SubagentRosterEntry> _roster = const [];

  SubagentController get _controller => component.controller;

  List<SubagentModelEntry> get _cursorPool => _pools[_cursorRole]!;

  @override
  void initState() {
    super.initState();
    _load();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final config = await component.configStore.readPools();
    if (!mounted) return;
    setState(() {
      _pools[SubagentRole.worker] = [...config.workers.models];
      _pools[SubagentRole.expert] = [...config.experts.models];
      _dirty = false;
      _clampCursor();
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
    if (!mounted) return;
    setState(() {
      _dirty = false;
      _savedFlash = true;
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _savedFlash = false);
    });
    await _reloadRoster();
  }

  /// Keep the cursor inside the pools' actual bounds after edits.
  void _clampCursor() {
    if (_cursorRow >= _cursorPool.length) {
      _cursorRow = _cursorPool.isEmpty ? 0 : _cursorPool.length - 1;
    }
  }

  // ── keyboard ───────────────────────────────────────────────────

  bool _handleKey(KeyboardEvent event) {
    final key = event.logicalKey;

    // Ctrl+S — save from anywhere in the pane.
    if (key == LogicalKey.keyS && event.isControlPressed) {
      if (_dirty) unawaited(_save());
      return true;
    }

    if (_picking) return _handlePickerKey(key);

    switch (key) {
      case LogicalKey.tab:
        setState(() {
          _region = _Region.values[(_region.index + 1) % _Region.values.length];
        });
        return true;
      case LogicalKey.keyW:
        unawaited(
          _controller.setToggle(SubagentRole.worker, !_controller.workersOn),
        );
        return true;
      case LogicalKey.keyE:
        unawaited(
          _controller.setToggle(SubagentRole.expert, !_controller.expertsOn),
        );
        return true;
    }
    if (_region == _Region.pools) return _handlePoolKey(key);
    return false;
  }

  bool _handlePickerKey(LogicalKey key) {
    final options = component.availableModels;
    if (key == LogicalKey.escape) {
      setState(() => _picking = false);
      return true;
    }
    if (key == LogicalKey.arrowUp) {
      if (_pickRow > 0) setState(() => _pickRow--);
      return true;
    }
    if (key == LogicalKey.arrowDown) {
      if (_pickRow < options.length - 1) setState(() => _pickRow++);
      return true;
    }
    if (key == LogicalKey.enter) {
      if (options.isEmpty) return true;
      final chosen = options[_pickRow.clamp(0, options.length - 1)];
      setState(() {
        _cursorPool.add(
          SubagentModelEntry(model: chosen.key, concurrency: 2),
        );
        _cursorRow = _cursorPool.length - 1;
        _picking = false;
        _dirty = true;
      });
      return true;
    }
    return false;
  }

  bool _handlePoolKey(LogicalKey key) {
    final workers = _pools[SubagentRole.worker]!;

    // Shared cursor across the two pools: ↓ past the last row of one
    // pool lands on the first row of the other; ↑ past the first row
    // of the second pool returns to the last row of the first.
    if (key == LogicalKey.arrowDown) {
      if (_cursorRow < _cursorPool.length - 1) {
        setState(() => _cursorRow++);
      } else if (_cursorPool.isNotEmpty) {
        // At the last row of this pool: only cross over when this pool
        // is non-empty (an empty pool keeps the cursor for itself).
        setState(() {
          _cursorRole = _opposite(_cursorRole);
          _cursorRow = 0;
        });
      }
      return true;
    }
    if (key == LogicalKey.arrowUp) {
      if (_cursorRow > 0) {
        setState(() => _cursorRow--);
      } else if (_cursorRole == SubagentRole.expert && workers.isNotEmpty) {
        setState(() {
          _cursorRole = SubagentRole.worker;
          _cursorRow = workers.length - 1;
        });
      }
      return true;
    }
    if (key == LogicalKey.keyA) {
      setState(() {
        _picking = true;
        _pickRow = 0;
      });
      return true;
    }
    if (_cursorPool.isEmpty) {
      // Nothing selected: a/d/+/- need a row.
      return key == LogicalKey.keyD || key == LogicalKey.equal ||
              key == LogicalKey.minus;
    }
    final entries = _cursorPool;
    final i = _cursorRow.clamp(0, entries.length - 1);
    if (key == LogicalKey.keyD) {
      setState(() {
        entries.removeAt(i);
        _clampCursor();
        _dirty = true;
      });
      return true;
    }
    if (key == LogicalKey.equal) {
      setState(() {
        entries[i] = SubagentModelEntry(
          model: entries[i].model,
          concurrency: entries[i].concurrency + 1,
        );
        _dirty = true;
      });
      return true;
    }
    if (key == LogicalKey.minus) {
      if (entries[i].concurrency > 1) {
        setState(() {
          entries[i] = SubagentModelEntry(
            model: entries[i].model,
            concurrency: entries[i].concurrency - 1,
          );
          _dirty = true;
        });
      }
      return true;
    }
    return false;
  }

  static SubagentRole _opposite(SubagentRole role) =>
      role == SubagentRole.worker ? SubagentRole.expert : SubagentRole.worker;

  // ── render ─────────────────────────────────────────────────────

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final s = component.strings;
    return Fullpane(
      title: s.t('subagent.config.title'),
      onClose: component.onClose,
      strings: s,
      contentBuilder: (context) => Focusable(
        focused: true,
        onKeyEvent: _handleKey,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: _picking ? _buildPicker(theme, s) : _buildMain(theme, s),
        ),
      ),
    );
  }

  Component _buildMain(dynamic theme, Strings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _switchRegion(theme, s),
        Divider(color: theme.outline, height: 1),
        Expanded(child: _poolsRegion(theme, s)),
        Divider(color: theme.outline, height: 1),
        _rosterRegion(theme, s),
        Text(
          _dirty
              ? s.t('subagent.config.unsaved')
              : (_savedFlash
                    ? s.t('subagent.config.saved')
                    : s.t('subagent.config.hint')),
          style: TextStyle(
            color: _dirty ? theme.warning : theme.onSurfaceDim,
          ),
        ),
      ],
    );
  }

  Component _buildPicker(dynamic theme, Strings s) {
    final options = component.availableModels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.t('subagent.config.pickModel'),
          style: TextStyle(
            color: theme.accent,
            fontWeight: FontWeight.bold,
          ),
        ),
        Expanded(
          child: options.isEmpty
              ? Text(
                  s.t('subagent.config.noModels'),
                  style: TextStyle(color: theme.onSurfaceDim),
                )
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < options.length; i++)
                        Text(
                          '${i == _pickRow ? '▸' : ' '} '
                          '${options[i].label.isEmpty ? options[i].key : options[i].label}'
                          '  (${options[i].key})',
                          style: TextStyle(
                            color: i == _pickRow
                                ? theme.accent
                                : theme.onSurface,
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        Text(
          s.t('subagent.config.pickHint'),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
      ],
    );
  }

  Component _switchRegion(dynamic theme, Strings s) {
    final focused = _region == _Region.switches;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${focused ? '▸ ' : ''}${s.t('subagent.config.switches')}',
          style: TextStyle(
            color: focused ? theme.accent : theme.onSurfaceDim,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          '  w  ✎ workers ${_controller.workersOn ? 'on' : 'off'}'
          '      e  ✦ experts ${_controller.expertsOn ? 'on' : 'off'}',
          style: TextStyle(
            color: _controller.anyOn ? theme.success : theme.onSurface,
          ),
        ),
      ],
    );
  }

  /// Both pools, stacked: workers then experts. One shared cursor
  /// ( [_cursorRole] / [_cursorRow] ) highlights the selected row in
  /// whichever pool it currently lives in.
  Component _poolsRegion(dynamic theme, Strings s) {
    final focused = _region == _Region.pools;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${focused ? '▸ ' : ''}${s.t('subagent.config.pools')}',
            style: TextStyle(
              color: focused ? theme.accent : theme.onSurfaceDim,
              fontWeight: FontWeight.bold,
            ),
          ),
          _poolSection(
            theme,
            s,
            role: SubagentRole.worker,
            glyph: '✎',
            label: 'workers',
            switchOn: _controller.workersOn,
            focused: focused,
          ),
          const SizedBox(height: 1),
          _poolSection(
            theme,
            s,
            role: SubagentRole.expert,
            glyph: '✦',
            label: 'experts',
            switchOn: _controller.expertsOn,
            focused: focused,
          ),
          if (focused)
            Text(
              s.t('subagent.config.poolHint'),
              style: TextStyle(color: theme.onSurfaceDim),
            ),
        ],
      ),
    );
  }

  Component _poolSection(
    dynamic theme,
    Strings s, {
    required SubagentRole role,
    required String glyph,
    required String label,
    required bool switchOn,
    required bool focused,
  }) {
    final entries = _pools[role]!;
    final isCursorPool = focused && _cursorRole == role;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '  $glyph $label '
          '${switchOn ? '· ON' : '· off'} '
          '(${entries.length})',
          style: TextStyle(
            color: switchOn ? theme.success : theme.onSurfaceDim,
            fontWeight: FontWeight.bold,
          ),
        ),
        if (entries.isEmpty)
          Text(
            '    ${s.t('subagent.config.poolEmpty')}',
            style: TextStyle(color: theme.onSurfaceDim),
          )
        else
          for (var i = 0; i < entries.length; i++)
            Text(
              '  ${isCursorPool && i == _cursorRow ? '▸' : ' '} '
              '${entries[i].model} · ×${entries[i].concurrency}',
              style: TextStyle(
                color: isCursorPool && i == _cursorRow
                    ? theme.accent
                    : theme.onSurface,
              ),
            ),
      ],
    );
  }

  Component _rosterRegion(dynamic theme, Strings s) {
    final focused = _region == _Region.roster;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${focused ? '▸ ' : ''}${s.t('subagent.config.roster')}',
          style: TextStyle(
            color: focused ? theme.accent : theme.onSurfaceDim,
            fontWeight: FontWeight.bold,
          ),
        ),
        if (_roster.isEmpty)
          Text(
            s.t('subagent.pool.empty'),
            style: TextStyle(color: theme.onSurfaceDim),
          )
        else
          for (final entry in _roster)
            Text(
              '${entry.role == 'expert' ? '✦' : '✎'} ${entry.name} '
              '${entry.busy ? s.t('subagent.pool.busy') : s.t('subagent.pool.ready')} · '
              '${entry.domain} · ${entry.model}',
              style: TextStyle(
                color: entry.busy ? theme.success : theme.onSurface,
              ),
            ),
      ],
    );
  }
}
