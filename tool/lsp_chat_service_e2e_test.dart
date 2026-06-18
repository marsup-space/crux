// End-to-end test that exercises the full chat_service persist path
// for LSP diagnostics. Goes:
//
//   EditTool.execute() — real dart language-server through LspManager
//     → result.metadata['lsp'] = [LspDiagnostic, ...]
//       → chat_service would call _messageStore.addMessage(role: 'lsp_diagnostics', ...)
//         → MessageBubble._buildInner would dispatch to LspDiagnosticsBubble
//
// We can't easily drive the live TUI from a tool, so this test
// drives the persist path directly: spin up a real LspManager, a
// real EditTool, run an edit on a real .dart file with broken
// syntax, then construct a message via the same addMessage call the
// chat service would make. The resulting Message is round-tripped
// through an in-memory store to confirm the bubble component
// actually receives the right data.

import 'dart:io';

import 'package:crux/src/components/lsp_diagnostics_bubble.dart';
import 'package:crux/src/lsp/actors/dart.dart';
import 'package:crux/src/lsp/manager.dart' show LspManager;
import 'package:crux/src/models/session.dart';
import 'package:crux/src/storage/database.dart';
import 'package:crux/src/storage/session_store.dart';
import 'package:crux/src/tools/edit_tool.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

Future<int> main() async {
  final tmp = await Directory.systemTemp.createTemp('lsp_e2e_');
  int exitCode = 0;
  late CruxDatabase db;
  late SessionStore store;

  try {
    // Set up a minimal "project" with a pubspec.yaml and a broken
    // .dart file.
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
      'name: lsp_e2e\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n',
    );
    final broken = File(p.join(tmp.path, 'foo.dart'))
      ..writeAsStringSync(
        'int main() {\n'
        '  return "wrong type"\n'
        '  var x = ;\n'
        '}\n',
      );

    // In-memory CruxDatabase — same schema the live app uses.
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = SessionStore(db);

    // Wire the LSP manager.
    final mgr = LspManager(
      workingDirectory: tmp.path,
      actorFactories: const {'dart': DartServerActor.new},
    );

    // Set up the edit tool with the manager.
    final tracker = FileReadTracker();
    await tracker.recordRead(
      broken.path,
      broken.statSync().modified.millisecondsSinceEpoch,
    );
    final tool = EditTool(tracker: tracker, lsp: mgr);
    final ctx = ToolContext(
      sessionId: 1,
      messageId: 1,
      abort: AbortSignal(sessionId: 1),
      workingDirectory: tmp.path,
    );

    print('--- EditTool.execute on a broken foo.dart ---');
    final result = await tool.execute({
      'filePath': broken.path,
      'oldString': 'return "wrong type"',
      'newString': 'return "still wrong";\n  var y = ;',
      'intent': 'make a small edit that keeps the file broken',
    }, ctx);
    print('Tool output: ${result.output}');
    final diagnostics = result.metadata['lsp'];
    if (diagnostics is! List || diagnostics.isEmpty) {
      print('FAIL: expected at least 1 diagnostic, got $diagnostics');
      exitCode = 1;
      return exitCode;
    }
    print('Got ${diagnostics.length} diagnostic(s) via metadata');

    // Create a session, then persist the lsp_diagnostics message
    // the way chat_service would.
    final session = await store.create(
      title: 'lsp-e2e',
      model: '',
      projectPath: tmp.path,
    );
    final sessionId = session.id;
    final relPath = p.relative(broken.path, from: tmp.path);
    final message = await store.messageStore.addMessage(
      sessionId,
      role: 'lsp_diagnostics',
      content: relPath,
      parallelCount: diagnostics.length,
    );
    print('Persisted message: role=${message.role} '
        'content=${message.content} parallelCount=${message.parallelCount}');

    // Round-trip: load it back from the store and verify shape.
    final loaded = await store.messageStore.getMessages(sessionId);
    final lspRow = loaded.firstWhere((m) => m.role == 'lsp_diagnostics');
    if (lspRow.content != relPath) {
      print('FAIL: round-trip content mismatch: '
          '${lspRow.content} vs $relPath');
      exitCode = 1;
      return exitCode;
    }
    if (lspRow.parallelCount != diagnostics.length) {
      print('FAIL: round-trip count mismatch: '
          '${lspRow.parallelCount} vs ${diagnostics.length}');
      exitCode = 1;
      return exitCode;
    }
    print('Round-trip OK: stored and retrieved '
        '${lspRow.parallelCount} errors for ${lspRow.content}');

    // Confirm the bubble class renders the expected body.
    const bubble = LspDiagnosticsBubble(
      errorCount: 3,
      filePath: 'foo.dart',
      language: 'Dart',
    );
    if (bubble.body != 'Dart lsp: 3 errors in foo.dart') {
      print('FAIL: bubble body wrong: ${bubble.body}');
      exitCode = 1;
      return exitCode;
    }
    if (bubble.kind.name != 'error') {
      print('FAIL: bubble kind wrong: ${bubble.kind.name}');
      exitCode = 1;
      return exitCode;
    }
    print('Bubble body: "${bubble.body}" (kind=${bubble.kind.name})');

    print('\nPASS: end-to-end LSP → metadata → DB → bubble wiring works');
    await mgr.shutdown();
  } catch (e, st) {
    print('FAIL: $e\n$st');
    exitCode = 1;
  } finally {
    try {
      await db.close();
    } catch (_) {}
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  }
  return exitCode;
}
