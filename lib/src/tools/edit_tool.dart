import 'dart:convert';
import 'dart:io';

import '../lsp/manager.dart' show LspManager;
import '../lsp/protocol.dart' show LspDiagnostic;
import '../utils/file_metadata.dart';
import '../utils/token_estimate.dart' show estimateToolRoundTripTokens;
import 'file_lock.dart';
import 'file_read_tracker.dart';
import 'matchers/matcher.dart';
import 'matchers/exact_matcher.dart';
import 'matchers/whitespace_matcher.dart';
import 'matchers/indentation_matcher.dart';
import 'tool_def.dart';
import '../models/message.dart';
import '../utils/tool_metrics_animator.dart';

class EditTool extends ToolDef with IntentionalTool {
  @override
  String get name => 'edit';

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final oldString = args['oldString'] as String? ?? '';
    final newString = args['newString'] as String? ?? '';
    final replaceAll = (args['replaceAll'] as bool?) ?? false;
    // The replacement count used to be stashed on the input
    // args map (as `_replaceCount`) by execute() and read back
    // here. That had two problems: (1) the args map is the
    // LLM-controlled input — once the model saw the field in
    // conversation history it would occasionally echo it back,
    // sometimes as a string, and the JSON round-trip through
    // SQLite preserved the bad type, crashing this bubble's
    // build on a defensive `as int?` cast. (2) it conflated
    // user input with tool internal state.
    //
    // The count is already in the human-readable output text
    // (`"Replaced N occurrence(s) of oldString ..."`), which
    // is set by execute() and never user-controlled. Parse it
    // out instead. Falls back to 1 when the output doesn't
    // match the expected shape (e.g. legacy or error output).
    final replaceCount =
        _replaceCountFromOutput(result.output) ??
        (replaceAll ? _allFallbackCount(args) : 1);
    final oldLines = oldString.isEmpty
        ? 0
        : '\n'.allMatches(oldString).length + 1;
    final newLines = newString.isEmpty
        ? 0
        : '\n'.allMatches(newString).length + 1;
    final linesRemoved = oldLines * replaceCount;
    final linesAdded = newLines * replaceCount;
    final totalTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: result.output,
    );
    final argsTokens = estimateToolRoundTripTokens(
      toolName: name,
      args: args,
      resultOutput: '',
    );
    String text;
    if (oldLines == 0) {
      text = 'new file, $newLines lines';
    } else {
      final parsedCount = _replaceCountFromOutput(result.output);
      final countLabel = parsedCount != null
          ? '$parsedCount'
          : (replaceAll ? 'all' : '1');
      final replacementLabel = countLabel == '1'
          ? '1 replacement'
          : '$countLabel replacements';
      text = '$replacementLabel, +$linesAdded -$linesRemoved lines';
    }
    return CollapsedSummary(
      text: text,
      argsTokens: argsTokens,
      totalTokens: totalTokens,
    );
  }

  @override
  ToolMetricsLineDelta? toolMetricsLineDelta(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    // Mirror the logic in [collapsedSummary] above so the
    // post-call animation lands on the same `+added -removed`
    // values the streaming bubble shows while the LLM is
    // still emitting input. For new files (`oldLines == 0`)
    // the `-N` half is omitted — matches the `git diff --stat`
    // convention and the streaming bubble's all-null default
    // for `edit` calls before the new content arrives.
    final oldString = args['oldString'] as String? ?? '';
    final newString = args['newString'] as String? ?? '';
    final replaceAll = (args['replaceAll'] as bool?) ?? false;
    final replaceCount =
        _replaceCountFromOutput(result.output) ??
        (replaceAll ? _allFallbackCount(args) : 1);
    final oldLines = oldString.isEmpty
        ? 0
        : '\n'.allMatches(oldString).length + 1;
    final newLines = newString.isEmpty
        ? 0
        : '\n'.allMatches(newString).length + 1;
    return ToolMetricsLineDelta(
      addedLines: newLines * replaceCount,
      removedLines: oldLines == 0 ? null : oldLines * replaceCount,
    );
  }

  /// Parse the replacement count out of an EditTool success
  /// message. Looks for the canonical
  /// `"Replaced N occurrence(s) of oldString ..."` form that
  /// `_doMutation` emits. Returns null for any other shape
  /// (new-file, auto-read, error, future format changes) so
  /// the caller can pick a sensible fallback.
  static final RegExp _replacedCountPattern = RegExp(
    r'Replaced (\d+) occurrence',
  );

  static int? _replaceCountFromOutput(String output) {
    final match = _replacedCountPattern.firstMatch(output);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// Used only as a placeholder for the unreplaced count when
  /// the output doesn't carry one and replaceAll is true. The
  /// displayed diff is computed against a single replacement
  /// (since the bubble doesn't actually know N) and the label
  /// collapses to `"all"` so the user sees the qualitative
  /// "multiple replacements" intent. Match prior behavior.
  static int _allFallbackCount(Map<String, dynamic> args) => 1;

  @override
  String get description =>
      'Replaces exact text in a file. '
      'Use replaceAll for renaming across file. '
      'CALL MULTIPLE IN PARALLEL — issue as many edit calls in one '
      'turn as you need, including several against the SAME file. '
      'Same-file edits are serialized internally so all of them apply '
      'in emission order; edits to different files run in parallel. '
      'This saves roundtrips. Mixing edit with read and grep in the '
      'same turn is also encouraged when the calls are independent.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'properties': {
      'filePath': {'type': 'string', 'description': 'Path to file'},
      'oldString': {
        'type': 'string',
        'description': 'Text to replace (must differ from newString)',
      },
      'newString': {
        'type': 'string',
        'description': 'Replacement text (must differ from oldString)',
      },
      'replaceAll': {
        'type': 'boolean',
        'description': 'Replace all occurrences (default false)',
      },
      'intent': {
        'type': 'string',
        'description': 'What this edit accomplishes. Be concise.',
      },
    },
    'required': ['filePath', 'oldString', 'newString', 'intent'],
  };

  final FileReadTracker? tracker;
  final LspManager? lsp;
  final List<Matcher> _matchers = [
    ExactMatcher(),
    IndentationMatcher(),
    WhitespaceMatcher(),
  ];

  EditTool({this.tracker, this.lsp});

  Future<GuardResult?> checkStreamingGuard({
    required String filePath,
    required String oldString,
    required String workingDirectory,
  }) async {
    if (oldString.isEmpty) return null;

    final resolved = resolvePath(filePath, workingDirectory);
    final t = tracker;
    if (t != null) {
      final writeGuard = await t.checkWriteGuard(resolved);
      if (writeGuard != null) {
        return GuardResult(
          header: writeGuard.header,
          content: writeGuard.content,
          reason: writeGuard.reason ?? 'read-before-write',
        );
      }
    }

    final file = File(resolved);
    if (!file.existsSync()) return null;

    final bytes = await file.readAsBytes();
    final meta = readFileWithMetadata(bytes);
    final targetLineEnding = targetLineEndingFor(resolved, meta.lineEnding);
    final content = targetLineEnding == null
        ? meta.content
        : normalizeToLineEnding(meta.content, targetLineEnding);
    final oldStringForMatch = targetLineEnding == null
        ? oldString
        : normalizeToLineEnding(oldString, targetLineEnding);

    if (_findMatch(content, oldStringForMatch, true) != null) {
      return null;
    }

    return GuardResult(
      header:
          '[GUARD] Edit was BLOCKED — oldString does not match any text '
          'in the file. Your edit did NOT take effect. The current file '
          'content is below; pick a different oldString and try again.',
      content: content,
      reason: 'oldString-no-match',
    );
  }

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final filePath = args['filePath'] as String?;
    final oldString = args['oldString'] as String?;
    final newString = args['newString'] as String?;
    final replaceAll = (args['replaceAll'] as bool?) ?? false;

    if (filePath == null || filePath.isEmpty) {
      return ToolResult.error('Missing required parameter: filePath');
    }
    if (oldString == null) {
      return ToolResult.error('Missing required parameter: oldString');
    }
    if (newString == null) {
      return ToolResult.error('Missing required parameter: newString');
    }
    if (oldString == newString) {
      return ToolResult.error('oldString and newString must be different');
    }

    final resolved = resolvePath(filePath, ctx.workingDirectory);
    final file = File(resolved);
    if (!file.existsSync()) {
      return ToolResult.error(
        'File not found: ${relativePath(resolved, ctx.workingDirectory)}',
      );
    }

    return fileLock(resolved).run(
      () => _doMutation(
        args: args,
        resolved: resolved,
        file: file,
        oldString: oldString,
        newString: newString,
        replaceAll: replaceAll,
        ctx: ctx,
      ),
    );
  }

  Future<ToolResult> _doMutation({
    required Map<String, dynamic> args,
    required String resolved,
    required File file,
    required String oldString,
    required String newString,
    required bool replaceAll,
    required ToolContext ctx,
  }) async {
    if (ctx.abort.isAborted) {
      return ToolResult.error('Tool aborted');
    }
    if (tracker != null) {
      final guard = await tracker!.checkWriteGuard(resolved);
      if (guard != null) {
        return ToolResult(
          title: 'Read-before-write guard triggered',
          output: '${guard.header}\n\n${guard.content}',
          metadata: {'guardTriggered': true},
        );
      }
    }

    final bytes = await file.readAsBytes();
    final meta = readFileWithMetadata(bytes);
    final targetLineEnding = targetLineEndingFor(resolved, meta.lineEnding);
    final content = targetLineEnding == null
        ? meta.content
        : normalizeToLineEnding(meta.content, targetLineEnding);
    final oldStringForMatch = (targetLineEnding == null || oldString.isEmpty)
        ? oldString
        : normalizeToLineEnding(oldString, targetLineEnding);

    if (oldString.isEmpty) {
      if (targetLineEnding != null) {
        await _writePreservingEncoding(
          file,
          normalizeToLineEnding(newString, targetLineEnding),
          meta,
          overrideLineEnding: targetLineEnding,
        );
      } else {
        await _writePreservingEncoding(file, newString, meta);
      }
      if (tracker != null) {
        await tracker!.recordRead(resolved, await _mtimeMs(file));
      }
      final newLines = newString.isEmpty
          ? 0
          : '\n'.allMatches(newString).length + 1;
      final lspResult = await _collectLspDiagnostics(
        resolved,
        _successMessage(
          relativePath(resolved, ctx.workingDirectory),
          'Created file with $newLines lines (+$newLines lines)',
          args,
        ),
        ctx,
      );
      // The output text stays as just the diff line; the LSP
      // count is surfaced via the [LspDiagnosticsBubble] in the
      // chat history, not appended here. The diagnostics still
      // travel in metadata so the chat service can persist the
      // bubble and any future consumer can render details.
      return ToolResult(
        title: 'Edit file: $resolved',
        output: lspResult.output,
        metadata: {'lsp': lspResult.diagnostics},
      );
    }

    final matchResult = _findMatch(content, oldStringForMatch, replaceAll);
    if (matchResult == null) {
      return _autoReadResult(
        resolved,
        'The oldString was not found in the file.',
        content,
      );
    }
    if (matchResult.error != null) {
      return _autoReadResult(resolved, '${matchResult.error}', content);
    }
    final matchLen = matchResult.matchLength ?? oldStringForMatch.length;
    if (_isDisproportionateMatch(oldStringForMatch, matchLen)) {
      return _autoReadResult(
        resolved,
        'Refusing replacement because the matched span ($matchLen chars) '
        'is much larger than oldString (${oldString.length} chars). '
        'The oldString was too vague and matched a much larger block '
        'than intended.',
        content,
      );
    }

    final newContent = _applyReplacements(
      content,
      matchResult.positions,
      oldStringForMatch,
      newString,
      replaceAll,
      matchResult.matchLength,
    );
    if (targetLineEnding != null) {
      final normalized = normalizeToLineEnding(newContent, targetLineEnding);
      await _writePreservingEncoding(
        file,
        normalized,
        meta,
        overrideLineEnding: targetLineEnding,
      );
    } else {
      await _writePreservingEncoding(file, newContent, meta);
    }
    if (tracker != null) {
      await tracker!.recordRead(resolved, await _mtimeMs(file));
    }

    final count = matchResult.positions.length;
    final oldLines = oldString.isEmpty
        ? 0
        : '\n'.allMatches(oldString).length + 1;
    final newLines = newString.isEmpty
        ? 0
        : '\n'.allMatches(newString).length + 1;
    final linesRemoved = oldLines * count;
    final linesAdded = newLines * count;
    final occLabel = count == 1 ? 'occurrence' : 'occurrences';
    final lspResult = await _collectLspDiagnostics(
      resolved,
      _successMessage(
        relativePath(resolved, ctx.workingDirectory),
        'Replaced $count $occLabel of oldString '
        '(+$linesAdded -$linesRemoved lines)',
        args,
      ),
      ctx,
    );
    return ToolResult(
      title: 'Edit file: $resolved',
      output: lspResult.output,
      metadata: {'lsp': lspResult.diagnostics},
    );
  }

  String _successMessage(
    String relPath,
    String body,
    Map<String, dynamic> args,
  ) {
    final intent = args['intent'];
    if (intent is String && intent.isNotEmpty) {
      return 'Edit applied to $relPath (intent: \'$intent\'): $body';
    }
    return 'Edit applied to $relPath: $body';
  }

  /// Append LSP diagnostics for [filePath] to [baseOutput], if any.
  ///
  /// Returns the (possibly-modified) output text and the raw
  /// diagnostic list. The list is exposed in [ToolResult.metadata]
  /// under the `lsp` key so [collapsedSummary] can show the count
  /// and the UI/agent can render or query the details.
  ///
  /// The output text gets a brief one-liner only (no verbose
  /// `<diagnostics>` block) — the count goes in the hint bubble
  /// instead, keeping the tool output scannable. The model can
  /// always call `read` or re-run the analyzer for details.
  ///
  /// Best-effort: any failure (no LSP, no server, timeout, malformed
  /// response) returns ([baseOutput], const []). The tool must
  /// never fail because of LSP.
  Future<({String output, List<LspDiagnostic> diagnostics})>
  _collectLspDiagnostics(
    String filePath,
    String baseOutput,
    ToolContext ctx,
  ) async {
    final mgr = lsp;
    if (mgr == null) {
      return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
    }
    try {
      if (ctx.abort.isAborted) {
        return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
      }
      final diagnostics = await mgr.touchFileAndWait(
        filePath,
        isCancelled: () => ctx.abort.isAborted,
      );
      if (diagnostics.isEmpty) {
        return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
      }
      // Output text stays clean; the count is surfaced via the
      // [LspDiagnosticsBubble] in the chat history, not appended
      // to the tool's textual output.
      return (output: baseOutput, diagnostics: diagnostics);
    } catch (_) {
      return (output: baseOutput, diagnostics: const <LspDiagnostic>[]);
    }
  }

  /// (Deprecated stub kept for source compatibility with tests.)
  /// The LSP count hint is now surfaced via [LspDiagnosticsBubble]
  /// in the chat history rather than appended to the collapsed
  /// summary.
  // ignore: unused_element
  static String _appendLspHint(String text, Map<String, dynamic> metadata) {
    return text;
  }

  MatchResult? _findMatch(String content, String oldString, bool replaceAll) {
    for (final matcher in _matchers) {
      final result = matcher.findMatches(content, oldString, replaceAll);
      if (result != null && result.error == null) {
        if (matcher is ExactMatcher) {
          final pos = result.positions.first;
          if (_isMidWhitespaceRun(content, pos)) continue;
        }
        return result;
      }
      if (result != null && result.error != null && matcher is ExactMatcher) {
        return result;
      }
    }
    return null;
  }

  String _applyReplacements(
    String content,
    List<int> positions,
    String oldString,
    String newString,
    bool replaceAll,
    int? matchLength,
  ) {
    final len = matchLength ?? oldString.length;
    if (replaceAll) {
      var result = content;
      for (final pos in positions.reversed) {
        result =
            result.substring(0, pos) + newString + result.substring(pos + len);
      }
      return result;
    }
    final pos = positions.first;
    return content.substring(0, pos) + newString + content.substring(pos + len);
  }

  Future<void> _writePreservingEncoding(
    File file,
    String text,
    FileReadResult meta, {
    String? overrideLineEnding,
  }) async {
    final body = overrideLineEnding == null
        ? normalizeToLineEnding(text, meta.lineEnding)
        : text;
    final encoded = utf8.encode(body);
    if (meta.encoding == 'utf-8-bom') {
      await file.writeAsBytes(<int>[0xEF, 0xBB, 0xBF, ...encoded]);
    } else {
      await file.writeAsBytes(encoded);
    }
  }

  Future<int> _mtimeMs(File file) async {
    final stat = await file.stat();
    return stat.modified.millisecondsSinceEpoch;
  }

  ToolResult _autoReadResult(String filePath, String reason, String content) {
    return ToolResult(
      title: 'Auto-read: $filePath',
      output:
          '[AUTOREAD] No changes were made — $reason\n\n'
          'We re-read the file for you (saved a round trip). '
          'The current content is below; you can call edit again '
          'now without having to call read first.\n\n'
          '$content',
      metadata: {'autoRead': true},
    );
  }

  bool _isMidWhitespaceRun(String content, int pos) {
    if (pos <= 0) return false;
    if (pos >= content.length) return false;
    final at = content[pos];
    final prev = content[pos - 1];
    final atIsWs = at == ' ' || at == '\t';
    final prevIsWs =
        prev == ' ' || prev == '\t' || prev == '\n' || prev == '\r';
    return atIsWs && prevIsWs;
  }

  bool _isDisproportionateMatch(String oldString, int matchLen) {
    final oldLines = '\n'.allMatches(oldString).length + 1;
    if (oldLines == 1) return false;
    final avgLineLen = oldString.length / oldLines;
    final matchLines = (matchLen / avgLineLen).round();
    if (matchLines >= oldLines * 3 && matchLines >= oldLines + 5) {
      return true;
    }
    return matchLen > oldString.length * 4 && matchLen > oldString.length + 500;
  }

  @override
  String renderPruneInline({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
  }) {
    final path = call.input['filePath']?.toString() ?? '?';
    final intent = (call.input['intent'] as String?) ?? '';
    final suffix = intent.isNotEmpty ? ' for {$intent}' : '';
    if (isError) return 'edit $path$suffix → $pairedResult';
    // No `→ $pairedResult` on success — the chat log body is a
    // compact call summary. Edit doesn't contribute to the
    // bottom-of-log section either (see [extractPruneSummary]):
    // the agent knows its own oldString/newString, the diff is
    // captured in the collapsed bubble, and the file's post-edit
    // state is on disk for the next `read` to pick up.
    return 'edit $path$suffix';
  }

  @override
  SummaryContribution? extractPruneSummary({
    required ToolCallData call,
    required String pairedResult,
    required bool isError,
    required String workingDirectory,
  }) {
    // Two edit paths contribute file content to the chat log's
    // `read files:` summary section. Everything else returns null
    // — the user spec keeps only `read files:` (and `write files:`
    // for newly created files); edit is "other" by that rubric on
    // the success path, since the model already has the diff
    // (oldString/newString) in its input args and the file's
    // post-edit state is on disk for the next `read` to pick up.
    //
    // The exceptions are the two cases where edit is effectively
    // "using the read tool" on the model's behalf:
    //
    //   1. Auto-read (oldString didn't match / ambiguous /
    //      disproportionate). The tool re-reads the file and
    //      returns the current content in the auto-read response.
    //      The model relies on that snapshot to formulate the
    //      retry's oldString, so the content is worth preserving
    //      verbatim in the `read files:` section — the resumed
    //      agent post-compact otherwise has no way to know what
    //      the model saw. Detected by the result text starting
    //      with `[AUTOREAD]`. (The matching prune filter is in
    //      [isNoOpForCompaction] — auto-read is NOT no-op, only
    //      guards and aborts are.)
    //
    //   2. Read-before-write guard. The guard returns the current
    //      file content as a hint for the retry. Same reasoning:
    //      the model relied on the snapshot to plan the fix. But
    //      the guard is filtered by [isNoOpForCompaction], so
    //      [extractPruneSummary] is never reached for that path
    //      — see the comment there. We don't try to recover the
    //      content here because the auto-read path is what the
    //      production code actually emits for the read-before-
    //      write case (the streaming guard's output and the
    //      post-execution guard's output are both routed through
    //      the same chat log pruning).
    if (isError) return null;
    if (!_looksLikeAutoRead(pairedResult)) return null;
    final raw = call.input['filePath']?.toString();
    if (raw == null || raw.isEmpty) return null;
    final content = _extractAutoReadContent(pairedResult);
    if (content == null) return null;
    final truncated = truncateForInline(
      content,
      kInlineReadMaxChars,
      hint: 're-read with offset/limit to see more',
    );
    return SummaryContribution.readFile(path: raw, content: truncated);
  }

  @override
  bool isNoOpForCompaction({
    required String pairedResult,
    required bool isError,
  }) {
    // The chat log drops edit calls whose result indicates the
    // file was NOT mutated. Two patterns, both surfaced in the
    // leading 200 chars of the result (see [_looksLikeError] for
    // the window-size rationale — file content further down the
    // body must not trigger a false positive):
    //
    //   * `[GUARD]…` — read-before-write guard (file was modified
    //     externally / was never read), oldString-no-match guard
    //     emitted from `checkStreamingGuard`, and the streaming
    //     abort case (`_buildGuardAbortedToolResult` reuses the
    //     same bracketed header shape). All three mean "the edit
    //     did NOT take effect; here's the current file content
    //     to retry against."
    //   * `Tool aborted` — the call was interrupted by
    //     `ctx.abort.isAborted` (user-initiated abort, parallel-
    //     tool sibling abort after a guard, etc.). The output is
    //     the literal string `Tool aborted` produced by
    //     `ToolResult.error('Tool aborted')` in `_doMutation`.
    //
    // Note we do NOT gate on [isError] here. `_looksLikeError`
    // catches `[GUARD]` and `Error: …` shapes, but not the
    // literal `Tool aborted` text — gating on `isError` would
    // let that one slip through. The text pattern alone is the
    // source of truth for this filter.
    //
    // NOT matched (intentionally kept): `[AUTOREAD]…`. The
    // auto-read response is filtered out of the success path
    // by `_looksLikeError` and is meaningful to preserve — the
    // call DID teach the model the file content, and
    // [extractPruneSummary] routes that into the
    // `read files:` summary section above. The inline chat log
    // line stays as `edit $path` (the tool the model actually
    // called) and the snapshot is preserved via the summary
    // section. Filtering the auto-read would lose that snapshot
    // for no real win.
    const leadingWindow = 200;
    final head = pairedResult.length > leadingWindow
        ? pairedResult.substring(0, leadingWindow)
        : pairedResult;
    final lower = head.toLowerCase();
    if (lower.startsWith('[guard]')) return true;
    if (head == 'Tool aborted') return true;
    return false;
  }
}

