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
    'state diagram (80)': '''
会话状态机：

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Running: start
    Running --> Idle: stop
    Running --> [*]: complete
```
''',
    'd2 (80)': '''
数据流：

```d2
user: 用户
server: Web 服务器
db: 数据库

user -> server: HTTP 请求
server -> db: SQL 查询
db -> server: 结果
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
