/// Shell-tool fallback guard: detects when the LLM uses the shell
/// (bash / cmd / powershell) for operations that have a dedicated
/// Crux tool, and applies a three-tier escalation mirroring the
/// single-call-hint pattern:
///
///   * **mild** (1st consecutive violation) — run the command,
///     append a system note to the tool result explaining which
///     dedicated tool to use instead.
///   * **firm** (2nd consecutive) — same as mild, but with firmer
///     wording in the appended note.
///   * **reject** (3rd consecutive, no proper tool in between) —
///     refuse to execute the command at all. Return an error
///     result explaining what the LLM should have done.
///
/// The detector is intentionally conservative — only flags the
/// most blatant "bash + cat / sed / rg" fallbacks, not every
/// pipeline that happens to mention these commands. False
/// positives are cheap (the LLM just sees a reminder and proceeds
/// with whatever the shell returned), but a false-positive
/// rejection blocks real work, so the threshold sits on the
/// forgiving side.
///
/// State lives on [SessionRuntimeState.consecutiveShellViolations]
/// (mirroring the parallel-call drift detector). The shell tool
/// reads the current counter from the session runtime passed in
/// via `ToolContext.sessionRuntime` to decide severity, then
/// increments the counter on every violation. The chat service
/// resets the counter to 0 whenever a proper-tool call (`grep`,
/// `read`, `glob`, `code_search`) succeeds.
library;

// =============================================================================
// Public types
// =============================================================================

/// What category of dedicated-tool fallback the detected command
/// would belong to. Drives the rendered reminder's recommended
/// tool name and example mapping. [ShellGuardKind.none] is the
/// sentinel for "not a violation" — never surfaced through the
/// verdict; detector returns `null` instead.
enum ShellGuardKind {
  none,
  read,
  glob,
  grep,
  codeSearch,
}

/// Severity tier for a detected violation. Maps directly to the
/// existing single-call-hint escalation so the model's view of
/// "you've been warned, now you're being blocked" is consistent
/// across Crux's two drift detectors.
enum ShellGuardSeverity { none, mild, firm, reject }

/// Result of inspecting a shell command for fallback violations.
///
/// Constructed only when a violation is found — the detector
/// returns `null` for shell-native commands (builds, git,
/// package managers, process control, …) so callers branch on
/// `null` rather than on [ShellGuardSeverity.none].
class ShellGuardVerdict {
  final ShellGuardKind kind;

  /// The severity tier that applies to *this* call, computed
  /// from the counter value at the time of the call.
  final ShellGuardSeverity severity;

  /// Short human description of the anti-pattern detected, e.g.
  /// `"file inspection via shell"`. Used inside the reminder body.
  final String what;

  /// Name of the dedicated Crux tool the LLM should call instead
  /// (`read`, `grep`, `glob`, `code_search`).
  final String toolName;

  /// Short canonical example of the anti-pattern → dedicated-tool
  /// mapping, e.g. `"cat / sed -n / head → read"`. Used inside
  /// the reminder body for at-a-glance recognition.
  final String example;

  /// The original shell command, truncated for embedding into
  /// the reminder body. Keeps the embedded note short even if
  /// the LLM wrote a 50-token pipeline.
  final String command;

  /// The streak value AFTER this call. Convenience for callers
  /// that want to mirror the verdict's post-state to the runtime
  /// (the shell tool itself increments the runtime directly).
  final int streakAfter;

  const ShellGuardVerdict({
    required this.kind,
    required this.severity,
    required this.what,
    required this.toolName,
    required this.example,
    required this.command,
    required this.streakAfter,
  });
}

// =============================================================================
// Detection
// =============================================================================

