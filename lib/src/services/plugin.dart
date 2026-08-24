// Spec-driven plugins (renamed and extended from "spec widgets").
//
// A "plugin" is a small TOML file declaring how one live surface renders:
// where its status comes from, how the status text is computed, which
// actions it exposes, and WHERE it shows — the side panel ("sidebar"),
// the home dashboard grid ("home"), or both. Any session — any agent,
// any human — can drop a spec file into a scanned directory and every
// Crux session picks it up on the next scan (~2 s). No rebuild, no
// restart: the filesystem is the bus.
//
// Scanned directories (in precedence order; later entries only fill
// ids not seen yet):
//
//   <project>/.crux/plugins/    the canonical location (new)
//   <project>/.crux/widgets/    legacy (pre-rename) project specs
//   ~/.crux/plugins/            global plugins, available in EVERY project
//   ~/.crux/widgets/            legacy global specs
//
// A plugin's two jobs:
//   1. STATUS — answer, at a glance, a question the user actually asks
//      ("is it still running?", "what's the price now?", "did the last
//      build pass?").
//   2. ACTIONS — turn something the user does repeatedly into one click
//      (start/stop/reload a service, run tests, submit a prompt).
//
// Schema (see .crux/plugins/dev-harness.toml for a live example):
//
//   id = "dev-harness"                  # must match the file name
//   placement = "sidebar"               # sidebar | home | both
//   title = "crux dev"                  # box title, defaults to id
//   label = "⟳ crux dev · {state}"      # label template (see below)
//   refresh_ms = 2000                   # status poll interval
//
//   [status]
//   path = ".dart_tool/crux_dev.json"   # status source (relative to the
//   #                                   PROJECT root, even for global
//   #                                   plugins in ~/.crux/...)
//   heartbeat_field = "heartbeatAt"     # optional liveness field
//   stale_after_seconds = 15            # heartbeat older ⇒ stale
//
//   [[status.state_rules]]              # top-down, first hit wins
//   when = { field = "lastReload.result", equals = "succeeded" }
//   text = "✓ {lastReload.at@HH:MM}"
//   color = "normal"                    # normal|success|warning|error|dim
//
//   fallback_alive_text = "●"           # alive, no rule matched
//   fallback_stale_text = "stale"       # heartbeat expired
//   fallback_absent_text = "not running"# status file missing
//
//   [[actions]]                         # become clickable buttons
//   label = "reload"
//   url = "http://127.0.0.1:{controlPort}/reload"   # kind = http
//
// Template syntax (labels, rule texts, action URLs/commands/prompts):
//   {state}             → the computed state text
//   {field}             → dotted path into the status JSON
//   {field@HH:MM}       → ISO-8601 timestamp formatted as local HH:MM
//
// Unknown/missing fields render as the literal placeholder (visible =
// debuggable; a spec that references a wrong field name shows it).

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

/// Rule-matched state text color hints. The renderer maps these onto
/// theme colors; unknown values fall back to the default.
enum PluginStateColor { normal, success, warning, error, dim }

/// One `when`/`text` state rule.
class PluginStateRule {
  final String field;
  final String equals;
  final String text;
  final PluginStateColor color;

  const PluginStateRule({
    required this.field,
    required this.equals,
    required this.text,
    this.color = PluginStateColor.normal,
  });
}

/// How an action's button renders. The spec picks the affordance;
/// the semantics (kind, liveness gating) are orthogonal to it.
enum PluginActionStyle {
  /// Hover-morph MultiButton segment — the historical compact
  /// chrome: label at rest, `seg | seg | …` on hover. Default.
  segment,

  /// Always-visible standalone [Button] — discovered without hover,
  /// better for a monitor box whose label列 is content, not chrome.
  button,
}

/// What an action does when invoked.
enum PluginActionKind {
  /// HTTP POST to the action's URL template (requires
  /// [PluginAction.url]). Rendered only while the plugin is alive.
  http,

  /// Launch a local command in a terminal (requires
  /// [PluginAction.command]). Rendered only while the plugin is NOT
  /// alive — it's the "start it" affordance for a dead service.
  launch,

