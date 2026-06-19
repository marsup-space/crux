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

/// Process-wide aggregator. One instance per Crux run.
class RunMetrics {
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
    final snap = snapshot ?? getSnapshot();
    final rich = !useAscii && supportsRichTerminalSymbols();

    // Border characters. The Unicode variants render as a
    // single rounded "box" character wide; the ASCII
    // variants are two chars wide for the horizontal lines
    // and one char wide for the corners, so a single
    // dash-and-plus frame still aligns when piped through
    // a non-UTF-8 pager.
    final topLeft = rich ? '┌' : '+';
    final topRight = rich ? '┐' : '+';
    final bottomLeft = rich ? '└' : '+';
    final bottomRight = rich ? '┘' : '+';
    final horizontal = rich ? '─' : '-';
    final vertical = rich ? '│' : '|';

    final titleText = ' Crux Run Summary ';
    final innerWidth = 42;

    // Build the top border: `┌─ Crux Run Summary ─────────...─┐`
    final topDashCount = (innerWidth - titleText.length).clamp(0, 200);
    final top = indent +
        topLeft +
        horizontal +
        titleText +
        List.filled(topDashCount, horizontal).join() +
        topRight;

    final bottom = indent +
        bottomLeft +
        List.filled(innerWidth + 1, horizontal).join() +
        bottomRight;

    String row(String label, String value) {
      // Two-space gutter on each side, then `label`, then a
      // gap, then the value right-aligned to the inner edge.
      final pad = innerWidth - 2 - label.length - value.length;
      final padding = pad < 1 ? 1 : pad;
      return '$indent$vertical  $label${' ' * padding}$value  $vertical';
    }

    final lines = <String>[top];

    if (snap.isEmpty) {
      // No turns ran — still print the duration so the user
      // can see how long the binary was open, but skip the
      // zero-only token rows.
      lines.add(row('Duration:', _formatDuration(snap.duration)));
      lines.add(row('Turns:', '0'));
      lines.add(row('Status:', 'no LLM calls this run'));
    } else {
      lines.add(row('Duration:', _formatDuration(snap.duration)));
      lines.add(row('Turns:', snap.turnCount.toString()));
      lines.add(
        row(
          'Tokens in:',
          '${_formatTokenCount(snap.totalTokensIn)}  '
              '${_formatCacheSuffix(snap)}',
        ),
      );
      lines.add(row('Tokens out:', _formatTokenCount(snap.totalTokensOut)));
    }

    lines.add(bottom);
    return lines.join('\n');
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
    return '(cache ${pct.toStringAsFixed(0)}%)';
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
