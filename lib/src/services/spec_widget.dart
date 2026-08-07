// Spec-driven sidebar widgets (Phase B).
//
// A "spec widget" is a small TOML file in `<project>/.crux/widgets/`
// declaring how one row in the right-hand side panel renders: where its
// status comes from, how the status text is computed, and which actions
// it exposes. Any session — any agent, any human — can drop a spec file
// into that directory and every Crux session opened on the same project
// picks it up on its next scan (~2 s). No rebuild, no restart: the
// filesystem is the bus, and the widget set is keyed on the project,
// so "session ↔ config hook" falls out of `Directory.current` for free.
//
// Schema (see .crux/widgets/dev-harness.toml for a live example):
//
//   id = "dev-harness"                  # must match the file name
//   label = "⟳ crux dev · {state}"      # label template (see below)
//   refresh_ms = 2000                   # status poll interval
//
//   [status]
//   path = ".dart_tool/crux_dev.json"   # status source, relative to the project root
//   heartbeat_field = "heartbeatAt"     # optional: JSON field used for liveness
//   stale_after_seconds = 15            # heartbeat older than this ⇒ stale
//
//   # State text: rules match top-down against the status JSON; the
//   # first hit wins. Missing field ⇒ no match. Rule/fallback texts
//   # are templates too (see below).
//   [[status.state_rules]]
//   when = { field = "lastReload.result", equals = "succeeded" }
//   text = "✓ {lastReload.at@HH:MM}"
//   color = "normal"                    # optional: normal|warning|error|dim
//
//   [[status.state_rules]]
//   when = { field = "lastReload.result", equals = "failed" }
//   text = "✗ reload failed"
//   color = "error"
//
//   fallback_alive_text = "●"           # alive, no rule matched
//   fallback_stale_text = "stale"       # heartbeat expired (warning color)
//   fallback_absent_text = "not running"# status file missing (dim color)
//
//   # Actions become MultiButton segments; only rendered while alive.
//   # URLs are templates over the status JSON, so a random control
//   # port read from the state file plugs straight into the URL.
//   [[actions]]
//   label = "reload"
//   url = "http://127.0.0.1:{controlPort}/reload"
//
// Template syntax (labels, rule texts, action URLs):
//   {state}             → the computed state text
//   {field}             → dotted path into the status JSON (e.g. lastReload.result)
//   {field@HH:MM}       → ISO-8601 timestamp field formatted as local HH:MM
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
enum SpecStateColor { normal, warning, error, dim }

/// One `when`/`text` state rule.
class SpecStateRule {
  final String field;
  final String equals;
  final String text;
  final SpecStateColor color;

  const SpecStateRule({
    required this.field,
    required this.equals,
    required this.text,
    this.color = SpecStateColor.normal,
  });
}

/// What an action does when invoked.
enum SpecActionKind {
  /// HTTP POST to the action's URL template (requires [SpecAction.url]).
  http,

  /// Launch a local command in a terminal (requires
  /// [SpecAction.command]). Rendered only while the widget is NOT
  /// alive — it's the "start it" affordance for a dead service.
  launch,

  /// Submit [SpecAction.prompt] as a user message to the current chat
  /// session — the "quick action". Frequent prompts and complex
  /// multi-step rituals become a one-click button on the widget box.
  /// The prompt is a template over the status JSON (same syntax as
  /// labels, no `{state}`), so the message can embed live values.
  /// Rendered regardless of liveness (as long as the status file
  /// parses); the agent side executes it like any typed message.
  prompt,

  /// Run [SpecAction.command] in the project root and report the
  /// result — the user-runnable quick action: run tests, lint, a
  /// release script, any multi-step shell workflow. Unlike
  /// [SpecActionKind.launch] it does NOT open a terminal; the command
  /// runs to completion in the background and its tail output is
  /// surfaced as a toast / tool result. Meant for finite tasks, not
  /// long-lived services. Rendered regardless of liveness.
  shell,
}

/// One action segment (`reload`, `close`, `start`, `review`, …).
class SpecAction {
  final String label;

  /// URL template for [SpecActionKind.http] actions.
  final String? url;

  final SpecActionKind kind;

  /// Shell command for [SpecActionKind.launch] and
  /// [SpecActionKind.shell] actions. `launch` runs it in a fresh
  /// terminal window; `shell` runs it in the project root with output
  /// captured. The command is a template over the status JSON.
  final String? command;

  /// Message template for [SpecActionKind.prompt] actions, submitted
  /// to the current session as a user message on click.
  final String? prompt;

  const SpecAction({
    required this.label,
    this.url,
    this.kind = SpecActionKind.http,
    this.command,
    this.prompt,
  });
}

/// A parsed spec widget.
class SpecWidget {
  final String id;

  /// Short title rendered inline on the box border (like the home
  /// grid's box chrome). Defaults to [id].
  final String title;

