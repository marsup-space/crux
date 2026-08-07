/// Best-effort progress extraction from raw shell output — the
/// "map any bash command into a progress box" layer.
///
/// The mapping lives entirely in this file: any command whose output
/// carries a recognizable progress signal (a percent, a bar, a
/// `cur/total` fraction, a transfer rate, an ETA, or a phase word
/// like "Downloading" / "Installing" / "Compiling") gets normalized
/// into a [ShellProgress]. No per-tool registration, no command
/// whitelist — `apt install`, `git clone`, `pip install`, `yarn`,
/// `tqdm` scripts, `cargo build` and a hundred others all fall out
/// of the same parser.
///
/// Design rules:
///
/// * **Corroboration beats pattern-matching.** A bare `45%` in a line
///   is NOT trusted — `%` appears all over normal output. A percent
///   counts only when the line also carries a bar, a phase word, a
///   rate, an ETA, or a fraction. A fraction counts only with a phase
///   or bar. A bar always counts. Phase words always count (they're
///   what the phase-only box renders). This is what keeps
///   `ssh-keygen`'s `+...+...` spinner and stray `%` noise out of the
///   UI.
/// * **Sticky state machine.** Once a phase/percent/rate is seen, it
///   persists until a newer signal supersedes it (newest-wins per
///   field, peak-percent tracked separately). `\r`-updated meters
///   (curl, apt, wget) produce one "line" per frame; the newest frame
///   wins naturally.
/// * **Zero cost to the LLM.** The parser is fed by a read-only tap
///   on the output stream — the buffered output the tool returns is
///   untouched, so token counts and result content are identical.
/// * **Fail-open everywhere.** A line that matches nothing is just
///   ignored; a weird stream never throws.
library;

/// Normalized, best-effort progress snapshot for one shell run.
///
/// Immutable; the parser emits fresh instances as signals arrive and
/// the UI renders the latest one. [percent] is null unless it was
/// corroborated (see the file docstring) — a phase-only run has
/// `percent == null` and `hasPercent == false`.
class ShellProgress {
  /// Human phase word ("Downloading", "Compiling", ...) or null when
  /// the output carried only quantitative signals.
  final String? phase;

  /// 0..100 when a trustworthy percent was seen (explicit `45%`, a
  /// bar fraction, or a corroborated `cur/total` ratio).
  final double? percent;

  /// `cur` / `total` of a fraction signal ("42/120", "[2/4]", ...).
  /// Rendered only in the persisted summary; the live bar uses
  /// [percent].
  final int? current;
  final int? total;

  /// Transfer/compile rate in bytes/sec ("12.4MB/s" → ~13,002,342).
  final double? ratePerSec;

  /// Raw ETA string from the output ("0:00:03", "1m 20s", "00:07").
  final String? eta;

  /// The most recent raw output line that produced a signal. Rendered
  /// as a dim second row — the "what is it actually doing" evidence.
  final String lastLine;

  /// How many distinct output lines carried a corroborated signal.
  /// The confidence gate: [ShellProgressParser.progress] is null
  /// until this reaches 1.
  final int signalCount;

  /// True when [percent] is trustworthy enough to render a bar.
  final bool hasPercent;

  const ShellProgress({
    this.phase,
    this.percent,
    this.current,
    this.total,
    this.ratePerSec,
    this.eta,
    this.lastLine = '',
    this.signalCount = 0,
    this.hasPercent = false,
  });
}

/// Merge two stream-parsers' snapshots into one. Used by the shell
/// base, which runs one parser per stream (stdout + stderr) so a
/// `\r` meter on stderr never corrupts a partial line on stdout.
/// Non-null fields win (b takes precedence); [signalCount] sums.
ShellProgress? mergeShellProgress(ShellProgress? a, ShellProgress? b) {
  if (a == null) return b;
  if (b == null) return a;
  return ShellProgress(
    phase: b.phase ?? a.phase,
    percent: b.percent ?? a.percent,
    current: b.current ?? a.current,
    total: b.total ?? a.total,
    ratePerSec: b.ratePerSec ?? a.ratePerSec,
    eta: b.eta ?? a.eta,
    lastLine: b.lastLine.isNotEmpty ? b.lastLine : a.lastLine,
    signalCount: a.signalCount + b.signalCount,
    hasPercent: a.hasPercent || b.hasPercent,
  );
}

