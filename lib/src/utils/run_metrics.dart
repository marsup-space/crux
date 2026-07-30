/// Per-run metrics aggregator — prints a one-screen summary when
/// Crux exits.
///
/// `RunMetrics` is a process-wide singleton (same pattern as
/// `FrameProfiler.instance`) that captures three things about this
/// Crux run:
///
///   1. How long Crux was running (from the first reference to
///      [instance] until the binary is about to `exit`).
///   2. How many agent turns the user drove (each "user → model →
///      tool rounds → final answer" exchange counts as one turn;
///      `/btw` side-questions contribute to the token totals but
///      are intentionally *not* counted as agent turns — they are
///      an out-of-band affordance, not part of the main flow).
///   3. How many tokens were spent overall, broken down by
///      input / output / prompt-cache-hit / prompt-cache-miss.
///
/// The aggregator is fed from three places:
///   - `ChatTurnOrchestrator.sendTurn` — bumps the turn counter
///     and records the turn's `ChatResponse` once the LLM stream
///     finishes.
///   - `ChatTurnOrchestrator.sendBtwTurn` — records a `/btw`
///     round's token usage. No turn-count bump.
///   - (no other call sites) — every other turn the binary
///     performs (title generation, TLDR, etc.) goes through one
///     of the two methods above or is tiny enough that mixing
///     it into the totals is harmless.
///
/// All updates are on the UI isolate; Dart's single-threaded
/// event loop makes concurrent updates impossible, so no
/// synchronisation is needed.
///
/// To print a summary, call [formatSummary] on the snapshot
/// returned by [getSnapshot]. `bin/crux.dart` does this after
/// `runApp()` returns, when the TUI has already torn down the
/// alt-screen — so the text lands in the user's shell buffer
/// (the "main buffer") rather than inside the now-defunct
/// alt-screen.
library;

import 'package:nocterm/nocterm.dart';

import '../theme/crux_theme.dart';
import 'terminal_symbols.dart';

/// Immutable snapshot of the run metrics. Returned by
/// [RunMetrics.getSnapshot] and consumed by the summary
/// renderer.
class RunMetricsSnapshot {
  final Duration duration;
  final int turnCount;
  final int totalTokensIn;
  final int totalTokensOut;
  final int cacheHitTokens;
  final int cacheMissTokens;

  const RunMetricsSnapshot({
    required this.duration,
    required this.turnCount,
    required this.totalTokensIn,
    required this.totalTokensOut,
    required this.cacheHitTokens,
    required this.cacheMissTokens,
  });

  /// Prompt-cache hit rate as a 0–100 percentage. Returns
  /// `null` when there are no input tokens at all (cache stats
  /// would be meaningless / divide-by-zero).
  double? get cacheHitPct {
    final total = cacheHitTokens + cacheMissTokens;
    if (total == 0) return null;
    return (cacheHitTokens / total) * 100.0;
  }

  /// Sum of input tokens counted by the cache (hit + miss).
  int get totalPromptTokens => cacheHitTokens + cacheMissTokens;

  /// True when no turns have completed and no tokens have been
  /// spent. The summary renderer uses this to decide whether
  /// to print a "no turns completed" line in place of the
  /// token breakdown — otherwise the breakdown would be a
  /// wall of zeros, which is more confusing than just saying
  /// "nothing happened".
  bool get isEmpty =>
      turnCount == 0 &&
      totalTokensIn == 0 &&
      totalTokensOut == 0 &&
      cacheHitTokens == 0 &&
      cacheMissTokens == 0;
}

/// One cell of the run-summary box.
///
/// The summary is structured as a grid: each row is a list
/// of cells, and each cell carries a single grapheme plus
/// a "kind" hint that tells the renderer how to style it.
/// Two formatters consume the same grid:
///
///   - [_formatSummaryPlain] — emits the raw characters
///     (current `formatSummary` behaviour, no ANSI codes).
///   - [_formatSummaryStyled] — wraps each cell in the
///     ANSI SGR codes that match its kind, picking colours
///     from the supplied [CruxThemeData].
///
/// Splitting "what each cell means" from "how to draw it"
/// keeps the column-aligned math in one place and makes it
/// trivial to add new formatters (e.g. Markdown, HTML)
/// without re-deriving the layout.
enum _SummaryCellKind {
  /// Box-drawing glyph (corner, edge, or vertical bar).
  border,

  /// The "Crux Run Summary" title in the top border.
  title,

