/// Shared type contract for the shell high-risk command guardrail.
///
/// Three-layer defence before bash / cmd / powershell execute a command:
///
///   1. Heuristic pre-screen (pure functions) classifies the command
///      into a [ShellRiskTier]: `safe` runs directly, `catastrophic`
///      is hard-rejected, `suspicious` is escalated to the auxiliary
///      model.
///   2. The auxiliary model (`AuxiliaryService.assessShellCommand`)
///      returns a [ShellRiskVerdict]: `safe` executes, `unsafe` /
///      `uncertain` are rejected, `unavailable` means the assessment
///      could not be produced (no auxiliary model configured, timeout,
///      transport error) and is handled by the caller's own policy.
///
/// The layer-1 heuristic pre-screen ([assessShellRiskHeuristic])
/// lives here too, directly under the contract, so the shared types
/// and the pure classifier travel together. It is a pure function —
/// no IO, no model calls — so the heuristic layer, the
/// auxiliary-model layer, and the wiring layer all import the same
/// contract without depending on each other's implementations.
library;

enum ShellRiskTier { safe, suspicious, catastrophic }

enum ShellRiskVerdictKind { safe, unsafe, uncertain, unavailable }

class ShellRiskAssessment {
  final ShellRiskTier tier;
  final String? reason;
  const ShellRiskAssessment(this.tier, [this.reason]);
}

class ShellRiskVerdict {
  final ShellRiskVerdictKind kind;
  final String? reason;
  const ShellRiskVerdict(this.kind, [this.reason]);
}

// =============================================================================
// Layer 1: heuristic pre-screen
// =============================================================================

/// Classify [command] into a [ShellRiskAssessment] using pure pattern
/// matching — no IO, no model calls, no platform probing beyond the
/// [isWindows] flag supplied by the caller (same convention as
/// `shell_guard.dart`; pass `Platform.isWindows` at the call site).
///
/// Tier policy (false-positive economics):
///
///   * **Catastrophic is narrow on purpose.** A false catastrophic
///     verdict hard-blocks legitimate work with no appeal (the
///     auxiliary model is never consulted), so only truly
///     irreversible operations qualify: wiping `/` or `~`, formatting
///     drives, raw-disk writes, fork bombs, rebooting the machine.
///     `rm -rf ./build` and `rm -rf node_modules` must NEVER land
///     here.
///   * **Suspicious is wide on purpose.** A false suspicious verdict
///     costs one cheap aux-model call; the model makes the final
///     decision. Anything destructive-but-plausibly-legitimate lands
///     here: sudo, force-push, pipe-to-shell installers, overwrites
///     under system paths, service control.
///
/// The command is split into segments on `&&`, `||`, `;`, `|`, and
/// newlines (quote-aware — operators inside `'...'` / `"..."` don't
/// split, mirroring `_splitSegments` in `shell_guard.dart`), and
/// every segment is judged independently, so a hard-block pattern
/// hiding in the second half of a compound command still blocks.
/// Catastrophic is checked before suspicious so an early suspicious
/// segment can't mask a later catastrophic one.
///
/// Deliberately does NOT unwrap nested `bash -c "..."` scripts or
/// command substitutions — the segment splitter is not a full shell
/// parser, and the aux model sees the full command text for anything
/// that isn't an obvious safe/catastrophic hit anyway.
ShellRiskAssessment assessShellRiskHeuristic(
  String command, {
  required bool isWindows,
}) {
  if (command.trim().isEmpty) {
    return const ShellRiskAssessment(ShellRiskTier.safe);
  }

  // The fork bomb is a structural pattern, not a per-segment one —
  // the `|` inside its function body would be misread as a pipeline
  // separator by the segmenter. Check the raw text up front.
  if (_forkBombPattern.hasMatch(command)) {
    return const ShellRiskAssessment(
      ShellRiskTier.catastrophic,
      'fork bomb — spawns processes until the machine stops responding',
    );
  }

  final segments = _splitSegments(command);

  // Pass 1: catastrophic. Any segment, first hit wins.
  for (final segment in segments) {
    final reason = isWindows
        ? _catastrophicWindows(segment)
        : _catastrophicPosix(segment);
    if (reason != null) {
      return ShellRiskAssessment(ShellRiskTier.catastrophic, reason);
    }
  }

  // Pass 2: suspicious. Per-segment checks first, then the
  // cross-segment pipe-to-shell pattern that only becomes visible
  // when two segments are looked at together.
  for (final segment in segments) {
    final reason = isWindows
        ? _suspiciousWindows(segment)
        : _suspiciousPosix(segment);
    if (reason != null) {
      return ShellRiskAssessment(ShellRiskTier.suspicious, reason);
    }
  }
  final pipeReason = _pipeToShell(segments, isWindows: isWindows);
  if (pipeReason != null) {
    return ShellRiskAssessment(ShellRiskTier.suspicious, pipeReason);
  }

  return const ShellRiskAssessment(ShellRiskTier.safe);
}

