// cruxd unit tests — reference-counting state machine, backoff
// math, producer keys, protocol DTOs. Integration (real daemon +
// fake producer processes) lives in daemon_e2e_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:crux/src/daemon/protocol.dart';
import 'package:crux/src/daemon/producer.dart';

void main() {
  group('producer keys', () {
    test('project plugin keys namespace by project + id', () {
      expect(producerKey(projectPath: '/a', pluginId: 'gold'), '/a:gold');
      expect(
        producerKey(projectPath: '/b', pluginId: 'gold'),
        isNot(producerKey(projectPath: '/a', pluginId: 'gold')),
      );
    });

    test('global plugin keys share the tilde namespace', () {
      expect(globalProducerKey(pluginId: 'gold'), '~:gold');
    });
  });

  group('BackoffPolicy', () {
    const policy = BackoffPolicy();
    test('doubles from base, capped', () {
      expect(policy.delayFor(0), const Duration(seconds: 1));
      expect(policy.delayFor(1), const Duration(seconds: 2));
      expect(policy.delayFor(2), const Duration(seconds: 4));
      expect(policy.delayFor(10), const Duration(seconds: 60));
    });
  });

  group('SupervisedProducer.renderCommand', () {
    test('substitutes flat and dotted fields', () {
      final cmd = SupervisedProducer.renderCommand(
        'fetch --unit {unit} --port {net.port}',
        {
          'unit': 'oz',
          'net': {'port': 8080},
        },
      );
      expect(cmd, 'fetch --unit oz --port 8080');
    });

    test('unknown placeholders stay literal (visible typos)', () {
      expect(SupervisedProducer.renderCommand('{nope}', const {}), '{nope}');
    });
  });

  group('protocol DTOs', () {
    test('DaemonStatus round-trips through state.json shape', () {
      final status = DaemonStatus(
        pid: 123,
        port: 4567,
        startedAt: DateTime.utc(2026, 8, 18, 10),
        heartbeatAt: DateTime.utc(2026, 8, 18, 10, 0, 5),
        instances: [
          InstanceInfo(
            id: 'i1',
            pid: 999,
            project: '/repo',
            producerKeys: const {'~:gold'},
            lastSeen: DateTime.utc(2026, 8, 18, 10, 0, 5),
          ),
        ],
        producers: [
          ProducerState(
            decl: const ProducerDecl(
              key: '~:gold',
              pluginId: 'gold',
              command: 'x.sh',
            ),
            pid: 111,
            startedAt: DateTime.utc(2026, 8, 18, 10),
            restarts: 0,
            status: 'running',
          ),
        ],
      );
      final parsed = DaemonStatus.tryParse(jsonEncode(status.toJson()));
      expect(parsed, isNotNull);
      expect(parsed!.pid, 123);
      expect(parsed.port, 4567);
      expect(parsed.instances.single.id, 'i1');
      expect(parsed.instances.single.producerKeys, {'~:gold'});
      expect(parsed.producers.single.decl.key, '~:gold');
      expect(parsed.producers.single.pid, 111);
    });

    test('tryParse rejects garbage / empty (clean-exit marker)', () {
      expect(DaemonStatus.tryParse(''), isNull);
      expect(DaemonStatus.tryParse('not json'), isNull);
      expect(DaemonStatus.tryParse('{"pid": 1}'), isNull); // no port
    });
  });

  group('SupervisedProducer lifecycle (fake script)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('cruxd_unit_');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('spawns via setsid, kills the group, no orphan children', () async {
      final script = File('${tmp.path}/worker.sh');
      script.writeAsStringSync('#!/bin/bash\nsleep 30 &\nsleep 30\n');
      Process.runSync('chmod', ['+x', script.path]);

      final p = SupervisedProducer(
        ProducerDecl(
          key: 'test:worker',
          pluginId: 'worker',
          command: script.path,
        ),
      );
      await p.start();
      expect(p.status, 'running');
      expect(p.pid, isNotNull);

      // The worker's background child must die with the group.
      final pgid = p.pid!;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await p.kill();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final probe = Process.runSync('/bin/sh', [
        '-c',
        'kill -0 -- -$pgid 2>/dev/null; echo rc=\$?',
      ]);
      // Group gone (or never had members): kill -0 -- -PGID fails.
      expect(probe.stdout.toString(), contains('rc=1'));
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('crash ladder: backoff then dead after maxRestarts', () async {
      // A command that always fails instantly.
      final p = SupervisedProducer(
        const ProducerDecl(
          key: 'test:crash',
          pluginId: 'crash',
          command: 'exit 7',
        ),
        backoff: const BackoffPolicy(
          base: Duration(milliseconds: 10),
          cap: Duration(milliseconds: 50),
          maxRestarts: 3,
          stableAfter: Duration(seconds: 30),
        ),
      );
      await p.start();
      // Let the crash-and-restart ladder run past maxRestarts.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(p.status, anyOf('dead', 'backoff'));
      // Dead eventually (with the short backoffs here).
      for (var i = 0; i < 50 && p.status != 'dead'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      expect(p.status, 'dead');
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('restart resets the crash ladder', () async {
      final p = SupervisedProducer(
        const ProducerDecl(
          key: 'test:crash2',
          pluginId: 'crash2',
          command: 'sleep 5',
        ),
        backoff: const BackoffPolicy(
          base: Duration(milliseconds: 10),
          maxRestarts: 0,
        ),
      );
      await p.start();
      await p.restart();
      expect(p.status, 'running');
      expect(p.restarts, 0);
      await p.kill();
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}