/// Inspect [command] for fallback violations and return the
/// verdict (with severity) or `null` if the command looks like
/// a legitimate shell-native invocation.
///
/// [currentStreak] is the value of
/// `SessionRuntimeState.consecutiveShellViolations` BEFORE this
/// call — used to compute the severity tier. Pass `0` when the
/// caller doesn't have access to the runtime; the detector will
/// then assume this is the 1st violation (mild) or the Nth
/// (reject if N >= 2).
///
/// [isWindows] switches between bash/POSIX verbs and the
/// PowerShell cmdlets + cmd builtins used by the Windows shell
/// tools. Pass the value of `Platform.isWindows` at the call
/// site — keeping the detector platform-aware (rather than
/// always-checking both) makes the matches more accurate and
/// avoids cross-platform false positives (e.g. flagging `dir`
/// inside a bash script on Linux).
ShellGuardVerdict? detectShellGuard(
  String command, {
  required bool isWindows,
  required int currentStreak,
}) {
  if (command.trim().isEmpty) return null;

  final kind = isWindows
      ? _classifyWindows(command)
      : _classifyPosix(command);
  if (kind == ShellGuardKind.none) return null;

  final severity = _severityForStreak(currentStreak);
  if (severity == ShellGuardSeverity.none) {
    // Should not happen — kind != none always produces a tier.
    return null;
  }

  return ShellGuardVerdict(
    kind: kind,
    severity: severity,
    what: _whatForKind(kind),
    toolName: _toolForKind(kind),
    example: _exampleForKind(kind),
    command: command.length > 200 ? '${command.substring(0, 200)}…' : command,
    streakAfter: currentStreak + 1,
  );
}

/// Map a streak value to a severity tier. Streak is the count
/// BEFORE the current call:
///
///   * `streak <= 0` → [ShellGuardSeverity.mild] (this is the
///     1st violation in the current streak)
///   * `streak == 1` → [ShellGuardSeverity.firm] (2nd)
///   * `streak >= 2` → [ShellGuardSeverity.reject] (3rd+)
///
/// A defensive `none` is never returned here — the detector
/// only calls this when a violation has been found, so the
/// tier is always mild/firm/reject.
ShellGuardSeverity _severityForStreak(int streak) {
  if (streak <= 0) return ShellGuardSeverity.mild;
  if (streak == 1) return ShellGuardSeverity.firm;
  return ShellGuardSeverity.reject;
}

// =============================================================================
// POSIX (bash) classifier
// =============================================================================

/// Verbs whose presence at the start of any segment signals
/// "this is a file-inspection operation; should be `read`".
const _posixReadVerbs = <String>{
  'cat', 'head', 'tail', 'less', 'more', 'bat',
  'sed', 'awk', 'cut', 'sort', 'uniq',
  'wc', 'md5sum', 'shasum', 'sha1sum', 'sha256sum', 'sha512sum',
  'file', 'stat',
  'strings', 'hexdump', 'xxd', 'od', 'base32', 'base64',
  'tac', 'rev', 'nl', 'paste', 'column', 'expand', 'unexpand',
  'tr', 'fold', 'fmt',
  'cmp', 'comm',
  'diff', 'patch',
};

/// Verbs whose presence at the start of any segment signals
/// "this is a directory listing; should be `glob`".
const _posixListVerbs = <String>{'ls', 'tree', 'du', 'find'};

/// Verbs whose presence at the start of any segment signals
/// "this is a content search; should be `grep`".
const _posixGrepVerbs = <String>{
  'grep', 'egrep', 'fgrep', 'rg', 'ack', 'ag', 'ripgrep',
};

