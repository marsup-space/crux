import 'package:crux/src/services/tool_execution_event.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:test/test.dart';

void main() {
  ToolExecutionCompleted event(String toolName, String command) =>
      ToolExecutionCompleted(
        toolName: toolName,
        input: {'command': command},
        result: const ToolResult(title: 'OK', output: ''),
        workspacePath: '/workspace',
      );

  group('commandContainsGit', () {
    test('recognizes a standalone Git command', () {
      expect(commandContainsGit('git add .'), isTrue);
      expect(commandContainsGit('git.exe commit -m "save"'), isTrue);
    });

    test('recognizes Git commands in command chains', () {
      expect(commandContainsGit('dart test && git status'), isTrue);
      expect(commandContainsGit('echo done; git restore README.md'), isTrue);
      expect(commandContainsGit('build | git add -p'), isTrue);
      expect(commandContainsGit('git commit -m "a && b"'), isTrue);
    });

    test('does not mistake quoted or embedded text for a Git command', () {
      expect(commandContainsGit('echo "git status"'), isFalse);
      expect(commandContainsGit("echo 'git add .'"), isFalse);
      expect(commandContainsGit('mygit status'), isFalse);
    });
  });

  group('ToolExecutionCompleted.isWorkspaceGitCommand', () {
    test('only accepts shell tools that ran a Git command', () {
      expect(event('cmd', 'git add .').isWorkspaceGitCommand, isTrue);
      expect(
        event('powershell', 'git switch main').isWorkspaceGitCommand,
        isTrue,
      );
      expect(event('bash', 'git status').isWorkspaceGitCommand, isTrue);
      expect(event('read', 'git status').isWorkspaceGitCommand, isFalse);
      expect(event('cmd', 'dart test').isWorkspaceGitCommand, isFalse);
    });
  });
}
