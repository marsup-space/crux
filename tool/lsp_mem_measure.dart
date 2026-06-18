// Measure two concurrent dart language-server processes on an
// idle (no traffic) workspace. Reports min/avg/max RSS over 30s
// of sampling. Uses the system's `ps` to read RSS — works on both
// macOS and Linux.

import 'dart:io';

Future<int> _rssKb(int pid) async {
  final r = await Process.run('ps', ['-o', 'rss=', '-p', '$pid']);
  return int.tryParse(r.stdout.toString().trim()) ?? 0;
}

Future<void> main() async {
  final procs = <Process>[];
  for (var i = 0; i < 2; i++) {
    final p = await Process.start(
      '/opt/homebrew/bin/dart',
      ['language-server', '--lsp'],
      workingDirectory: '/tmp',
    );
    procs.add(p);
    // ignore: avoid_print
    print('Spawned dart language-server #${i + 1} pid=${p.pid}');
  }

  // Sample RSS every 2s for 30s.
  final samples = <List<int>>[[], []];
  for (var t = 0; t < 15; t++) {
    await Future.delayed(const Duration(seconds: 2));
    for (var i = 0; i < procs.length; i++) {
      samples[i].add(await _rssKb(procs[i].pid));
    }
  }

  // ignore: avoid_print
  print('\n=== RSS samples (KB) per server ===');
  for (var i = 0; i < 2; i++) {
    final s = samples[i];
    if (s.isEmpty) continue;
    final minS = s.reduce((a, b) => a < b ? a : b);
    final maxS = s.reduce((a, b) => a > b ? a : b);
    final lastS = s.last;
    final avgS = s.reduce((a, b) => a + b) ~/ s.length;
    // ignore: avoid_print
    print('Server #${i + 1}: '
        'min=${(minS / 1024).toStringAsFixed(0)}MB '
        'avg=${(avgS / 1024).toStringAsFixed(0)}MB '
        'max=${(maxS / 1024).toStringAsFixed(0)}MB '
        'last=${(lastS / 1024).toStringAsFixed(0)}MB');
  }

  // Sum to show what 2 instances cost together.
  final totals = <int>[];
  for (var t = 0; t < 15; t++) {
    totals.add(samples[0][t] + samples[1][t]);
  }
  final totalMin = totals.reduce((a, b) => a < b ? a : b);
  final totalAvg = totals.reduce((a, b) => a + b) ~/ totals.length;
  final totalMax = totals.reduce((a, b) => a > b ? a : b);
  // ignore: avoid_print
  print('\n=== 2 servers combined ===');
  // ignore: avoid_print
  print('Total RSS: min=${(totalMin / 1024).toStringAsFixed(0)}MB '
      'avg=${(totalAvg / 1024).toStringAsFixed(0)}MB '
      'max=${(totalMax / 1024).toStringAsFixed(0)}MB');

  for (final p in procs) {
    p.kill();
  }
  await Future.delayed(const Duration(milliseconds: 500));
  exit(0);
}
