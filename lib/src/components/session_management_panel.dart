import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import '../models/session.dart';
import '../i18n/strings.dart';
import '../utils/terminal_symbols.dart';
import 'ui/fullpane.dart';

/// Async loader for the panel's candidate set: every session the panel
/// can show — in-memory active rows plus archived rows from the store.
/// Returns newest-first; the panel filters in memory.
typedef SessionCandidatesLoader = Future<List<Session>> Function();

/// Opens a session by id, unarchiving it first when needed — the same
/// archived-aware switch path a `ses://<id>` link uses, so Enter on an
/// archived row restores it to the sidebar before switching to it.
typedef SessionOpener = Future<String?> Function(int sessionId);

class SessionManagementPanel extends StatefulComponent {
  /// In-memory non-archived workspace sessions (the sidebar list).
  final List<Session> sessions;

  /// Chat-mode sessions (global). Rendered in a separate "Chats"
  /// section below the project "Sessions"/"Archived" sections.
  final List<Session> chats;

  /// Fired once per open (initState): returns every session including
  /// archived ones (in-memory + store rows). The panel owns the loaded
  /// snapshot; the live [sessions]/[chats] lists always win on merge,
  /// so a title renamed after the load still renders fresh. When null
  /// the panel shows only the in-memory lists (legacy hosts, tests).
  final SessionCandidatesLoader? onLoadCandidates;

  final int currentSessionId;
  final Future<void> Function(int sessionId) onDeleteSession;
  final Future<void> Function(int sessionId, String newTitle) onRenameSession;
  final void Function(int sessionId) onSwitchSession;

  /// Archived-aware open. When null the plain [onSwitchSession] is
  /// used (hosts that didn't opt into archived support — tests).
  final SessionOpener? onOpenSession;
  final VoidCallback onDismiss;
  final Strings strings;

  const SessionManagementPanel({
    required this.sessions,
    this.chats = const [],
    this.onLoadCandidates,
    required this.currentSessionId,
    this.onOpenSession,
    required this.onDeleteSession,
    required this.onRenameSession,
    required this.onSwitchSession,
    required this.onDismiss,
    this.strings = kEnglishStrings,
  });

  @override
  State<SessionManagementPanel> createState() => _SessionManagementPanelState();
}

enum _PanelMode { browse, confirmDelete, rename }

/// One row in the flat list the panel renders: a section header or an
/// actual session/chat row.
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

class _Section {
  final String header;
  final List<Session> sessions;
  const _Section(this.header, this.sessions);
}

class _SessionManagementPanelState extends State<SessionManagementPanel> {
  int _selectedIndex = 0;
  _PanelMode _mode = _PanelMode.browse;
  final _renameController = TextEditingController();
  final _scrollController = ScrollController();

  /// Search query over titles + `#id`. Typing any printable character
  /// outside a text field enters search mode; Esc first clears the
  /// query, then closes the panel.
  String _query = '';
  bool _searchMode = false;
  final _searchController = TextEditingController();

  /// True while the post-open candidate load is in flight (host wired
  /// [SessionManagementPanel.onLoadCandidates]).
  bool _loadingCandidates = false;

  /// Full-candidate snapshot from the post-open load (active +
  /// archived). Null until it lands; live in-memory lists always win
  /// during merge (see [_pool]).
  List<Session>? _all;