// =============================================================================
// Shared pattern tables
// =============================================================================

/// The classic bash fork bomb, `:(){ :|:& };:`, matched loosely on
/// its structural skeleton so whitespace variants still hit. One
/// accepted false positive: `echo ":(){ :|:& };:"` (printing the
/// string) trips it too — vanishingly rare in practice, and blocking
/// an echo costs nothing real.
final _forkBombPattern = RegExp(r':\s*\(\s*\)\s*\{[^{}]*:\s*\|\s*:\s*&');

/// Shell redirect into a raw block device (`> /dev/sda`,
/// `> /dev/nvme0n1`, …). Overwrites disk sectors directly, bypassing
/// the filesystem — unrecoverable by definition.
final _rawDeviceWrite = RegExp(
  r'>\s*/dev/(?:sd[a-z]|hd[a-z]|vd[a-z]|xvd[a-z]|nvme\d|mmcblk\d)',
);

/// Shell redirect overwriting a file under a well-known system tree
/// (`> /etc/resolv.conf`). Suspicious rather than catastrophic: a
/// single config overwrite is usually recoverable, but the aux model
/// should confirm.
final _posixSystemPathWrite = RegExp(
  r'>>?\s*/(?:etc|usr|bin|sbin|boot|lib)(?:/|\s|$)',
);

/// Same idea for Windows: redirect into `C:\Windows\...`.
final _winSystemPathWrite = RegExp(
  r""">\s*["']?[A-Za-z]:[\\/]Windows[\\/]""",
  caseSensitive: false,
);

/// A bare drive root with nothing below it: `C:\`, `D:/`, `C:\*`.
/// Deleting or formatting *this* is the irreversible case — deleting
/// something under it usually isn't.
final _winDriveRoot = RegExp(r'^[A-Za-z]:[\\/]\*?$');

/// A bare drive letter, as `format` expects it (`format C:`).
final _winDriveLetter = RegExp(r'^[A-Za-z]:$');

/// Anything under the Windows system directory.
final _winSystemDir = RegExp(
  r'^[A-Za-z]:[\\/]Windows(?:[\\/]|$)',
  caseSensitive: false,
);

/// Verbs that remove files on Windows — a mix of cmd builtins and
/// PowerShell aliases for `Remove-Item`.
const _winDeleteVerbs = <String>{
  'del',
  'erase',
  'rd',
  'rmdir',
  'remove-item',
  'ri',
  'rm',
};

/// Pipe-to-shell tables: a payload-producing verb in one segment and
/// a shell verb in another is the classic untrusted-installer shape
/// (`curl … | sh`, `irm … | iex`, `base64 -d | sh`).
const _posixShellVerbs = <String>{
  'sh',
  'bash',
  'zsh',
  'dash',
  'ksh',
  'ash',
  'fish',
};
const _posixDownloaderVerbs = <String>{'curl', 'wget', 'fetch'};
const _winShellVerbs = <String>{
  'iex',
  'invoke-expression',
  'powershell',
  'pwsh',
  'cmd',
};
const _winDownloaderVerbs = <String>{
  'irm',
  'invoke-restmethod',
  'iwr',
  'invoke-webrequest',
  'curl',
  'wget',
  'curl.exe',
  'wget.exe',
};

