import 'package:crux/src/diagram/diagram.dart';

/// Repro: LR chain wider than the box, TB chain arrow spacing, quoted
/// labels with literal \n escapes (the fog-shader graph shape).
Future<void> main() async {
  final lr = '''
flowchart LR
    A[终局: 官投市场清算<br>或泄漏值裁决] --> B[第1回合: 人设簿注册<br>+ 表达类 低压 搜档案]
    B --> C[第2-3回合: 判断/博弈类<br>关系网成型 开始投票]
    C --> D[第4回合: 考官干预<br>注入真信息 打破僵局]
    D --> E[第5回合: 高压类<br>忏悔 辩护 总清算]
''';
  final r1 = renderDiagram(
    lr,
    const DiagramRenderOptions(maxWidth: 76),
    language: 'mermaid',
  );
  print('==== LR chain, maxWidth 76 ====');
  print(r1.text);

  final tb = '''
flowchart TB
    A[第1回合: 大课堂<br>群答亮卷 搜档案] --> B[第2回合: 答辩会<br>纵向解剖一个目标]
    B --> C[第3回合: 拍卖会<br>用秘密换豁免 吐真货]
''';
  final r2 = renderDiagram(
    tb,
    const DiagramRenderOptions(maxWidth: 76),
    language: 'mermaid',
  );
  print('==== TB chain ====');
  print(r2.text);

  // Quoted labels + literal \n escapes + bare ids with dots — the exact
  // shape from the user's fog-shader screenshot.
  final quoted = '''
flowchart LR
    A["SpriteRenderer.color.a\\n(0=远 1=近)"] --> C
    B["FishingSkyDriver\\n(dayTime 三段混合)"] --> C
    C[_GameFogColor 全局雾色] --> D["SpriteAmbientLight.shader"]
    D --> E["lerp(fog, lit, color.a)"]
''';
  final r3 = renderDiagram(
    quoted,
    const DiagramRenderOptions(maxWidth: 96),
    language: 'mermaid',
  );
  print('==== quoted + \\n labels ====');
  print(r3.text);
}