  /// Row label, e.g. `Duration:`, `Turns:`, `Tokens in:`.
  label,

  /// Row value, e.g. `5m 23s`, `3`, `12.8K`.
  value,

  /// Muted row value used for the "no LLM calls this run"
  /// status note in the empty-run case, so the renderer can
  /// dim it slightly relative to a real value.
  valueMuted,
}

class _SummaryCell {
  final String char;
  final _SummaryCellKind kind;
  const _SummaryCell(this.char, this.kind);
}

class RunMetrics {
  /// The most recent theme the chat panel saw at exit time.
  /// Stashed by [ChatPanel._quitAndPrintSummary] right before
  /// the TUI tears down, so the `bin/crux.dart` post-`runApp`
  /// fallback path can produce a styled summary even though
  /// the `ThemeController` has already been disposed.
  ///
  /// `null` when the chat panel never had a chance to stash
  /// anything (e.g. the very early-boot `--doctor` path, or
  /// `runApp` returning because of some other shutdown path
  /// the chat panel didn't drive). In that case
  /// [formatStyledSummary] falls back to plain output.
  CruxThemeData? _lastKnownTheme;

  /// Set the most recent theme. Called by the chat panel
  /// right before [formatStyledSummary] so the post-`runApp`
  /// fallback path can read it back. See [_lastKnownTheme]
  /// for the full rationale.
  void setLastKnownTheme(CruxThemeData theme) {
    _lastKnownTheme = theme;
  }

  RunMetrics._();

  /// Shared instance. Lazily captures `_startTime` on first
  /// access so the "duration" field measures the time from
  /// the first meaningful interaction (or just the first
  /// reference) until shutdown, rather than the time from
  /// `main()`'s entry — the splash + DB-init work isn't part
  /// of the user's session.
  static final RunMetrics instance = RunMetrics._();

  DateTime? _startTime;

  int _turnCount = 0;
  int _totalTokensIn = 0;
  int _totalTokensOut = 0;
  int _cacheHitTokens = 0;
  int _cacheMissTokens = 0;

  /// Mark the start of the run (lazy). Called by every public
  /// mutator below so callers don't have to remember to call
  /// a separate "begin" method on startup.
  void _ensureStarted() {
    _startTime ??= DateTime.now();
  }

  /// Number of completed main-agent turns observed so far.
  int get turnCount {
    _ensureStarted();
    return _turnCount;
  }

  /// Increment the turn counter. Called by the turn
  /// orchestrator right after the user submits a message.
  void recordTurnStart() {
    _ensureStarted();
    _turnCount++;
  }

  /// Record a regular turn's token usage. Called by the turn
  /// orchestrator's `onComplete` callback once the LLM stream
  /// has finished and the final `ChatResponse` is available.
  ///
  /// Zero values are valid: an LLM call that returned zero
  /// tokens (rare but possible — e.g. a prompt that was
  /// entirely refused) should still count, so we don't filter
  /// them out.
  void recordTurnUsage({
    required int tokensIn,
    required int tokensOut,
    required int cacheHit,
    required int cacheMiss,
  }) {
    _ensureStarted();
    _totalTokensIn += tokensIn;
    _totalTokensOut += tokensOut;
    _cacheHitTokens += cacheHit;
    _cacheMissTokens += cacheMiss;
  }

  /// Record a `/btw` turn's token usage. `/btw` rounds are
  /// ephemeral side-questions that never touch the persisted
  /// session — but they do call the LLM and cost tokens, so
  /// they belong in the totals. They are deliberately NOT
  /// counted in [turnCount]; the counter only reflects
  /// "real" agent turns.
  void recordBtwUsage({
    required int tokensIn,
    required int tokensOut,
    required int cacheHit,
    required int cacheMiss,
  }) {
    _ensureStarted();
    _totalTokensIn += tokensIn;
    _totalTokensOut += tokensOut;
    _cacheHitTokens += cacheHit;
    _cacheMissTokens += cacheMiss;
  }

  /// Return an immutable snapshot of the current state. Used
  /// by `bin/crux.dart` after `runApp()` returns to render
  /// the summary.
  RunMetricsSnapshot getSnapshot() {
    _ensureStarted();
    return RunMetricsSnapshot(
      duration: DateTime.now().difference(_startTime!),
      turnCount: _turnCount,
      totalTokensIn: _totalTokensIn,
      totalTokensOut: _totalTokensOut,
      cacheHitTokens: _cacheHitTokens,
      cacheMissTokens: _cacheMissTokens,
    );
  }