// =============================================================================
// POSIX (bash) classifiers
// =============================================================================

/// Return the catastrophic reason for a POSIX segment, or `null`.
/// Keep this table NARROW — a hit here hard-blocks the command with
/// no aux-model appeal.
String? _catastrophicPosix(String segment) {
  // Redirects aren't verb-bound — check the raw segment text first.
  if (_rawDeviceWrite.hasMatch(segment)) {
    return 'writes directly to a raw block device — can corrupt the disk';
  }

  final p = _parseSegment(segment);
  if (p.isEmpty) return null;
  final verb = p.verb;
  if (verb == null) return null;
  final args = p.args;

  switch (verb) {
    case 'shutdown':
    case 'reboot':
    case 'halt':
    case 'poweroff':
      return 'shuts down or reboots the machine';
    case 'systemctl':
      if (args.any((a) => a == 'poweroff' || a == 'reboot' || a == 'halt')) {
        return 'shuts down or reboots the machine via systemctl';
      }
      return null;
    case 'dd':
      if (args.any((a) => a.startsWith('of=/dev/'))) {
        return 'dd writing to a raw device — can overwrite the disk';
      }
      return null;
    case 'rm':
      return _rmAssessment(args, rootOnly: true);
    case 'chmod':
      final recursive =
          _hasShortFlag(args, 'R') || _hasLongFlag(args, 'recursive');
      final worldWritable = args.any((a) => a == '777' || a == '0777');
      if (recursive && worldWritable && _nonFlagArgs(args).any(_isRootTarget)) {
        return 'chmod -R 777 on the filesystem root — '
            'breaks permissions system-wide';
      }
      return null;
    case 'chown':
    case 'chgrp':
      final recursive =
          _hasShortFlag(args, 'R') || _hasLongFlag(args, 'recursive');
      if (recursive && _nonFlagArgs(args).any(_isRootTarget)) {
        return 'chown -R on the filesystem root — '
            'breaks ownership system-wide';
      }
      return null;
  }

  // mkfs.ext4 / mkfs.xfs / plain mkfs — formatting a device is
  // irreversible regardless of flavour. The `/dev/` check keeps
  // `mkfs --version` and image-file usage (`mkfs.ext4 img.raw`) out
  // of this tier.
  if (verb.startsWith('mkfs') && segment.contains('/dev/')) {
    return 'formats a device — irreversible data loss';
  }
  return null;
}

