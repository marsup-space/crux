import 'dart:io';

import 'package:crux/src/components/ui/highlighted_markdown_text.dart';
import 'package:nocterm/nocterm.dart' hide isNotEmpty;

/// Demo: render AI-response markdown containing mermaid/d2 fences through
/// the real HighlightedMarkdownText pipeline and dump the screen to
/// /tmp/diagram_screen.txt.
///
/// Run: `dart test tool/diagram_screen_demo.dart`
Future<void> main() async {
  final cases = <String, String>{
    '<br> multi-line labels (80)': '''
```mermaid
flowchart TB
    A[AI 的双面表演<br>公开装AI躲票 私密装人偷情报] --> B
    B[人装AI: 冷静 逻辑 无情绪<br>避免成为投票目标] --> C
    C[人装人: 互证身份 交换实锤<br>组建人类同盟] --> A
```
''',
    'flowchart (80)': '''
这是系统架构：

```mermaid
flowchart LR
    A[用户请求] --> B[网关]
    B --> C{鉴权}
    C -->|通过| D[服务]
    C -->|拒绝| B
```
''',
  };

  final buffer = StringBuffer();
  for (final entry in cases.entries) {
    await testNocterm(
      'demo ${entry.key}',
      (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 32,
            child: HighlightedMarkdownText(entry.value),
          ),
        );
        buffer.writeln('== ${entry.key} ==');
        buffer.writeln(tester.renderToString(showBorders: false));
        buffer.writeln();
      },
      size: const Size(80, 32),
    );
  }
  File('/tmp/diagram_screen.txt').writeAsStringSync(buffer.toString());
}
