import 'dart:async';

import '../models/message.dart';
import '../models/session.dart';
import '../storage/session_store.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'tool_def.dart';

/// Inspection + archive lifecycle for Crux chat sessions.
///
/// Lets the agent answer questions like "what did we do last session?",
/// "find the message where the user said X", or "show me the recent
/// sessions in this project" without having to shell out to `sqlite3`
/// against the user-data directory.
///
/// The read actions (`list` / `show` / `messages` / `search`) never
/// mutate anything. The only mutations are the `archive` /
/// `unarchive` lifecycle flips — they never delete, rename, or edit
/// content, and the current session can never be archived out from
/// under the running agent.
class SessionTool extends ToolDef {
  final SessionStore _store;

  /// Fires after a successful `archive` / `unarchive` so the UI can
  /// refresh its sidebar session list + archived counts without a
  /// full `initSessions()` (which would re-select the current
  /// session and reload messages mid-turn). Null in tests and
  /// standalone harnesses — mutation still lands in the store, the
  /// sidebar just refreshes on its next natural reload.
  final FutureOr<void> Function(int sessionId, bool archived)? onSessionMutated;

  SessionTool({required this._store, this.onSessionMutated});

  @override
  String get name => 'session';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final action = args['action'] as String? ?? '?';
    String label;
    final meta = result.metadata;
    switch (action) {
      case 'list':
        final n = meta['returned'] as int? ?? 0;
        final hidden = meta['hiddenCurrent'] as bool? ?? false;
        label = '$n other sessions';
        if (hidden) label += ' (current hidden)';
        break;
      case 'show':
        final sid = meta['sessionId'] as int?;
        final title = (meta['title'] as String?) ?? '';
        label = sid != null ? '#$sid $title'.trim() : action;
        break;
      case 'messages':
        final sid = meta['sessionId'] as int?;
        final n = meta['returned'] as int? ?? 0;
        label = sid != null ? '#$sid: $n msgs' : '$n msgs';
        break;
      case 'search':
        final pattern = (args['pattern'] as String?) ?? '';
        final total = meta['totalMatches'] as int? ?? 0;
        final sess = meta['sessionsScanned'] as int? ?? 0;
        final suffix = result.truncated ? ' [truncated]' : '';
        label = '"$pattern": $total matches in $sess sessions$suffix';
        break;
      case 'archive':
      case 'unarchive':
        final sid = meta['sessionId'] as int?;
        final title = (meta['title'] as String?) ?? '';
        label = action == 'archive' ? 'archived ' : 'unarchived ';
        label += sid != null ? '#$sid $title'.trim() : '?';
        break;
      default:
        label = action;
    }
    final total = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    return CollapsedSummary(text: label, argsTokens: total, totalTokens: total);
  }

  @override
  String get description =>
      'Inspect OTHER Crux chat sessions — the agent already has the current '
      'conversation in context, so this tool is for looking at past sessions. '
      'Read actions never mutate anything. '
      'Actions: '
      '`list` (other sessions for the current project, most-recent first; the '
      'current session is hidden by default — pass `includeCurrent: true` to '
      'see it; pass `project=""` to span all projects), '
      '`show` (one session\'s metadata + recent-message summary; `sessionId` '
      'is required), '
      '`messages` (full messages from one session, paginated by id; '
      '`sessionId` is required), '
      '`search` (regex across messages in one or more sessions, ripgrep-style; '
      'the current session is excluded unless pinned via `sessionId` or '
      '`includeCurrent: true`), '
      '`archive` (move a session out of the sidebar into the archived set; '
      '`sessionId` is required and must NOT be the current session — when '
      'the user asks to clean up / tidy old sessions, list first, confirm '
      'which ones, then archive), '
      '`unarchive` (restore an archived session to the sidebar; `sessionId` '
      'is required — e.g. the user wants to revisit a session referenced by '
      'an old `ses://<id>` link). '
      'Tool results (the `tool` role rows that record bash / read / edit output) '
      'are searchable like any other content. '
      'Search is bounded: by default it scans the 50 most-recent sessions so a '
      'multi-year project does not fan out to every session; raise `maxSessions` '
      'if you need a deeper sweep. '
      'Do NOT shell out to sqlite3 against the user-data dir to do this — '
      'call this tool directly. It is faster, returns structured output, and '
      'avoids shell-quoting bugs.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': const [
          'list',
          'show',
          'messages',
          'search',
          'archive',
          'unarchive',
        ],
        'description':
            'What to do. `list` needs no sessionId. `show` and `messages` '
            'require `sessionId`. `search` scans across sessions and can '
            'optionally be pinned to one via `sessionId`. `archive` / '
            '`unarchive` require `sessionId` (never the current session).',
      },
      'sessionId': {
        'type': 'integer',
        'description':
            'Required for `show`/`messages`/`archive`/`unarchive`: id of the '
            'target session. Optional for `search`: pin the search to one '
            'session. Ignored by `list`.',
      },
      'limit': {
        'type': 'integer',
        'description':
            'Max rows to return. For `list`: max sessions (default 20). '
            'For `show`/`messages`: max messages (default 20).',
      },
      'offset': {
        'type': 'integer',
        'description': 'For `list`: pagination offset (default 0).',
      },
      'beforeId': {
        'type': 'integer',
        'description':
            'For `messages`: only return messages with id < beforeId, for '
            'backward pagination of a long session.',
      },
      'includeArchived': {
        'type': 'boolean',
        'description': 'For `list`: include archived sessions (default false).',
      },
      'includeCurrent': {
        'type': 'boolean',
        'description':
            'For `list` and `search`: include the current session (default '
            'false). The agent already has the current conversation in '
            'context, so it is hidden/excluded by default; set true to '
            'include it. Ignored when `search` pins a `sessionId`.',
      },
      'project': {
        'type': 'string',
        'description':
            'For `list`: filter to sessions whose projectPath matches exactly. '
            'Empty string "" spans every project; omitted = current project.',
      },
      'role': {
        'type': 'string',
        'description':
            'For `messages`: filter by message role '
            '(user | assistant | tool_call | tool | system).',
      },
      'pattern': {
        'type': 'string',
        'description':
            'For `search`: regular expression applied to message content '
            '(content, reasoning content, and tool output). '
            'Use ripgrep syntax — see the `grep` tool description.',
      },
      'caseInsensitive': {
        'type': 'boolean',
        'description':
            'For `search`: case-insensitive matching (default false).',
      },
      'headLimit': {
        'type': 'integer',
        'description': 'For `search`: max matches to return (default 50).',
      },
      'maxSessions': {
        'type': 'integer',
        'description':
            'For `search`: max sessions to scan, most-recent first '
            '(default 50). Caps the blast radius on multi-year projects.',
      },
    },
    'required': const ['action'],
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final action = args['action'] as String?;
    if (action == null || action.isEmpty) {
      return ToolResult.error('Missing required parameter: action');
    }

    final sessionId = args['sessionId'] as int?;
    final projectFilter = args['project'] as String?;
    final resolvedProject = projectFilter == ''
        ? null
        : (projectFilter ?? ctx.workingDirectory);

    switch (action) {
      case 'list':
        return _listSessions(
          limit: (args['limit'] as int?) ?? 20,
          offset: (args['offset'] as int?) ?? 0,
          includeArchived: (args['includeArchived'] as bool?) ?? false,
          includeCurrent: (args['includeCurrent'] as bool?) ?? false,
          projectFilter: resolvedProject,
          ctx: ctx,
        );
      case 'show':
        if (sessionId == null) {
          return ToolResult.error(
            'Missing required parameter for action=show: sessionId. '
            'This tool is for inspecting other sessions — the current '
            'conversation is already in your context.',
          );
        }
        return _showSession(
          sessionId: sessionId,
          messageLimit: (args['limit'] as int?) ?? 20,
        );
      case 'messages':
        if (sessionId == null) {
          return ToolResult.error(
            'Missing required parameter for action=messages: sessionId. '
            'This tool is for reading other sessions\' messages — the '
            'current conversation is already in your context.',
          );
        }
        return _listMessages(
          sessionId: sessionId,
          limit: (args['limit'] as int?) ?? 20,
          beforeId: args['beforeId'] as int?,
          role: args['role'] as String?,
        );
      case 'search':
        final pattern = args['pattern'] as String?;
        if (pattern == null || pattern.isEmpty) {
          return ToolResult.error(
            'Missing required parameter for action=search: pattern',
          );
        }
        return _searchSessions(
          pattern: pattern,
          sessionId: sessionId,
          includeCurrent: (args['includeCurrent'] as bool?) ?? false,
          caseInsensitive: (args['caseInsensitive'] as bool?) ?? false,
          headLimit: (args['headLimit'] as int?) ?? 50,
          maxSessions: (args['maxSessions'] as int?) ?? 50,
          ctx: ctx,
        );
      case 'archive':
        if (sessionId == null) {
          return ToolResult.error(
            'Missing required parameter for action=archive: sessionId. '
            'Use `list` first to pick the session, and never archive the '
            'current session — the user drives that via `/archive`.',
          );
        }
        return _archiveSession(sessionId: sessionId, ctx: ctx);
      case 'unarchive':
        if (sessionId == null) {
          return ToolResult.error(
            'Missing required parameter for action=unarchive: sessionId. '
            'Find archived ids via `list` with `includeArchived: true`.',
          );
        }
        return _unarchiveSession(sessionId: sessionId);
      default:
        return ToolResult.error(
          'Unknown action: $action. Expected one of: '
          'list, show, messages, search, archive, unarchive.',
        );
    }
  }

  // ── list ──────────────────────────────────────────────────────────

  Future<ToolResult> _listSessions({
    required int limit,
    required int offset,
    required bool includeArchived,
    required bool includeCurrent,
    required String? projectFilter,
    required ToolContext ctx,
  }) async {
    // Fetch one extra row so we can detect "more available" past the
    // current-session filter without an extra round-trip.
    final all = await _store.list(
      projectPath: projectFilter,
      includeArchived: includeArchived,
      limit: limit + 2,
      offset: offset,
    );
    final filtered = includeCurrent
        ? all
        : all.where((s) => s.id != ctx.sessionId).toList();
    final hiddenCurrent =
        !includeCurrent && all.any((s) => s.id == ctx.sessionId);
    final hasMore = filtered.length > limit;
    final shown = hasMore ? filtered.sublist(0, limit) : filtered;

    final ids = shown.map((s) => s.id).toList();
    final counts = await _store.messageStore.countBySessions(ids);

    final buf = StringBuffer();
    if (shown.isEmpty) {
      buf.writeln('No other sessions found.');
      if (hiddenCurrent) {
        buf.writeln(
          '(the current session ${_sesRef(ctx.sessionId)} is hidden — '
          'pass `includeCurrent: true` to see it)',
        );
      } else if (projectFilter != null) {
        buf.writeln('(project filter: $projectFilter)');
      }
      return ToolResult(
        title: 'Session list',
        output: buf.toString().trimRight(),
        metadata: {
          'returned': 0,
          'total': all.length,
          'hasMore': false,
          'hiddenCurrent': hiddenCurrent,
        },
      );
    }

    buf.writeln(
      '${_pad('ID', 6)}  ${_pad('UPDATED', 17)}  '
      '${_pad('MSGS', 5)}  STATUS     TITLE',
    );
    buf.writeln('-' * 78);
    for (final s in shown) {
      final id = _sesRef(s.id);
      final updated = _formatTimestamp(s.updatedAt);
      final msgCount = counts[s.id] ?? 0;
      buf.writeln(
        '${_pad(id, 6)}  ${_pad(updated, 17)}  '
        '${_pad(msgCount.toString(), 5)}  '
        '${_pad(s.status.name, 9)}  ${s.title.isEmpty ? '(untitled)' : s.title}',
      );
    }
    if (hasMore) {
      buf.writeln(
        '... (more available — raise `limit` or use `offset` to paginate)',
      );
    }
    if (hiddenCurrent) {
      buf.writeln();
      buf.writeln(
        '(current session ${_sesRef(ctx.sessionId)} hidden — pass '
        '`includeCurrent: true` to include it)',
      );
    }

    return ToolResult(
      title: 'Session list',
      output: buf.toString().trimRight(),
      metadata: {
        'returned': shown.length,
        'total': all.length,
        'hasMore': hasMore,
        'hiddenCurrent': hiddenCurrent,
      },
    );
  }

  // ── show / current ────────────────────────────────────────────────

  Future<ToolResult> _showSession({
    required int sessionId,
    required int messageLimit,
  }) async {
    final session = await _store.getById(sessionId);
    if (session == null) {
      return ToolResult.error('No session with id ${_sesRef(sessionId)}');
    }

    final total = await _store.messageStore.countBySession(sessionId);
    final recent = await _store.messageStore.getMessages(
      sessionId,
      limit: messageLimit,
    );

    final buf = StringBuffer();
    buf.writeln(
      'Session ${_sesRef(session.id)} — '
      '"${session.title.isEmpty ? '(untitled)' : session.title}"',
    );
    buf.writeln(
      '  model:        ${session.model.isEmpty ? '(unset)' : session.model}',
    );
    buf.writeln(
      '  agent:        ${session.agent.isEmpty ? '(default)' : session.agent}',
    );
    buf.writeln('  status:       ${session.status.name}');
    buf.writeln(
      '  project:      '
      '${session.projectPath.isEmpty ? '(none)' : session.projectPath}',
    );
    if (session.parentId != null) {
      buf.writeln('  parent:       ${_sesRef(session.parentId!)}');
    }
    buf.writeln('  created:      ${_formatTimestamp(session.createdAt)}');
    buf.writeln('  updated:      ${_formatTimestamp(session.updatedAt)}');
    if (session.archivedAt != null) {
      buf.writeln('  archived:     ${_formatTimestamp(session.archivedAt!)}');
    }
    buf.writeln(
      '  tokens:       '
      'in=${session.tokensIn} out=${session.tokensOut} '
      'cached=${session.promptCacheHitTokens}',
    );
    if (session.thinkingMode.isNotEmpty) {
      buf.writeln(
        '  thinking:     ${session.thinkingMode}'
        '${session.reasoningEffort != null ? ' (${session.reasoningEffort})' : ''}',
      );
    }
    if (session.ttftMs > 0 || session.tokPerSec > 0) {
      buf.writeln(
        '  perf:         '
        'ttft=${session.ttftMs.toStringAsFixed(0)}ms '
        'tok/s=${session.tokPerSec.toStringAsFixed(1)}',
      );
    }

    buf.writeln();
    final showing = recent.length;
    if (total == 0) {
      buf.writeln('No messages.');
    } else {
      final verb = total > showing
          ? 'showing last $showing of $total'
          : 'all $total';
      buf.writeln('Recent messages ($verb):');
      buf.writeln('-' * 78);
      for (final m in recent) {
        _appendMessageHeader(buf, m);
        _appendMessageBody(buf, m);
      }
      if (total > showing) {
        buf.writeln(
          'Showing the $showing most recent of $total messages. '
          'Use action=`messages` with `beforeId=${recent.first.id}` '
          'to read earlier messages.',
        );
      }
    }

    return ToolResult(
      title: 'Session #${session.id}',
      output: buf.toString().trimRight(),
      metadata: {
        'sessionId': session.id,
        'title': session.title,
        'returned': showing,
        'totalMessages': total,
      },
    );
  }

  // ── messages ──────────────────────────────────────────────────────

  Future<ToolResult> _listMessages({
    required int sessionId,
    required int limit,
    int? beforeId,
    String? role,
  }) async {
    final session = await _store.getById(sessionId);
    if (session == null) {
      return ToolResult.error('No session with id ${_sesRef(sessionId)}');
    }

    final all = await _store.messageStore.getMessages(
      sessionId,
      limit: limit,
      beforeId: beforeId,
    );
    final filtered = role == null
        ? all
        : all.where((m) => m.role == role).toList();
    final total = await _store.messageStore.countBySession(sessionId);

    final buf = StringBuffer();
    buf.writeln(
      'Session ${_sesRef(session.id)} — '
      '"${session.title.isEmpty ? '(untitled)' : session.title}"',
    );
    buf.writeln(
      '(${filtered.length} of $total messages'
      '${role != null ? ', role=$role' : ''}'
      '${beforeId != null ? ', id < $beforeId' : ''})',
    );
    buf.writeln('-' * 78);

    if (filtered.isEmpty) {
      buf.writeln('(no messages match)');
    } else {
      for (final m in filtered) {
        _appendMessageHeader(buf, m);
        _appendMessageBody(buf, m);
      }
      // `filtered` is in chronological order. The first id is the
      // oldest on this page — pass it as `beforeId` to walk further
      // back. We have more to show iff we hit the limit (with
      // `beforeId` set, the cap means there might be older messages;
      // without `beforeId`, the cap means there might be older
      // messages we didn't include in the latest-N window).
      final moreAvailable = beforeId == null
          ? total > filtered.length
          : filtered.length == limit;
      if (moreAvailable) {
        final firstId = filtered.first.id;
        buf.writeln();
        buf.writeln(
          '(more messages exist — pass `beforeId=$firstId` to paginate)',
        );
      }
    }

    return ToolResult(
      title: 'Messages — session #${session.id}',
      output: buf.toString().trimRight(),
      metadata: {
        'sessionId': session.id,
        'returned': filtered.length,
        'total': total,
        'role': role,
        'beforeId': beforeId,
      },
    );
  }

  // ── search ────────────────────────────────────────────────────────

  Future<ToolResult> _searchSessions({
    required String pattern,
    required int? sessionId,
    required bool includeCurrent,
    required bool caseInsensitive,
    required int headLimit,
    required int maxSessions,
    required ToolContext ctx,
  }) async {
    final RegExp regex;
    try {
      regex = RegExp(pattern, caseSensitive: !caseInsensitive, multiLine: true);
    } catch (e) {
      return ToolResult.error('Invalid regex: $e');
    }

    int? singleSessionId = sessionId;

    // Determine which sessions to scan. When the caller pins a sessionId
    // we scan only that one; otherwise we take the most-recent N
    // (capped by `maxSessions`) so a multi-year project doesn't fan
    // out to every session.
    final List<Session> sessionsToScan;
    if (singleSessionId != null) {
      final session = await _store.getById(singleSessionId);
      if (session == null) {
        return ToolResult.error(
          'No session with id ${_sesRef(singleSessionId)}',
        );
      }
      sessionsToScan = [session];
    } else {
      // Consistent with `list`: the current session is excluded unless the
      // caller explicitly asks for it via `includeCurrent` — the agent
      // already has the current conversation in context. Over-fetch one
      // row so excluding the current session doesn't shrink the scan
      // below the requested `maxSessions`.
      final listed = await _store.list(
        projectPath: ctx.workingDirectory,
        includeArchived: false,
        limit: includeCurrent ? maxSessions : maxSessions + 1,
        offset: 0,
      );
      sessionsToScan = includeCurrent
          ? listed
          : listed.where((s) => s.id != ctx.sessionId).toList();
    }

    if (sessionsToScan.isEmpty) {
      return ToolResult(
        title: 'Search: $pattern',
        output: 'No sessions to search.',
        metadata: {'totalMatches': 0, 'sessionsScanned': 0, 'truncated': false},
      );
    }

    final matches = StringBuffer();
    int totalMatches = 0;
    bool truncated = false;
    final sessionCount = sessionsToScan.length;

    for (final session in sessionsToScan) {
      if (totalMatches >= headLimit) {
        truncated = true;
        break;
      }
      final messages = await _store.messageStore.getMessages(
        session.id,
        limit: 100000, // session cap, not match cap
      );

      for (final m in messages) {
        if (totalMatches >= headLimit) {
          truncated = true;
          break;
        }
        final haystacks = <String>[
          m.content,
          if (m.reasoningContent.isNotEmpty) m.reasoningContent,
        ];
        for (final hay in haystacks) {
          for (final match in regex.allMatches(hay)) {
            if (totalMatches >= headLimit) {
              truncated = true;
              break;
            }
            final excerpt = _excerptAround(hay, match.start, match.end, 80);
            final sessionLabel = session.title.isEmpty
                ? _sesRef(session.id)
                : '${_sesRef(session.id)} "${_truncate(session.title, 40)}"';
            matches.writeln(
              '$sessionLabel:msg#${m.id} '
              '(${m.role}, ${_formatTimestamp(m.createdAt)}) '
              'offset=${match.start}: $excerpt',
            );
            totalMatches++;
          }
          if (totalMatches >= headLimit) break;
        }
        if (totalMatches >= headLimit) break;
      }
    }

    final buf = StringBuffer();
    if (totalMatches == 0) {
      buf.writeln('No matches for pattern: $pattern');
    } else {
      buf.writeln(
        'Search "$pattern" — '
        '$totalMatches match${totalMatches == 1 ? '' : 'es'} '
        'across $sessionCount session${sessionCount == 1 ? '' : 's'}',
      );
      buf.write(matches);
    }
    if (truncated) {
      buf.writeln();
      buf.writeln(
        '(truncated: showing first $headLimit matches — '
        'raise `headLimit` or narrow `pattern` to see more)',
      );
    }

    return ToolResult(
      title: 'Search: $pattern',
      output: buf.toString().trimRight(),
      truncated: truncated,
      metadata: {
        'totalMatches': totalMatches,
        'sessionsScanned': sessionCount,
        'truncated': truncated,
        // ignore: use_null_aware_elements
        if (singleSessionId != null) 'sessionId': singleSessionId,
      },
    );
  }

  // ── archive / unarchive ───────────────────────────────────────────

  /// Archive [sessionId]: flip `archivedAt` and drop it from the live
  /// sidebar list. Guards:
  ///   * unknown id → error;
  ///   * the current session → error (the agent must never pull the
  ///     session it is running in out from under itself; the user
  ///     drives that via `/archive`);
  ///   * already archived → error (idempotence with a visible cause,
  ///     mirroring `/unarchive`'s "not archived" toast);
  ///   * live running in another Crux instance → error (same lease
  ///     rule the sidebar's switch respects).
  Future<ToolResult> _archiveSession({
    required int sessionId,
    required ToolContext ctx,
  }) async {
    final session = await _store.getById(sessionId);
    if (session == null) {
      return ToolResult.error('No session with id ${_sesRef(sessionId)}');
    }
    if (sessionId == ctx.sessionId) {
      return ToolResult.error(
        'Cannot archive the current session ${_sesRef(sessionId)} — the '
        'agent is running inside it. Ask the user to run `/archive` '
        'instead if that is the intent.',
      );
    }
    if (session.archivedAt != null) {
      return ToolResult.error(
        'Session ${_sesRef(sessionId)} is already archived '
        '(${_formatTimestamp(session.archivedAt!)}).',
      );
    }
    if (_store.isLiveRunningSessionOwnedByAnotherInstance(session)) {
      return ToolResult.error(
        'Session ${_sesRef(sessionId)} is running in another Crux '
        'instance — archive it from there once it finishes.',
      );
    }
    await _store.archiveSession(sessionId);
    await onSessionMutated?.call(sessionId, true);
    return ToolResult(
      title: 'Archived — session #${session.id}',
      output:
          'Archived ${_sesRef(session.id)} '
          '"${session.title.isEmpty ? '(untitled)' : session.title}". '
          'It no longer appears in the sidebar; restore it with '
          'action=unarchive.',
      metadata: {
        'sessionId': session.id,
        'title': session.title,
        'archived': true,
      },
    );
  }

  /// Unarchive [sessionId]: clear `archivedAt` so the session returns
  /// to the live sidebar list. A session that wasn't archived is an
  /// error (visible, idempotent) rather than a silent no-op.
  Future<ToolResult> _unarchiveSession({required int sessionId}) async {
    final session = await _store.getById(sessionId);
    if (session == null) {
      return ToolResult.error('No session with id ${_sesRef(sessionId)}');
    }
    if (session.archivedAt == null) {
      return ToolResult.error(
        'Session ${_sesRef(sessionId)} is not archived — it is already '
        'in the sidebar.',
      );
    }
    await _store.unarchiveSession(sessionId);
    await onSessionMutated?.call(sessionId, false);
    return ToolResult(
      title: 'Unarchived — session #${session.id}',
      output:
          'Unarchived ${_sesRef(session.id)} '
          '"${session.title.isEmpty ? '(untitled)' : session.title}". '
          'It is back in the sidebar session list.',
      metadata: {
        'sessionId': session.id,
        'title': session.title,
        'archived': false,
      },
    );
  }

  // ── helpers ───────────────────────────────────────────────────────

  /// Render [sessionId] as the clickable reference format the TUI
  /// recognises — `ses://<id>`. The prompt teaches the LLM this
  /// format, and the session tool emits it in its output so the
  /// agent sees the convention in context and writes it back in
  /// replies without further prompting.
  ///
  /// Kept distinct from the user-facing `#<id>` used in collapsed
  /// summaries and `ToolResult.title` — `#` reads more naturally in
  /// a one-line collapsed chip, but in the LLM-facing tool body
  /// we want every session id to carry the clickable scheme so the
  /// agent copies the form verbatim when it references a session.
  static String _sesRef(int sessionId) => 'ses://$sessionId';

  static String _pad(String s, int width) {
    if (s.length >= width) return s;
    return s + ' ' * (width - s.length);
  }

  static String _formatTimestamp(DateTime t) {
    final local = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max - 1)}…';
  }

  /// One-line preview of [s] centred on [start..end]. Preserves as
  /// much context as possible without crossing too many newlines.
  static String _excerptAround(String s, int start, int end, int maxLen) {
    const span = 60;
    final from = (start - span).clamp(0, s.length);
    final to = (end + span).clamp(0, s.length);
    var excerpt = s
        .substring(from, to)
        .replaceAll('\n', ' ')
        .replaceAll('\r', '');
    if (from > 0) excerpt = '…$excerpt';
    if (to < s.length) excerpt = '$excerpt…';
    excerpt = excerpt.trim();
    if (excerpt.length > maxLen) {
      excerpt = '${excerpt.substring(0, maxLen - 1)}…';
    }
    return excerpt;
  }

  static void _appendMessageHeader(StringBuffer buf, Message m) {
    final header = StringBuffer()
      ..write('[#${m.id}] ')
      ..write(_formatTimestamp(m.createdAt))
      ..write('  ')
      ..write(m.role);
    if (m.model.isNotEmpty) header.write('  (${m.model})');
    if (m.tokensIn > 0 || m.tokensOut > 0) {
      header.write('  tokens in=${m.tokensIn} out=${m.tokensOut}');
    }
    if (m.error != null) header.write('  ERROR: ${m.error}');
    buf.writeln(header.toString());
  }

  static void _appendMessageBody(StringBuffer buf, Message m) {
    if (m.content.isNotEmpty) {
      _appendIndentedBlock(buf, m.content, 120);
    }
    if (m.reasoningContent.isNotEmpty) {
      buf.writeln('  reasoning:');
      _appendIndentedBlock(buf, m.reasoningContent, 120);
    }
    if (m.toolCalls.isNotEmpty) {
      buf.writeln('  tool_calls:');
      for (final tc in m.toolCalls) {
        final argsPreview = _summarizeArgs(tc.input);
        buf.writeln(
          '    - ${tc.name} (id=${_truncate(tc.callId, 24)}): $argsPreview',
        );
      }
    }
    buf.writeln();
  }

  static void _appendIndentedBlock(
    StringBuffer buf,
    String content,
    int maxLineLen,
  ) {
    for (final line in content.split('\n')) {
      final clipped = line.length > maxLineLen
          ? '${line.substring(0, maxLineLen - 1)}…'
          : line;
      buf.writeln('  $clipped');
    }
  }

  @override
  bool get skipInPrune => true;

  static String _summarizeArgs(Map<String, dynamic> args) {
    if (args.isEmpty) return '{}';
    // Pick the most informative single key — `command`, `filePath`,
    // `pattern`, `intent`, `url` — and fall back to a generic summary.
    const preferredKeys = ['command', 'filePath', 'pattern', 'intent', 'url'];
    for (final k in preferredKeys) {
      final v = args[k];
      if (v is String && v.isNotEmpty) {
        return '$k: ${_truncate(v, 80)}';
      }
    }
    final first = args.entries.first;
    final v = first.value;
    if (v is String) return '${first.key}: ${_truncate(v, 80)}';
    return '${first.key}: <${v.runtimeType}>';
  }
}