/// Phase words that mark "this is a long-running op worth watching".
/// Order matters: more specific alternatives precede their prefixes
/// (`Uninstalling` before `Installing`, `Resolving dependencies`
/// before `Resolving`) and every alternative is word-bounded so
/// `Installing` never matches inside `Uninstalling`.
final RegExp _phaseRe = RegExp(
  r'\b(?:'
  r'Downloading|Downloaded|Fetching|Fetch|Extracting|Unpacking|'
  r'Installing|Uninstalling|Removing|Generating|Compiling|Building|'
  r'Linking|Uploading|Uploaded|Resolving dependencies|Resolving|'
  r'Preparing|Copying|Processing|Configuring|Reading|Writing|'
  r'Packaging|Verifying checksums|Verifying|Receiving objects|'
  r'Receiving|Checking out|Pushing|Pulling|Transforming|Optimizing|'
  r'Minifying|Rendering|Serializing|Deserializing|Loading|Importing|'
  r'Exporting|Pruning|Cloning|Analyzing|Formatting|Linting|Testing|'
  r'Executing|Deploying|Provisioning|Destroying|Planning|Applying|'
  r'Bundling|Transpiling|Emitting|Collecting'
  r')\b',
  caseSensitive: false,
);

/// `45%`, `68.5%`, `100%`.
final RegExp _percentRe = RegExp(r'(\d{1,3}(?:\.\d+)?)\s*%');

/// Bracketed (or pipe-framed) progress bars: `[########....]`,
/// `[=========> ]`, tqdm's `|██████████ |` meter.
final RegExp _barRe = RegExp(r'[\[\(|]([#=▰▱▉▊▋▌▍▎▏*>.·\-\s]{2,})[\]\)|]');

/// `42/120`, `[2/4]`, `42 of 100`.
final RegExp _fractionRe = RegExp(
  r'(\d{1,7})\s*(?:/\s*|of\s+)(\d{1,7})',
);

/// `12.4MB/s`, `4.0 MiB/s`, `123 kB/s`. Deliberately requires a `B`
/// so tqdm's `8.10it/s` (items, not bytes) never parses as a byte
/// rate.
final RegExp _rateRe = RegExp(
  r'(\d+(?:\.\d+)?)\s*([KMG]i?)?B/s',
  caseSensitive: false,
);

/// `ETA 1m 20s`, `remaining: 0:00:03`, `time left: 5s`, `left: 2m`.
final RegExp _etaRe = RegExp(
  r'(?:ETA|remaining|left|time\s*left)\s*[:\s]\s*'
  r'(\d{1,2}:\d{2}(?::\d{2})?|\d+[hm]s?(?:\s*\d+s)?)',
  caseSensitive: false,
);

/// tqdm's `[00:05<00:07, 8.10it/s]` — the ETA after `<`.
final RegExp _tqdmEtaRe = RegExp(r'<\s*(\d{1,2}:\d{2}(?::\d{2})?)');

/// A bare clock at end-of-line (`... 0:00:03`) on an already-
/// corroborated meter line (curl / apt output). Only consulted when
/// the line is corroborated, so log timestamps never become ETAs.
final RegExp _trailingTimeRe = RegExp(r'(\d{1,2}:\d{2}(?::\d{2})?)\s*$');

const Set<String> _filledChars = {
  '#', '=', '▰', '▉', '▊', '▋', '▌', '▍', '▎', '▏', '*', '>',
};

const Set<String> _unfilledChars = {'-', '.', ' ', '·'};

/// Sticky, stateful progress extractor for ONE output stream.
///
/// Feed it decoded text chunks with [addChunk]; it buffers partial
/// lines (splitting on both `\n` and `\r`) and updates its state as
/// signal-bearing lines arrive. [progress] exposes the current best
/// snapshot, or null until the first corroborated signal.
///
/// Not thread-safe and not re-entrant — owned by a single shell run,
/// fed from one stream.
class ShellProgressParser {
  String _pending = '';
  String? _phase;
  double? _percent;
  int? _current;
  int? _total;
  double? _ratePerSec;
  String? _eta;
  String _lastLine = '';
  int _signalCount = 0;
  bool _percentCorroborated = false;
  double? _peakPercent;

  /// Highest percent value seen across the run, regardless of
  /// corroboration. Used for the persisted summary.
  double? get peakPercent => _peakPercent;

  /// The current best snapshot, or null when no corroborated signal
  /// has been seen yet.
  ShellProgress? get progress {
    if (_signalCount == 0) return null;
    final hasPercent = _percentCorroborated && _percent != null;
    return ShellProgress(
      phase: _phase,
      percent: hasPercent ? _percent : null,
      current: _current,
      total: _total,
      ratePerSec: _ratePerSec,
      eta: _eta,
      lastLine: _lastLine,
      signalCount: _signalCount,
      hasPercent: hasPercent,
    );
  }

  /// Feed one decoded text chunk. Partial trailing lines are buffered
  /// until the next chunk or [finish].
  void addChunk(String chunk) {
    _pending += chunk;
    final parts = _pending.split(_lineSplitRe);
    _pending = parts.removeLast();
    for (final line in parts) {
      _processLine(line);
    }
  }

  /// Flush the buffered trailing line (a `\r` meter's final frame
  /// often has no terminator). Call once when the stream closes.
  void finish() {
    final tail = _pending.trim();
    if (tail.isNotEmpty) _processLine(tail);
    _pending = '';
  }

