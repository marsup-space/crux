// End-to-end demonstration of WebFetchTool against x.com, using
// the same wrapper plumbing that the real TUI uses.
//
// Usage: dart run tool/_demo_xcom_e2e.dart

import 'dart:io';

import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/tools/webfetch_tool.dart';
import 'package:crux/src/utils/system_proxy.dart';

class _Ctx extends ToolContext {
  _Ctx()
      : super(
          sessionId: 0,
          messageId: 0,
          abort: AbortSignal(),
          workingDirectory: Directory.systemTemp.path,
        );
}

Future<void> main() async {
  final proxy = SystemProxyDetector.detect();
  stderr.writeln('System proxy detected: $proxy');
  stderr.writeln('Target URL: https://x.com/');
  stderr.writeln('');

  final tool = WebFetchTool(WebProviderRegistry());
  final ctx = _Ctx();
  final sw = Stopwatch()..start();
  final result = await tool.execute(
    {'url': 'https://x.com/', 'format': 'text', 'timeout': 15},
    ctx,
  );
  sw.stop();

  stderr.writeln('Returned in ${sw.elapsedMilliseconds} ms');
  stderr.writeln('title:    ${result.title}');
  stderr.writeln('truncated: ${result.truncated}');
  stderr.writeln('metadata: ${result.metadata}');
  stderr.writeln('');

  if (result.metadata['via'] == 'system-proxy') {
    stderr.writeln(
        '→ tool metadata reports the response was fetched via the system proxy.');
  }

  if (result.output.length > 500) {
    stderr.writeln('--- first 500 chars of output ---');
    stdout.writeln(result.output.substring(0, 500));
    stderr.writeln('--- ... (${result.output.length} chars total) ---');
  } else {
    stdout.writeln(result.output);
  }

  exit(0);
}
