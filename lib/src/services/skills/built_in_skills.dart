/// Built-in skills — file-less skills that ship with Crux itself.
///
/// A built-in skill exists **always**, in every workspace session,
/// regardless of what the project or the user has installed. It is
/// not discovered from the filesystem: `discoverSkills` prepends
/// [builtInSkills] to its result, and `findSkillByName` can resolve
/// them too. The `skill` tool renders their body straight from the
/// constants below — zero disk access.
///
/// Properties of built-ins:
///
///   - `location`/`baseDirectory` are the sentinel string `(built-in)`
///     — UI surfaces (the home skills fullpane, the `skill` tool's
///     sibling sampler) must tolerate a non-path location.
///   - Names are reserved: a user skill that reuses a built-in name
///     is shadowed by the built-in (built-ins win the dedup race in
///     [discoverSkills]).
///   - Bodies are plain Dart constants — edit and recompile, no
///     packaging step.
///
/// The first (and so far only) built-in is [widgetSkill], which
/// teaches the agent how to author project widgets (`.crux/widgets/
/// *.toml`).
library;

import 'skill.dart';

/// Sentinel for `SkillInfo.location` / `SkillInfo.baseDirectory` of a
/// file-less skill. Never a real path — consumers that touch the
/// filesystem (sibling sampling in the `skill` tool) already guard
/// with `Directory.existsSync`, which returns false for this.
const String kBuiltInSkillLocation = '(built-in)';

/// `widget` — how to write and use Crux project widgets.
///
/// This is the canonical reference for the `.crux/widgets/*.toml`
/// schema, taught to the agent on demand (progressive disclosure:
/// the description sits in `<available_skills>`; the body is loaded
/// via the `skill` tool only when the agent is about to write or
/// debug a widget). Keep it in sync with the parser in
/// `lib/src/services/spec_widget.dart` — the schema documented here
/// is exactly what that parser accepts.
const SkillInfo widgetSkill = SkillInfo(
  name: 'widget',
  description:
      'Author Crux widgets: live status + action rows shown in the '
      'sidebar, defined by TOML specs in .crux/widgets/. Load when '
      'writing, updating, debugging, or explaining a widget spec, or '
      'when deciding whether a long-running dev workflow deserves one.',
  location: kBuiltInSkillLocation,
  baseDirectory: kBuiltInSkillLocation,
  content: _widgetSkillBody,
);

/// Every built-in skill, in display order. `discoverSkills` prepends
/// this list to its result and reserves the names.
const List<SkillInfo> builtInSkills = [widgetSkill];