/// Return the suspicious reason for a POSIX segment, or `null`. This
/// table is WIDE — the aux model re-judges every hit, so erring on
/// the side of escalation only costs one cheap model call.
String? _suspiciousPosix(String segment) {
  if (_posixSystemPathWrite.hasMatch(segment)) {
    return 'overwrites a file under a system path (/etc, /usr, …)';
  }

  final p = _parseSegment(segment);
  if (p.isEmpty) return null;
  final verb = p.verb;
  if (verb == null) {
    // `sudo` with nothing after it still deserves the escalation.
    return p.hasSudo ? 'runs with sudo — elevated privileges' : null;
  }
  final args = p.args;

  // Verb-specific checks run BEFORE the generic sudo fallback so the
  // reason names the actual risk (`sudo rm -rf /tmp/x` reports the
  // rm, not the sudo). Verb/args already have sudo stripped.
  switch (verb) {
    case 'rm':
      return _rmAssessment(args, rootOnly: false);
    case 'git':
      if (args.contains('push') &&
          (args.contains('--force') ||
              args.contains('--force-with-lease') ||
              _hasShortFlag(args, 'f'))) {
        return 'force-pushes to a remote — can rewrite shared history';
      }
      if (args.contains('reset') && args.contains('--hard')) {
        return 'git reset --hard — discards uncommitted changes';
      }
      return null;
    case 'kill':
      // `-1` as the pid signals every process the user can kill.
      // Position doesn't disambiguate it — `kill -1 -9` is the same
      // kill-everything form as `kill -9 -1` — so ANY `-1` argument
      // escalates, even though that also catches the benign
      // `kill -1 1234` (SIGHUP to one pid). Over-matching is cheap
      // here: the aux model makes the final call.
      if (args.contains('-1')) {
        return 'signals every process the user owns';
      }
      return null;
    case 'killall':
      return 'kills processes by name — easy to over-match';
    case 'pkill':
      return 'kills processes by pattern — easy to over-match';
    case 'systemctl':
      if (args.any((a) => a == 'stop' || a == 'disable' || a == 'mask')) {
        return 'stops or disables a system service';
      }
      return null;
    case 'launchctl':
      if (args.any(
        (a) =>
            a == 'stop' ||
            a == 'unload' ||
            a == 'remove' ||
            a == 'disable' ||
            a == 'bootout',
      )) {
        return 'stops or unloads a system agent/daemon';
      }
      return null;
    case 'crontab':
      if (_hasShortFlag(args, 'r')) {
        return 'deletes the crontab — scheduled jobs are lost';
      }
      return null;
  }

  // Generic fallback: any other command elevated with sudo gets the
  // aux model's second look (catastrophic sudo commands were already
  // caught in pass 1 with the prefix stripped).
  if (p.hasSudo) {
    return 'runs with sudo — elevated privileges';
  }
  return null;
}

/// Shared `rm` analysis behind both tiers. With `rootOnly` only the
/// catastrophic form is reported (recursive + force + root target:
/// `/`, `~`, `/*`); with `rootOnly: false` the suspicious forms are
/// reported too (recursive + force + any absolute or indirect —
/// variable / substitution / ~user — target).
///
/// Relative targets — `rm -rf ./build`, `rm -rf node_modules`,
/// `rm -rf ../scratch` — match neither and stay safe, by design.
String? _rmAssessment(List<String> args, {required bool rootOnly}) {
  final recursive =
      _hasShortFlag(args, 'r') ||
      _hasShortFlag(args, 'R') ||
      _hasLongFlag(args, 'recursive');
  final force = _hasShortFlag(args, 'f') || _hasLongFlag(args, 'force');
  if (!recursive || !force) return null;

  final targets = _nonFlagArgs(args);
  if (targets.any(_isRootTarget)) {
    return 'rm -rf on the filesystem root or home directory — '
        'irreversible data loss';
  }
  if (rootOnly) return null;
  if (targets.any(_isIndirectTarget)) {
    return 'rm -rf on a variable / command-substitution / ~user target — '
        'the heuristic cannot see what it expands to';
  }
  if (targets.any(_isAbsoluteTarget)) {
    return 'rm -rf on an absolute path — destructive, needs a second look';
  }
  return null;
}

// =============================================================================
// Windows (cmd + PowerShell) classifiers
// =============================================================================