  /// Submit [PluginAction.prompt] as a user message to the current chat
  /// session — the "quick action". Rendered regardless of liveness.
  prompt,

  /// Run [PluginAction.command] in the project root and report the
  /// result — the user-runnable quick action: run tests, lint, a
  /// release script. Runs to completion; tail output surfaces as a
  /// toast / tool result. Rendered regardless of liveness.
  shell,

  /// Open an in-process Crux screen (a fullpane) identified by
  /// [PluginAction.screen] (e.g. `notes`). Pure UI. Rendered
  /// regardless of liveness.
  screen,
}

/// One action button (`reload`, `close`, `start`, `review`, ...).
class PluginAction {
  final String label;

  /// URL template for [PluginActionKind.http] actions.
  final String? url;

  final PluginActionKind kind;

  /// Shell command for [PluginActionKind.launch] and
  /// [PluginActionKind.shell] actions. `launch` runs it in a fresh
  /// terminal window; `shell` runs it in the project root with output
  /// captured.
  final String? command;

  /// Message template for [PluginActionKind.prompt] actions.
  final String? prompt;

  /// Screen identifier for [PluginActionKind.screen] actions.
  final String? screen;

  /// Whether firing this action records an event into the session
  /// context. Defaults to `true`; pure-UI actions can set
  /// `record = false`.
  final bool record;

  /// Button affordance for this action. Defaults to a hover-morph
  /// MultiButton segment ([PluginActionStyle.segment]) — the compact
  /// historical chrome. `style = "button"` in the TOML renders an
  /// always-visible [Button] instead.
  final PluginActionStyle style;

  const PluginAction({
    required this.label,
    this.url,
    this.kind = PluginActionKind.http,
    this.command,
    this.prompt,
    this.screen,
    this.record = true,
    this.style = PluginActionStyle.segment,
  });
}

/// Where a plugin renders:
/// - [sidebar]: the right-hand side panel (the historical location —
///   the default, so pre-`placement` specs keep working unchanged).
/// - [home]: a box in the home dashboard grid.
/// - [both]: sidebar row AND home box.
enum PluginPlacement { sidebar, home, both }

/// `[producer]` table: a command cruxd keeps running while any
/// instance renders the plugin (reference-counted, crash-restarted,
/// group-killed on last-consumer exit — see lib/src/daemon/).
class PluginProducer {
  /// Command template (bash -c), `{field}` placeholders resolved
  /// against the plugin's OWN status JSON at spawn time.
  final String command;

  /// Working directory; null = the declaring instance's project root.
  final String? cwd;

  const PluginProducer({required this.command, this.cwd});
}

/// A parsed plugin spec.
class Plugin {
  final String id;

  /// Box title, rendered on the border. May be an i18n catalog key
  /// (e.g. `chat.notes.title`) — the host resolves it via `Strings.t`.
  final String title;

  /// Where this plugin renders (sidebar / home / both). Defaults to
  /// [PluginPlacement.sidebar] — the pre-rename behaviour, so legacy
  /// specs parse identically.
  final PluginPlacement placement;

  final String labelTemplate;
  final Duration refresh;
  final String statusPath;
  final String? heartbeatField;
  final Duration staleAfter;
  final List<PluginStateRule> stateRules;
  final String aliveText;
  final String staleText;
  final String absentText;

  /// Optional file the consumer TOUCHES on each poll tick (mtime
  /// bump, no content). Pair it with a launchd `WatchPaths` agent:
  /// the agent fires ONCE when the file changes (oneshot, exits
  /// after fetching) and `ThrottleInterval` merges bursts from
  /// multiple Crux instances. Zero consumers ⇒ zero fetches, zero
  /// daemons — data collection becomes consumer-driven. The path
  /// resolves against the project root like [statusPath] (absolute
  /// paths win, which is what a global plugin wants).
  final String? touchOnPoll;