  @override
  void initState() {
    super.initState();
    if (component.onLoadCandidates != null) {
      _loadingCandidates = true;
      _loadCandidates();
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _ensureSelectedVisible();
    });
  }

  Future<void> _loadCandidates() async {
    List<Session>? loaded;
    try {
      loaded = await component.onLoadCandidates!();
    } catch (_) {
      loaded = null;
    }
    if (!mounted) return;
    setState(() {
      _all = loaded;
      _loadingCandidates = false;
    });
  }

  @override
  void dispose() {
    _renameController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// The candidate pool this panel can show: the loaded snapshot
  /// (active + archived) merged with the live in-memory lists —
  /// in-memory entries win, so a just-renamed title or a status flip
  /// renders fresh even though the snapshot is older. Without a
  /// snapshot this is exactly the old panel's data.
  List<Session> get _pool {
    final live = [...component.sessions, ...component.chats];
    final snapshot = _all;
    if (snapshot == null) return live;
    final byId = {for (final s in snapshot) s.id: s};
    for (final s in live) {
      byId[s.id] = s;
    }
    return byId.values.toList();
  }

  /// Sessions matching [_query]: case-insensitive title substring, or
  /// a `#id` prefix match when the query starts with `#` (purely
  /// numeric queries also match the id as a substring). Empty query
  /// matches everything.
  bool _matches(Session s) {
    final q = _query.trim();
    if (q.isEmpty) return true;
    if (q.startsWith('#')) {
      final digits = q.substring(1).trim();
      return digits.isEmpty || '${s.id}'.startsWith(digits);
    }
    final title = s.title.isEmpty
        ? (s.isChat
              ? component.strings.t('chat.newPlaceholder')
              : component.strings.t('session.newPlaceholder'))
        : s.title;
    if (title.toLowerCase().contains(q.toLowerCase())) return true;
    return '${s.id}'.contains(q);
  }

  /// Flat row list: section header + session rows per [_Section].
  /// Selection moves over session rows only; headers are skipped by
  /// the nav helpers.
  List<_Row> get _rows {
    final pool = _pool.where(_matches).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final sessions = pool.where((s) => !s.isChat).toList();
    final chats = pool.where((s) => s.isChat).toList();
    final active = sessions.where((s) => s.archivedAt == null).toList();
    final archived = sessions.where((s) => s.archivedAt != null).toList();
    final activeChats = chats.where((s) => s.archivedAt == null).toList();
    final archivedChats = chats.where((s) => s.archivedAt != null).toList();

    final sectionDefs = <_Section>[
      if (active.isNotEmpty)
        _Section(component.strings.t('chat.sessions.sessions'), active),
      if (archived.isNotEmpty)
        _Section(component.strings.t('chat.sessions.archived'), archived),
      if (activeChats.isNotEmpty)
        _Section(component.strings.t('chat.sessions.chats'), activeChats),
      if (archivedChats.isNotEmpty)
        _Section(
          component.strings.t('chat.sessions.chatsArchived'),
          archivedChats,
        ),
    ];

    final rows = <_Row>[];
    for (final section in sectionDefs) {
      rows.add(_HeaderRow(section.header));
      rows.addAll(section.sessions.map(_SessionRow.new));
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
        renderedOffset += 2; // divider + label (see build render)
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
    final deletedId = session.id;
    await component.onDeleteSession(deletedId);
    // Drop the deleted row from the panel's snapshot too — the live
    // lists refresh via the host's callback, but [_pool] merges the
    // snapshot back in and would resurrect the row here.
    _all = _all?.where((s) => s.id != deletedId).toList();
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
    if (session.archivedAt != null) {
      // Renaming an archived row would bump `updatedAt` (the rename
      // store path writes it), silently reordering the recency list.
      // Keep archived rows immutable; unarchive first (Enter), then
      // rename.
      return;
    }
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

  void _openSelected() {
    final sorted = _sorted;
    if (sorted.isEmpty) return;
    final session = sorted[_selectedIndex];
    final onOpen = component.onOpenSession;
    if (onOpen != null) {
      onOpen(session.id);
    } else {
      component.onSwitchSession(session.id);
    }
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
    // Search mode: the Fullpane's Focusable holds keyboard focus while
    // the panel is open (a second focused TextField would fight it for
    // dispatch and lose), so the panel itself appends/deletes in the
    // search controller. The TextField is display-only.
    if (_searchMode) {
      if (event.logicalKey == LogicalKey.escape) {
        if (_searchController.text.isNotEmpty) {
          setState(() {
            _searchController.clear();
            _query = '';
            _selectedIndex = 0;
          });
          _ensureSelectedVisible();
        } else {
          setState(() => _searchMode = false);
          component.onDismiss();
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
      if (event.logicalKey == LogicalKey.enter) {
        _openSelected();
        return true;
      }
      if (event.logicalKey == LogicalKey.backspace &&
          !event.isControlPressed &&
          !event.isAltPressed &&
          !event.isMetaPressed) {
        final runes = _searchController.text.runes.toList();
        if (runes.isNotEmpty) {
          runes.removeLast(); // rune-wise so CJK/emoji delete whole glyphs
          final text = String.fromCharCodes(runes);
          setState(() {
            _searchController.text = text;
            _query = text;
            _selectedIndex = 0;
          });
        }
        return true;
      }
      final ch = event.character;
      final printable =
          ch != null &&
          ch.isNotEmpty &&
          ch.runes.every((r) => r >= 0x20) &&
          ch != '\x7f';
      if (!event.isControlPressed &&
          !event.isAltPressed &&
          !event.isMetaPressed &&
          printable) {
        final text = _searchController.text + ch;
        setState(() {
          _searchController.text = text;
          _query = text;
          _selectedIndex = 0;
        });
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
      _openSelected();
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      component.onDismiss();
      return true;
    }
    // Any other printable character: enter search mode, seed the
    // field with that character (this frame's keystroke would never
    // reach the field — it doesn't exist yet — so the panel owns the
    // first insertion), and consume. Subsequent keystrokes dispatch
    // to the now-focused field first.
    final ch = event.character;
    final printable =
        ch != null &&
        ch.isNotEmpty &&
        ch.runes.every((r) => r >= 0x20) &&
        ch != '\x7f';
    if (!event.isControlPressed &&
        !event.isAltPressed &&
        !event.isMetaPressed &&
        printable) {
      setState(() {
        _searchMode = true;
        _searchController.text = ch;
        _query = ch;
      });
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
        label: component.strings.t('chat.sessions.delete'),
        keyHint: 'Ctrl+D',
        matches: (e) => e.isControlPressed && e.logicalKey == LogicalKey.keyD,
        onActivate: _mode == _PanelMode.confirmDelete
            ? _confirmDelete
            : _initiateDelete,
      ),
      FullpaneShortcut(
        label: component.strings.t('chat.sessions.rename'),
        keyHint: 'Ctrl+R',
        matches: (e) => e.isControlPressed && e.logicalKey == LogicalKey.keyR,
        onActivate: _initiateRename,
      ),
    ];

    return Fullpane(
      title: component.strings.t(
        _mode == _PanelMode.confirmDelete
            ? 'chat.sessions.confirmDelete'
            : 'chat.sessions.sessions',
      ),
      onClose: component.onDismiss,
      strings: component.strings,
      shortcuts: shortcuts,
      onKeyEvent: _handleKeyEvent,
      contentBuilder: (context) {
        if (_loadingCandidates) {
          return Center(
            child: Text(
              component.strings.t('chat.history.loadingUnknown'),
              style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
            ),
          );
        }
        if (sorted.isEmpty) {
          // Even with no matches the search row stays visible (with
          // the query in it) so the user can see what they typed and
          // keep editing / Esc-clear it.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_searchMode)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: TextField(
                    controller: _searchController,
                    focused: false,
                    maxLines: 1,
                    style: TextStyle(color: CruxTheme.of(context).foreground),
                    placeholder: component.strings.t(
                      'chat.sessions.searchHint',
                    ),
                  ),
                ),
              Expanded(
                child: Center(
                  child: Text(
                    _query.isNotEmpty
                        ? component.strings.t('chat.sessions.searchNoMatch', {
                            'query': _query,
                          })
                        : component.strings.t('chat.sessions.noSessions'),
                    style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
                  ),
                ),
              ),
            ],
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
                    component.strings.t('chat.sessions.deleteConfirm', {
                      'title': session.title,
                    }),
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

        if (_searchMode) {
          children.add(
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              // Display-only: the panel's key handler edits the
              // controller (the Fullpane Focusable owns focus, so a
              // focused field would never receive events anyway).
              child: TextField(
                controller: _searchController,
                focused: false,
                maxLines: 1,
                style: TextStyle(color: CruxTheme.of(context).foreground),
                placeholder: component.strings.t('chat.sessions.searchHint'),
              ),
            ),
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
                    component.strings.t('chat.sessions.status'),
                    style: TextStyle(
                      color: CruxTheme.of(context).onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    component.strings.t('chat.sessions.title'),
                    style: TextStyle(
                      color: CruxTheme.of(context).onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                SizedBox(
                  width: 12,
                  child: Text(
                    component.strings.t('chat.sessions.model'),
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
          final isArchived = s.archivedAt != null;

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
          final titleBase = s.title.isEmpty
              ? (s.isChat
                    ? component.strings.t('chat.newPlaceholder')
                    : component.strings.t('session.newPlaceholder'))
              : s.title;
          final titleText = isArchived
              ? '${component.strings.t('chat.sessions.archivedTag')}$titleBase'
              : titleBase;
          final titleDisplay = titleText.length > 30
              ? '${titleText.substring(0, 29)}~'
              : titleText;
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
                  _openSelected();
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
      title: component.strings.t('chat.sessions.renameTitle'),
      onClose: _cancelAction,
      strings: component.strings,
      contentBuilder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            component.strings.t('chat.sessions.current', {
              'title': session.title,
            }),
            style: TextStyle(color: CruxTheme.of(context).onSurfaceVariant),
          ),
          const SizedBox(height: 1),
          Row(
            children: [
              Text(
                component.strings.t('chat.sessions.newName'),
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
            component.strings.t('chat.sessions.confirmHint'),
            style: TextStyle(color: CruxTheme.of(context).hintText),
          ),
        ],
      ),
    );
  }
}
