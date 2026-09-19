/// Canonical section names for the `[subagent.*]` blocks of `config.toml`.
library;

/// Normalizes a subagent config section name to its canonical plural form.
///
/// The config file drifted between the singular and plural spellings
/// (`[subagent.worker]` vs `[subagent.workers]`) while the store only ever
/// reads and writes the plural keys. Callers that accept a user-supplied
/// section name funnel it through here so both spellings land on the same
/// key. Matching ignores surrounding whitespace and case.
///
/// Unrecognised names are returned verbatim (not trimmed, not lower-cased)
/// so a caller can quote back the exact input it was handed.
///
/// Idempotent: a canonical name maps to itself.
String canonicalSubagentSection(String name) =>
    switch (name.trim().toLowerCase()) {
      'worker' || 'workers' => 'workers',
      'expert' || 'experts' => 'experts',
      _ => name,
    };