  /// The plugin's producer declaration (`[producer]` in the TOML):
  /// a resident command cruxd keeps running WHILE any instance
  /// renders this plugin. Null for plugins with no producer.
  final PluginProducer? producer;

  /// The plugin's action buttons. See [PluginAction].
  final List<PluginAction> actions;

  /// True when the spec file lives under a global root (`~/.crux/...`)
  /// rather than the project's `.crux/`. Global plugins resolve their
  /// status file and shell/launch commands against the *project* root,
  /// so one global spec monitors the same relative path in every
  /// project. Set by the registry from the file's location, never from
  /// the TOML.
  final bool isGlobal;

  const Plugin({
    required this.id,
    required this.labelTemplate,
    required this.refresh,
    required this.statusPath,
    String? title,
    this.placement = PluginPlacement.sidebar,
    this.isGlobal = false,
    this.heartbeatField,
    this.staleAfter = const Duration(seconds: 15),
    this.stateRules = const [],
    this.aliveText = '●',
    this.staleText = 'stale',
    this.absentText = 'not running',
    this.actions = const [],
    this.touchOnPoll,
    this.producer,
  }) : title = title ?? id;

  bool get showsOnSidebar =>
      placement == PluginPlacement.sidebar ||
      placement == PluginPlacement.both;

  bool get showsOnHome =>
      placement == PluginPlacement.home ||
      placement == PluginPlacement.both;

  /// Non-empty display lines in [labelTemplate] — statically known at
  /// parse time, so the home grid can size its box to the spec
  /// (label lines + headroom for todo/action rows).
  static int labelLineCount(String template) => template
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .length;

  /// Parse a spec file. Returns null when the file is unreadable or
  /// malformed, or the `id` doesn't match the file name — the caller
  /// (registry/tool) skips such files and surfaces a warning.
  static Plugin? parse(File file, {bool isGlobal = false}) {
    final String content;
    try {
      content = file.readAsStringSync();
    } catch (_) {
      return null;
    }
    final Map<String, dynamic> map;
    try {
      map = TomlDocument.parse(content).toMap();
    } catch (_) {
      return null;
    }
    final id = map['id'] as String?;
    final fileName = p.basenameWithoutExtension(file.path);
    if (id == null || id != fileName) return null;

    final label = map['label'] as String?;
    if (label == null || label.trim().isEmpty) return null;

    final status = map['status'];
    if (status is! Map) return null;
    final statusPath = status['path'] as String?;
    if (statusPath == null || statusPath.trim().isEmpty) return null;

    final placement = switch (map['placement'] as String?) {
      'home' => PluginPlacement.home,
      'both' => PluginPlacement.both,
      _ => PluginPlacement.sidebar,
    };

    final rules = <PluginStateRule>[];
    final rawRules = status['state_rules'];
    if (rawRules is List) {
      for (final raw in rawRules) {
        if (raw is! Map) continue;
        final when = raw['when'];
        if (when is! Map) continue;
        final field = when['field'] as String?;
        final equals = when['equals'] as String?;
        final text = raw['text'] as String?;
        if (field == null || equals == null || text == null) continue;
        rules.add(
          PluginStateRule(
            field: field,
            equals: equals,
            text: text,
            color: _parseColor(raw['color'] as String?),
          ),
        );
      }
    }

    final actions = <PluginAction>[];
    final rawActions = map['actions'];
    if (rawActions is List) {
      for (final raw in rawActions) {
        if (raw is! Map) continue;
        final aLabel = raw['label'] as String?;
        if (aLabel == null) continue;
        final kind = switch (raw['kind'] as String?) {
          'launch' => PluginActionKind.launch,
          'prompt' => PluginActionKind.prompt,
          'shell' => PluginActionKind.shell,
          'screen' => PluginActionKind.screen,
          _ => PluginActionKind.http,
        };
        final url = raw['url'] as String?;
        final command = raw['command'] as String?;
        final prompt = raw['prompt'] as String?;
        final screen = raw['screen'] as String?;
        final record = raw['record'] as bool? ?? true;
        final style = switch (raw['style'] as String?) {
          'button' => PluginActionStyle.button,
          _ => PluginActionStyle.segment,
        };
        if (kind == PluginActionKind.http && url == null) continue;
        if ((kind == PluginActionKind.launch ||
                kind == PluginActionKind.shell) &&
            (command == null || command.trim().isEmpty)) {
          continue;
        }
        if (kind == PluginActionKind.prompt &&
            (prompt == null || prompt.trim().isEmpty)) {
          continue;
        }
        if (kind == PluginActionKind.screen &&
            (screen == null || screen.trim().isEmpty)) {
          continue;
        }
        actions.add(
          PluginAction(
            label: aLabel,
            url: url,
            kind: kind,
            command: command,
            prompt: prompt,
            screen: screen,
            record: record,
            style: style,
          ),
        );
      }
    }

    return Plugin(
      id: id,
      title: map['title'] as String?,
      labelTemplate: label,
      placement: placement,
      isGlobal: isGlobal,
      refresh: Duration(
        milliseconds: (map['refresh_ms'] as num?)?.toInt() ?? 2000,
      ),
      statusPath: statusPath,
      heartbeatField: status['heartbeat_field'] as String?,
      staleAfter: Duration(
        seconds: (status['stale_after_seconds'] as num?)?.toInt() ?? 15,
      ),
      stateRules: rules,
      aliveText: status['fallback_alive_text'] as String? ?? '●',
      staleText: status['fallback_stale_text'] as String? ?? 'stale',
      absentText: status['fallback_absent_text'] as String? ?? 'not running',
      actions: actions,
      touchOnPoll: (status['touch_on_poll'] as String?)?.trim(),
      producer: _parseProducer(map['producer']),
    );
  }