  void _processLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;

    final phaseM = _phaseRe.firstMatch(trimmed);
    final barM = _barRe.firstMatch(trimmed);
    final pctM = _percentRe.firstMatch(trimmed);
    final fracM = _fractionRe.firstMatch(trimmed);
    final rateM = _rateRe.firstMatch(trimmed);

    // Bar fraction — the strongest quantitative signal.
    double? barFraction;
    if (barM != null) {
      final body = barM.group(1)!;
      var filled = 0, total = 0;
      for (final c in body.split('')) {
        if (_filledChars.contains(c)) {
          filled++;
          total++;
        } else if (_unfilledChars.contains(c)) {
          total++;
        }
      }
      if (total > 0 && filled > 0) barFraction = filled / total;
    }

    double? pctValue;
    if (pctM != null) pctValue = double.tryParse(pctM.group(1)!);

    int? fracCur, fracTotal;
    if (fracM != null) {
      final c = int.tryParse(fracM.group(1)!);
      final t = int.tryParse(fracM.group(2)!);
      if (c != null && t != null && t > 0 && c <= t && t <= 100000) {
        fracCur = c;
        fracTotal = t;
      }
    }

    double? rateValue;
    if (rateM != null) {
      final v = double.tryParse(rateM.group(1)!);
      if (v != null) rateValue = v * _rateMultiplier(rateM.group(2));
    }

    // Percent source priority: explicit `%` > bar fraction > ratio.
    // Corroboration decides whether any of them is trustworthy.
    double? percent;
    var corroborated = false;
    if (pctValue != null) {
      percent = pctValue;
      if (barFraction != null ||
          phaseM != null ||
          rateValue != null ||
          fracCur != null ||
          _etaRe.hasMatch(trimmed)) {
        corroborated = true;
      }
    } else if (barFraction != null) {
      percent = barFraction * 100;
      corroborated = true;
    } else if (fracCur != null) {
      if (phaseM != null || barFraction != null) {
        percent = fracCur / fracTotal! * 100;
        corroborated = true;
      }
    }

    String? eta = _etaRe.firstMatch(trimmed)?.group(1);
    eta ??= _tqdmEtaRe.firstMatch(trimmed)?.group(1);
    if (eta == null && corroborated) {
      eta = _trailingTimeRe.firstMatch(trimmed)?.group(1);
    }

    final hasAnySignal =
        phaseM != null ||
        percent != null ||
        rateValue != null ||
        eta != null ||
        fracCur != null;
    if (!hasAnySignal) return;

    // Apply to the sticky state (newest-wins per field).
    if (phaseM != null) _phase = _titleCase(phaseM.group(0)!);
    if (percent != null) {
      _percent = percent;
      if (_peakPercent == null || percent > _peakPercent!) {
        _peakPercent = percent;
      }
    }
    if (fracCur != null) {
      _current = fracCur;
      _total = fracTotal;
    }
    if (rateValue != null) _ratePerSec = rateValue;
    if (eta != null) _eta = eta;
    _lastLine = trimmed;

    if (corroborated) {
      _percentCorroborated = true;
      _signalCount++;
    } else if (phaseM != null) {
      // A phase word alone earns a phase-only box (no bar).
      _signalCount++;
    }
  }
}

final RegExp _lineSplitRe = RegExp(r'[\r\n]+');

double _rateMultiplier(String? unit) {
  switch (unit?.toUpperCase()) {
    case 'K':
    case 'KI':
      return 1024;
    case 'M':
    case 'MI':
      return 1024 * 1024;
    case 'G':
    case 'GI':
      return 1024 * 1024 * 1024;
    default:
      return 1;
  }
}

/// Capitalize only the first letter — "receiving objects" →
/// "Receiving objects". Keeps multi-word phases readable without
/// mangling proper nouns.
String _titleCase(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}

/// Receives progress snapshots for one shell run. Wired from the chat
/// executor down to the shell tools via `ToolContext` — the analogue
/// of `ShellMonitorLogSink`, but for the live UI instead of the DB.
///
/// Implementations must not throw (the shell base's progress tap is
/// fail-open — a logging hiccup must never affect the command), and
/// [update] may be called from either stream's async context.
abstract class ShellProgressSink {
  /// The compact summary stamped into `ToolResult.metadata` as
  /// `'shellProgress'` when the run produced detectable signals.
  /// Null until [finish] runs; null forever when nothing was found.
  Map<String, dynamic>? get summary;

  /// Record a normalized snapshot. [command] is passed on the first
  /// update so the sink can stamp the entry's preview.
  void update(ShellProgress progress, {String? command});

  /// The run is over. [summary] (null when no progress was detected)
  /// becomes the tool result's `shellProgress` metadata; [exitCode]
  /// marks the registry entry done.
  void finish({int? exitCode, Map<String, dynamic>? summary});
}
