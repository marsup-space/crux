import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import '../models/session.dart';
import '../utils/terminal_symbols.dart';
import 'ui/fullpane.dart';

class SessionManagementPanel extends StatefulComponent {
  final List<Session> sessions;

  /// Chat-mode sessions (global). Rendered in a separate "Chats"
  /// section below the project "Sessions".
  final List<Session> chats;
  final int currentSessionId;
  final Future<void> Function(int sessionId) onDeleteSession;
  final Future<void> Function(int sessionId, String newTitle) onRenameSession;
  final void Function(int sessionId) onSwitchSession;
  final VoidCallback onDismiss;

  const SessionManagementPanel({
    required this.sessions,
    this.chats = const [],
    required this.currentSessionId,
    required this.onDeleteSession,
    required this.onRenameSession,
    required this.onSwitchSession,
    required this.onDismiss,
  });

  @override
  State<SessionManagementPanel> createState() => _SessionManagementPanelState();
}

enum _PanelMode { browse, confirmDelete, rename }

/// One row in the flat list the panel renders: either a section
/// header or an actual session/chat row.
sealed class _Row {
  const _Row();
}

class _HeaderRow extends _Row {
  final String label;
  const _HeaderRow(this.label);
}

class _SessionRow extends _Row {
  final Session session;
  const _SessionRow(this.session);
}

class _SessionManagementPanelState extends State<SessionManagementPanel> {
  int _selectedIndex = 0;
  _PanelMode _mode = _PanelMode.browse;
  final _renameController = TextEditingController();
  final _scrollController = ScrollController();

  /// Flat row list: "Sessions" header + session rows, then "Chats"
  /// header + chat rows. Selection moves over session rows only;
  /// headers are skipped by the nav helpers.
  List<_Row> get _rows {
    final sessions = List<Session>.from(component.sessions)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final chats = List<Session>.from(component.chats)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final rows = <_Row>[];
    if (sessions.isNotEmpty) {
      rows.add(const _HeaderRow('Sessions'));
      rows.addAll(sessions.map(_SessionRow.new));
    }
    if (chats.isNotEmpty) {
      rows.add(const _HeaderRow('Chats'));
      rows.addAll(chats.map(_SessionRow.new));
    }
    return rows;
  }

  /// Only the selectable session rows (headers filtered out), used by
  /// the nav/enter/delete/rename logic which operates on sessions.
  List<Session> get _sorted {
    return [
      for (final row in _rows)
        if (row is _SessionRow) row.session,
    ];
  }

