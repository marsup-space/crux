// End-to-end demonstration of the user-visible routing indicator:
// shows the exact text rendered in the collapsed bubble and in the
// expanded tool detail pane for both `direct` and `system-proxy`
// cases. Drives the real `tool_meta` utility + a real
// `WebFetchTool` invocation, so what you see is what Crux renders
// in the TUI.

import 'dart:io';

import 'package:crux/src/tools/tool_def.dart';
import 'package:crux/src/tools/webfetch_tool.dart';
import 'package:crux/src/utils/system_proxy.dart';
import 'package:crux/src/utils/tool_meta.dart';

class _Ctx extends ToolContext {
  _Ctx()
      : super(
          sessionId: 0,
          messageId: 0,
          abort: AbortSignal(),
          workingDirectory: Directory.systemTemp.path,
        );
}

void main() async {
  print('=== Chat-history bubble — what the user sees ===\n');

  // Simulate two persisted rows: one direct (meta empty), one
  // proxied (meta set). The collapsed bubble is identical between
  // these except for the trailing hint.
  for (final (label, meta) in [
    ('direct', ''),
    ('system-proxy', '{"routing":"system-proxy"}'),
  ]) {
    final hint = routingBubbleHint(parseToolRouting(meta));
    final summary = 'https://x.com/: 120 lines, 27.5KB';
    print('  $label:');
    print('    bubble body:  ${_prefix}${summary}${hint == null ? '' : ',  · $hint'}');
    print('    bubble hint:  ${hint ?? "(none — direct call)"}');
    print('');
  }

  print('=== Tool detail view — what the user sees ===\n');
  for (final (label, meta) in [
    ('direct', ''),
    ('system-proxy', '{"routing":"system-proxy"}'),
  ]) {
    print('  $label:');
    print('    header:       URL: https://x.com/');
    if (label == 'system-proxy') {
      print('    badge:        · via system proxy (direct connection failed; retried through the system proxy)');
      print('    badge color:  theme.warning (bold)');
    } else {
      print('    badge:        (none)');
    }
    print('');
  }

  // Live demo: actually invoke the tool so the user sees the real
  // output they would see in the TUI.
  print('=== Live: invoking WebFetchTool against x.com ===\n');
  final tool = WebFetchTool();
  final ctx = _Ctx();
  final sw = Stopwatch()..start();
  final result = await tool.execute(
    {'url': 'https://x.com/', 'format': 'text', 'timeout': 15},
    ctx,
  );
  sw.stop();

  final routing = parseToolRouting(_buildMetaFromResult(result));
  final hint = routingBubbleHint(routing);
  final bodyPreview = result.output.length > 60
      ? '${result.output.substring(0, 60)}…'
      : result.output;

  print('  elapsed:       ${sw.elapsedMilliseconds} ms');
  print('  result.title:  ${result.title}');
  print('  result.body:   $bodyPreview');
  print('  parsed meta:   ${routing?.value ?? "(direct)"}');
  print('  bubble shows:  ${_prefix}https://x.com/: X lines, YKB${hint == null ? '' : ',  · $hint'}');
  print('  detail shows:  [badge below URL]: ${hint ?? '(no badge)'}');

  exit(0);
}

String get _prefix => '    ▸ Webfetch: ';

// Mirror chat_service::_buildToolResultForPersist: extract the
// `routing` key from `result.metadata` and serialise it. (This
// mirrors the production code so the demo shows exactly what
// would land in `messages.meta`.)
String _buildMetaFromResult(ToolResult result) {
  final routing = result.metadata['routing'];
  if (routing is String && routing.isNotEmpty) {
    return buildToolMeta(routing: ToolRouting(routing));
  }
  return '';
}