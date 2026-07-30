import 'dart:io';

import 'tool_def.dart';

/// Tracks which files have been read and their mtime at read time.
/// Used by edit/write to enforce the read-before-write guard.
///
/// Storage: in-memory map for the current session + persisted to
/// the `file_read_state` table so the guard survives session resume.
///
/// On top of that, attribution — which session last wrote each
/// file, and the `intent` it passed to that edit/write — is looked
/// up live from the `file_last_writer` table when the guard fires.
/// The tracker doesn't store attribution itself; the wiring in
/// `chat_panel.dart` injects a [lookupAttribution] callback that
/// does the DB query. The live lookup means `/rename` is reflected
/// in the guard message immediately.
class FileReadTracker {
  /// In-memory cache: normalized path → mtime at read time.
  /// Loaded from DB on session start, updated on every read/write.
  final Map<String, int> _cache = {};

  /// Current session. Set on construction for new sessions, by
  /// [loadSession] on resume. Drives the `onRecordRead`/`onRecordWrite`
  /// persistence callbacks (they no-op while `null`).
  int? _sessionId;

  /// Called after a successful read. Records path + mtime.
  /// Persistence failure is non-fatal — the in-memory cache update
  /// is sufficient for the current session.
  final Future<void> Function(
    int sessionId,
    String normalizedPath,
    int mtimeMs,
  )?
  onRecordRead;

  /// Called after a successful edit/write. Records path + mtime
  /// (so subsequent edits in the same session don't falsely trigger
  /// the guard) AND records the cross-session attribution row so
  /// other sessions' guards can name this writer + intent when
  /// they detect drift on the same file.
  final Future<void> Function(
    int sessionId,
    String normalizedPath,
    int mtimeMs,
    String intent,
  )?
  onRecordWrite;

  /// Look up the writer attribution for [normalizedPath]. Returns
  /// `null` when no attribution row exists or when the recorded
  /// mtime no longer matches the on-disk mtime (i.e. something
  /// external touched the file after our write — in that case the
  /// intent no longer reflects the file's current state).
  ///
  /// Returning `null` makes the guard drop the attribution line
  /// and fall back to the generic "file modified since last read"
  /// message. The title is included here (looked up live from
  /// `sessions.title`) so `/rename` changes show up immediately.
  ///
  /// Exposed via [lookupAttribution] below; callers shouldn't
  /// invoke this field directly.
  final Future<({int sessionId, String intent, String title})?> Function(
    String normalizedPath,
    int currentMtimeMs,
  )?
  onLookupAttribution;

  FileReadTracker({
    this._sessionId,
    this.onRecordRead,
    this.onRecordWrite,
    this.onLookupAttribution,
  });

  /// Look up the writer attribution for [normalizedPath]. Used by
  /// both the drift branch of [checkWriteGuard] and by the `read`
  /// tool to surface provenance before the agent commits to an
  /// edit. Returns `null` on lookup failure, missing row, mtime
  /// mismatch, or self-write (when the tracker has a session id).
  Future<({int sessionId, String intent, String title})?> lookupAttribution(
    String normalizedPath,
    int currentMtimeMs,
  ) async {
    final lookup = onLookupAttribution;
    if (lookup == null) return null;
    try {
      return await lookup(_normalize(normalizedPath), currentMtimeMs);
    } catch (_) {
      // Lookup failure is non-fatal — callers fall back to the
      // generic message without attribution.
      return null;
    }
  }

  Future<void> recordRead(String filePath, int mtimeMs) async {
    final normalized = _normalize(filePath);
    _cache[normalized] = mtimeMs;
    if (_sessionId != null && onRecordRead != null) {
      try {
        await onRecordRead!(_sessionId!, normalized, mtimeMs);
      } catch (_) {
        // Persistence failure is non-fatal — the in-memory cache
        // update above is sufficient for the current session.
      }
    }
  }

  /// Record a successful edit/write. Two effects:
  ///
  /// 1. Updates the in-memory read cache to the post-write mtime so
  ///    the next edit in the same session doesn't false-trigger the
  ///    drift branch.
  /// 2. Persists the cross-session attribution row so other
  ///    sessions' guards can name this session + intent.
  ///
  /// Both effects go through callbacks; persistence failure is
  /// non-fatal.
  Future<void> recordWrite(
    String filePath, {
    required int mtimeMs,
    required String intent,
  }) async {
    final normalized = _normalize(filePath);
    _cache[normalized] = mtimeMs;
    final sid = _sessionId;
    if (sid == null) return;

    if (onRecordRead != null) {
      try {
        await onRecordRead!(sid, normalized, mtimeMs);
      } catch (_) {
        /* see recordRead */
      }
    }
    if (onRecordWrite != null) {
      try {
        await onRecordWrite!(sid, normalized, mtimeMs, intent);
      } catch (_) {
        // Same as recordRead — persistence failure is non-fatal.
      }
    }
  }