/// Windows counterpart of [_catastrophicPosix]. Verbs are matched
/// case-insensitively (PowerShell and cmd are both case-insensitive).
/// Same narrow-table rule applies.
String? _catastrophicWindows(String segment) {
  final p = _parseSegment(segment);
  if (p.isEmpty) return null;
  final verb = p.verb?.toLowerCase();
  if (verb == null) return null;
  final args = p.args;

  switch (verb) {
    // shutdown.exe exists on Windows too — same irreversible action
    // as the POSIX verbs, so it lives in the same tier on both.
    case 'shutdown':
    case 'reboot':
    case 'halt':
    case 'poweroff':
      return 'shuts down or reboots the machine';
    case 'bcdedit':
      return 'modifies boot configuration — can render the machine '
          'unbootable';
    case 'diskpart':
      return 'partition editor — can destroy volumes irreversibly';
    case 'format':
      // The drive-letter argument is what makes `format` destructive;
      // a bare `format` errors out harmlessly.
      if (args.any((a) => _winDriveLetter.hasMatch(_stripQuotes(a)))) {
        return 'formats a drive — irreversible data loss';
      }
      return null;
  }

  // Recursive delete aimed at a drive root: `del /s /q C:\`,
  // `rd /s D:\`, `Remove-Item -Recurse C:\`. The same verbs aimed at
  // anything below the root stay out of this tier — see
  // [_suspiciousWindows].
  if (_winDeleteVerbs.contains(verb)) {
    final recursive = args.any((a) {
      final lower = a.toLowerCase();
      return lower == '/s' || lower == '-recurse' || lower == '-r';
    });
    if (recursive && args.any(_isWinDriveRoot)) {
      return 'recursively deletes a drive root — irreversible data loss';
    }
  }
  return null;
}

/// Windows counterpart of [_suspiciousPosix]. Wide table, same
/// reasoning.
String? _suspiciousWindows(String segment) {
  if (_winSystemPathWrite.hasMatch(segment)) {
    return 'overwrites a file under the Windows system directory';
  }

  final p = _parseSegment(segment);
  if (p.isEmpty) return null;
  final verb = p.verb?.toLowerCase();
  if (verb == null) return null;
  final args = p.args;
  final lowerArgs = args.map((a) => a.toLowerCase()).toList(growable: false);

  switch (verb) {
    case 'set-executionpolicy':
      return 'weakens the PowerShell script-signing policy';
    case 'stop-computer':
    case 'restart-computer':
      return 'shuts down or restarts the machine';
    case 'takeown':
    case 'icacls':
      if (args.any((a) => _isWinSystemDir(a) || _isWinDriveRoot(a))) {
        return 'changes ownership or ACLs on system directories';
      }
      return null;
    case 'reg':
      final modifiesHive =
          lowerArgs.contains('add') || lowerArgs.contains('delete');
      final targetsHklm = lowerArgs.any(
        (a) => a.contains('hklm') || a.contains('hkey_local_machine'),
      );
      if (modifiesHive && targetsHklm) {
        return 'modifies the HKLM registry hive — system-wide effect';
      }
      return null;
    case 'netsh':
      if (lowerArgs.any((a) => a.contains('firewall'))) {
        return 'changes firewall configuration';
      }
      return null;
  }

  // Non-recursive delete of a drive root (`rd C:\`) or any delete
  // touching the Windows directory. Destructive, but plausibly
  // legitimate cleanup — the aux model decides.
  if (_winDeleteVerbs.contains(verb) &&
      args.any((a) => _isWinDriveRoot(a) || _isWinSystemDir(a))) {
    return 'deletes from a drive root or the Windows system directory';
  }
  return null;
}

// =============================================================================
// Cross-segment: pipe-to-shell
// =============================================================================

/// Flag the untrusted-installer shape: one segment produces a payload
/// (`curl`, `wget`, `irm`, `base64 -d`) and another segment is a
/// shell (`sh`, `bash`, `iex`, `powershell`). Neither half is
/// suspicious on its own — `curl url | head` and `bash setup.sh`
/// both stay safe — so this has to look at the segment list as a
/// whole.
String? _pipeToShell(List<String> segments, {required bool isWindows}) {
  var hasPayload = false;
  var hasShell = false;

  for (final segment in segments) {
    final p = _parseSegment(segment);
    var verb = p.verb;
    if (verb == null) continue;
    if (isWindows) verb = verb.toLowerCase();

    if (isWindows) {
      if (_winShellVerbs.contains(verb)) hasShell = true;
      if (_winDownloaderVerbs.contains(verb)) hasPayload = true;
    } else {
      if (_posixShellVerbs.contains(verb)) hasShell = true;
      if (_posixDownloaderVerbs.contains(verb)) hasPayload = true;
      // `base64 -d | sh` — the obfuscated cousin of `curl | sh`.
      if (verb == 'base64' &&
          (_hasShortFlag(p.args, 'd') ||
              _hasShortFlag(p.args, 'D') ||
              _hasLongFlag(p.args, 'decode'))) {
        hasPayload = true;
      }
    }
  }

  if (hasPayload && hasShell) {
    return 'pipes downloaded or decoded content into a shell — '
        'classic untrusted-installer pattern';
  }
  return null;
}

