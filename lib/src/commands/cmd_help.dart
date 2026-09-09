import '../components/ui/toast.dart';
import '../i18n/app_locale.dart';
import '../i18n/strings.dart';
import 'command_executor.dart';
import 'registry.dart';

/// Role used for local, UI-only notices written into the chat
/// history. Deliberately NOT `system`: `wire_format.dart` forwards
/// every `system` row to the LLM, so a help sheet persisted as
/// `system` would ride along on every subsequent turn and burn
/// context. `info` has no case in the wire-format switch (nor in
/// the compaction chat-log builder), so it renders in the chat log
/// as a "Crux:" bubble but never reaches the model.
const String localInfoRole = 'info';

/// Builds the `/help` sheet.
///
/// The command list is generated from [CommandRegistry.instance.all]
/// at call time — never hard-coded — so this output cannot drift
/// from the registry the way the old static docs did (the P0
/// "three sources of truth" bug). When debug mode is enabled the
/// `/d-*` set is included automatically via the registry's `all`
/// getter.
String buildHelpText([Strings? strings]) {
  final s = strings ?? const Strings(AppLocale.en);
  final buf = StringBuffer()
    ..writeln('**Crux Help · 帮助**')
    ..writeln()
    ..writeln('**Getting started · 上手**')
    ..writeln()
    ..writeln(
      'Connect a model provider first: `/provider <name> <key>`, '
      'then type your question and press Enter.',
    )
    ..writeln('先用 `/provider <name> <key>` 接入模型，然后直接输入问题、回车即可。')
    ..writeln()
    ..writeln('**Commands · 命令**')
    ..writeln();
  for (final cmd in CommandRegistry.instance.all) {
    final aliases = cmd.aliases.isEmpty ? '' : ' (${cmd.aliases.join(', ')})';
    buf.writeln('- `${cmd.name}`$aliases — ${s.t(cmd.description)}');
  }
  buf
    ..writeln()
    ..writeln('**Shortcuts & input · 快捷键与输入**')
    ..writeln()
    ..writeln('- `Tab` — autocomplete commands, params, mentions · 补全命令、参数与引用')
    ..writeln('- `@` — attach project files to the prompt · 在输入中引用项目文件')
    ..writeln(r'- `$` — invoke a skill · 调用技能')
    ..writeln(
      '- model button — click the flashing model name to interrupt the response · 点击闪烁的模型按钮中断回复',
    )
    ..writeln(
      '- `Ctrl+C` — exit Crux; double-press when a session is running '
      '· 退出 Crux；有会话运行时需快速双击',
    )
    ..writeln()
    ..writeln(
      'Type `/help` anytime to see this sheet again · 随时输入 `/help` 再次查看。',
    );
  return buf.toString().trimRight();
}

/// `/help` — print the help sheet into the chat history.
///
/// Preferred path: the host wires [CommandContext.appendLocalMessage],
/// which persists the sheet AND makes it visible immediately. When
/// the hook is absent (legacy hosts, unit tests) the sheet is
/// persisted directly through the message store so it lands in the
/// session history and surfaces on the next load; a toast tells the
/// user where it went.
Future<void> executeHelp(CommandContext ctx) async {
  final text = buildHelpText(ctx.strings);
  final post = ctx.appendLocalMessage;
  if (post != null) {
    await post(text);
    return;
  }
  final sessionId = ctx.currentSessionId;
  if (sessionId == null) {
    ctx.showToast(ctx.strings.t('toast.noSession'), mode: ToastMode.error);
    return;
  }
  await ctx.store.messageStore.addMessage(
    sessionId,
    role: localInfoRole,
    content: text,
  );
  ctx.refresh();
  ctx.showToast(ctx.strings.t('toast.helpWritten'), mode: ToastMode.status);
}
