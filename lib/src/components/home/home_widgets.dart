import 'package:nocterm/nocterm.dart';

import '../../models/session.dart';
import '../../services/git_status_service.dart';

/// Live services handed to every home widget.
///
/// This is a service *locator*, not a god-bag: the field list only
/// grows when a concrete widget needs a service none of the current
/// ones cover, and never for a single widget's convenience (such a
/// widget keeps its own reference at registration time). TOML-defined
/// widgets never see these services — they only render their file's
/// data and command output.
class HomeContext {
  /// Run a slash command against the chat panel (`_executeCommand`).
  ///
  /// Returns `false` while a response is in flight — session-mutating
  /// actions (`/new`, `switchSession`, continue) must not fire
  /// mid-stream. Callers surface a one-line notice and stay on home.
  /// Seed-only actions (e.g. `/project `) that don't execute are
  /// allowed regardless and don't go through this guard.
  final bool Function(String command) runCommand;

  /// Dismiss home and return to the chat screen.
  final VoidCallback close;

  /// Seed text into the chat input without executing (prefill for
  /// seed-only quick actions like `/project `).
  final void Function(String text) seedInput;

  /// The git-status service for the `git-status` box (push liveness).
  final GitStatusService gitStatusService;

  /// Sessions + chats, merged and ordered by `updatedAt` descending —
  /// the in-memory lists from the panel, read on each build. Feeds
  /// `recent-sessions` and `yesterday`.
  final List<Session> Function() sessions;

  /// The currently-active session id (for the `▸` marker), or null.
  final int? Function() currentSessionId;

  /// Switch to a session by id. Returns `false` if refused (mid-stream);
  /// the widget keeps home open so the user sees the refusal.
  final bool Function(int sessionId) switchSession;

  const HomeContext({
    required this.runCommand,
    required this.close,
    required this.seedInput,
    required this.gitStatusService,
    required this.sessions,
    required this.currentSessionId,
    required this.switchSession,
  });

  /// A no-op context for rendering the bare grid without a panel behind
  /// it (layout tests, previews). Every service is a stub: no sessions,
  /// a fresh (non-repo) git service, nothing runs. [gitStatusService] is
  /// a real instance so the widget can subscribe to it harmlessly.
  HomeContext.minimal({required this.close})
      : runCommand = ((_) => true),
        seedInput = ((_) {}),
        gitStatusService = GitStatusService(),
        sessions = (() => const <Session>[]),
        currentSessionId = (() => null),
        switchSession = ((_) => false);
}

/// One pluggable dashboard box.
///
/// A widget renders a bordered box inside the home grid. It declares
/// which column spans it supports, how tall it wants to be, and what
/// (if anything) happens on `enter`/click. Built-ins and TOML-defined
/// widgets both implement this interface and live in the same grid.
abstract class HomeWidget {
  /// Stable id, used as the key in the persisted layout and the
  /// registry. Built-ins own their namespace; a TOML widget whose id
  /// collides with a built-in is skipped.
  String get id;

  /// Box chrome title, rendered in the border.
  String get title;

  /// Column spans this widget can render at, e.g. `{1, 2}`. The layout
  /// engine assigns the largest span that fits the current column
  /// count.
  Set<int> get supportedSpans;

  /// Minimum content height in rows for the given span. A row's height
  /// is the max of its boxes' values; shorter boxes stretch their
  /// borders to match, so widgets must render at any height ≥ this.
  int heightFor(int span);

  /// Primary action for `enter`/click. Return `null` for a passive box
  /// (no-op on activation). Returning a callback marks the box
  /// actionable (shown in the key legend / hover).
  void Function()? activate(HomeContext ctx);

  /// Render the box *content* (the border/title chrome is the grid's
  /// job, not the widget's).
  Component build(BuildContext context, HomeContext ctx, int span);
}

/// The set of registered home widgets, keyed by [HomeWidget.id].
///
/// Same shape as `ToolRegistry`: built-ins register at startup, and
/// TOML-defined widgets register through the same path so built-in and
/// custom boxes live in the same grid and are rearranged identically.
class HomeWidgetRegistry {
  final Map<String, HomeWidget> _widgets = {};

  /// Register [widget]. Returns `false` (and keeps the existing entry)
  /// if a widget with the same id is already registered — first
  /// registration wins, which gives built-ins their namespace and gives
  /// project TOML widgets precedence over global ones when discovery
  /// registers project first.
  bool register(HomeWidget widget) {
    if (_widgets.containsKey(widget.id)) return false;
    _widgets[widget.id] = widget;
    return true;
  }

  HomeWidget? operator [](String id) => _widgets[id];

  /// All registered widgets, in registration order.
  List<HomeWidget> get widgets => List.unmodifiable(_widgets.values);

  int get length => _widgets.length;

  bool contains(String id) => _widgets.containsKey(id);
}
