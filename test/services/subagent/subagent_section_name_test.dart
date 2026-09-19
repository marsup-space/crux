// Tests for the subagent section-name normalizer.
//
// The TOML config drifted between singular and plural spellings
// (`subagent.worker` vs `subagent.workers`) while the store only reads the
// plural keys. These tests lock the normalization rules so both spellings
// keep collapsing onto the same key, and so an unrecognised name is never
// silently rewritten.

import 'package:crux/src/services/subagent/subagent_section_name.dart';
import 'package:test/test.dart';

void main() {
  group('canonicalSubagentSection — singular to plural', () {
    test('maps worker to workers', () {
      expect(canonicalSubagentSection('worker'), 'workers');
    });

    test('maps expert to experts', () {
      expect(canonicalSubagentSection('expert'), 'experts');
    });
  });

  group('canonicalSubagentSection — idempotent on canonical input', () {
    test('workers stays workers', () {
      expect(canonicalSubagentSection('workers'), 'workers');
    });

    test('experts stays experts', () {
      expect(canonicalSubagentSection('experts'), 'experts');
    });

    test('applying twice equals applying once', () {
      for (final name in ['worker', 'workers', 'expert', 'experts']) {
        final once = canonicalSubagentSection(name);
        expect(canonicalSubagentSection(once), once, reason: 'name=$name');
      }
    });
  });

  group('canonicalSubagentSection — case and whitespace', () {
    test('accepts mixed case', () {
      expect(canonicalSubagentSection('Worker'), 'workers');
      expect(canonicalSubagentSection('WORKERS'), 'workers');
      expect(canonicalSubagentSection('ExPeRtS'), 'experts');
    });

    test('ignores surrounding whitespace', () {
      expect(canonicalSubagentSection('  worker '), 'workers');
      expect(canonicalSubagentSection('\texperts\n'), 'experts');
    });
  });

  group('canonicalSubagentSection — unknown input passes through', () {
    test('returns unrecognised names verbatim', () {
      expect(canonicalSubagentSection('advisor'), 'advisor');
      expect(canonicalSubagentSection('workerz'), 'workerz');
      expect(canonicalSubagentSection(''), '');
    });

    test('does not trim or lower-case unknown names', () {
      expect(canonicalSubagentSection('  Advisor '), '  Advisor ');
      expect(canonicalSubagentSection('Expertise'), 'Expertise');
    });
  });
}