  @override
  void initState() {
    super.initState();
    final sorted = _sorted;
    final currentIdx = sorted.indexWhere(
      (s) => s.id == component.currentSessionId,
    );
    _selectedIndex = currentIdx >= 0 ? currentIdx : 0;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _ensureSelectedVisible();
    });
  }

  @override
  void dispose() {
    _renameController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _selectPrev() {
    final len = _sorted.length;
    if (len == 0) return;
    setState(() {
      _selectedIndex = _selectedIndex > 0 ? _selectedIndex - 1 : len - 1;
    });
    _ensureSelectedVisible();
  }

  void _selectNext() {
    final len = _sorted.length;
    if (len == 0) return;
    setState(() {
      _selectedIndex = _selectedIndex < len - 1 ? _selectedIndex + 1 : 0;
    });
    _ensureSelectedVisible();
  }

  void _ensureSelectedVisible() {
    // Each session row is 1 terminal row. In confirm-delete mode there
    // are 2 extra rows (message + divider) above the list.
    //
    // The selected index counts *selectable session rows* (headers are
    // filtered out of `_sorted`), but the rendered list also contains
    // header rows. Map the session index to its rendered row offset by
    // counting how many header rows precede it.
    final rows = _rows;
    var sessionOrdinal = -1;
    var renderedOffset = 0;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is _HeaderRow) {
        renderedOffset += 2; // divider + label (see _buildRows render)
        continue;
      }
      sessionOrdinal++;
      if (sessionOrdinal == _selectedIndex) break;
      renderedOffset += 1;
    }
    final baseOffset = _mode == _PanelMode.confirmDelete ? 2.0 : 0.0;
    final itemOffset = baseOffset + renderedOffset.toDouble();
    _scrollController.ensureVisible(itemOffset: itemOffset, itemExtent: 1.0);
  }

  void _initiateDelete() {
    if (_sorted.isEmpty) return;
    setState(() {
      _mode = _PanelMode.confirmDelete;
    });
  }

  void _confirmDelete() async {
    if (_sorted.isEmpty) return;
    final session = _sorted[_selectedIndex];
    await component.onDeleteSession(session.id);
    final newLen = _sorted.length;
    if (newLen == 0) {
      component.onDismiss();
      return;
    }
    setState(() {
      _mode = _PanelMode.browse;
      if (_selectedIndex >= newLen) {
        _selectedIndex = newLen - 1;
      }
    });
  }

  void _initiateRename() {
    if (_sorted.isEmpty) return;
    final session = _sorted[_selectedIndex];
    _renameController.text = session.title;
    setState(() {
      _mode = _PanelMode.rename;
    });
  }

  void _confirmRename() async {
    if (_sorted.isEmpty) return;
    final session = _sorted[_selectedIndex];
    final newTitle = _renameController.text.trim();
    if (newTitle.isNotEmpty && newTitle != session.title) {
      await component.onRenameSession(session.id, newTitle);
    }
    setState(() {
      _mode = _PanelMode.browse;
    });
  }

  void _cancelAction() {
    setState(() {
      _mode = _PanelMode.browse;
    });
  }

  String _statusIcon(SessionStatus status) {
    switch (status) {
      case SessionStatus.idle:
        return terminalSymbol('·', '.');
      case SessionStatus.running:
        return terminalSymbol('▶', '>');
      case SessionStatus.needUserAction:
        return '?';
      case SessionStatus.done:
        return terminalSymbol('✦', '*');
      case SessionStatus.interrupted:
        return terminalSymbol('✗', 'x');
    }
  }

  Color _statusColor(SessionStatus status) {
    switch (status) {
      case SessionStatus.idle:
        return CruxTheme.of(context).sessionPrefixIdle;
      case SessionStatus.running:
        return CruxTheme.of(context).sessionPrefixRunning;
      case SessionStatus.needUserAction:
        return CruxTheme.of(context).sessionPrefixNeedsAction;
      case SessionStatus.done:
        return CruxTheme.of(context).sessionPrefixDone;
      case SessionStatus.interrupted:
        return CruxTheme.of(context).sessionPrefixInterrupted;
    }
  }

  bool _handleKeyEvent(KeyboardEvent event) {
    if (_mode == _PanelMode.confirmDelete) {
      if (event.isControlPressed && event.logicalKey == LogicalKey.keyD) {
        _confirmDelete();
        return true;
      }
      if (event.logicalKey == LogicalKey.escape) {
        _cancelAction();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowUp) {
        _selectPrev();
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        _selectNext();
        return true;
      }
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowUp) {
      _selectPrev();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      _selectNext();
      return true;
    }
    if (event.isControlPressed && event.logicalKey == LogicalKey.keyD) {
      _initiateDelete();
      return true;
    }
    if (event.isControlPressed && event.logicalKey == LogicalKey.keyR) {
      _initiateRename();
      return true;
    }
    if (event.logicalKey == LogicalKey.enter) {
      final sorted = _sorted;
      if (sorted.isNotEmpty) {
        component.onSwitchSession(sorted[_selectedIndex].id);
      }
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      component.onDismiss();
      return true;
    }
    return true;
  }

  @override
  Component build(BuildContext context) {
    final sorted = _sorted;

    if (_mode == _PanelMode.rename) {
      return _buildRenameFullpane(sorted);
    }

    final shortcuts = <FullpaneShortcut>[
      FullpaneShortcut(
        label: 'delete',
        keyHint: 'Ctrl+D',
        matches: (e) => e.isControlPressed && e.logicalKey == LogicalKey.keyD,
        onActivate: _mode == _PanelMode.confirmDelete
            ? _confirmDelete
            : _initiateDelete,
      ),
      FullpaneShortcut(
        label: 'rename',
        keyHint: 'Ctrl+R',
        matches: (e) => e.isControlPressed && e.logicalKey == LogicalKey.keyR,
        onActivate: _initiateRename,
      ),
    ];

    return Fullpane(
      title: _mode == _PanelMode.confirmDelete ? 'Confirm Delete' : 'Sessions',
      onClose: component.onDismiss,
      shortcuts: shortcuts,
      onKeyEvent: _handleKeyEvent,
      contentBuilder: (context) {
        if (sorted.isEmpty) {
          return Center(
            child: Text(
              'No sessions found.',
              style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
            ),
          );
        }

        final children = <Component>[];

        if (_mode == _PanelMode.confirmDelete) {
          final session = sorted[_selectedIndex];
          children.add(
            Container(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: [
                  Text(
                    'Delete "${session.title}"? Ctrl+D to confirm, Esc to cancel',
                    style: TextStyle(
                      color: CruxTheme.of(context).deleteWarning,
                    ),
                  ),
                ],
              ),
            ),
          );
          children.add(
            Divider(color: CruxTheme.of(context).outline, height: 1),
          );
        }

        // Column header shared by both sections. Rendered once at the
        // top of the scrollable list.
        final headerBg = CruxTheme.of(context).wizardRowBgSelected;
        children.add(
          Container(
            decoration: BoxDecoration(color: headerBg),
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              children: [
                SizedBox(
                  width: 4,
                  child: Text(
                    '#',
                    style: TextStyle(
                      color: CruxTheme.of(context).onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                SizedBox(
                  width: 3,
                  child: Text(
                    ' ',
                    style: TextStyle(
                      color: CruxTheme.of(context).onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(
                  width: 6,
                  child: Text(
                    'St',
                    style: TextStyle(
                      color: CruxTheme.of(context).onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    ' Title',
                    style: TextStyle(
                      color: CruxTheme.of(context).onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                SizedBox(
                  width: 12,
                  child: Text(
                    'Model',
                    style: TextStyle(
                      color: CruxTheme.of(context).onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
        );

        // Iterate the flat row list (section headers + session rows).
        // `selectableOrdinal` tracks the index into `_sorted` (the
        // header-free selectable list) so selection, hover, and tap
        // all line up with `_selectedIndex`.
        final rows = _rows;
        var selectableOrdinal = -1;
        for (final row in rows) {
          if (row is _HeaderRow) {
            children.add(
              Divider(color: CruxTheme.of(context).outline, height: 1),
            );
            children.add(
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                child: Text(
                  row.label,
                  style: TextStyle(
                    color: CruxTheme.of(context).onSurfaceDim,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            );
            continue;
          }
          final s = (row as _SessionRow).session;
          selectableOrdinal++;
          final i = selectableOrdinal;
          final isSelected = i == _selectedIndex;
          final isCurrent = s.id == component.currentSessionId;

          final bgColor = isSelected
              ? CruxTheme.of(context).wizardRowBgSelected
              : isCurrent
              ? CruxTheme.of(context).buttonBackgroundHover
              : CruxTheme.of(context).buttonBackground;
          final textColor = isSelected
              ? CruxTheme.of(context).wizardTextSelected
              : isCurrent
              ? CruxTheme.of(context).foreground
              : CruxTheme.of(context).onSurfaceVariant;

          final prefix = isSelected ? '${terminalSymbol('▸', '>')} ' : '  ';
          final status = s.status;
          final icon = _statusIcon(status);
          final iconColor = _statusColor(status);
          final titleDisplay = s.title.length > 30
              ? '${s.title.substring(0, 29)}~'
              : s.title;
          final modelShort = s.model.contains('/')
              ? s.model.split('/').last
              : s.model;
          final modelDisplay = modelShort.length > 12
              ? '${modelShort.substring(0, 11)}~'
              : modelShort;

          children.add(
            MouseRegion(
              onEnter: (_) => setState(() => _selectedIndex = i),
              opaque: false,
              child: GestureDetector(
                onTap: () {
                  setState(() => _selectedIndex = i);
                  component.onSwitchSession(s.id);
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  decoration: BoxDecoration(color: bgColor),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 1,
                    vertical: 0,
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 4,
                        child: Text(
                          '${s.id}',
                          style: TextStyle(color: textColor),
                        ),
                      ),
                      Text(prefix, style: TextStyle(color: textColor)),
                      SizedBox(
                        width: 3,
                        child: Text(icon, style: TextStyle(color: iconColor)),
                      ),
                      Expanded(
                        child: Text(
                          ' $titleDisplay',
                          style: TextStyle(
                            color: textColor,
                            fontWeight: isSelected ? FontWeight.bold : null,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 12,
                        child: Text(
                          modelDisplay,
                          style: TextStyle(
                            color: CruxTheme.of(context).onSurfaceDim,
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        return SingleChildScrollView(
          controller: _scrollController,
          keyboardScrollable: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        );
      },
    );
  }

  Component _buildRenameFullpane(List<Session> sorted) {
    if (sorted.isEmpty) return const SizedBox();
    final session = sorted[_selectedIndex];

    return Fullpane(
      title: 'Rename Session',
      onClose: _cancelAction,
      contentBuilder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Current: ${session.title}',
            style: TextStyle(color: CruxTheme.of(context).onSurfaceVariant),
          ),
          const SizedBox(height: 1),
          Row(
            children: [
              Text(
                'New: ',
                style: TextStyle(color: CruxTheme.of(context).foreground),
              ),
              Expanded(
                child: TextField(
                  controller: _renameController,
                  focused: true,
                  maxLines: 1,
                  style: TextStyle(color: CruxTheme.of(context).foreground),
                  onSubmitted: (_) => _confirmRename(),
                  onKeyEvent: (event) {
                    if (event.logicalKey == LogicalKey.escape) {
                      _cancelAction();
                      return true;
                    }
                    if (event.logicalKey == LogicalKey.enter) {
                      _confirmRename();
                      return true;
                    }
                    return false;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 1),
          Text(
            'Enter to confirm, Esc to cancel',
            style: TextStyle(color: CruxTheme.of(context).hintText),
          ),
        ],
      ),
    );
  }
}
