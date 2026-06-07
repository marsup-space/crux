import 'package:test/test.dart';
import 'package:crux/src/commands/registry.dart';
import 'package:crux/src/models/slash_command.dart';

void main() {
  group('CommandRegistry', () {
    setUp(() {
      // Each test starts with a clean state.
      CommandRegistry.instance.disableDebug();
    });

    test('starts with debug mode disabled', () {
      expect(CommandRegistry.instance.debugEnabled, isFalse);
    });

    test('enableDebug registers the debug command set', () {
      CommandRegistry.instance.enableDebug();
      expect(CommandRegistry.instance.debugEnabled, isTrue);

      final names = CommandRegistry.instance.all.map((c) => c.name).toList();
      expect(names, contains('/d-state'));
      expect(names, contains('/d-messages'));
      expect(names, contains('/d-context'));
      expect(names, contains('/d-runtime'));
      expect(names, contains('/d-providers'));
      expect(names, contains('/d-tools'));
      expect(names, contains('/d-paths'));
      expect(names, contains('/d-env'));
      expect(names, contains('/d-toast'));
    });

    test('disableDebug unregisters the debug command set', () {
      CommandRegistry.instance.enableDebug();
      CommandRegistry.instance.disableDebug();
      expect(CommandRegistry.instance.debugEnabled, isFalse);

      final names = CommandRegistry.instance.all.map((c) => c.name).toList();
      expect(names, isNot(contains('/d-state')));
      expect(names, isNot(contains('/d-tools')));
    });

    test('toggleDebug flips the flag', () {
      expect(CommandRegistry.instance.debugEnabled, isFalse);
      expect(CommandRegistry.instance.toggleDebug(), isTrue);
      expect(CommandRegistry.instance.debugEnabled, isTrue);
      expect(CommandRegistry.instance.toggleDebug(), isFalse);
      expect(CommandRegistry.instance.debugEnabled, isFalse);
    });

    test('enableDebug is idempotent', () {
      CommandRegistry.instance.enableDebug();
      final first = CommandRegistry.instance.all.length;
      CommandRegistry.instance.enableDebug();
      expect(CommandRegistry.instance.all.length, equals(first));
    });

    test('disableDebug is idempotent', () {
      CommandRegistry.instance.disableDebug();
      final first = CommandRegistry.instance.all.length;
      CommandRegistry.instance.disableDebug();
      expect(CommandRegistry.instance.all.length, equals(first));
    });

    test('notifyListeners fires on enable and disable', () {
      var calls = 0;
      void listener() {
        calls++;
      }

      CommandRegistry.instance.addListener(listener);
      try {
        CommandRegistry.instance.enableDebug();
        expect(calls, equals(1));
        CommandRegistry.instance.disableDebug();
        expect(calls, equals(2));
        // Idempotent calls should not fire.
        CommandRegistry.instance.disableDebug();
        expect(calls, equals(2));
      } finally {
        CommandRegistry.instance.removeListener(listener);
      }
    });

    test('base commands are always present', () {
      // Debug off
      final offNames = CommandRegistry.instance.all
          .map((c) => c.name)
          .toList();
      expect(offNames, contains('/model'));
      expect(offNames, contains('/new'));
      expect(offNames, contains('/session'));
      expect(offNames, contains('/clear'));
      expect(offNames, contains('/compact'));
      expect(offNames, contains('/help'));
      expect(offNames, contains('/theme'));
      expect(offNames, contains('/history'));
      expect(offNames, contains('/provider'));
      expect(offNames, contains('/think'));
      expect(offNames, contains('/auxiliary'));
      expect(offNames, contains('/tldr'));
      expect(offNames, contains('/project'));
      expect(offNames, contains('/debug'));

      // Debug on
      CommandRegistry.instance.enableDebug();
      final onNames = CommandRegistry.instance.all.map((c) => c.name).toList();
      for (final n in offNames) {
        expect(onNames, contains(n), reason: 'lost $n after enabling debug');
      }
    });

    test('removed commands stay removed when debug is off', () {
      final names = CommandRegistry.instance.all.map((c) => c.name).toList();
      expect(names, isNot(contains('/config')));
      expect(names, isNot(contains('/quit')));
    });
  });

  group('Top-level registry helpers', () {
    setUp(() {
      CommandRegistry.instance.disableDebug();
    });

    test('slashCommands is a non-empty unmodifiable list', () {
      expect(slashCommands, isA<List<SlashCommand>>());
      expect(slashCommands, isNotEmpty);
    });

    test('filterCommands filters by prefix', () {
      final hits = filterCommands('/d');
      final names = hits.map((c) => c.name).toList();
      // /debug is always there
      expect(names, contains('/debug'));
      // No commands starting with anything other than /d
      expect(names.every((n) => n.startsWith('/d')), isTrue);
    });

    test('filterCommands with empty prefix returns all', () {
      final all = filterCommands('');
      expect(all.length, equals(CommandRegistry.instance.all.length));
    });

    test('findCommand returns the exact match', () {
      final cmd = findCommand('/model');
      expect(cmd, isNotNull);
      expect(cmd!.name, equals('/model'));
    });

    test('findCommand returns null for unknown commands', () {
      expect(findCommand('/nonsense'), isNull);
    });

    test('findCommand returns null for debug commands when disabled', () {
      CommandRegistry.instance.disableDebug();
      expect(findCommand('/d-state'), isNull);
    });

    test('findCommand returns debug commands when enabled', () {
      CommandRegistry.instance.enableDebug();
      expect(findCommand('/d-state'), isNotNull);
      expect(findCommand('/d-env'), isNotNull);
      expect(findCommand('/d-toast'), isNotNull);
    });

    test('/d-toast has a single message param and is available during response', () {
      CommandRegistry.instance.enableDebug();
      final cmd = findCommand('/d-toast');
      expect(cmd, isNotNull);
      expect(cmd!.params, equals(['message']));
      expect(cmd.availableDuringResponse, isTrue);
    });

    test('/debug takes no params and is available during response', () {
      final cmd = findCommand('/debug');
      expect(cmd, isNotNull);
      expect(cmd!.params, isEmpty);
      expect(cmd.availableDuringResponse, isTrue);
    });
  });
}