  /// Format [snapshot] as a multi-line block ready to be
  /// written to stdout. Box-drawing characters use Unicode on
  /// terminals that support them and ASCII otherwise
  /// (detected by [supportsRichTerminalSymbols]).
  ///
  /// [indent] lets callers prefix every line (e.g. when the
  /// summary is embedded in a wider log). [useAscii] forces
  /// the ASCII variant regardless of the platform — used by
  /// tests to make snapshots stable.
  String formatSummary({
    RunMetricsSnapshot? snapshot,
    String indent = '',
    bool useAscii = false,
  }) {
    final cells = _buildSummaryGrid(
      snapshot ?? getSnapshot(),
      useAscii: useAscii,
    );
    return _renderSummaryPlain(cells, indent: indent);
  }

  /// Same as [formatSummary] but with ANSI SGR escape
  /// sequences around each cell so the box is coloured
  /// according to the active [CruxThemeData]. Colours are
  /// sourced from the theme as follows:
  ///
  ///   - border: `theme.borderSubtle` (a muted line so the
  ///     frame doesn't fight the text)
  ///   - title:  `theme.primary` (the "Crux Run Summary"
  ///     banner)
  ///   - label:  `theme.textMuted` (so the labels read as
  ///     secondary to the values)
  ///   - value:  `theme.text`
  ///   - valueMuted (the "no LLM calls this run" status):
  ///     `theme.textMuted`
  ///
  /// When [useAscii] is true the box characters themselves
  /// are also swapped for ASCII, even in styled mode — this
  /// is what you'd want for piping the summary into a file
  /// (`crux … > log.txt`) or any other context where the
  /// terminal can't render Unicode.
  String formatStyledSummary({
    RunMetricsSnapshot? snapshot,
    CruxThemeData? theme,
    String indent = '',
    bool useAscii = false,
  }) {
    final effectiveTheme = theme ?? _lastKnownTheme;
    final cells = _buildSummaryGrid(
      snapshot ?? getSnapshot(),
      useAscii: useAscii,
    );
    if (effectiveTheme == null) {
      // No theme stashed yet (very-early-boot `--doctor` or
      // the bare `runApp`-returns path that bypassed the
      // chat panel) — fall back to plain output so the
      // summary still renders cleanly without colour codes.
      return _renderSummaryPlain(cells, indent: indent);
    }
    return _renderSummaryStyled(cells, theme: effectiveTheme, indent: indent);
  }

  /// Reset all counters. Test-only — production code never
  /// calls this. Exposed publicly so test setup can wipe
  /// state between cases without re-instantiating the
  /// singleton.
  void reset() {
    _startTime = null;
    _turnCount = 0;
    _totalTokensIn = 0;
    _totalTokensOut = 0;
    _cacheHitTokens = 0;
    _cacheMissTokens = 0;
  }

  // ── Cell grid + renderers ─────────────────────────────────────