/// Classify a bash command. Walks the segments split by `|`,
/// `;`, `&&`, `||`, newlines; the first segment whose first
/// non-redirect verb matches a violation set wins. Special-cases
/// the `search-verb | head/tail` anti-pattern as `code_search`
/// before falling through to the verb classifier.
///
/// Per-segment rules (enforced by [_classifySegment]):
///
///   * Input redirect (`<` anywhere in the segment) → skip. The
///     verb is reading from a file descriptor, not from a path
///     argument the dedicated tools can address. Covers heredocs
///     (`<<EOF`), stdin pipes (`< some_pipe`), and process
///     substitution (`<(...)`).
///   * Read/list verbs require at least one non-flag argument.
///     `tail -50` (just truncating output) is NOT a violation;
///     `tail -50 build.log` (reading a file) IS.
///   * Grep verbs always flag, even without arguments. The model
///     could have used the `grep` tool with a path. False
///     positives on `ps -ef | grep node`-style filters are
///     accepted — they're cheap reminders, not hard blocks, and
///     the firm/reject tiers only fire after 2-3 consecutive
///     hits. EXCEPTION: when the command STARTS with a
///     shell-script verb (`cd`, `echo`, `export`, etc.), the
///     grep verdict is skipped. The LLM is clearly running a
///     shell script (cd /path && grep …, multi-line verification
///     scripts, etc.) and grep is a legitimate component of
///     such scripts. cat/head/ls/etc. are NOT exempt from this
///     exception because they're unambiguously about file
///     inspection regardless of script context — `cd /path &&
///     cat file` is still a violation.
ShellGuardKind _classifyPosix(String command) {
  // Code-search pipe anti-pattern: search-verb | head/tail/…
  // is overwhelmingly "I want to see a few code snippets", which
  // `code_search` answers in one call. Detected first so the
  // verb-classifier doesn't fall through to `grep` (which would
  // technically also be correct but is much more wasteful).
  if (_isCodeSearchPipe(command, _posixGrepVerbs, _posixListVerbs)) {
    return ShellGuardKind.codeSearch;
  }

  final segments = _splitSegments(command);
  final startsWithShellScript = _startsWithShellScriptVerb(segments);

  for (final seg in segments) {
    final kind = _classifySegment(
      seg,
      readVerbs: _posixReadVerbs,
      listVerbs: _posixListVerbs,
      grepVerbs: _posixGrepVerbs,
    );
    if (kind == null) continue;
    // Skip the grep verdict when the command starts with a
    // shell-script verb. See the design notes above for the
    // rationale — covers both `cd /path && grep …` (single line,
    // `&&`-chained) and multi-line verification scripts (the
    // user's example).
    if (kind == ShellGuardKind.grep && startsWithShellScript) continue;
    return kind;
  }
  return ShellGuardKind.none;
}

/// Verbs that signal "the LLM is running a shell script, not
/// using bash as a substitute for the dedicated tools". When
/// the first non-empty segment of a command starts with one of
/// these verbs, the detector skips the grep verdict in the rest
/// of the command (grep is a common component of verification
/// and filter scripts).
///
/// Deliberately conservative — only verbs that are unambiguously
/// "shell setup / scripting" rather than "shell-native work".
/// `env` is intentionally absent: `env | grep PATH` and similar
/// filters are still considered grep violations (the verb IS
/// grep and the user could use the `grep` tool). `cat`, `ls`,
/// `find`, etc. are also absent — those are unambiguous file
/// inspection violations regardless of script context.
const _shellScriptVerbs = <String>{
  'cd', 'pushd', 'popd',
  'echo', 'printf',
  'export', 'unset', 'set',
  'source', '.',
  'alias', 'unalias',
};

/// True when the first non-empty segment of [segments] starts
/// with one of the [_shellScriptVerbs]. Used by the POSIX and
/// Windows classifiers to skip the grep verdict in shell-script
/// commands (see the design notes on [_classifyPosix]).
bool _startsWithShellScriptVerb(List<String> segments) {
  for (final seg in segments) {
    final trimmed = seg.trim();
    if (trimmed.isEmpty) continue;
    final verb = _firstVerb(trimmed);
    if (verb == null) return false;
    return _shellScriptVerbs.contains(verb);
  }
  return false;
}

// =============================================================================
// Windows (cmd + PowerShell) classifier
// =============================================================================

/// PowerShell cmdlets and aliases used for file inspection.
/// Includes the cross-shell aliases (`cat`, `ls`, `dir`) so
/// the detector catches PowerShell pipelines that lean on POSIX
/// verbs (PowerShell aliases them).
const _winReadVerbs = <String>{
  'Get-Content', 'gc', 'cat',
  'Select-Object', 'select',
  'Sort-Object', 'sort',
  'Get-Unique', 'gu',
  'Measure-Object', 'measure',
  'Get-FileHash', 'Format-Hex', 'fhx',
  'Get-Item', 'gi',
  'Compare-Object', 'diff', 'cmp',
  // cmd builtins:
  'type', 'more',
};

const _winListVerbs = <String>{
  'Get-ChildItem', 'gci', 'ls', 'dir', 'Get-Item',
  'tree', 'Tree',
};

const _winGrepVerbs = <String>{
  'Select-String', 'sls',
  // cmd builtins:
  'findstr', 'find',
};

