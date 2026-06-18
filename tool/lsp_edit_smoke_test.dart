// End-to-end smoke test: edit a real .dart file with the real
// edit tool, verify the result metadata carries LSP diagnostics
// (which the chat service uses to render an LspDiagnosticsBubble
// in the chat history). The tool's textual output is intentionally
// clean — only the diff line, no LSP mention.

import 'dart:io';

import 'package:crux/src/lsp/actors/dart.dart';
import 'package:crux/src/lsp/manager.dart' show LspManager;
import 'package:crux/src/lsp/protocol.dart';
import 'package:crux/src/tools/edit_tool.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:path/path.dart' as p;

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('lsp_edit_smoke_');
  try {
    File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync(
      'name: smoke\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n',
    );
    final file = File(p.join(tmp.path, 'foo.dart'))
      ..writeAsStringSync('int main() {\n  return 42;\n}\n');

    final tracker = FileReadTracker();
    final mtime = file.statSync().modified.millisecondsSinceEpoch;
    await tracker.recordRead(file.path, mtime);

    final manager = await LspManager.create(
      workingDirectory: tmp.path,
      actorFactories: {'dart': DartServerActor.new},
    );

    final tool = EditTool(tracker: tracker, lsp: manager);
    final ctx = ToolContext(
      sessionId: 1,
      messageId: 1,
      abort: AbortSignal(sessionId: 1),
      workingDirectory: tmp.path,
    );

    // Edit the file to introduce a deliberate type error.
    final result = await tool.execute({
      'filePath': file.path,
      'oldString': 'return 42;',
      'newString': 'return "wrong type";',
      'intent': 'smoke test',
    }, ctx);

    print('--- edit tool output ---');
    print(result.output);
    print('--- end ---\n');

    // The output text should be just the diff line.
    if (!result.output.contains('Edit applied')) {
      print('FAIL: tool output missing Edit applied');
      exit(1);
    }
    if (result.output.contains('LSP')) {
      print('FAIL: tool output should be clean (no LSP mention)');
      exit(1);
    }

    // The metadata should carry the diagnostics for the chat
    // service to render an LspDiagnosticsBubble.
    final diagnostics = result.metadata['lsp'];
    if (diagnostics is! List || diagnostics.isEmpty) {
      print('FAIL: metadata missing LSP diagnostics');
      exit(1);
    }
    if (diagnostics.first is! LspDiagnostic) {
      print('FAIL: metadata diagnostic is wrong type: '
          '${diagnostics.first.runtimeType}');
      exit(1);
    }
    print('Metadata carries ${diagnostics.length} LSP diagnostic(s):');
    for (final d in diagnostics.cast<LspDiagnostic>()) {
      print('  L${d.range.start.line + 1}:'
          '${d.range.start.character + 1} ${d.severity?.name ?? '?'} '
          '${d.message}');
    }
    print('PASS: edit tool surfaces LSP diagnostics via metadata');

    await manager.shutdown();
  } finally {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  }
}