  static PluginProducer? _parseProducer(dynamic raw) {
    if (raw is! Map) return null;
    final command = raw['command'] as String?;
    if (command == null || command.trim().isEmpty) return null;
    return PluginProducer(
      command: command,
      cwd: raw['cwd'] as String?,
    );
  }

  static PluginStateColor _parseColor(String? raw) {
    switch (raw) {
      case 'success':
        return PluginStateColor.success;
      case 'warning':
        return PluginStateColor.warning;
      case 'error':
        return PluginStateColor.error;
      case 'dim':
        return PluginStateColor.dim;
      default:
        return PluginStateColor.normal;
    }
  }
}

/// One rendered label fragment: [text], whether it came from a
/// `{placeholder}` substitution (a live data VALUE), and whether the
/// spec marked it with a trailing `!` (`{price!}`) for emphasis
/// coloring by the renderer.
typedef PluginLabelSpan = ({String text, bool isValue, bool emphasize});

/// Liveness of a plugin's status source.
enum PluginAlive { absent, stale, alive }

/// A computed status snapshot for one plugin.
class PluginStatus {
  final PluginAlive alive;

  /// The parsed status JSON (empty map when the file is missing or
  /// unparseable).
  final Map<String, dynamic> data;

  /// The computed `{state}` text.
  final String stateText;

  /// The rendered label (template fully substituted). May contain
  /// `\n` — a plugin can render several lines of content.
  final String label;

  /// [label] split on `\n`, empty/whitespace-only lines dropped.
  List<String> get labelLines => label
      .split('\n')
      .map((l) => l.trimRight())
      .where((l) => l.trim().isNotEmpty)
      .toList(growable: false);

  /// The rendered label split into display lines of
  /// [PluginLabelSpan]s, mirroring [labelLines]. Dead states render
  /// as single literal spans (colors would be misleading). Renderers
  /// that don't care about per-value coloring can keep using
  /// [labelLines] — the plain text is identical.
  final List<List<PluginLabelSpan>> spanLines;

  /// Display color for the label.
  final PluginStateColor color;

  const PluginStatus({
    required this.alive,
    required this.data,
    required this.stateText,
    required this.label,
    required this.spanLines,
    required this.color,
  });
}

