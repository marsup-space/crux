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
/// The first (and so far only) built-in is [pluginSkill], which
/// teaches the agent how to author plugins (`.crux/plugins/*.toml`).
library;

import 'skill.dart';

/// Sentinel for `SkillInfo.location` / `SkillInfo.baseDirectory` of a
/// file-less skill. Never a real path — consumers that touch the
/// filesystem (sibling sampling in the `skill` tool) already guard
/// with `Directory.existsSync`, which returns false for this.
const String kBuiltInSkillLocation = '(built-in)';

/// `plugin` — how to write and use Crux plugins.
///
/// This is the canonical reference for the plugin TOML schema,
/// taught to the agent on demand (progressive disclosure: the
/// description sits in `<available_skills>`; the body is loaded via
/// the `skill` tool only when the agent is about to write or debug a
/// plugin). Keep it in sync with the parser in
/// `lib/src/services/plugin.dart` — the schema documented here is
/// exactly what that parser accepts.
const SkillInfo pluginSkill = SkillInfo(
  name: 'plugin',
  description:
      'Author Crux plugins: live status lines and one-click action '
      'buttons shown in the sidebar and/or the home dashboard, defined '
      'by TOML specs in .crux/plugins/ (project) or ~/.crux/plugins/ '
      '(global). A plugin exists to (1) answer a question the user '
      'actually asks at a glance and (2) turn a repeated command into '
      'one click. Load when creating, updating, debugging, or '
      'explaining a plugin, or when judging whether a workflow '
      'deserves one.',
  location: kBuiltInSkillLocation,
  baseDirectory: kBuiltInSkillLocation,
  content: _pluginSkillBody,
);

/// Every built-in skill, in display order. `discoverSkills` prepends
/// this list to its result and reserves the names.
const List<SkillInfo> builtInSkills = [pluginSkill];