  /// Build the run-summary layout as a 2-D grid of cells.
  ///
  /// The grid has `boxWidth` columns per row. Every row's
  /// contents (top border, content rows, bottom border) all
  /// sum to the same width so the right edge lines up.
  ///
  /// Math derivation (each line is `boxWidth` cols wide):
  ///   top:    `┌─<titleText>─…─┐`
  ///            1 + 1 + titleText.length + N = boxWidth
  ///   row:    `│  <label><padding><value>  │`
  ///            2 + label.length + padding + value.length + 2 = boxWidth
  ///   bottom: `└─…─┐` (well, └…┘ — the bottom-right is `┘`)
  ///            1 + N = boxWidth
  ///
  /// Earlier revisions of this code used `innerWidth` for
  /// the row math and `innerWidth + 1` for the bottom
  /// border math, but the offset between those was a
  /// classic off-by-one — the row landed 1 col to the right
  /// of the borders, breaking the right edge of the box.
  /// Centralising on `boxWidth` keeps all three formulas in
  /// sync.
  static List<List<_SummaryCell>> _buildSummaryGrid(
    RunMetricsSnapshot snap, {
    bool useAscii = false,
  }) {
    final rich = !useAscii && supportsRichTerminalSymbols();
    final topLeft = rich ? '╭' : '+';
    final topRight = rich ? '╮' : '+';
    final bottomLeft = rich ? '╰' : '+';
    final bottomRight = rich ? '╯' : '+';
    final horizontal = rich ? '─' : '-';
    final vertical = rich ? '│' : '|';

    const boxWidth = 45;
    final titleText = ' Crux Run Summary ';
    final topDashCount = boxWidth - 3 - titleText.length;
    final bottomDashCount = boxWidth - 2;

    List<_SummaryCell> topRow() {
      // ┌─ Crux Run Summary ─...─┐
      return <_SummaryCell>[
        _SummaryCell(topLeft, _SummaryCellKind.border),
        _SummaryCell(horizontal, _SummaryCellKind.border),
        for (final c in titleText.codeUnits)
          _SummaryCell(String.fromCharCode(c), _SummaryCellKind.title),
        for (var i = 0; i < topDashCount; i++)
          _SummaryCell(horizontal, _SummaryCellKind.border),
        _SummaryCell(topRight, _SummaryCellKind.border),
      ];
    }

    List<_SummaryCell> bottomRow() {
      // └─...─┘
      return <_SummaryCell>[
        _SummaryCell(bottomLeft, _SummaryCellKind.border),
        for (var i = 0; i < bottomDashCount; i++)
          _SummaryCell(horizontal, _SummaryCellKind.border),
        _SummaryCell(bottomRight, _SummaryCellKind.border),
      ];
    }

    List<_SummaryCell> contentRow(
      String label,
      String value,
      _SummaryCellKind valueKind,
    ) {
      // │  <label>...<value>  │
      final pad = boxWidth - 2 - 4 - label.length - value.length;
      final padding = pad < 1 ? 1 : pad;
      return <_SummaryCell>[
        _SummaryCell(vertical, _SummaryCellKind.border),
        _SummaryCell(' ', _SummaryCellKind.border),
        _SummaryCell(' ', _SummaryCellKind.border),
        for (final c in label.codeUnits)
          _SummaryCell(String.fromCharCode(c), _SummaryCellKind.label),
        for (var i = 0; i < padding; i++)
          _SummaryCell(' ', _SummaryCellKind.border),
        for (final c in value.codeUnits)
          _SummaryCell(String.fromCharCode(c), valueKind),
        _SummaryCell(' ', _SummaryCellKind.border),
        _SummaryCell(' ', _SummaryCellKind.border),
        _SummaryCell(vertical, _SummaryCellKind.border),
      ];
    }

    final rows = <List<_SummaryCell>>[topRow()];

    if (snap.isEmpty) {
      // No turns ran — still print the duration so the
      // user can see how long the binary was open, but
      // skip the zero-only token rows. The "no LLM calls
      // this run" line uses `valueMuted` so the renderer
      // can dim it.
      rows.add(
        contentRow(
          'Duration:',
          _formatDuration(snap.duration),
          _SummaryCellKind.value,
        ),
      );
      rows.add(contentRow('Turns:', '0', _SummaryCellKind.value));
      rows.add(
        contentRow(
          'Status:',
          'no LLM calls this run',
          _SummaryCellKind.valueMuted,
        ),
      );
    } else {
      rows.add(
        contentRow(
          'Duration:',
          _formatDuration(snap.duration),
          _SummaryCellKind.value,
        ),
      );
      rows.add(
        contentRow('Turns:', snap.turnCount.toString(), _SummaryCellKind.value),
      );
      rows.add(
        contentRow(
          'Tokens in:',
          '${_formatTokenCount(snap.totalTokensIn)}  '
              '${_formatCacheSuffix(snap)}',
          _SummaryCellKind.value,
        ),
      );
      rows.add(
        contentRow(
          'Tokens out:',
          _formatTokenCount(snap.totalTokensOut),
          _SummaryCellKind.value,
        ),
      );
    }

    rows.add(bottomRow());
    return rows;
  }

  /// Flatten the cell grid into a plain string. Each cell
  /// contributes exactly its character — no styling. Used
  /// by [formatSummary] and by tests that want a stable,
  /// platform-agnostic rendering of the summary (e.g. for
  /// snapshot tests or piped output).
  static String _renderSummaryPlain(
    List<List<_SummaryCell>> grid, {
    String indent = '',
  }) {
    return grid.map((row) => indent + row.map((c) => c.char).join()).join('\n');
  }