const String _widgetSkillBody = r'''
# Crux widgets

A **widget** is a small TOML file at `<project>/.crux/widgets/<id>.toml`
that renders one bordered box in the Crux side panel: a live status
label plus optional action buttons. A widget is NOT limited to dev
servers — it is a general-purpose mini dashboard for anything a JSON
file can describe. If a script can write `{"price": 2411.5, "delta":
"+0.8%"}` to a file, a widget can show a live gold price; if a cron
job can write `{"open_issues": 7}` a widget can watch that too.
Dev servers, hot-reload harnesses, test watchers, CI status, stock /
crypto / gold prices, weather, deploy state — all fair game.

## Why widgets — what the user gets

- **Ambient awareness**: anything that matters shows its live state in
  the sidebar of EVERY Crux session opened on the project — no need
  to ask you "is it still running?" or "what's the price now?".
- **One-click control**: reload / restart / stop / open become buttons
  on the box (and `widgets trigger` calls for you) instead of typed
  commands.
- **Multi-line content**: the label template may contain `\n`, so one
  widget can stack several rows of live data (e.g. spot price on line
  1, daily change on line 2, last-updated time on line 3).
- **Zero rebuild, zero restart**: the sidebar rescans `.crux/widgets/`
  every ~2 s. Write the file, the box appears; edit it, the box
  updates; delete it, the box disappears. The filesystem is the bus.
- **Cheap**: a widget is ~20 lines of TOML reading a JSON status file.
  No Dart code, no Crux plugin.

## When to write a widget for a project

Write one when ANY of these holds:

1. **A long-lived process** with meaningful state (dev server, hot-reload
   harness, file watcher, codegen runner, docker compose stack, tunnel)
   the user will start / stop / reload repeatedly, OR
2. **A value the user wants to keep an eye on** while working (a price,
   a count, a build / deploy status, a queue depth) that can be
   refreshed into a JSON file by a script, cron job, or the process
   itself, OR
3. **An action the user runs over and over** — two quick-action
   flavours, both `[[actions]]` entries that render in any state:
   - `kind = "shell"`: a script the USER wants to run themselves
     (run tests, lint, build, a release checklist script). Clicking
     runs it in the project root and records the exit code + output
     tail into the session so you see what the user ran and how it
     went — no need for them to paste results back to you.
   - `kind = "prompt"`: a prompt the AGENT should perform (a
     code-review ritual, a complex multi-step instruction). Clicking
     submits the template as a user message.
   A widget can exist purely to hold buttons — give it a minimal
   static status file or a trivial heartbeat and a one-word label.

Do NOT write a widget for: one-shot commands, purely static facts that
never change, things already visible in `git status`, or when the user
didn't ask and the workflow isn't clearly recurring. When unsure,
propose the widget and let the user decide.

## How to write one

### 1. Make something report state

The widget polls a JSON file relative to the project root. Anything
can write it — the monitored process itself, a wrapper script, a cron
job, a CI webhook receiver:

    {"heartbeatAt": "2026-08-05T12:00:00Z", "port": 8080, "phase": "ready"}

A `heartbeatAt` (ISO-8601) field drives liveness: heartbeat fresher
than `stale_after_seconds` ⇒ alive; older ⇒ stale; file missing ⇒
absent. Without a heartbeat field, mere file presence means alive —
fine for pure monitoring widgets where "stale" isn't meaningful (just
omit `heartbeat_field` and refresh the file on whatever cadence the
data source allows).

### 2. Write the spec

Create `.crux/widgets/<id>.toml`. Full schema (single-line label —
a dev server):

    id = "my-server"                     # REQUIRED, must equal the file name
    title = "my server"                  # optional box title, defaults to id
    label = "⬢ my server · {state}"      # REQUIRED label template
    refresh_ms = 2000                    # poll interval, default 2000

    [status]
    path = ".dart_tool/my_server.json"   # REQUIRED, relative to project root
    heartbeat_field = "heartbeatAt"      # optional liveness field
    stale_after_seconds = 15             # default 15

    # TOML gotcha: fallback_* keys MUST stay above [[status.state_rules]]
    # — after an array-of-tables entry, bare keys belong to the LAST
    # array element, not to [status].
    fallback_alive_text = "●"            # alive, no rule matched
    fallback_stale_text = "stale"        # heartbeat expired
    fallback_absent_text = "not running" # status file missing

    [[status.state_rules]]               # top-down, first match wins
    when = { field = "phase", equals = "ready" }
    text = "✓ ready on :{port}"
    color = "normal"                     # normal|warning|error|dim

    [[status.state_rules]]
    when = { field = "phase", equals = "error" }
    text = "✗ failed"
    color = "error"

    # "start" action — shown only while NOT alive (kind = "launch").
    # macOS + Ghostty only: opens a fresh terminal in the project root.
    [[actions]]
    label = "start"
    kind = "launch"
    command = "./scripts/dev-server.sh"

    # Control actions — shown only while alive (default kind = "http").
    # POST to the rendered URL; the URL template reads the status JSON.
    [[actions]]
    label = "reload"
    url = "http://127.0.0.1:{port}/reload"

    [[actions]]
    label = "stop"
    url = "http://127.0.0.1:{port}/close"

    # Quick actions — always shown, any liveness. Two flavours:
    #
    #   kind = "shell"  → run `command` in the project root (no
    #                     terminal window). For finite tasks: tests,
    #                     lint, codegen, a release script. The exit
    #                     code + output tail are recorded into the
    #                     session so you see what the user ran.
    #   kind = "prompt" → submit `prompt` as a user message to the
    #                     current session. For frequent prompts and
    #                     multi-step rituals the agent should perform.
    #
    # Both command and prompt are templates over the status JSON.
    [[actions]]
    label = "test"
    kind = "shell"
    command = "dart test"

    [[actions]]
    label = "review"
    kind = "prompt"
    prompt = "Review my uncommitted changes against CONTRIBUTING.md and report issues by severity."

### 3. A monitoring widget (multi-line, no process)

A pure monitor has no `heartbeat_field`, no launch action, and often
no http actions at all — it just shows data. Use a TOML multi-line
basic string (`"""`) or `\n` escapes in the label to stack rows:

    id = "gold"
    title = "gold"
    # Three lines: spot, daily change, last-updated clock time.
    label = """
    XAU ${price}/oz
    {arrow} {delta} today
    updated {updatedAt@HH:MM}"""
    refresh_ms = 60000

    [status]
    path = ".dart_tool/gold.json"
    # No heartbeat_field → file presence = alive. The fetching script
    # (cron / loop) rewrites the JSON every minute.

    # Color the whole box by trend: state_rules still apply — the
    # first matching rule's color styles every line.
    [[status.state_rules]]
    when = { field = "trend", equals = "up" }
    text = "▲ up"
    color = "normal"

    [[status.state_rules]]
    when = { field = "trend", equals = "down" }
    text = "▼ down"
    color = "warning"

    fallback_alive_text = "live"

With a fetcher writing `.dart_tool/gold.json` like
`{"price": 2411.5, "delta": "+0.8%", "arrow": "▲", "trend": "up",
"updatedAt": "2026-08-05T11:59:00Z"}` the box renders as:

    ╭ gold ──────────╮
    │ XAU 2411.5/oz  │
    │ ▲ +0.8% today  │
    │ updated 11:59  │
    ╰────────────────╯

### 4. Template syntax

In `label`, rule `text`, action `url`, action `command`, and action
`prompt`:

    {state}         → the computed state text (labels only)
    {field}         → dotted path into the status JSON (e.g. {lastRun.result})
    {field@HH:MM}   → ISO-8601 timestamp rendered as local HH:MM
    \n in the label → hard line break; each line renders as its own row

Unknown fields render as the literal `{placeholder}` — typos stay
visible instead of silently blank.

### 5. Rules

- `id` MUST match the file name (`foo.toml` → `id = "foo"`) or the
  spec is skipped.
- HTTP actions POST and treat 200 as success.
- `launch` actions need macOS + Ghostty; elsewhere they fail.
- Actions render only in their liveness state: `launch` while dead,
  `http` while alive — a dead service can't silently accept clicks.
  `prompt` and `shell` actions render in ANY state (including
  absent) — they're quick actions for the user, not operations on
  the service.
- A monitoring widget with no actions is always just a label.

### 6. You see what the user does

Every widget interaction lands in the session context, so you're
never guessing what the user clicked:

- `shell` actions inject a `[Widget action]` note with the command,
  exit code, and output tail — you see test/lint results without the
  user pasting them.
- `http` / `launch` clicks inject a `[Widget action]` note WITH THE
  OUTCOME ("clicked `reload` on widget `dev-harness` (POST … →
  succeeded)" or "→ FAILED — target unreachable") — you know whether
  the action worked, not just that it was attempted.
- `prompt` clicks appear as the submitted user message itself.

Use these as live signals: if the user just reloaded the harness,
its state probably changed; if a test run failed, offer to fix it.

## How to use widgets as an agent

- `widgets list` — every widget, live status label, action labels.
- `widgets inspect <id>` — one widget's spec, liveness, full status
  JSON, action URLs (unrendered templates).
- `widgets trigger <id> <action>` — execute an action. `http` actions
  are refused while the widget isn't alive; `launch` actions are the
  way to START a dead one; `prompt` actions return the rendered
  quick-action message (act on it as if the user had typed it);
  `shell` actions run the command and return the exit code + output
  tail.
- To create/update a widget, just write the TOML — the user's sidebar
  picks it up within ~2 s. Tell the user what you added and where.

Canonical live example: `.crux/widgets/dev-harness.toml` in the Crux
repo itself (a service widget: heartbeat + reload/remount/close
actions). Parser source of truth: `lib/src/services/spec_widget.dart`.
''';