const String _pluginSkillBody = r'''
# Crux plugins

A **plugin** is a small TOML spec that renders a live box in the
user's UI — the side panel (`placement = "sidebar"`, the default),
the home dashboard grid (`"home"`), or both (`"both"`).

A plugin has exactly TWO jobs. Before writing one, ask which of the
two the user needs — a plugin that does neither is noise:

1. **STATUS: answer a question the user actually asks.** "Is the dev
   server still running?" "What's the gold price?" "Did the last
   build pass?" The label must answer it AT A GLANCE — the user
   should never have to ask you or run a command to find out.
2. **ACTIONS: turn a repeated command into one click.** Start/stop/
   reload a service, run the test suite, submit a code-review
   ritual. Only buttons the user will genuinely click MORE THAN
   ONCE — a button for something they'd never run is clutter.

## Fit the user's need (read this before writing)

The most common failure mode is a plugin that's technically correct
but useless — generic labels, decorative buttons, answering a
question nobody asked. Guard against it:

- **Restate the need in one sentence before writing the spec** (in
  your reply, so the user can correct you): "You want to see X at a
  glance and restart it with one click — I'll build that."
- **The label answers the user's actual question**, not a generic
  one. If they ask "is the port up?", prefer `✓ :8080 ready` over
  `●`; if they track a price, the number goes IN the label, not
  behind a rule. `fallback_alive_text = "●"` is a last resort, not
  a default.
- **Every button earns its place**: name it after the command it
  runs (`test`, `reload`, `deploy`), and only include the ones the
  user repeatedly uses. No "refresh" button when the box already
  auto-refreshes; no "open" button for a directory they never open.
- **Ask when the request is ambiguous.** "Monitor my server" —
  which server, what signal matters (port? errors? requests/min?),
  and what does the user want to DO about it (restart? tail logs)?
  One short clarifying question beats a mis-fitted plugin the user
  silently deletes.
- **Propose, don't surprise.** If the user didn't explicitly ask
  for a plugin, describe what you'd add (one line: what it shows,
  which buttons) and let them confirm. An unasked-for dashboard is
  clutter, not help.
- **Placement follows purpose.** A value the user glances at while
  working → sidebar. A status they check when they land on the
  dashboard → home. Something they want everywhere → both. When in
  doubt, default to sidebar.
- **Prefer project-local (`.crux/plugins/`)**; use global
  (`~/.crux/plugins/`) only for cross-project utilities the user
  wants everywhere (a generic "run tests" plugin, a price ticker).
  Global plugins resolve statuses/commands against whatever project
  is open.

## When a plugin is the right tool

Write one when ANY of these holds:

1. **A long-lived process** with meaningful state (dev server,
   hot-reload harness, file watcher, docker stack, tunnel) the user
   starts / stops / reload repeatedly, OR
2. **A value to keep an eye on** while working (price, count, build
   status, queue depth) refreshable into a JSON file, OR
3. **A repeated action** the user wants as a button:
   - `kind = "shell"`: a finite command the USER runs (tests, lint,
     release checklist). The exit code + output tail are recorded
     into the session — you see the result without the user pasting
     it.
   - `kind = "prompt"`: a task the AGENT should perform (review
     ritual, multi-step instruction). Clicking submits it as a user
     message.

Do NOT write a plugin for: one-shot commands (a plugin outlives the
task), static facts that never change, anything `git status` already
shows, or when the workflow isn't clearly recurring.

## Writing the spec

### 1. Make something report state

The plugin polls a JSON file. Anything can write it — the monitored
process, a wrapper script, cron, a CI webhook:

    {"heartbeatAt": "2026-08-05T12:00:00Z", "port": 8080, "phase": "ready"}

A `heartbeatAt` (ISO-8601) drives liveness: fresher than
`stale_after_seconds` ⇒ alive; older ⇒ stale; file missing ⇒ absent.
No `heartbeat_field` → file presence = alive (fine for pure
monitors).

### 2. The spec file

Create `.crux/plugins/<id>.toml` (project) or `~/.crux/plugins/<id>
.toml` (global). Full schema — a dev-server service plugin:

    id = "my-server"                     # REQUIRED, must equal file name
    placement = "sidebar"                # sidebar (default) | home | both
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
    fallback_alive_text = "✓ :{port}"    # alive, no rule matched — ANSWER,
                                         # don't default to a bare "●"
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

    # "start" — shown only while NOT alive. macOS + Ghostty: opens a
    # fresh terminal in the project root.
    [[actions]]
    label = "start"
    kind = "launch"
    command = "./scripts/dev-server.sh"

    # Control — shown only while alive (default kind = "http").
    # POST to the rendered URL; the template reads the status JSON,
    # so a randomly assigned port plugs straight in.
    [[actions]]
    label = "reload"
    url = "http://127.0.0.1:{port}/reload"

    [[actions]]
    label = "stop"
    url = "http://127.0.0.1:{port}/close"

    # Quick actions — always shown. command/prompt are templates over
    # the status JSON.
    [[actions]]
    label = "test"
    kind = "shell"
    command = "dart test"

    [[actions]]
    label = "review"
    kind = "prompt"
    prompt = "Review my uncommitted changes against CONTRIBUTING.md and report issues by severity."

### 3. A monitor plugin (multi-line, no process)

A pure monitor has no heartbeat, no launch action, often no actions
at all — it just answers "what's the value now?". Stack rows with a
TOML `"""` string or `\n`:

    id = "gold"
    title = "gold"
    placement = "sidebar"
    label = """
    XAU ${price}/oz
    {arrow} {delta} today
    updated {updatedAt@HH:MM}"""
    refresh_ms = 60000

    [status]
    path = ".dart_tool/gold.json"

    [[status.state_rules]]
    when = { field = "trend", equals = "down" }
    text = "▼ down"
    color = "warning"

    fallback_alive_text = "live"

Renders as:

    ╭ gold ──────────╮
    │ XAU 2411.5/oz  │
    │ ▲ +0.8% today  │
    │ updated 11:59  │
    ╰────────────────╯

### 4. A global plugin

`~/.crux/plugins/tests.toml` — the same schema; the spec lives in
the user's home but `status.path` and shell/launch commands resolve
against the CURRENT project root, so one spec works in every repo:

    id = "tests"
    placement = "home"
    label = "last run: {state}"
    refresh_ms = 10000

    [status]
    path = ".dart_tool/last_test_run.json"

    [[actions]]
    label = "run tests"
    kind = "shell"
    command = "dart test"

(You'd pair it with something that writes `last_test_run.json` —
e.g. the same `command` wrapped to tee its result, or a git hook.)

### 5. Template syntax

In `label`, rule `text`, action `url` / `command` / `prompt`:

    {state}         → the computed state text (labels only)
    {field}         → dotted path into the status JSON ({lastRun.result})
    {field@HH:MM}   → ISO-8601 timestamp as local HH:MM
    \n in the label → hard line break; each line renders as its own row

Unknown fields render as the literal `{placeholder}` — typos stay
visible instead of silently blank.

### 6. Rules

- `id` MUST match the file name (`foo.toml` → `id = "foo"`) or the
  spec is skipped.
- Scan roots (precedence order; first hit wins per id):
  `<project>/.crux/plugins/` → `<project>/.crux/widgets/` (legacy) →
  `~/.crux/plugins/` → `~/.crux/widgets/` (legacy).
- HTTP actions POST and treat 200 as success.
- `launch` actions need macOS + Ghostty; elsewhere they fail.
- Actions render only in their liveness state: `launch` while dead,
  `http` while alive. `prompt` / `shell` render in ANY state.
- A monitor with no actions is just a label — that's fine.
- Home boxes: `Enter` on a focused plugin box fires its first
  available action; the mouse covers per-button clicks.

### 7. You see what the user does

Every plugin interaction lands in the session context:

- `shell` actions inject a `[Plugin action]` note with the command,
  exit code, and output tail.
- `http` / `launch` clicks inject a `[Plugin action]` note WITH the
  OUTCOME (succeeded / FAILED).
- `prompt` clicks appear as the submitted user message itself.

Use these as live signals: if the user just reloaded a harness, its
state changed; if a test run failed, offer to fix it.

## Working with plugins as an agent

- `plugins list` — every plugin, placement, live status, actions.
- `plugins inspect <id>` — spec, liveness, full status JSON,
  actions (unrendered templates).
- `plugins trigger <id> <action>` — execute an action (`http`
  refused while not alive; `launch` starts a dead one; `prompt`
  returns the rendered message — act on it; `shell` runs and
  returns exit code + tail).
- To create/update: write the TOML; the UI picks it up in ~2 s.
  Tell the user what you added, where, and WHAT IT SHOWS — reuse
  your one-sentence restatement so they can veto early.
- To remove: delete the file. To migrate a legacy
  `.crux/widgets/*.toml`: `git mv` it to `.crux/plugins/` (the
  schema is unchanged; `placement` is the only new key).

Canonical live example: `.crux/plugins/dev-harness.toml` in the
Crux repo (a service plugin: heartbeat + start/reload/close).
Parser source of truth: `lib/src/services/plugin.dart`.
''';