  final String labelTemplate;
  final Duration refresh;
  final String statusPath;
  final String? heartbeatField;
  final Duration staleAfter;
  final List<SpecStateRule> stateRules;
  final String aliveText;
  final String staleText;
  final String absentText;
  final List<SpecAction> actions;

  const SpecWidget({
    required this.id,
    required this.labelTemplate,
    required this.refresh,
    required this.statusPath,
    String? title,
    this.heartbeatField,
    this.staleAfter = const Duration(seconds: 15),
    this.stateRules = const [],
    this.aliveText = '●',
    this.staleText = 'stale',
    this.absentText = 'not running',
    this.actions = const [],
  }) : title = title ?? id;

  /// Parse a spec file. Returns null when the file is unreadable or
  /// malformed, or the `id` doesn't match the file name — the caller
  /// (registry) skips such files and surfaces a warning.
  static SpecWidget? parse(File file) {
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

    final rules = <SpecStateRule>[];
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
          SpecStateRule(
            field: field,
            equals: equals,
            text: text,
            color: _parseColor(raw['color'] as String?),
          ),
        );
      }
    }

    final actions = <SpecAction>[];
    final rawActions = map['actions'];
    if (rawActions is List) {
      for (final raw in rawActions) {
        if (raw is! Map) continue;
        final aLabel = raw['label'] as String?;
        if (aLabel == null) continue;
        final kind = switch (raw['kind'] as String?) {
          'launch' => SpecActionKind.launch,
          'prompt' => SpecActionKind.prompt,
          'shell' => SpecActionKind.shell,
          _ => SpecActionKind.http,
        };
        final url = raw['url'] as String?;
        final command = raw['command'] as String?;
        final prompt = raw['prompt'] as String?;
        if (kind == SpecActionKind.http && url == null) continue;
        if ((kind == SpecActionKind.launch || kind == SpecActionKind.shell) &&
            (command == null || command.trim().isEmpty)) {
          continue;
        }
        if (kind == SpecActionKind.prompt &&
            (prompt == null || prompt.trim().isEmpty)) {
          continue;
        }
        actions.add(
          SpecAction(
            label: aLabel,
            url: url,
            kind: kind,
            command: command,
            prompt: prompt,
          ),
        );
      }
    }

    return SpecWidget(
      id: id,
      title: map['title'] as String?,
      labelTemplate: label,
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
    );
  }

  static SpecStateColor _parseColor(String? raw) {
    switch (raw) {
      case 'warning':
        return SpecStateColor.warning;
      case 'error':
        return SpecStateColor.error;
      case 'dim':
        return SpecStateColor.dim;
      default:
        return SpecStateColor.normal;
    }
  }
}

/// Liveness of a spec widget's status source.
enum SpecAlive { absent, stale, alive }

/// A computed status snapshot for one spec widget.
class SpecWidgetStatus {
  final SpecAlive alive;

  /// The parsed status JSON (empty map when the file is missing or
  /// unparseable).
  final Map<String, dynamic> data;

  /// The computed `{state}` text.
  final String stateText;

  /// The rendered label (template fully substituted). May contain
  /// `\n` — a spec can render several lines of content, e.g. a gold
  /// monitor showing spot / change / updated-at on separate rows.
  final String label;

  /// [label] split on `\n`, empty/whitespace-only lines dropped.
  /// The renderer lays out one [Text] per line. For a single-line
  /// label this is `[label]` — backward compatible.
  List<String> get labelLines => label
      .split('\n')
      .map((l) => l.trimRight())
      .where((l) => l.trim().isNotEmpty)
      .toList(growable: false);

  /// Display color for the label.
  final SpecStateColor color;

  const SpecWidgetStatus({
    required this.alive,
    required this.data,
    required this.stateText,
    required this.label,
    required this.color,
  });
}

/// Read + evaluate a spec's status source. Pure: takes the status file
/// (path resolved by the caller against the project root) and returns a
/// snapshot, so it is fully headless-testable.
SpecWidgetStatus evaluateSpecStatus(
  SpecWidget spec,
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

  final alive = _computeAlive(spec, data, fileExists, now);
  switch (alive) {
    case SpecAlive.absent:
      return SpecWidgetStatus(
        alive: alive,
        data: data,
        stateText: spec.absentText,
        label: renderTemplate(spec.labelTemplate, data, spec.absentText),
        color: SpecStateColor.dim,
      );
    case SpecAlive.stale:
      return SpecWidgetStatus(
        alive: alive,
        data: data,
        stateText: spec.staleText,
        label: renderTemplate(spec.labelTemplate, data, spec.staleText),
        color: SpecStateColor.warning,
      );
    case SpecAlive.alive:
      // Top-down rule match; first hit wins.
      for (final rule in spec.stateRules) {
        final value = _dig(data, rule.field);
        if (value != null && value.toString() == rule.equals) {
          final stateText = renderTemplate(rule.text, data, rule.text);
          return SpecWidgetStatus(
            alive: alive,
            data: data,
            stateText: stateText,
            label: renderTemplate(spec.labelTemplate, data, stateText),
            color: rule.color,
          );
        }
      }
      return SpecWidgetStatus(
        alive: alive,
        data: data,
        stateText: spec.aliveText,
        label: renderTemplate(spec.labelTemplate, data, spec.aliveText),
        color: SpecStateColor.normal,
      );
  }
}

