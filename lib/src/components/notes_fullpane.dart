import 'dart:async';

import 'package:nocterm/nocterm.dart';

import '../services/notes_service.dart';
import '../theme/crux_theme.dart';
import '../i18n/strings.dart';
import '../utils/cjk_word_boundary.dart';
import '../utils/todo_parser.dart';
import 'ui/fullpane.dart';

/// Full-pane raw markdown editor for the project's "my notes".
///
/// Opened from the `my notes` sidebar widget's `open` screen action.
/// A single plain-text [TextField] holds the whole note — what you see
/// is exactly what's saved: raw markdown, no rendering, no preview, no
/// mode toggle.
///
/// Plain Enter inserts a newline; `Ctrl+S` saves immediately; changes
/// autosave shortly after typing stops; `Esc` closes. Content persists
/// to the crux DB through [NotesService], which also refreshes the
/// widget's todo projection on every save.
///
/// This component renders its own [Fullpane] chrome; [onClose] is the
/// host's dismissal callback (the chat panel clears its fullpane flag).
class NotesFullpane extends StatefulComponent {
  final NotesService service;

  /// Host dismissal callback — invoked on `Esc` / close so the chat
  /// panel tears the fullpane down.
  final VoidCallback onClose;

  /// Called after each successful save with the fresh todo summary —
  /// the host can toast or refresh. Optional (tests).
  final void Function(TodoSummary summary)? onSaved;
  final Strings strings;

  const NotesFullpane({
    super.key,
    required this.service,
    required this.onClose,
    this.onSaved,
    this.strings = kEnglishStrings,
  });

  @override
  State<NotesFullpane> createState() => _NotesFullpaneState();
}

class _NotesFullpaneState extends State<NotesFullpane> {
  /// Debounce window for autosave after the last keystroke.
  static const _autosaveDelay = Duration(milliseconds: 700);

  final TextEditingController _controller = TextEditingController();

  bool _loading = true;
  bool _dirty = false;
  bool _saving = false;
  String _lastSaved = '';
  Timer? _autosaveTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final content = await component.service.init();
    if (!mounted) return;
    setState(() {
      _controller.text = content;
      _lastSaved = content;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _dirty = _controller.text != _lastSaved;
    _autosaveTimer?.cancel();
    _autosaveTimer = Timer(_autosaveDelay, () => unawaited(_save()));
    setState(() {});
  }

  Future<void> _save() async {
    _autosaveTimer?.cancel();
    if (_saving || !_dirty) return;
    final content = _controller.text;
    setState(() => _saving = true);
    try {
      final summary = await component.service.save(content);
      if (!mounted) return;
      _lastSaved = content;
      _dirty = _controller.text != _lastSaved;
      component.onSaved?.call(summary);
    } catch (_) {
      // A failed save keeps _dirty set so the next autosave retries;
      // the status line keeps showing "unsaved".
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _requestClose() {
    // Flush any unsaved edit, then hand dismissal to the host.
    unawaited(_save());
    component.onClose();
  }

  /// Insert [text] at the current selection (replacing any selected
  /// range), moving the caret to just after the inserted text. Used to
  /// make plain Enter a newline in the editor.
  void _insertAtCursor(String text) {
    final current = _controller.text;
    final sel = _controller.selection;
    final start = sel.start.clamp(0, current.length);
    final end = sel.end.clamp(0, current.length);
    final next = current.replaceRange(start, end, text);
    _controller.text = next;
    _controller.selection =
        TextSelection.collapsed(offset: start + text.length);
    _onChanged(next);
  }

  /// Intercept keys before the [TextField] processes them. Plain Enter
  /// becomes a newline (the field's default is "submit"); Ctrl+S saves.
  /// Everything else falls through to normal editing.
  bool _handleEditKey(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter ||
        event.logicalKey == LogicalKey.numpadEnter) {
      // Shift/Ctrl/Alt+Enter already insert a newline in the field; for
      // plain Enter we insert one ourselves so the editor never submits.
      if (!event.isShiftPressed &&
          !event.isControlPressed &&
          !event.isAltPressed) {
        _insertAtCursor('\n');
        return true;
      }
      return false;
    }
    if (event.matches(LogicalKey.keyS, ctrl: true)) {
      unawaited(_save());
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final todos = parseTodos(_controller.text);

    return Fullpane(
      title: component.strings.t('chat.notes.title'),
      onClose: _requestClose,
      strings: component.strings,
      shortcuts: [
        FullpaneShortcut(
          label: component.strings.t('chat.notes.save'),
          keyHint: '⌃S',
          matches: (e) => e.matches(LogicalKey.keyS, ctrl: true),
          onActivate: () => unawaited(_save()),
        ),
        FullpaneShortcut(
          label: component.strings.t('chat.notes.close'),
          keyHint: 'esc',
          matches: (e) => e.logicalKey == LogicalKey.escape,
          onActivate: _requestClose,
        ),
      ],
      contentBuilder: (context) {
        if (_loading) {
          return Center(
            child: Text(
              component.strings.t('chat.notes.loading'),
              style: TextStyle(color: theme.onSurfaceDim),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Status strip: todo count + save state ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Row(
                children: [
                  Text(
                    todos.isEmpty
                        ? component.strings.t('home.notes.noTodos')
                        : '◷ ${component.strings.t(todos.openCount == 1 ? 'chat.notes.openTodo' : 'chat.notes.openTodos', {'n': '${todos.openCount}'})}'
                            ' · ${component.strings.t('chat.notes.doneCount', {'n': '${todos.done.length}'})}',
                    style: TextStyle(
                      color: todos.openCount > 0
                          ? theme.warningColor
                          : theme.onSurfaceDim,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _saving
                        ? component.strings.t('chat.notes.saving')
                        : _dirty
                            ? component.strings.t('chat.notes.unsaved')
                            : component.strings.t('chat.notes.saved'),
                    style: TextStyle(
                      color: _dirty && !_saving
                          ? theme.warningColor
                          : theme.onSurfaceDim,
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: theme.divider, height: 1),
            // ── Raw markdown, whole note in one field ──
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: TextField(
                  controller: _controller,
                  focused: true,
                  maxLines: null,
                  onChanged: _onChanged,
                  onKeyEvent: _handleEditKey,
                  placeholder: component.strings.t('chat.notes.placeholder'),
                  wordBoundaryProvider: cjkWordBoundaryProvider,
                  style: TextStyle(color: theme.onSurface),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