ShellGuardKind _classifyWindows(String command) {
  if (_isCodeSearchPipe(command, _winGrepVerbs, _winListVerbs)) {
    return ShellGuardKind.codeSearch;
  }

  final segments = _splitSegments(command);
  final startsWithShellScript = _startsWithShellScriptVerb(segments);

  for (final seg in segments) {
    final kind = _classifySegment(
      seg,
      readVerbs: _winReadVerbs,
      listVerbs: _winListVerbs,
      grepVerbs: _winGrepVerbs,
    );
    if (kind == null) continue;
    // Skip the grep verdict in shell-script commands (same
    // rationale as the POSIX classifier — see
    // [_classifyPosix]).
    if (kind == ShellGuardKind.grep && startsWithShellScript) continue;
    return kind;
  }
  return ShellGuardKind.none;
}

/// Classify a single shell segment into a violation kind, or
/// return `null` if the segment doesn't match a violation pattern.
///
/// [readVerbs], [listVerbs], [grepVerbs] are the platform-specific
/// sets (POSIX vs Windows) supplied by the caller. Splitting them
/// out as parameters keeps the rules identical across platforms
/// — only the verb sets differ.
///
/// Per-segment rules:
///
///   1. Input redirect (`<` anywhere in the segment) → return
///      null. The verb is reading from a file descriptor or
///      heredoc body, not a path argument. Output redirects
///      (`>` / `>>`) do NOT skip the segment — `cat file > /dev/null`
///      is still reading a file and the model should use `read`.
///
///   2. Read and list verbs require at least one non-flag
///      argument. `tail -50` (just truncating output from an
///      upstream command) is NOT a violation; `tail -50 build.log`
///      (reading a file) IS. The flag-skip logic strips tokens
///      starting with `-` so `-n 20`, `-rn`, etc. don't count as
///      the "path argument".
///
///   3. Grep verbs always flag, even without arguments. False
///      positives on `ps -ef | grep node`-style filters are
///      accepted (see the design notes on [_classifyPosix]).
ShellGuardKind? _classifySegment(
  String seg, {
  required Set<String> readVerbs,
  required Set<String> listVerbs,
  required Set<String> grepVerbs,
}) {
  final trimmed = seg.trim();
  if (trimmed.isEmpty) return null;

  // (1) Input-redirect / heredoc skip. The `<` check catches
  // `cat < file`, `cat <<EOF …`, and `<(…)` process substitution.
  if (trimmed.contains('<')) return null;

  // Tokenize; find the verb (skip env assignments like `FOO=bar`).
  final tokens = trimmed.split(RegExp(r'\s+'));
  int verbIdx = -1;
  String? verb;
  for (var i = 0; i < tokens.length; i++) {
    if (!_isEnvAssignment(tokens[i])) {
      verbIdx = i;
      verb = tokens[i];
      break;
    }
  }
  if (verb == null || verbIdx < 0) return null;

  // (2) Collect non-flag arguments after the verb.
  final args = <String>[];
  for (var i = verbIdx + 1; i < tokens.length; i++) {
    if (!tokens[i].startsWith('-')) args.add(tokens[i]);
  }

  // Strip any path prefix from the verb (e.g. `/usr/bin/cat`).
  final base = verb.split(RegExp(r'[/\\]')).last;

  if (readVerbs.contains(base)) {
    return args.isEmpty ? null : ShellGuardKind.read;
  }
  if (listVerbs.contains(base)) {
    return args.isEmpty ? null : ShellGuardKind.glob;
  }
  if (grepVerbs.contains(base)) {
    // (3) Grep always flags.
    return ShellGuardKind.grep;
  }
  return null;
}

// =============================================================================
// Shared segment/verb helpers
// =============================================================================

