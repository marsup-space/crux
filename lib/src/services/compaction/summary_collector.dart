// Bottom-of-log summary section builder.
//
// Accumulates [SummaryContribution]s, deduplicates by (category, key)
// using last-write-wins, and renders three optional sections:
//
//   * `loaded skills:` — skill bodies the agent loaded via the
//                        `skill` tool. Sourced from the tool_result
//                        (the `<skill_content>` block the model saw).
//                        Dedup by skill name: re-loading the same
//                        skill collapses to one entry. Rendered
//                        FIRST, before the file sections, because
//                        skill bodies are instructions the resumed
//                        agent must follow while reading the rest.
//   * `read files:`   — file content the agent READ, one entry per
//                       path. Sourced from the read tool's tool_result
//                       (what the model actually saw), not from a
//                       fresh re-read of disk at compact time. The
//                       chat log preserves the model's memory.
//   * `write files:`  — file content the agent WROTE, one entry per
//                       path. Sourced from the write tool's input
//                       `content` argument (the payload the model
//                       produced), so post-compact the resumed agent
//                       has its own write preserved verbatim.
//
// Other categories that tools might still send (`searched-terms`,
// `fetched-pages`) are ignored — they're either obsolete or were
// double-counting inline result text.
//
// Also exposes [fileMarkers] so the caller can replay the file reads
// into the [FileReadTracker] — that's how the chat log "counts as a
// read" of the file, keeping the read-before-write guard happy post-
// compact. (Write markers are NOT replayed; the write tool already
// records its own mtime via the tracker when it persists the file.)

import '../../tools/tool_def.dart';

class FileReadMarker {
  final String path;
  final int mtime;
  const FileReadMarker({required this.path, required this.mtime});
}

class SummaryCollector {
  final Map<String, SummaryContribution> _entries = {};

  /// Add or replace the contribution for this (category, key).
  /// Last-write-wins: if the same file is read five times during the
  /// chat log range, only the last snapshot survives.
  void add(SummaryContribution c) {
    _entries['${c.category}::${c.key}'] = c;
  }

  bool get isEmpty => _entries.isEmpty;

  /// Render the summary section, appended to the chat log after the
  /// inline per-round blocks. Returns an empty string when nothing
  /// was contributed.
  String render() {
    if (_entries.isEmpty) return '';

    final skills = <SummaryContribution>[];
    final reads = <SummaryContribution>[];
    final writes = <SummaryContribution>[];
    for (final c in _entries.values) {
      switch (c.category) {
        case 'skill-bodies':
          skills.add(c);
          break;
        case 'read-files':
          reads.add(c);
          break;
        case 'write-files':
          writes.add(c);
          break;
        // `searched-terms` / `fetched-pages` (and any future
        // category we haven't taught this collector about) are
        // silently dropped — the chat log body already records
        // the call (path / query / intent), and the result text
        // doesn't survive into the post-compact summary.
      }
    }

    if (skills.isEmpty && reads.isEmpty && writes.isEmpty) return '';

    final buf = StringBuffer();
    _renderSection(buf, header: 'loaded skills:', entries: skills);
    _renderSection(buf, header: 'read files:', entries: reads);
    _renderSection(buf, header: 'write files:', entries: writes);
    return buf.toString().trimRight();
  }

  /// Render one section under a fixed [header]. Same cap-and-omit
  /// logic for every category: try each entry in full, truncate the
  /// one that overflows, omit the rest. The sections share the
  /// global [kInlineSummarySectionMaxChars] budget because they
  /// together form the "content the agent knows" bulk of the
  /// post-compact context.
  ///
  /// The trailing marker wording is file-centric ("re-read") but
  /// applies to skill bodies too — a truncated skill can be
  /// re-loaded with the `skill` tool, which is the same gesture.
  void _renderSection(
    StringBuffer buf, {
    required String header,
    required List<SummaryContribution> entries,
  }) {
    if (entries.isEmpty) return;
    const sectionCap = kInlineSummarySectionMaxChars;
    var written = 0;
    var omitted = 0;
    buf.writeln('\n$header');
    for (final r in entries) {
      if (written >= sectionCap) {
        omitted++;
        continue;
      }
      final body = r.value;
      final sectionSize = r.key.length + 1 + body.length + 2;
      if (written + sectionSize > sectionCap) {
        // Partial fit — show whatever body bytes fit plus a
        // short marker so the LLM knows the file is bigger.
        // Reserve ~80 chars for the marker line itself.
        final roomForBody = sectionCap - written - r.key.length - 80;
        if (roomForBody > 256) {
          buf.writeln(r.key);
          buf.writeln(
            '${body.substring(0, roomForBody)}... (truncated, re-read for full content)',
          );
          buf.writeln();
        }
        written = sectionCap;
      } else {
        buf.writeln(r.key);
        buf.writeln(body);
        buf.writeln();
        written += sectionSize;
      }
    }
    if (omitted > 0) {
      final noun = omitted == 1 ? 'file' : 'files';
      buf.writeln(
        '($omitted more $noun omitted to fit ${sectionCap ~/ 1024}KB section cap; re-read on demand)',
      );
    }
  }

  /// File markers extracted from `read-files` contributions. The caller
  /// replays these through [FileReadTracker.recordRead] so that the
  /// read-before-write guard sees the mtime we captured at compact
  /// time and doesn't spuriously report the file as modified.
  ///
  /// Note: only `read-files` entries carry an mtime (recorded by the
  /// read tool itself). `write-files` entries are tracked separately
  /// by the write tool's own `recordRead` call, so no marker is
  /// returned for them here.
  List<FileReadMarker> fileMarkers() {
    final markers = <FileReadMarker>[];
    for (final c in _entries.values) {
      if (c.category != 'read-files') continue;
      // Mtime isn't surfaced in the chat log section anymore
      // (we show what the model saw, not a freshness marker),
      // but the tracker still wants the original mtime so the
      // read-before-write guard doesn't fire on a re-read of the
      // same content. Pull from the entry's stored value if a
      // future caller starts attaching it; for now the
      // [SummaryContribution] doesn't carry one and we skip.
      final mtime = c.meta?['mtime'];
      if (mtime is int) {
        markers.add(FileReadMarker(path: c.key, mtime: mtime));
      }
    }
    return markers;
  }
}
