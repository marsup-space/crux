import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../../../i18n/strings.dart';
import '../../../services/notes_service.dart';
import '../../../theme/crux_theme.dart';
import '../../ui/button.dart';
import '../../ui/clickable_todo_list.dart';
import '../home_widgets.dart';

/// The `my notes` box — the per-project note's open todos, same data
/// and interaction as the sidebar `my-notes` spec widget.
///
/// Data source: the `.dart_tool/my_notes.json` projection written by
/// [NotesService] — the same file the sidebar widget polls. The box
/// polls it on a short interval (mirroring the sidebar's refresh), so
/// checking a todo in the editor (or in the sidebar) shows up here too.
///
/// Rows are clickable, reusing [ClickableTodoList] (identical to the
/// sidebar): clicking an open row marks it done — flips to checked
/// locally, stays for the undo window — and clicking a checked row
/// restores it. The box title row carries an `open` button that opens
/// the fullpane editor via [HomeContext.openNotes].
class NotesHomeWidget extends HomeWidget {
  final NotesService? service;
  final void Function()? openNotes;

  NotesHomeWidget({required this.service, required this.openNotes});

  @override
  String get id => 'notes';

  @override
  String get title => 'my notes';

  @override
  String titleFor(HomeContext ctx) => ctx.strings.t('home.title.notes');

  @override
  Set<int> get supportedSpans => const {1, 2};

  /// 4 rows minimum: count line + the first todo rows; a longer list
  /// scrolls inside the box (home wraps every box in a scroll area,
  /// so the full todo list renders and overflows into scrolling, with
  /// a scrollbar thumb signalling more below).
  @override
  int heightFor(int span) => 4;

  /// A content list — stays top-aligned (centering a scrollable list
  /// would fight the scrollview's height constraint).
  @override
  bool get verticallyCenter => false;

  /// Passive box (no selectable items) — the whole-box Enter/click opens
  /// the editor. Todo rows handle their own clicks.
  @override
  void Function()? activate(HomeContext ctx) {
    final open = ctx.openNotes;
    if (open == null) return null;
    return open;
  }

  @override
  Component build(
    BuildContext context,
    HomeContext ctx,
    int span, {
    bool focused = false,
  }) {
    return _NotesHomeView(
      service: ctx.notesService,
      openNotes: ctx.openNotes,
      strings: ctx.strings,
    );
  }
}

/// Stateful view so the box can poll the projection file and re-render
/// when todos change (the widget object itself is cached by home and has
/// no lifecycle hooks).
class _NotesHomeView extends StatefulComponent {
  final NotesService? service;
  final void Function()? openNotes;
  final Strings strings;

  const _NotesHomeView({
    required this.service,
    required this.openNotes,
    required this.strings,
  });

  @override
  State<_NotesHomeView> createState() => _NotesHomeViewState();
}

class _NotesHomeViewState extends State<_NotesHomeView> {
  /// How often the box re-reads the projection (matches the sidebar
  /// spec widget's 2 s refresh).
  static const _poll = Duration(seconds: 2);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (component.service != null) {
      _timer = Timer.periodic(_poll, (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final service = component.service;

    if (service == null) {
      return Text(
        component.strings.t('home.notes.unavailable'),
        style: TextStyle(color: theme.onSurfaceDim),
      );
    }

    final todos = service.loadProjectionTodos();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Count line + open button (inline, like the sidebar) ──
        Row(
          children: [
            Text(
              todos.isEmpty
                  ? component.strings.t('home.notes.noTodos')
                  : component.strings.t(
                      todos.length == 1 ? 'home.notes.todo' : 'home.notes.todos',
                      {'n': '${todos.length}'},
                    ),
              style: TextStyle(
                color: todos.isEmpty ? theme.onSurfaceDim : theme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            if (component.openNotes != null)
              Button(
                label: component.strings.t('home.notes.open'),
                onPressed: component.openNotes,
                color: theme.accent,
                hoverColor: theme.buttonTextHover,
                bgColor: theme.surfaceVariant,
                hoverBgColor: theme.buttonBackgroundHover,
                padding: const EdgeInsets.symmetric(horizontal: 1),
              ),
          ],
        ),
        // ── Clickable todo rows (shared interaction with the sidebar) ──
        ClickableTodoList(
          todos: todos,
          onToggle: (text, line, done) {
            // Fire-and-forget; the projection rewrite on the next poll
            // reflects the change (and the shared component keeps the
            // checked row visible for the undo window).
            unawaited(
              done
                  ? service.markTodoDone(line)
                  : service.markTodoOpen(line),
            );
          },
          color: theme.onSurfaceVariant,
        ),
      ],
    );
  }
}
