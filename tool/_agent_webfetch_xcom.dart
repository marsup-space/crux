// Driver that invokes the real WebFetchTool the same way the TUI
// does: through ToolRegistry → WebFetchTool.execute. The script
// also reports the system proxy detection so we can confirm the
// fallback path engaged.

import 'dart:io';

import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/utils/system_proxy.dart';

import 'package:drift/native.dart';
import 'package:crux/src/storage/storage.dart';

class _Ctx extends ToolContext {
  _Ctx(String cwd)
      : super(
          sessionId: 0,
          messageId: 0,
          abort: AbortSignal(),
          workingDirectory: cwd,
        );
}

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args.first : 'https://x.com/';
  stderr.writeln('=== invoking WebFetchTool via ToolRegistry ===');
  stderr.writeln('url: $url');
  stderr.writeln('proxy: ${SystemProxyDetector.detect()}');
  stderr.writeln('');

  final registry = ToolRegistry();
  registry.registerDefaults(
    FileReadTracker(),
    sessionStore: SessionStore(
      CruxDatabase.forTesting(NativeDatabase.memory()),
    ),
  );

  final tool = registry.lookup('webfetch');
  if (tool == null) {
    stderr.writeln('webfetch tool not registered!');
    exit(1);
  }

  final sw = Stopwatch()..start();
  final result = await tool.execute(
    {'url': url, 'format': 'text', 'timeout': 15},
    _Ctx(Directory.current.path),
  );
  sw.stop();

  stderr.writeln('Returned in ${sw.elapsedMilliseconds} ms');
  stderr.writeln('title:     ${result.title}');
  stderr.writeln('truncated: ${result.truncated}');
  stderr.writeln('metadata:  ${result.metadata}');
  stderr.writeln('output length: ${result.output.length} chars');
  stderr.writeln('');

  if (result.metadata['via'] == 'system-proxy') {
    stderr.writeln('✓ webfetch tool used the system proxy (direct connection failed)');
  }

  // Print first ~500 chars of the body for proof of life.
  stdout.writeln('--- first 500 chars of fetched body ---');
  stdout.writeln(result.output.substring(0, result.output.length.clamp(0, 500)));
  if (result.output.length > 500) {
    stdout.writeln('... (${result.output.length - 500} more chars)');
  }

  exit(0);
}