/// Split a shell command into top-level segments separated by
/// `|`, `;`, `&&`, `||`, or newlines.
///
/// **Quote-aware.** Operators inside `'...'` or `"..."` strings
/// don't split segments — `git commit -m 'pipes (|) here'` stays
/// as one segment. Without quote-awareness, the detector fires
/// false positives on commands whose arguments legitimately
/// contain operator characters (commit messages, long
/// explanations, user-supplied strings). This is the
/// `bash+cat/sed/rg` fallback detector's most common source of
/// false positives in practice.
///
/// Not a full shell parser. Here-docs (`<<EOF`), command
/// substitution (`$(...)`), and process substitution (`<(...)`)
/// are still misread — those patterns are rare in the LLM's
/// bash calls and the gain from full parsing wouldn't justify
/// the complexity. Backslash escapes are honoured outside
/// strings and inside double-quoted strings (matching POSIX
/// shell semantics); inside single-quoted strings, backslash
/// is literal (single quotes preserve everything except the
/// closing quote).
///
/// Operator precedence: `&&` and `||` are matched before `&`
/// and `|` so the multi-char tokens win the race. Newlines and
/// `;` are single-char separators, no precedence issue.
///
/// Returns the segments in source order. Empty segments (from
/// adjacent separators or leading/trailing separators) are
/// preserved as empty strings; callers handle them.
List<String> _splitSegments(String command) {
  final result = <String>[];
  final current = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  var escapeNext = false;

  for (var i = 0; i < command.length; i++) {
    final ch = command[i];

    // Inside single quotes: every char is literal until the
    // closing single quote. No escape handling, no operator
    // interpretation — POSIX semantics.
    if (inSingle) {
      if (ch == "'") {
        inSingle = false;
      }
      current.write(ch);
      continue;
    }

    // Inside double quotes: backslash escapes the next char,
    // closing `"` exits the state, everything else is literal.
    if (inDouble) {
      if (escapeNext) {
        current.write(ch);
        escapeNext = false;
        continue;
      }
      if (ch == r'\') {
        current.write(ch);
        escapeNext = true;
        continue;
      }
      if (ch == '"') {
        inDouble = false;
        current.write(ch);
        continue;
      }
      current.write(ch);
      continue;
    }

    // Outside quotes: standard shell semantics. Backslash
    // escapes the next char; single and double quotes enter
    // their respective states; operator characters split.
    if (escapeNext) {
      current.write(ch);
      escapeNext = false;
      continue;
    }

    if (ch == r'\') {
      current.write(ch);
      escapeNext = true;
      continue;
    }

    if (ch == "'") {
      inSingle = true;
      current.write(ch);
      continue;
    }

    if (ch == '"') {
      inDouble = true;
      current.write(ch);
      continue;
    }

    // Operator split. `&&` / `||` are checked before `&` / `|`
    // so the multi-char tokens win the race — `i++` consumes
    // the second char.
    if (ch == ';' || ch == '\n') {
      result.add(current.toString());
      current.clear();
      continue;
    }
    if (ch == '&' &&
        i + 1 < command.length &&
        command[i + 1] == '&') {
      result.add(current.toString());
      current.clear();
      i++;
      continue;
    }
    if (ch == '|' &&
        i + 1 < command.length &&
        command[i + 1] == '|') {
      result.add(current.toString());
      current.clear();
      i++;
      continue;
    }
    if (ch == '|') {
      result.add(current.toString());
      current.clear();
      continue;
    }

    current.write(ch);
  }
  result.add(current.toString());
  return result;
}

/// Quote-aware pipe split. Same quoting rules as
/// [_splitSegments], but only splits on `|` — used by
/// [_isCodeSearchPipe] to find `search-verb | truncator`
/// patterns without false positives from operators inside
/// quoted strings (commit messages, user-supplied strings).
///
/// `||` (logical OR) is treated as a single pipe for the
/// purposes of this check: when `||` appears in source, the
/// `|` in `_isCodeSearchPipe`'s left/right adjacency check
/// wouldn't fire anyway (because the segments wouldn't be
/// adjacent — `||` would be a segment separator in the
/// verb-classifier's view). For symmetry and to keep the
/// helper focused, we still skip `||` here rather than
/// splitting on it.
List<String> _splitOnPipes(String command) {
  final result = <String>[];
  final current = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  var escapeNext = false;

  for (var i = 0; i < command.length; i++) {
    final ch = command[i];

    if (inSingle) {
      if (ch == "'") {
        inSingle = false;
      }
      current.write(ch);
      continue;
    }

    if (inDouble) {
      if (escapeNext) {
        current.write(ch);
        escapeNext = false;
        continue;
      }
      if (ch == r'\') {
        current.write(ch);
        escapeNext = true;
        continue;
      }
      if (ch == '"') {
        inDouble = false;
        current.write(ch);
        continue;
      }
      current.write(ch);
      continue;
    }

    if (escapeNext) {
      current.write(ch);
      escapeNext = false;
      continue;
    }

    if (ch == r'\') {
      current.write(ch);
      escapeNext = true;
      continue;
    }

    if (ch == "'") {
      inSingle = true;
      current.write(ch);
      continue;
    }

    if (ch == '"') {
      inDouble = true;
      current.write(ch);
      continue;
    }

    // Only split on `|` here — other operators pass through.
    // `||` is preserved (kept inside the segment) so the
    // left/right adjacency check in _isCodeSearchPipe works
    // naturally on the surrounding segments.
    if (ch == '|') {
      result.add(current.toString());
      current.clear();
      continue;
    }

    current.write(ch);
  }
  result.add(current.toString());
  return result;
}