/// Whether [pairedResult] is the auto-read response emitted by
/// [_autoReadResult]. The check is the leading 200 chars of the
/// result text — `[AUTOREAD]` is always the first line. Mirrors
/// the leading-window reasoning in [_looksLikeError]: file
/// content further down the body must not trigger a false
/// positive, and the auto-read header is always emitted in line
/// one.
bool _looksLikeAutoRead(String pairedResult) {
  const leadingWindow = 200;
  final head = pairedResult.length > leadingWindow
      ? pairedResult.substring(0, leadingWindow)
      : pairedResult;
  return head.toLowerCase().startsWith('[autoread]');
}

/// Extract the file content from an auto-read response. The
/// response shape (emitted by [_autoReadResult]) is three
/// segments separated by blank lines:
///
///   [AUTOREAD] No changes were made — `<reason>`
///
///   We re-read the file for you (saved a round trip). The
///   current content is below; you can call edit again now
///   without having to call read first.
///
///   `<content>`
///
/// The content is everything after the second blank line.
/// Re-join with `\n\n` so file bodies that legitimately contain
/// blank lines are preserved verbatim. Returns null on any
/// structural mismatch so the caller can fall back to skipping
/// the contribution rather than emit a corrupt snapshot.
String? _extractAutoReadContent(String pairedResult) {
  // Find the first blank line.
  final firstBlank = pairedResult.indexOf('\n\n');
  if (firstBlank < 0) return null;
  // Skip past it and find the second blank line.
  final rest = pairedResult.substring(firstBlank + 2);
  final secondBlank = rest.indexOf('\n\n');
  if (secondBlank < 0) return null;
  // Content is everything after the second blank line, leading
  // whitespace trimmed (the [AUTOREAD] template leaves the file
  // body flush-left with no indent).
  final content = rest.substring(secondBlank + 2);
  return content.trimLeft();
}