  /// Flatten the cell grid into a string with ANSI SGR
  /// escape codes around each cell. Adjacent cells of the
  /// same kind are wrapped in a single SGR span (so the
  /// output doesn't emit a redundant `\x1B[…m` per
  /// character), but every kind change still emits a fresh
  /// "set style" code so the rendering is robust to any
  /// unexpected state left in the terminal by the previous
  /// TUI frame.
  ///
  /// The terminator after each cell is `\x1B[0m` (SGR
  /// reset). That means the next cell always starts from a
  /// known baseline, even if the terminal only partially
  /// supports the codes our previous summary wrote.
  static String _renderSummaryStyled(
    List<List<_SummaryCell>> grid, {
    required CruxThemeData theme,
    String indent = '',
  }) {
    TextStyle styleFor(_SummaryCellKind kind) {
      switch (kind) {
        case _SummaryCellKind.border:
          return TextStyle(color: theme.borderSubtle);
        case _SummaryCellKind.title:
          return TextStyle(color: theme.primary, fontWeight: FontWeight.bold);
        case _SummaryCellKind.label:
          return TextStyle(color: theme.textMuted);
        case _SummaryCellKind.value:
          return TextStyle(color: theme.text);
        case _SummaryCellKind.valueMuted:
          return TextStyle(color: theme.textMuted);
      }
    }

    String renderRow(List<_SummaryCell> row) {
      final buf = StringBuffer();
      buf.write(indent);
      var i = 0;
      while (i < row.length) {
        final cell = row[i];
        final kind = cell.kind;
        // Coalesce adjacent same-kind cells into a single
        // SGR span — a label like "Duration:" is 9 chars
        // but should be wrapped in one `\x1B[…m` … `\x1B[0m`
        // pair, not nine.
        var j = i;
        while (j + 1 < row.length && row[j + 1].kind == kind) {
          j++;
        }
        final span = row.sublist(i, j + 1).map((c) => c.char).join();
        buf.write(styleFor(kind).toAnsi());
        buf.write(span);
        buf.write('\x1B[0m');
        i = j + 1;
      }
      return buf.toString();
    }

    return grid.map(renderRow).join('\n');
  }

  // ── Formatters ───────────────────────────────────────────────

  /// `12.5K`, `1.23M`, `782`. One decimal for K/M, no
  /// fractional for < 1000. Picked to keep the row
  /// narrow enough that the box border doesn't wrap on a
  /// 60-column terminal.
  static String _formatTokenCount(int n) {
    if (n < 1000) return n.toString();
    if (n < 1_000_000) {
      final v = n / 1000.0;
      // Strip the trailing ".0" so 12000 reads "12K" not
      // "12.0K".
      return v.truncateToDouble() == v
          ? '${v.toStringAsFixed(0)}K'
          : '${v.toStringAsFixed(1)}K';
    }
    final v = n / 1_000_000.0;
    return v.truncateToDouble() == v
        ? '${v.toStringAsFixed(0)}M'
        : '${v.toStringAsFixed(1)}M';
  }

  /// `(cache 78%)` or `(cache —)` when no input tokens
  /// were recorded. Inline suffix on the "Tokens in" row
  /// to avoid giving cache stats their own line — a turn
  /// with 0 tokens is a turn with 0 cache, so a separate
  /// row would always read 0 in degenerate cases.
  static String _formatCacheSuffix(RunMetricsSnapshot snap) {
    final pct = snap.cacheHitPct;
    if (pct == null) return '(cache —)';
    return '(cache ${pct.toStringAsFixed(1)}%)';
  }

  /// `5m 23s`, `1h 12m 5s`, `42s`, `2h 0m`. Skips
  /// leading zero fields (so 5m 0s reads "5m" not
  /// "5m 0s"). For durations over 1 day (highly
  /// unlikely in a single Crux run) the days roll up into
  /// hours so the box doesn't overflow.
  static String _formatDuration(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final totalSeconds = d.inSeconds;
    if (totalSeconds < 60) return '${totalSeconds}s';
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    if (minutes < 60) {
      return seconds == 0 ? '${minutes}m' : '${minutes}m ${seconds}s';
    }
    final hours = minutes ~/ 60;
    final remMinutes = minutes % 60;
    if (hours < 24) {
      if (remMinutes == 0 && seconds == 0) return '${hours}h';
      if (seconds == 0) return '${hours}h ${remMinutes}m';
      return '${hours}h ${remMinutes}m ${seconds}s';
    }
    // Very long sessions (>24h) — show days + hours.
    final days = hours ~/ 24;
    final remHours = hours % 24;
    if (remHours == 0) return '${days}d';
    return '${days}d ${remHours}h';
  }
}