/// Read + evaluate a plugin's status source. Pure: takes the status file
/// (path resolved by the caller against the project root) and returns a
/// snapshot, so it is fully headless-testable.
PluginStatus evaluatePluginStatus(
  Plugin plugin,
  File statusFile,
  DateTime now,
) {
  final fileExists = statusFile.existsSync();
  Map<String, dynamic> data;
  if (fileExists) {
    try {
      final decoded = jsonDecode(statusFile.readAsStringSync());
      data = decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      data = {};
    }
  } else {
    data = {};
  }

  final alive = _computeAlive(plugin, data, fileExists, now);

  // Dead-state label: when the template embeds `{state}` the fallback
  // text renders through the template as before (single-line service
  // plugins). A template WITHOUT `{state}` (multi-line content
  // plugins, e.g. a price monitor) has no place for the fallback —
  // rendering it would leak raw `{field}` placeholders from the
  // missing file — so the whole label becomes the fallback text.
  String deadLabel(String text) => plugin.labelTemplate.contains('{state}')
      ? renderTemplate(plugin.labelTemplate, data, text)
      : text;

  switch (alive) {
    case PluginAlive.absent:
      return PluginStatus(
        alive: alive,
        data: data,
        stateText: plugin.absentText,
        label: deadLabel(plugin.absentText),
        spanLines: _deadSpanLines(deadLabel(plugin.absentText)),
        color: PluginStateColor.dim,
      );
    case PluginAlive.stale:
      return PluginStatus(
        alive: alive,
        data: data,
        stateText: plugin.staleText,
        label: deadLabel(plugin.staleText),
        spanLines: _deadSpanLines(deadLabel(plugin.staleText)),
        color: PluginStateColor.warning,
      );
    case PluginAlive.alive:
      // Top-down rule match; first hit wins.
      for (final rule in plugin.stateRules) {
        final value = _dig(data, rule.field);
        if (value != null && value.toString() == rule.equals) {
          final stateText = renderTemplate(rule.text, data, rule.text);
          return PluginStatus(
            alive: alive,
            data: data,
            stateText: stateText,
            label: renderTemplate(plugin.labelTemplate, data, stateText),
            spanLines:
                _aliveSpanLines(plugin.labelTemplate, data, stateText),
            color: rule.color,
          );
        }
      }
      return PluginStatus(
        alive: alive,
        data: data,
        stateText: plugin.aliveText,
        label: renderTemplate(plugin.labelTemplate, data, plugin.aliveText),
        spanLines:
            _aliveSpanLines(plugin.labelTemplate, data, plugin.aliveText),
        color: PluginStateColor.normal,
      );
  }
}

/// Dead states: the label is plain fallback text — one literal span
/// per line (no values to emphasize).
List<List<PluginLabelSpan>> _deadSpanLines(String label) => label
    .split('\n')
    .map((l) => l.trimRight())
    .where((l) => l.trim().isNotEmpty)
    .map((l) => <PluginLabelSpan>[(text: l, isValue: false, emphasize: false)])
    .toList(growable: false);

/// Alive: partition each template line into literal/value spans with
/// the same substitution rules as [renderTemplate] (including the
/// visible-literal-placeholder fallback for unknown fields).
List<List<PluginLabelSpan>> _aliveSpanLines(
  String template,
  Map<String, dynamic> data,
  String stateText,
) {
  final out = <List<PluginLabelSpan>>[];
  for (final rawLine in template.split('\n')) {
    final line = rawLine.trimRight();
    if (line.trim().isEmpty) continue;
    final spans = <PluginLabelSpan>[];
    var last = 0;
    for (final m in _placeholderPattern.allMatches(line)) {
      if (m.start > last) {
        spans.add(
          (text: line.substring(last, m.start), isValue: false, emphasize: false),
        );
      }
      final name = m.group(1)!;
      String? value;
      if (name == 'state') {
        value = stateText;
      } else {
        final v = _dig(data, name);
        if (v != null) {
          value = m.group(2) == 'HH:MM'
              ? _formatHm(v.toString())
              : v.toString();
        }
      }
      spans.add(
        value == null
            // Unknown field: keep the literal placeholder visible
            // (spec typo) — nothing to emphasize.
            ? (text: m.group(0)!, isValue: false, emphasize: false)
            : (text: value, isValue: true, emphasize: m.group(3) == '!'),
      );
      last = m.end;
    }
    if (last < line.length) {
      spans.add((text: line.substring(last), isValue: false, emphasize: false));
    }
    if (spans.isNotEmpty) out.add(spans);
  }
  return out;
}

