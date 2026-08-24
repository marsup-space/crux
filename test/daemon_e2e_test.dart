// End-to-end cruxd acceptance (plan §7): real daemon + real producer
// script, sealed HOME. Verifies the full lifecycle contract:
//
//   register        → producer spawned (1 instance, 1 producer)
//   second register → REUSED (still 1 producer process)
//   deregister one  → still 1 (refcount 1)
//   deregister last → grace elapses → producer killed → daemon exits
//
// Run: dart test test/daemon_e2e_test.dart (macOS/Linux only)

@Timeout(Duration(seconds: 90))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory home;
  late Directory proj;

  setUp(() {
    home = Directory.systemTemp.createTempSync('cruxd_e2e_home_');
    proj = Directory.systemTemp.createTempSync('cruxd_e2e_proj_');
  });

  tearDown(() {
    // Belt & braces: kill anything the test left behind.
    Process.runSync('/bin/sh', [
      '-c',
      'pkill -f "cruxd_e2e" 2>/dev/null; '
      'for p in \$(pgrep -f gold-loop-standin 2>/dev/null); do '
      'kill -TERM -- -\$p 2>/dev/null; done; true',
    ]);
    for (final d in [home, proj]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('full lifecycle: register, reuse, grace, lights-off', () async {
    // 1. A stand-in producer: resident loop writing a heartbeat file.
    final producer = File('${home.path}/gold-loop-standin.sh')
      ..writeAsStringSync('#!/bin/bash\n'
          'while true; do\n'
          '  date -u +%Y-%m-%dT%H:%M:%SZ > "\$HOME/producer-beat"\n'
          '  sleep 1\n'
          'done\n');
    Process.runSync('chmod', ['+x', producer.path]);

    // 2. Spawn the daemon with the sealed HOME.
    final daemonProc = await Process.start(
      '/usr/bin/perl',
      [
        '-MPOSIX=setsid',
        '-e',
        'setsid() or die "setsid: \$!\\n"; exec @ARGV or die "exec: \$!\\n";',
        'dart',
        'run',
        '--enable-vm-service=0',
        'bin/cruxd.dart',
        'serve',
      ],
      workingDirectory: Directory.current.path,
      environment: {'HOME': home.path, 'PATH': Platform.environment['PATH']!},
    );
    addTearDown(() => daemonProc.kill());

    // 3. Wait for the state file (daemon up).
    final stateFile = File('${home.path}/.crux/daemon/state.json');
    var ok = false;
    for (var i = 0; i < 100 && !ok; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      try {
        final raw = stateFile.readAsStringSync();
        if (raw.trim().isNotEmpty && jsonDecode(raw) is Map) ok = true;
      } catch (_) {}
    }
    expect(ok, isTrue, reason: 'daemon never wrote state.json');
    final port = (jsonDecode(stateFile.readAsStringSync())
        as Map<String, dynamic>)['port'] as int;

    Future<Map<String, dynamic>> status() async {
      final c = HttpClient();
      try {
        final r = await c.getUrl(Uri.parse('http://127.0.0.1:$port/status'));
        final res = await r.close();
        return jsonDecode(await res.transform(utf8.decoder).join())
            as Map<String, dynamic>;
      } finally {
        c.close(force: true);
      }
    }

    Future<void> post(String path, Map<String, dynamic> body) async {
      final c = HttpClient();
      try {
        final r = await c.postUrl(Uri.parse('http://127.0.0.1:$port$path'));
        r.headers.contentType = ContentType.json;
        r.write(jsonEncode(body));
        final res = await r.close();
        await res.drain<void>();
      } finally {
        c.close(force: true);
      }
    }

    // 4. Instance A registers with one producer decl.
    await post('/register', {
      'instanceId': 'A',
      'pid': pid,
      'project': proj.path,
      'producers': [
        {
          'key': '~:gold',
          'pluginId': 'gold',
          'command': producer.path,
        }
      ],
    });
    await Future<void>.delayed(const Duration(seconds: 1));
    var s = await status();
    expect(s['producers'] as List, hasLength(1));
    final producerPid = (s['producers'][0] as Map)['pid'];
    expect(producerPid, isNotNull);
    // The producer is actually running and beating.
    expect(File('${home.path}/producer-beat').existsSync(), isTrue);

    // 5. Instance B registers the SAME key → no duplicate process.
    await post('/register', {
      'instanceId': 'B',
      'pid': pid,
      'project': proj.path,
      'producers': [
        {'key': '~:gold', 'pluginId': 'gold', 'command': producer.path}
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    s = await status();
    expect(s['producers'] as List, hasLength(1));
    expect((s['producers'][0] as Map)['pid'], producerPid);

    // 6. A leaves → refcount 1 → producer stays.
    await post('/deregister', {'instanceId': 'A'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    s = await status();
    expect(s['producers'] as List, hasLength(1));

    // 7. B leaves → grace (5s) → producer killed → daemon exits.
    final daemonPid = s['pid'];
    await post('/deregister', {'instanceId': 'B'});
    // grace 5s + kill window up to 3s + slack
    var daemonGone = false;
    var producerGone = false;
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final dp = Process.runSync(
        '/bin/sh',
        ['-c', 'kill -0 ${daemonPid} 2>/dev/null'],
      );
      daemonGone = dp.exitCode != 0;
      final pp = Process.runSync(
        '/bin/sh',
        ['-c', 'kill -0 -- -${producerPid} 2>/dev/null'],
      );
      producerGone = pp.exitCode != 0;
      if (daemonGone && producerGone) break;
    }
    expect(producerGone, isTrue,
        reason: 'producer process group survived lights-off');
    expect(daemonGone, isTrue, reason: 'daemon did not light off');
    // State file ends as the clean-exit marker (empty).
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(stateFile.readAsStringSync().trim(), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 80)));
}