/// Substitute a URL template for an action (same syntax as labels; no
/// `{state}` — actions only read the status JSON). Only valid for
/// [SpecActionKind.http] actions.
String renderActionUrl(SpecAction action, Map<String, dynamic> data) =>
    renderTemplate(action.url ?? '', data, '');

/// Substitute a prompt template for a [SpecActionKind.prompt] action
/// against the status JSON (same syntax as [renderActionUrl]). The
/// rendered text is what gets submitted to the chat session.
String renderActionPrompt(SpecAction action, Map<String, dynamic> data) =>
    renderTemplate(action.prompt ?? '', data, '');

/// Execute a spec action: substitute the URL template from the status
/// JSON and POST it. Returns true on HTTP 200. Shared by the sidebar
/// renderer and the `widgets` tool so both see identical action
/// semantics. Errors (unreachable harness, malformed URL, launch-only
/// action) return false.
Future<bool> sendSpecAction(
  SpecAction action,
  Map<String, dynamic> data,
) async {
  if (action.kind != SpecActionKind.http || action.url == null) return false;
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

/// Launch a [SpecActionKind.launch] action: open a fresh terminal
/// window in the project root and run the command. Shared by the
/// renderer and the `widgets` tool.
///
/// Platform support (Phase B): macOS + Ghostty only — the window is
/// opened via `open -na Ghostty`. Other platforms return false and the
/// UI renders the start segment disabled / the tool reports failure.
Future<bool> launchSpecAction(SpecAction action, String projectPath) async {
  if (action.kind != SpecActionKind.launch) return false;
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

/// Substitute a shell-command template for a [SpecActionKind.shell]
/// or [SpecActionKind.launch] action against the status JSON (same
/// syntax as [renderActionUrl]).
String renderActionCommand(SpecAction action, Map<String, dynamic> data) =>
    renderTemplate(action.command ?? '', data, '');

/// Outcome of running a [SpecActionKind.shell] action.
class ShellActionResult {
  final int exitCode;

  /// Combined stdout+stderr, trimmed to the trailing [maxChars]
  /// characters — enough for a toast / tool result without flooding
  /// the context.
  final String tail;

  const ShellActionResult({required this.exitCode, required this.tail});

  bool get ok => exitCode == 0;
}

/// Run a [SpecActionKind.shell] action: execute the rendered command
/// in the project root, capture combined output, and return the exit
/// code plus a bounded tail. Shared by the sidebar renderer and the
/// `widgets` tool so both see identical semantics.
///
/// The command runs via the platform shell (`/bin/sh -c` on POSIX,
/// `cmd /c` on Windows) so pipes, `&&`, and globs work as the user
/// expects. A generous timeout bounds runaway scripts; a timed-out
/// process is killed and reported with exit code -1.
Future<ShellActionResult> runSpecShellAction(
  SpecAction action,
  Map<String, dynamic> data,
  String projectPath, {
  Duration timeout = const Duration(minutes: 10),
  int maxTailChars = 2000,
}) async {
  final command = renderActionCommand(action, data).trim();
  if (action.kind != SpecActionKind.shell || command.isEmpty) {
    return const ShellActionResult(exitCode: -1, tail: '(no command)');
  }
  try {
    final proc = await Process.start(
      Platform.isWindows ? 'cmd' : '/bin/sh',
      Platform.isWindows ? ['/c', command] : ['-c', command],
      workingDirectory: projectPath,
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

SpecAlive _computeAlive(
  SpecWidget spec,
  Map<String, dynamic> data,
  bool fileExists,
  DateTime now,
) {
  final heartbeatField = spec.heartbeatField;
  if (heartbeatField == null) {
    // No liveness declared: file presence is the liveness.
    return fileExists ? SpecAlive.alive : SpecAlive.absent;
  }
  final raw = _dig(data, heartbeatField);
  if (raw == null) return SpecAlive.absent;
  final heartbeat = DateTime.tryParse(raw.toString());
  if (heartbeat == null) return SpecAlive.absent;
  return now.difference(heartbeat) <= spec.staleAfter
      ? SpecAlive.alive
      : SpecAlive.stale;
}

/// Substitute `{state}`, `{field}` and `{field@HH:MM}` placeholders.
/// Unknown or missing fields render as the literal placeholder so spec
/// typos are visible instead of silently blank.
///
/// The template may be multi-line (embed `\n` in the TOML string);
/// [SpecWidgetStatus.labelLines] splits the rendered result into
/// per-row content for the renderer.
String renderTemplate(
  String template,
  Map<String, dynamic> data,
  String stateText,
) {
  return template.replaceAllMapped(
    RegExp(r'\{([a-zA-Z0-9_.]+)(?:@(HH:MM))?\}'),
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