/// `{field@HH:MM}` — ISO-8601 timestamp as local HH:MM (empty when
/// unparseable, mirroring [renderTemplate]).
String? _formatHm(String raw) {
  final t = DateTime.tryParse(raw);
  if (t == null) return '';
  final local = t.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// Substitute a URL template for an action (same syntax as labels; no
/// `{state}` — actions only read the status JSON).
String renderActionUrl(PluginAction action, Map<String, dynamic> data) =>
    renderTemplate(action.url ?? '', data, '');

/// Substitute a prompt template for a [PluginActionKind.prompt] action
/// against the status JSON. The rendered text is what gets submitted to
/// the chat session.
String renderActionPrompt(PluginAction action, Map<String, dynamic> data) =>
    renderTemplate(action.prompt ?? '', data, '');

/// Execute an http action: substitute the URL template from the status
/// JSON and POST it. Returns true on HTTP 200. Shared by the renderers
/// and the `plugins` tool so both see identical action semantics.
/// Errors (unreachable service, malformed URL, wrong kind) return
/// false.
Future<bool> sendPluginAction(
  PluginAction action,
  Map<String, dynamic> data,
) async {
  if (action.kind != PluginActionKind.http || action.url == null) {
    return false;
  }
  final url = renderActionUrl(action, data);
  final parsed = Uri.tryParse(url);
  if (parsed == null || !parsed.isAbsolute) return false;
  try {
    final client = HttpClient();
    try {
      final request = await client
          .postUrl(parsed)
          .timeout(const Duration(seconds: 5));
      final response =
          await request.close().timeout(const Duration(seconds: 5));
      await response.drain<void>();
      return response.statusCode == 200;
    } finally {
      client.close(force: true);
    }
  } catch (_) {
    return false;
  }
}

/// Launch a [PluginActionKind.launch] action: open a fresh terminal
/// window in the project root and run the command. Shared by the
/// renderers and the `plugins` tool.
///
/// Platform support: macOS + Ghostty only — other platforms return
/// false and the UI renders the start segment disabled / the tool
/// reports failure.
Future<bool> launchPluginAction(
  PluginAction action,
  String projectPath,
) async {
  if (action.kind != PluginActionKind.launch) return false;
  final command = action.command;
  if (command == null || command.trim().isEmpty) return false;
  if (!Platform.isMacOS) return false;
  try {
    final proc = await Process.start('open', [
      '-na',
      'Ghostty',
      '--args',
      '-e',
      'bash',
      '-lc',
      'cd "${p.normalize(projectPath)}" && $command',
    ]);
    unawaited(proc.exitCode);
    return true;
  } catch (_) {
    return false;
  }
}

/// Substitute a shell-command template for a [PluginActionKind.shell]
/// or [PluginActionKind.launch] action against the status JSON.
String renderActionCommand(PluginAction action, Map<String, dynamic> data) =>
    renderTemplate(action.command ?? '', data, '');

/// Outcome of running a [PluginActionKind.shell] action.
class ShellActionResult {
  final int exitCode;

  /// Combined stdout+stderr, trimmed to the trailing characters —
  /// enough for a toast / tool result without flooding the context.
  final String tail;

  const ShellActionResult({required this.exitCode, required this.tail});

  bool get ok => exitCode == 0;
}

/// Run a [PluginActionKind.shell] action: execute the rendered command
/// in the project root, capture combined output, and return the exit
/// code plus a bounded tail. Shared by the renderers and the `plugins`
/// tool so both see identical semantics.
///
/// The command runs via the platform shell (`/bin/sh -c` on POSIX,
/// `cmd /c` on Windows). A generous timeout bounds runaway scripts; a
/// timed-out process is killed and reported with exit code -1.
Future<ShellActionResult> runPluginShellAction(
  PluginAction action,
  Map<String, dynamic> data,
  String projectRoot, {
  Duration timeout = const Duration(minutes: 10),
  int maxTailChars = 2000,
}) async {
  final command = renderActionCommand(action, data).trim();
  if (action.kind != PluginActionKind.shell || command.isEmpty) {
    return const ShellActionResult(exitCode: -1, tail: '(no command)');
  }
  try {
    final proc = await Process.start(
      Platform.isWindows ? 'cmd' : '/bin/sh',
      Platform.isWindows ? ['/c', command] : ['-c', command],
      workingDirectory: projectRoot,
    );
    final out = StringBuffer();
    final subOut = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(out.write);
    final subErr = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(out.write);

    final exitCode = await proc.exitCode.timeout(
      timeout,
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await subOut.cancel();
    await subErr.cancel();

    var tail = out.toString().trim();
    if (tail.length > maxTailChars) {
      tail = '…${tail.substring(tail.length - maxTailChars)}';
    }
    if (exitCode == -1 && tail.isEmpty) {
      tail = '(timed out after ${timeout.inMinutes}m)';
    }
    return ShellActionResult(exitCode: exitCode, tail: tail);
  } catch (e) {
    return ShellActionResult(exitCode: -1, tail: 'failed to start: $e');
  }
}

PluginAlive _computeAlive(
  Plugin plugin,
  Map<String, dynamic> data,
  bool fileExists,
  DateTime now,
) {
  final heartbeatField = plugin.heartbeatField;
  if (heartbeatField == null) {
    // No liveness declared: file presence is the liveness.
    return fileExists ? PluginAlive.alive : PluginAlive.absent;
  }
  final raw = _dig(data, heartbeatField);
  if (raw == null) return PluginAlive.absent;
  final heartbeat = DateTime.tryParse(raw.toString());
  if (heartbeat == null) return PluginAlive.absent;
  return now.difference(heartbeat) <= plugin.staleAfter
      ? PluginAlive.alive
      : PluginAlive.stale;
}

/// The placeholder pattern shared by [renderTemplate] and span
/// splitting: `{field}`, `{field@HH:MM}`, `{state}`, each optionally
/// suffixed with `!` (`{price!}`) to mark the substituted value for
/// emphasis coloring.
final RegExp _placeholderPattern =
    RegExp(r'\{([a-zA-Z0-9_.]+)(?:@(HH:MM))?(!)?\}');

/// Substitute `{state}`, `{field}` and `{field@HH:MM}` placeholders.
/// Unknown or missing fields render as the literal placeholder so spec
/// typos are visible instead of silently blank.
///
/// The template may be multi-line (embed `\n` in the TOML string);
/// [PluginStatus.labelLines] splits the rendered result into per-row
/// content for the renderers.
String renderTemplate(
  String template,
  Map<String, dynamic> data,
  String stateText,
) {
  return template.replaceAllMapped(
    _placeholderPattern,
    (match) {
      final name = match.group(1)!;
      if (name == 'state') return stateText;
      final value = _dig(data, name);
      if (value == null) return match.group(0)!;
      if (match.group(2) == 'HH:MM') {
        final t = DateTime.tryParse(value.toString());
        if (t == null) return '';
        final local = t.toLocal();
        return '${local.hour.toString().padLeft(2, '0')}:'
            '${local.minute.toString().padLeft(2, '0')}';
      }
      return value.toString();
    },
  );
}

dynamic _dig(Map<String, dynamic> data, String dottedPath) {
  var current = data;
  final parts = dottedPath.split('.');
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    if (current.containsKey(part)) {
      final value = current[part];
      if (i == parts.length - 1) return value;
      if (value is Map<String, dynamic>) {
        current = value;
      } else {
        return null;
      }
    } else {
      return null;
    }
  }
  return null;
}