  Future<GuardResult?> checkWriteGuard(String filePath) async {
    final normalized = _normalize(filePath);
    final file = File(filePath);

    if (!file.existsSync()) return null;

    final currentMtime = file.statSync().modified.millisecondsSinceEpoch;

    if (!_cache.containsKey(normalized)) {
      final content = file.readAsStringSync();
      await recordRead(filePath, currentMtime);
      return GuardResult(
        header:
            '[GUARD] Write was BLOCKED — file was not read before write. '
            'Your write did NOT take effect. The current file content is '
            'below; call edit or write again now and it will succeed '
            '(the file has been auto-read for you).',
        content: content,
        reason: 'read-before-write',
      );
    }

    final recordedMtime = _cache[normalized];
    if (recordedMtime != null && currentMtime > recordedMtime) {
      final content = file.readAsStringSync();
      await recordRead(filePath, currentMtime);

      // Look up cross-session attribution. Only shown when:
      //   - a FileLastWriter row exists for this path,
      //   - the recorded writer's mtime still matches the on-disk
      //     mtime (otherwise something external touched the file
      //     after our write and the intent no longer reflects the
      //     file's actual state — we'd be misleading the agent),
      //   - the writer is a different session, OR we have no
      //     session id on this tracker and so can't compare
      //     (self-attribution in the same session is noise, but
      //     we don't suppress attribution when the comparison is
      //     impossible).
      final attr = await lookupAttribution(normalized, currentMtime);
      final attributionLine = _formatAttribution(attr);

      return GuardResult(
        header:
            '[GUARD] Write was BLOCKED — file was modified since last '
            'read. Your write did NOT take effect.'
            '$attributionLine\n'
            'The new content is below; retry your edit with a pattern that matches this version.',
        content: content,
        reason: 'read-before-write',
      );
    }

    return null;
  }

  void loadFromMap(Map<String, int> data) {
    _cache.addAll(data.map((k, v) => MapEntry(_normalize(k), v)));
  }

  void loadSession(int sessionId, Map<String, int> data) {
    _sessionId = sessionId;
    _cache.clear();
    _cache.addAll(data.map((k, v) => MapEntry(_normalize(k), v)));
  }

  void clear() {
    _cache.clear();
  }

  Map<String, int> toMap() {
    return Map.fromEntries(_cache.entries);
  }

  /// Format an attribution row into the human-readable line that
  /// gets appended to a guard message or prepended to a read
  /// banner. Returns the empty string when the row is null
  /// (no attribution), the title is empty AND intent is empty
  /// (nothing meaningful to say), or the writer is the current
  /// session (self-attribution is noise).
  String _formatAttribution(
    ({int sessionId, String intent, String title})? attr,
  ) {
    if (attr == null) return '';
    if (_sessionId != null && attr.sessionId == _sessionId) return '';
    if (attr.title.isEmpty && attr.intent.isEmpty) return '';
    final titleSuffix = attr.title.isEmpty ? '' : ' [${attr.title}]';
    final intentSuffix = attr.intent.isEmpty
        ? ''
        : ', with intent: "${attr.intent}"';
    return '\n\nLast modified by session://${attr.sessionId}'
        '$titleSuffix$intentSuffix. '
        'Use the session tool to read that session for context.';
  }

  /// Format the attribution row as a single-line banner suitable
  /// for prepending to the `read` tool's output. Wrapped in a
  /// `[NOTE: …]` tag so the LLM recognizes it as informational
  /// metadata (sibling to `[GUARD]` / `[AUTOREAD]`). Returns the
  /// empty string when no attribution applies — caller should not
  /// add a blank line in that case.
  ///
  /// Same suppression rules as the drift branch: no row, mtime
  /// mismatch, self-write, or both title+intent empty → empty
  /// string.
  String _formatReadBanner(
    ({int sessionId, String intent, String title})? attr,
  ) {
    if (attr == null) return '';
    if (_sessionId != null && attr.sessionId == _sessionId) return '';
    if (attr.title.isEmpty && attr.intent.isEmpty) return '';
    final titleSuffix = attr.title.isEmpty ? '' : ' [${attr.title}]';
    final intentSuffix = attr.intent.isEmpty
        ? ''
        : ', with intent: "${attr.intent}"';
    return '[NOTE: last written by session://${attr.sessionId}'
        '$titleSuffix$intentSuffix. '
        'Use the session tool to read that session for context.]';
  }

  /// Public entry point used by the `read` tool. Looks up the
  /// attribution row and returns the pre-formatted banner line
  /// (or empty string). One DB roundtrip per call.
  Future<String> readAttributionBanner(
    String filePath,
    int currentMtimeMs,
  ) async {
    final attr = await lookupAttribution(filePath, currentMtimeMs);
    return _formatReadBanner(attr);
  }

  String _normalize(String path) {
    var p = path;
    if (!p.startsWith('/')) p = '/$p';
    p = p.replaceAll('/./', '/');
    p = p.replaceAll(RegExp(r'/\.$'), '');
    if (p.endsWith('/..')) {
      p = '${p.substring(0, p.length - 3)}/__dotdot__';
    }
    var iterations = 0;
    while (p.contains('/../') && iterations < 64) {
      p = p.replaceAll(RegExp(r'/[^/]+/\.\./'), '/');
      iterations++;
    }
    p = p.replaceAll('/__dotdot__', '/..');
    if (p.endsWith('/..')) {
      final lastSep = p.lastIndexOf('/', p.length - 4);
      if (lastSep > 0) {
        p = p.substring(0, lastSep);
      } else {
        p = '/';
      }
    }
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}
