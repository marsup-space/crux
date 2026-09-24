// Integration tests for utils/process_group_kill.dart.
//
// The LSP actor's kill sites rely on two properties that only hold
// for processes spawned through the setsid trampoline
// (utils/setsid_spawn.dart): pid == pgid, and a group kill reaching
// forked grandchildren. These tests spawn REAL processes to prove
// both, using a shell whose command forks a long `sleep` child.

import 'dart:io';

import 'package:crux/src/utils/process_group_kill.dart';
import 'package:crux/src/utils/setsid_spawn.dart';
import 'package:test/test.dart';

void main() {
  if (Platform.isWindows) {
    // The setsid trampoline is Unix-only; nothing to test here.
    return;
  }

  /// pgid of [pid] via `ps`, or null when the process is gone.
  int? pgidOf(int pid) {
    final r = Process.runSync('ps', ['-o', 'pgid=', '-p', '$pid']);
    if (r.exitCode != 0) return null;
    final v = int.tryParse(r.stdout.toString().trim());
    return v == null || v <= 0 ? null : v;
  }

  /// Whether any process still lives in the group [pgid].
  bool groupAlive(int pgid) {
    final r = Process.runSync('ps', ['-A', '-o', 'pgid=']);
    if (r.exitCode != 0) return false;
    return r.stdout
        .toString()
        .split('\n')
        .any((line) => int.tryParse(line.trim()) == pgid);
  }

  /// Settle the trampoline: `startWithSetsid` returns the moment the
  /// Perl wrapper is forked, but `setsid()` only runs once the Perl
  /// interpreter has booted (~10-20ms). Production kill sites never
  /// fire inside that window; tests wait it out explicitly.
  Future<void> settleTrampoline() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  test('setsid-spawned server is its own process group leader', () async {
    final server = await startWithSetsid([
      '/bin/sh',
      '-c',
      'sleep 3027 & wait',
    ]);
    addTearDown(() => killProcessGroup(server));
    await settleTrampoline();

    // The trampoline has already exec'd the shell, so the pid we
    // hold IS the shell's — and setsid made it the group leader.
    expect(pgidOf(server.pid), server.pid);
  });

  test('killProcessGroup reaps the server and its forked child', () async {
    // `sleep ... & wait`: the shell forks a child that would happily
    // outlive the shell if teardown killed only the shell itself.
    final server = await startWithSetsid([
      '/bin/sh',
      '-c',
      'sleep 3027 & wait',
    ]);
    await settleTrampoline();
    expect(
      pgidOf(server.pid),
      server.pid,
      reason: 'setsid must make the server its own group leader',
    );

    killProcessGroup(server);

    // The group TERM reaches both the shell and the sleep; give the
    // signals a beat to land before asserting the group is empty.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(pgidOf(server.pid), isNull, reason: 'server itself must be dead');
    expect(
      groupAlive(server.pid),
      isFalse,
      reason: 'forked children must die with the server',
    );
  });
}