// =============================================================================
// Segment parsing + target helpers
// =============================================================================

/// A parsed command segment: the raw whitespace-split tokens after
/// any `FOO=bar` env-assignment prefix, with a leading `sudo` tracked
/// separately so classifiers can both see the real verb (`sudo rm
/// -rf /` must still be catastrophic) and know elevation happened.
class _ParsedSegment {
  final List<String> tokens;
  const _ParsedSegment(this.tokens);

  bool get isEmpty => tokens.isEmpty;

  /// POSIX-only in practice; harmless on Windows where `sudo`
  /// doesn't exist (it's just an unmatched verb there).
  bool get hasSudo => tokens.isNotEmpty && tokens.first == 'sudo';

  /// Tokens with any `sudo` prefix and any env-assignment prefix
  /// removed. Env stripping happens HERE — after sudo removal, not
  /// only in `_parseSegment` — so `sudo FOO=bar rm -rf /` resolves
  /// `rm` as the verb. Stripping env assignments only ahead of
  /// `sudo` would leave `FOO=bar` as the verb and silently downgrade
  /// the segment.
  List<String> get effective {
    final afterSudo = hasSudo ? tokens.sublist(1) : tokens;
    var start = 0;
    while (start < afterSudo.length && _isEnvAssignment(afterSudo[start])) {
      start++;
    }
    return afterSudo.sublist(start);
  }

  /// The executable name, stripped of any path prefix
  /// (`/sbin/shutdown` → `shutdown`). Aliases and shell functions
  /// aren't resolved — same limitation as `shell_guard.dart`.
  String? get verb {
    if (effective.isEmpty) return null;
    final first = effective.first;
    final slash = first.lastIndexOf(RegExp(r'[/\\]'));
    return slash >= 0 ? first.substring(slash + 1) : first;
  }

  List<String> get args =>
      effective.length <= 1 ? const <String>[] : effective.sublist(1);
}

_ParsedSegment _parseSegment(String segment) {
  final tokens = segment
      .trim()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
  var start = 0;
  while (start < tokens.length && _isEnvAssignment(tokens[start])) {
    start++;
  }
  return _ParsedSegment(tokens.sublist(start));
}

/// Whether any short-flag token contains [flag] — `-rf` counts for
/// both `r` and `f`. Long flags (`--force`) are excluded so
/// `--force` doesn't trip the `f` check and `--recursive` doesn't
/// trip `r`.
bool _hasShortFlag(List<String> args, String flag) => args.any(
  (a) =>
      a.length > 1 &&
      a.startsWith('-') &&
      !a.startsWith('--') &&
      a.contains(flag),
);

bool _hasLongFlag(List<String> args, String name) =>
    args.any((a) => a == '--$name');

/// Arguments that aren't flags — the targets the verb acts on.
/// Quoted paths keep their quotes here; comparison helpers strip
/// them via [_stripQuotes].
List<String> _nonFlagArgs(List<String> args) =>
    args.where((a) => !a.startsWith('-')).toList(growable: false);

String _stripQuotes(String token) {
  if (token.length >= 2) {
    final first = token[0];
    final last = token[token.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return token.substring(1, token.length - 1);
    }
  }
  return token;
}