/// Return the first verb of a segment (the first whitespace-
/// separated token, stripped of any path prefix like
/// `/usr/bin/cat`). Returns `null` for empty segments.
///
/// "Verb" here means the executable name — what would appear
/// in `argv[0]` after shell expansion. Aliases and shell
/// functions aren't recognized (the shell tool runs commands
/// via `/bin/bash -c`, which DOES expand aliases for the
/// non-interactive case but we don't try to model that here).
String? _firstVerb(String segment) {
  final trimmed = segment.trim();
  if (trimmed.isEmpty) return null;

  // Skip env-var prefix (`FOO=bar cat file` → verb is `cat`).
  // Walk tokens until we find one that isn't `NAME=VALUE`.
  final tokens = trimmed.split(RegExp(r'\s+'));
  String? candidate;
  for (final tok in tokens) {
    if (candidate == null) {
      if (_isEnvAssignment(tok)) continue;
      candidate = tok;
    } else {
      break; // first non-env token; this is the verb
    }
  }
  if (candidate == null) return null;

  // Strip path prefix.
  final slash = candidate.lastIndexOf(RegExp(r'[/\\]'));
  return slash >= 0 ? candidate.substring(slash + 1) : candidate;
}

bool _isEnvAssignment(String token) {
  // `FOO=bar`, `FOO=` — but NOT `=value` or `=cat`.
  if (!token.contains('=')) return false;
  final name = token.substring(0, token.indexOf('='));
  if (name.isEmpty) return false;
  // Identifier-like names only (start with letter or `_`,
  // followed by letters / digits / `_`).
  return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name);
}

/// Detect the "search verb piped into a truncator" anti-pattern
/// (e.g. `rg "auth" lib/ | head -10`, `find . -name "*.dart" |
/// head`, `dir *.cs | more`). These pipelines almost always
/// mean "I want a few matching snippets" — the semantic-search
/// use case that `code_search` was built for.
///
/// `searchVerbs` is the set of "left-side" verbs that trigger
/// the pattern (ripgrep/grep on POSIX; Select-String/findstr on
/// Windows). `listVerbs` extends the trigger set to include
/// directory-listing verbs, since `find … | head` is also a
/// common "show me a few matches" pattern.
///
/// `truncatorVerbs` is the implicit set of "right-side" verbs
/// that look like the user wanted to limit output: `head`,
/// `tail`, `less`, `more`, `sort`, `uniq`, `wc`. The pipeline
/// also requires at least one pipe (`|`) — single-command
/// invocations like `rg "auth" lib/` go through the regular
/// verb classifier and surface as `grep`, which is correct.
bool _isCodeSearchPipe(
  String command,
  Set<String> searchVerbs,
  Set<String> listVerbs,
) {
  const truncatorVerbs = <String>{
    'head', 'tail', 'less', 'more', 'sort', 'uniq', 'wc', 'tee',
    // PowerShell equivalents:
    'Select-Object', 'select', 'Get-First', 'Get-Last',
    'Get-Unique', 'gu',
  };

  // Quote-aware pipe split — operators inside `'...'` or `"..."`
  // don't count as pipes. Delegates to [_splitOnPipes] so this
  // detector stays consistent with the verb-classifier's
  // [_splitSegments] (both honour the same quoting rules).
  final segments = _splitOnPipes(command);
  if (segments.length < 2) return false;

  for (var i = 0; i < segments.length - 1; i++) {
    final left = segments[i].trim();
    final right = segments[i + 1].trim();
    final leftVerb = _firstVerb(left);
    final rightVerb = _firstVerb(right);
    if (leftVerb == null || rightVerb == null) continue;
    final leftBase = leftVerb.split(RegExp(r'[/\\]')).last;
    if (searchVerbs.contains(leftBase) || listVerbs.contains(leftBase)) {
      if (truncatorVerbs.contains(rightVerb) ||
          truncatorVerbs.contains(rightVerb.split(RegExp(r'[/\\]')).last)) {
        return true;
      }
    }
  }
  return false;
}

