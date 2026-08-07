import 'package:crux/src/tools/shell_progress_parser.dart';
import 'package:test/test.dart';

void main() {
  group('ShellProgressParser', () {
    test('curl meter: percent + rate + trailing ETA', () {
      final p = ShellProgressParser();
      p.addChunk(' 45% 12.3M 4.2MB/s 0:00:03\r');
      final prog = p.progress;
      expect(prog, isNotNull);
      expect(prog!.percent, closeTo(45, 0.5));
      expect(prog.hasPercent, isTrue);
      expect(prog.ratePerSec, closeTo(4.2 * 1024 * 1024, 1));
      expect(prog.eta, '0:00:03');
    });

    test('git clone: percent + fraction + rate + phase', () {
      final p = ShellProgressParser();
      p.addChunk('Receiving objects:  45% (123/273), 3.2 MiB | 4.0 MiB/s\n');
      final prog = p.progress;
      expect(prog, isNotNull);
      expect(prog!.percent, closeTo(45, 0.5));
      expect(prog.phase, 'Receiving objects');
      expect(prog.current, 123);
      expect(prog.total, 273);
      expect(prog.ratePerSec, closeTo(4.0 * 1024 * 1024, 1));
    });

    test('apt: bar + percent + rate + ETA', () {
      final p = ShellProgressParser();
      p.addChunk(' 45% [###############           ] 123 MB 4.2 MB/s 0:03\n');
      final prog = p.progress;
      expect(prog, isNotNull);
      expect(prog!.percent, closeTo(45, 0.5));
      expect(prog.ratePerSec, closeTo(4.2 * 1024 * 1024, 1));
      expect(prog.eta, '0:03');
    });

    test('yarn: [n/m] fraction + phase → percent', () {
      final p = ShellProgressParser();
      p.addChunk('[2/4] Fetching packages...\n');
      final prog = p.progress;
      expect(prog, isNotNull);
      expect(prog!.percent, closeTo(50, 0.5));
      expect(prog.phase, 'Fetching');
    });

    test('tqdm: bar + percent + fraction + <eta>', () {
      final p = ShellProgressParser();
      p.addChunk('42%|██████████████████  | 42/100 [00:05<00:07, 8.10it/s]\n');
      final prog = p.progress;
      expect(prog, isNotNull);
      expect(prog!.percent, closeTo(42, 0.5));
      expect(prog.current, 42);
      expect(prog.total, 100);
      expect(prog.eta, '00:07');
    });

    test('next build: fraction + phase', () {
      final p = ShellProgressParser();
      p.addChunk('✓ Generating static pages (45/78)\n');
      final prog = p.progress;
      expect(prog, isNotNull);
      expect(prog!.percent, closeTo(45 / 78 * 100, 0.5));
      expect(prog.phase, 'Generating');
    });

    test('xcodebuild: "N of M" fraction + phase', () {
      final p = ShellProgressParser();
      p.addChunk('Compiling 42 of 100 files...\n');
      final prog = p.progress;
      expect(prog, isNotNull);
      expect(prog!.percent, closeTo(42, 0.5));
      expect(prog.phase, 'Compiling');
    });

    test('bare percent without corroboration is ignored', () {
      final p = ShellProgressParser();
      p.addChunk('45% done with nothing else here\n');
      // No corroborating signal (bar / phase / rate / eta / fraction) →
      // no box. The raw percent IS still tracked as the peak (that's
      // deliberate: the peak feeds the persisted summary regardless).
      expect(p.progress, isNull);
      expect(p.peakPercent, closeTo(45, 0.5));
    });

    test('fraction without phase or bar is not corroborated', () {
      final p = ShellProgressParser();
      p.addChunk('ratio 2/4 here\n');
      expect(p.progress, isNull);
    });

    test('phase-only line exposes a phase box with no percent', () {
      final p = ShellProgressParser();
      p.addChunk('==> Downloading https://example.com/pkg.tar.gz\n');
      final prog = p.progress;
      expect(prog, isNotNull);
      expect(prog!.phase, 'Downloading');
      expect(prog.hasPercent, isFalse);
      expect(prog.percent, isNull);
    });

    test('\\r-updated meter takes the newest percent, peak is tracked', () {
      final p = ShellProgressParser();
      p.addChunk(
        ' 10% [##                ] 10MB 1.0MB/s\r'
        ' 50% [##########          ] 50MB 1.0MB/s\r'
        ' 90% [##################  ] 90MB 1.0MB/s\r',
      );
      expect(p.progress!.percent, closeTo(90, 0.5));
      expect(p.peakPercent, closeTo(90, 0.5));
    });

    test('ssh-keygen spinner is ignored', () {
      final p = ShellProgressParser();
      p.addChunk('+...+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+.+\n');
      expect(p.progress, isNull);
    });

    test('unterminated trailing line is flushed on finish', () {
      final p = ShellProgressParser();
      p.addChunk(' 75% [###############     ]');
      expect(p.progress, isNull); // buffered, not yet a complete line
      p.finish();
      expect(p.progress!.percent, closeTo(75, 0.5));
    });

    test('cross-stream merge prefers non-null fields and sums signals', () {
      final merged = mergeShellProgress(
        const ShellProgress(
          percent: 45,
          hasPercent: true,
          signalCount: 1,
          lastLine: 'a',
        ),
        const ShellProgress(
          phase: 'Downloading',
          signalCount: 1,
          lastLine: 'b',
        ),
      );
      expect(merged, isNotNull);
      expect(merged!.percent, 45);
      expect(merged.phase, 'Downloading');
      expect(merged.signalCount, 2);
      expect(merged.lastLine, 'b');
    });

    test('merging with a null side returns the other side', () {
      const a = ShellProgress(percent: 12, hasPercent: true, signalCount: 1);
      expect(mergeShellProgress(null, a), same(a));
      expect(mergeShellProgress(a, null), same(a));
    });

    test('Installing does not match inside Uninstalling', () {
      final p = ShellProgressParser();
      p.addChunk('Uninstalling foo 1.0.0\n');
      final prog = p.progress;
      expect(prog, isNotNull);
      expect(prog!.phase, 'Uninstalling');
    });
  });
}