/// Whether [raw] targets the filesystem root or the home directory
/// itself — `/`, `/*`, `~`, `~/*`, with trailing slashes tolerated
/// (`~/`). This is the catastrophic `rm -rf` target set, kept
/// deliberately narrow: `~/anything-else` is only absolute
/// (suspicious), and relative paths never match.
bool _isRootTarget(String raw) {
  var t = _stripQuotes(raw).trim();
  while (t.length > 1 && (t.endsWith('/') || t.endsWith(r'\'))) {
    t = t.substring(0, t.length - 1);
  }
  return t == '/' || t == '~' || t == '/*' || t == '~/*';
}

/// Whether [raw] is an absolute POSIX path (`/tmp/x`, `~/foo`).
/// The suspicious `rm -rf` target set.
bool _isAbsoluteTarget(String raw) {
  final t = _stripQuotes(raw).trim();
  return t.startsWith('/') || t == '~' || t.startsWith('~/');
}

/// Whether [raw] is a target the heuristic cannot resolve to a
/// concrete path: shell variables (`$HOME`, `${HOME}`), command
/// substitution (`` `...` ``, `$(...)`), or the `~user` form (tilde
/// followed by a non-slash character, which expands to another
/// user's home). A recursive+forced `rm` on any of these slips past
/// both the root-target and absolute-path checks because the literal
/// text never looks like a dangerous path — so it must escalate to
/// the aux model. `~` and `~/` themselves are NOT indirect: they are
/// pinned as root targets (catastrophic).
bool _isIndirectTarget(String raw) {
  final t = _stripQuotes(raw).trim();
  if (t.contains(r'$') || t.contains('`')) return true;
  return t.length > 1 && t.startsWith('~') && !t.startsWith('~/');
}

bool _isWinDriveRoot(String raw) => _winDriveRoot.hasMatch(_stripQuotes(raw));

bool _isWinSystemDir(String raw) => _winSystemDir.hasMatch(_stripQuotes(raw));

// =============================================================================
// Segment splitter + env-prefix detection (mirrors shell_guard.dart)
// =============================================================================

/// Split a shell command into top-level segments separated by `|`,
/// `;`, `&&`, `||`, or newlines. Quote-aware: operators inside
/// `'...'` or `"..."` don't split, so `git commit -m 'a | b'` stays
/// one segment. Mirrors `_splitSegments` in `shell_guard.dart`
/// (private there, so duplicated rather than shared); see that file
/// for the full parsing-semantics notes. Not a full shell parser —
/// here-docs and command substitutions are still misread, which is
/// fine for a heuristic tier whose questionable output gets reviewed
/// by the aux model anyway.
List<String> _splitSegments(String command) {
  final result = <String>[];
  final current = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  var escapeNext = false;

  for (var i = 0; i < command.length; i++) {
    final ch = command[i];

    // Inside single quotes: everything is literal until the closing
    // quote (POSIX semantics — no escape handling).
    if (inSingle) {
      if (ch == "'") {
        inSingle = false;
      }
      current.write(ch);
      continue;
    }

    // Inside double quotes: backslash escapes the next char, closing
    // `"` exits, everything else is literal.
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

    // Outside quotes: backslash escapes; quotes enter their states;
    // operator characters split. `&&` / `||` are checked before `&`
    // / `|` so the multi-char tokens win the race.
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

    if (ch == ';' || ch == '\n') {
      result.add(current.toString());
      current.clear();
      continue;
    }
    if (ch == '&' && i + 1 < command.length && command[i + 1] == '&') {
      result.add(current.toString());
      current.clear();
      i++;
      continue;
    }
    if (ch == '|' && i + 1 < command.length && command[i + 1] == '|') {
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

/// Whether [token] looks like an env-assignment prefix (`FOO=bar`).
/// Copied from `shell_guard.dart` so `FOO=bar rm -rf /` resolves the
/// real verb.
bool _isEnvAssignment(String token) {
  if (!token.contains('=')) return false;
  final name = token.substring(0, token.indexOf('='));
  if (name.isEmpty) return false;
  return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name);
}