// =============================================================================
// Kind → text mappings (for the rendered reminder body)
// =============================================================================

String _whatForKind(ShellGuardKind kind) {
  switch (kind) {
    case ShellGuardKind.none:
      return 'shell command';
    case ShellGuardKind.read:
      return 'file inspection via shell';
    case ShellGuardKind.glob:
      return 'directory listing via shell';
    case ShellGuardKind.grep:
      return 'content search via shell';
    case ShellGuardKind.codeSearch:
      return 'concept search via shell pipeline';
  }
}

String _toolForKind(ShellGuardKind kind) {
  switch (kind) {
    case ShellGuardKind.none:
      return '';
    case ShellGuardKind.read:
      return 'read';
    case ShellGuardKind.glob:
      return 'glob';
    case ShellGuardKind.grep:
      return 'grep';
    case ShellGuardKind.codeSearch:
      return 'code_search';
  }
}

String _exampleForKind(ShellGuardKind kind) {
  switch (kind) {
    case ShellGuardKind.read:
      return 'cat / head / tail / sed -n / wc / file → read';
    case ShellGuardKind.glob:
      return 'ls / find / tree / du → glob';
    case ShellGuardKind.grep:
      return 'grep / rg / ack / ag → grep';
    case ShellGuardKind.codeSearch:
      return 'rg "concept" | head · find … | head → code_search';
    case ShellGuardKind.none:
      return '';
  }
}

// =============================================================================
// Wire-format helpers (mirroring praise_prompts.dart)
// =============================================================================

/// Marker tag that frames the reminder as Crux system feedback
/// rather than the tool's actual output. Exposed as a constant
/// so tests and the shell-tool injection site use the same tag.
///
/// Tier-specific suffix (`— firm`) mirrors the single-call-hint
/// pattern: the LLM pattern-matches the severity from the
/// bracketed tag alone, no separate body inspection needed.
String shellGuardEmbeddedMarker(ShellGuardSeverity severity) {
  switch (severity) {
    case ShellGuardSeverity.none:
      return '[Crux system note — shell-tool fallback]';
    case ShellGuardSeverity.mild:
      return '[Crux system note — shell-tool fallback]';
    case ShellGuardSeverity.firm:
      return '[Crux system note — shell-tool fallback — firm]';
    case ShellGuardSeverity.reject:
      // Rejections never use the embedded marker — they go
      // through [renderShellGuardRejection] as the full output
      // of a rejected tool call, so no marker is needed.
      return '[Crux system note — shell-tool fallback — rejected]';
  }
}

/// Render the reminder wrapped in the embedded marker, ready to
/// be appended to a shell tool's `output`. Used by the mild and
/// firm tiers. The reject tier uses [renderShellGuardRejection]
/// instead (it's the full output of a rejected call, not a
/// trailing note on a successful one).
///
/// Throws if called with the reject tier — same defensive guard
/// the single-call-hint helpers use to catch call-site mix-ups
/// at test time rather than at runtime.
String renderShellGuardEmbedded(ShellGuardVerdict verdict) {
  if (verdict.severity == ShellGuardSeverity.reject) {
    throw StateError(
      'renderShellGuardEmbedded called for reject tier '
      '(streak=${verdict.streakAfter - 1}, '
      'kind=${verdict.kind}). Reject tier must use '
      'renderShellGuardRejection — the shell tool picks the '
      'right renderer based on severity.',
    );
  }
  if (verdict.severity == ShellGuardSeverity.none) {
    throw StateError(
      'renderShellGuardEmbedded called for none tier — '
      'no violation, no reminder to embed.',
    );
  }

  final body = _buildBody(verdict);
  final marker = shellGuardEmbeddedMarker(verdict.severity);
  return '\n\n$marker\n$body\n';
}

/// Render the rejection body for the reject tier. Becomes the
/// full `output` of the rejected tool call (no marker tag,
/// since the rejected call has no real tool output to
/// distinguish from).
String renderShellGuardRejection(ShellGuardVerdict verdict) {
  if (verdict.severity != ShellGuardSeverity.reject) {
    throw StateError(
      'renderShellGuardRejection called for non-reject tier '
      '(${verdict.severity}). Mild/firm tiers must use '
      'renderShellGuardEmbedded — the shell tool picks the '
      'right renderer based on severity.',
    );
  }
  return _buildBody(verdict);
}

String _buildBody(ShellGuardVerdict verdict) {
  // Three severity wordings. Mirrors the single-call-hint
  // escalation trajectory (mild = observation, firm = named
  // drift, urgent/reject = "stop, do this differently").
  final String header;
  switch (verdict.severity) {
    case ShellGuardSeverity.mild:
      header = 'This shell command would be served by the dedicated Crux tool:';
      break;
    case ShellGuardSeverity.firm:
      header =
          'You have used the shell tool for a file-inspection-style operation '
          'twice in a row. Switch to the dedicated Crux tool:';
      break;
    case ShellGuardSeverity.reject:
      header =
          'This shell call was BLOCKED. You have used the shell tool for a '
          'file-inspection-style operation three or more times in a row. Use '
          'the dedicated Crux tool instead:';
      break;
    case ShellGuardSeverity.none:
      // Unreachable — the detector never produces a verdict
      // with `severity == none`. Defensive throw for clarity.
      throw StateError('Unreachable: _buildBody called with severity.none');
  }

  final commandEcho = verdict.command.trim().isEmpty
      ? ''
      : '\n\nYour command was:\n  ${verdict.command.trim()}';

  // The user explicitly asked for code_search to be emphasised
  // ("especially code search"), so the body always mentions it
  // as the preferred surface for "how does X work" /
  // "find code that does X" questions, regardless of which
  // kind was detected.
  return '$header\n'
      '• detected: ${verdict.what}  '
      '(e.g. ${verdict.example})\n'
      '• use the `${verdict.toolName}` tool instead — it is faster, '
      'returns structured output, supports parallel calls, and avoids '
      'shell-quoting bugs.\n'
      '\n'
      'For "how does X work" / "find code that does X" questions, '
      'prefer `code_search` (semantic search) over `grep` + `read` '
      'loops — one code_search call returns ranked snippets in '
      '~600ms instead of the bash+rg+read dance.\n'
      '\n'
      'Reserve `bash` for shell-native tasks: builds, tests, '
      'package managers, git, and process control.$commandEcho';
}

// =============================================================================
// User-facing bubble label (mirrors praise_prompts.dart shape)
// =============================================================================

/// Short, user-facing label for the `shell_guard` bubble
/// rendered in the TUI. This is *not* sent to the LLM — it's
/// the one-liner the user sees scrolling past in the chat
/// history, telling them Crux caught a bash+cat/sed/rg fallback.
///
/// Three severity tiers so the visible message escalates with
/// the same wording trajectory as the in-context reminder:
///   * mild  → "1st · use `read`"
///   * firm  → "2nd · switch to `read`"
///   * reject → "3rd · call blocked, use `read`"
String renderShellGuardBubbleLabel(ShellGuardVerdict verdict) {
  final ordinal = _ordinalFor(verdict.streakAfter);
  final verb = switch (verdict.severity) {
    ShellGuardSeverity.mild => 'use `${verdict.toolName}` instead',
    ShellGuardSeverity.firm => 'switch to `${verdict.toolName}`',
    ShellGuardSeverity.reject => 'blocked — use `${verdict.toolName}`',
    ShellGuardSeverity.none => 'shell fallback',
  };
  return 'shell-tool fallback · $ordinal · $verb';
}

String _ordinalFor(int streak) {
  switch (streak) {
    case 1:
      return '1st';
    case 2:
      return '2nd';
    case 3:
      return '3rd';
    default:
      return '${streak}th';
  }
}