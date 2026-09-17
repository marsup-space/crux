import 'app_locale.dart';

/// A small hand-rolled message catalog for UI chrome strings.
///
/// Deliberately *not* the `intl` message system: for a pure-Dart TUI the
/// catalog is a pair of `Map<String, String>` per locale, looked up by key
/// with `{name}` placeholder substitution. Chinese has no plural
/// morphology, so the first pass needs none of `intl`'s plural/gender
/// machinery — and if number/date formatting is ever needed, `intl` can be
/// pulled in later for *just* its `NumberFormat`/`DateFormat`.
class Strings {
  final AppLocale locale;

  const Strings(this.locale);

  /// Look up [key] in the active locale, falling back to English, then to
  /// the key itself (so a missing key renders visibly instead of throwing).
  /// `{name}` placeholders in the value are replaced from [args].
  String t(String key, [Map<String, String> args = const {}]) {
    final raw = _catalog[locale]?[key] ?? _catalog[AppLocale.en]?[key] ?? key;
    if (args.isEmpty) return raw;
    return args.entries.fold<String>(
      raw,
      (s, e) => s.replaceAll('{${e.key}}', e.value),
    );
  }
}

const Map<AppLocale, Map<String, String>> _catalog = {
  AppLocale.en: _en,
  AppLocale.zh: _zh,
};

/// English fallback used when a component has no locale wired (tests,
/// previews, or a host that hasn't threaded a [LocaleController]).
const Strings kEnglishStrings = Strings(AppLocale.en);

/// [Strings] provider defaulting to English. Used where a component
/// receives a locale resolver at construction time but the locale may
/// only be knowable later (e.g. [QuitHandler]); the default keeps
/// existing constructions (tests, previews) English-only.
Strings kEnglishStringsFn() => kEnglishStrings;

const Map<String, String> _en = {
  // ── /language command ──
  'lang.unavailable': 'Language service is unavailable',
  'lang.current': 'Current language: {lang}. Usage: /language <en|zh>',
  'lang.unknown': 'Unknown language "{lang}". Available: {list}',
  'lang.switched': 'Language switched to {lang}',
  'lang.persistFailed':
      'Language switched to {lang}, but config could not be saved',

  // ── /reply-language command ──
  'replylang.unavailable': 'Reply-language service is unavailable',
  'replylang.current':
      'Current reply language: {mode}. Usage: /reply-language <follow|auto>',
  'replylang.unknown': 'Unknown reply language "{mode}". Available: {list}',
  'replylang.switched': 'Reply language switched to {mode}',
  'replylang.persistFailed':
      'Reply language switched to {mode}, but config could not be saved',
  'replylang.follow': 'Follow language',
  'replylang.auto': 'Auto',

  // ── Home screen chrome ──
  'home.editing': 'editing',
  'home.noWorkspace': '(no workspace)',
  'home.notGitRepo': 'not a git repo',
  'home.noBranch': '(no branch)',
  'home.fixedSize': 'this box has a fixed size',
  'home.keepOne': 'keep at least one box',
  'home.noHidden': 'no hidden boxes',
  'home.footerEdit': '←→ reorder · -/= resize · x hide · a add · e/esc done',
  'home.footerNav':
      '↑↓ select · ←→ box · tab row · enter open · e edit · esc chat',
  'home.weekdays': 'Mon,Tue,Wed,Thu,Fri,Sat,Sun',
  'home.months': 'Jan,Feb,Mar,Apr,May,Jun,Jul,Aug,Sep,Oct,Nov,Dec',
  'home.date': '{weekday} {month} {day}',

  // ── Day labels ──
  'home.day.today': 'Today',
  'home.day.yesterday': 'Yesterday',
  'home.day.daysAgo': '{n} days ago',

  // ── Relative time ──
  'home.time.now': 'now',
  'home.time.minutes': '{n}m',
  'home.time.hours': '{n}h',
  'home.time.days': '{n}d',
  'home.time.months': '{n}mo',

  // ── Widget titles ──
  'home.title.quickActions': 'Quick actions',
  'home.title.recent': 'Recent',
  'home.title.skills': 'Skills',
  'home.title.workspace': 'Workspace',
  'home.title.notes': 'my notes',
  'home.title.activity': 'Activity',
  'home.title.codingPlan': 'Coding plan',
  'home.title.settings': 'Settings',
  'home.title.git': 'Git',

  // ── Settings rows ──
  'home.settings.theme': 'theme',
  'home.settings.auxiliary': 'auxiliary',
  'home.settings.view': 'view',
  'home.settings.language': 'language',
  'home.settings.replyLanguage': 'reply language',
  'home.settings.openSetup': 'setup',

  // ── Setup guide ──
  'setup.header.exitHint': 'Esc exit setup',

  // ── Quick actions ──
  'home.qa.freshSession': 'start a fresh session',
  'home.qa.chatSession': 'open a Chat-mode session',
  'home.qa.resume': 'resume the last session',
  'home.qa.switchProject': 'switch project…',

  // ── Recent sessions ──
  'home.recent.empty': 'no sessions yet — /new to start',

  // ── Skills ──
  'home.skills.empty': 'no skills found',

  // ── Workspace ──
  'home.ws.dir': 'dir',
  'home.ws.branch': 'branch',
  'home.ws.model': 'model',
  'home.ws.sessions': 'sessions',
  'home.ws.noModel': 'no model — /provider to connect',
  'home.ws.sessionsCount': '{n} in this workspace',
  'home.ws.unknown': '(unknown)',

  // ── Notes ──
  'home.notes.unavailable': 'no notes feature',
  'home.notes.noTodos': 'no todos',
  'home.notes.todo': '{n} todo',
  'home.notes.todos': '{n} todos',
  'home.notes.open': 'open',

  // ── Activity ──
  'home.activity.counting': 'counting tokens…',
  'home.activity.total': 'total',
  'home.activity.less': 'less ',
  'home.activity.more': ' more  ',
  'home.activity.weekdays': 'M,T,W,T,F,S,S',

  // ── Tokens ──
  'home.tokens.loading': 'loading…',
  'home.tokens.noActivity': 'no activity',
  'home.tokens.tokens': 'tokens',
  'home.tokens.turns': 'turns',
  'home.tokens.sessions': 'sessions',
  'home.tokens.models': 'models',

  // ── Yesterday ──
  'home.yesterday.summarizing': 'summarizing {day}…',
  'home.yesterday.nothing': 'nothing {day}',
  'home.yesterday.sessionActive': '{n} session active',
  'home.yesterday.sessionsActive': '{n} sessions active',

  // ── Coding plan ──
  'home.cp.empty': 'no usage data',
  'home.cp.waiting': 'waiting…',
  'home.cp.credit': 'credit',
  'home.cp.window5h': '5h',
  'home.cp.window7d': '7d',

  // ── Git ──
  'home.git.clean': 'clean',
  'home.git.staged': 'staged',
  'home.git.modified': 'modified',
  'home.git.deleted': 'deleted',
  'home.git.untracked': 'untracked',
  'home.git.conflict': 'conflict',

  // ── Command descriptions ──
  'cmd.overlay.title': 'Commands',
  'cmd.model.desc': 'Switch the AI model',
  'cmd.new.desc': 'Create a new session',
  'cmd.chat.desc': 'Start a workspace-free chat (global, minimal prompt)',
  'cmd.session.desc': 'Switch to a session',
  'cmd.compact.desc': 'Compact the context window',
  'cmd.help.desc': 'Show the help sheet (commands, shortcuts, tips)',
  'cmd.home.desc': 'Open the home screen dashboard',
  'cmd.setup.desc': 'Open the launch setup guide',
  'cmd.theme.desc': 'Change the UI theme',
  'cmd.provider.desc':
      'Connect a provider (usage: /provider <name> [<key>|remove])',
  'cmd.webProvider.desc':
      'Configure a web provider: /web-provider (list) | '
      '/web-provider <name> (status) | /web-provider <name> <key> | '
      '/web-provider <name> remove',
  'cmd.think.desc': 'Toggle thinking mode (off|low|normal|adaptive|high|max)',
  'cmd.view.desc': 'Switch chat log display mode (verbose|vibe)',
  'cmd.plan.desc': 'Enter or leave plan mode (split plan doc + chat)',
  'cmd.temperature.desc':
      'Override sampling temperature for the session (clamped 0.0–1.0)',
  'cmd.auxiliary.desc':
      'Select the auxiliary model (for summaries, session names)',
  'cmd.tldr.desc': 'Generate TLDR for the last AI response',
  'cmd.project.desc': 'Switch to a different project directory',
  'cmd.debug.desc': 'Toggle debug commands on/off',
  'cmd.continue.desc': 'Resubmit context so the LLM keeps generating',
  'cmd.retry.desc': 'Re-send the last user input from scratch',
  'cmd.undo.desc': 'Wipe the last round; restore prompt for editing',
  'cmd.btw.desc':
      'Ephemeral side-question — not saved, discarded on next real turn',
  'cmd.archive.desc': 'Archive the current session (hide from sidebar)',
  'cmd.unarchive.desc': 'Unarchive a session by id (restore to sidebar)',
  'cmd.rename.desc': 'Rename the current session',
  'cmd.quit.desc': 'Exit Crux (prints a run summary)',
  'cmd.language.desc': 'Switch the UI language (en|zh)',
  'cmd.replyLanguage.desc': 'Switch the reply language (follow|auto)',

  // ── Toast messages ──
  'toast.noSession': 'No active session',
  'toast.responding': 'AI is already responding',
  'toast.unknownModel': 'Unknown model: {model}',
  'toast.archived': 'Archived "{title}"',
  'toast.auxDisabled': 'Auxiliary model disabled',
  'toast.auxSet': 'Auxiliary model set to {model}',
  'toast.auxUsage': 'Usage: /auxiliary <name>',
  'toast.btwUsage': 'Usage: /btw <prompt>',
  'toast.chatUnavailable': '/chat is not available here',
  'toast.alreadyNewChat': 'Already on a new chat',
  'toast.compactUnavailable': 'Compaction unavailable',
  'toast.nothingContinue': 'Nothing to continue — session is empty',
  'toast.helpWritten': 'Help written to the chat history',
  'toast.homeUnavailable': 'Home screen not available',

  // ── /upgrade command ──
  'cmd.upgrade.desc': 'Download and install the latest release',
  'toast.upgradeChecking': 'Checking for the latest version…',
  'toast.upgradeDone': 'Upgraded to v{version} — restart Crux to run it',
  'toast.upgradeUpToDate': 'Already on the latest version (v{version})',
  'toast.upgradeDevBuild':
      'This is a development build — /upgrade only manages installed '
      'release binaries',
  'toast.upgradeUnsupported':
      'No published build for {target} (published: {published})',
  'toast.upgradeInstallMissing': 'Install directory not found: {directory}',
  'toast.upgradeNotWritable': 'Install directory is not writable: {directory}',
  'toast.upgradeFailed': 'Upgrade failed: {detail}',
  'toast.modelSwitched': 'Model switched to {model}',
  'toast.modelUsage': 'Usage: /model <name>',
  'toast.alreadyNewSession': 'Already on a new session',
  'toast.dirNotFound': 'Directory not found: {path}',
  'toast.switchedProject': 'Switched to {path}',
  'toast.projectUsage': 'Usage: /project <path> (current: {path})',
  'toast.providerList':
      'Providers: {names}. Usage: /provider <name> [<key>|remove]',
  'toast.providerNotFound':
      'Provider "{name}" not found. Available: {names}. To add it, copy '
      '~/.config/crux/providers/example.provider.toml to '
      '~/.config/crux/providers/{name}.toml and edit it.',
  'toast.providerStatus':
      '{name}  [{type}]  endpoint={endpoint}  key={key}  models={models}',
  'toast.keySet': 'set',
  'toast.keyMissing': 'missing',
  'toast.removedKey': 'Removed API key for {name}',
  'toast.savedKey': 'Saved API key for {name}',
  'toast.providerSyncUnsupported':
      'Provider "{name}" does not support sync. Only openrouter-free does.',
  'toast.providerSyncPreview': 'Stealth-model sync preview:\n{diff}\nRun /provider openrouter-free sync confirm to apply.',
  'toast.providerSyncNoPending':
      'No pending sync. Run /provider openrouter-free sync first.',
  'toast.providerSyncApplied':
      'Synced stealth models (+{added} −{removed}) → {path}',
  'toast.providerSyncError': 'Provider sync failed: {error}',
  'sync.warnExpired':
      'EXPIRED: {model} expired {date} — remove it or expect 404s',
  'sync.warnExpiringSoon': '{model} expires {date} (within {days} days)',
  'sync.warnVanished': '{model} is no longer in OpenRouter\'s catalog',
  'sync.remove': 'remove {model} (gone upstream)',
  'sync.add': 'add {model} (ctx {ctx})',
  'sync.keep': 'keep {model} (refreshed)',
  'sync.noChanges': '(no changes — already in sync)',
  'toast.quitRunning': 'A session is running — click the model button to interrupt, Ctrl+C×2 exits',
  'toast.quitUnavailable': 'Quit unavailable (no TUI bound)',
  'toast.renameUsage': 'Usage: /rename <new title>',
  'toast.titleUnchanged': 'Title unchanged',
  'toast.renamed': 'Renamed "{old}" → "{new}"',
  'toast.retryResponding': 'Cannot retry while AI is responding',
  'toast.nothingRetry': 'Nothing to retry — no user message yet',
  'toast.sessionUsage': 'Usage: /session #<id>',
  'toast.tempDefaultNoOverride': 'Temperature: model default (no override set)',
  'toast.tempDefaultWithValue':
      'Temperature: model default {value} (no override set)',
  'toast.tempOverride': 'Temperature: {value} (override; default {default})',
  'toast.tempOverrideNoDefault': 'Temperature: {value} (override)',
  'toast.tempInvalid':
      'Invalid temperature: "{raw}". Usage: /temperature <0.0–1.0>',
  'toast.tempClamped':
      'Temperature set to {value} (clamped from {raw}; range 0.0–1.0)',
  'toast.tempSet':
      'Temperature set to {value} (override; will apply for the session)',
  'toast.themeUnavailable': 'Theme service is unavailable',
  'toast.themeCurrent': 'Current theme: {id}. Usage: /theme <name>',
  'toast.themeUnknown': 'Unknown theme "{id}". Available: {list}',
  'toast.themePersistFailed':
      'Theme switched to {id}, but config could not be saved',
  'toast.themeSwitched': 'Theme switched to {id}',
  'toast.thinkOff': 'Thinking mode: off',
  'toast.thinkLow': 'Thinking mode: low',
  'toast.thinkNormal': 'Thinking mode: {label}',
  'toast.thinkHigh': 'Thinking mode: high',
  'toast.thinkMax': 'Thinking mode: max',
  'toast.thinkUsage': 'Usage: /think {levels} (current: {current})',
  'toast.tldrNoResponse': 'No AI response to summarize',
  'toast.tldrUnknownLevel':
      'Unknown /tldr level "{level}". Use concise, default, or detailed.',
  'toast.sessionNotFound': 'Session #{id} not found',
  'toast.notArchived': 'Session #{id} is not archived',
  'toast.unarchived': 'Unarchived "{title}"',
  'toast.unarchiveUsage': 'Usage: /unarchive #<id>',
  'toast.noArchived': 'No archived sessions',
  'toast.archivedList': 'Archived sessions:',
  'toast.undoResponding': 'Cannot undo while AI is responding',
  'toast.nothingUndo': 'Nothing to undo — no user message yet',
  'toast.undone': 'Undone — edit the prompt and press Enter to resend',
  'toast.displayMode': 'Display mode: {mode}',
  'toast.viewUnknown': 'Unknown mode: "{mode}". Usage: /view <verbose|vibe>',

  // ── Plan mode ──
  'cmd.plan.unavailable': 'Plan mode is unavailable',
  'cmd.plan.entered': 'Plan mode: {path}',
  'cmd.plan.exited': 'Plan mode off',
  'plan.pane.follow': 'follow',
  'plan.pane.free': 'free',
  'plan.pane.jumpToLatest': 'Jump to latest',
  'plan.timeline.head': 'HEAD · v{version}',
  'plan.timeline.viewingVersion': 'viewing v{version} · current v{head}',
  'plan.timeline.revert': 'Revert to this',
  'plan.timeline.empty': 'no versions yet',
  'plan.context.attached': 'plan context attached',
  'plan.pane.approved': 'approved',
  'plan.pane.approve': 'approve',
  'plan.pane.unapprove': 'unapprove',
  'plan.pane.exit': 'exit',
  'cmd.plan.approved': 'Plan approved — codebase edits enabled',
  'cmd.plan.unapproved': 'Plan unapproved — plan-doc editing only',
  'cmd.plan.sug.active': 'active plan',
  'cmd.plan.sug.recent': 'recent plan',
  'cmd.plan.sug.byName': 'name contains "plan"',
  'toast.webNoProviders': 'No web providers registered.',
  'toast.webUnknown': 'Unknown web provider "{id}".{known} Usage: /web-provider <name> <key>|remove',
  'toast.webKnown': ' Known: {list}.',
  'toast.webRemovedKey': 'Removed {name} API key.',
  'toast.webSavedKey': 'Saved {name} API key.',
  'toast.webMissingKey':
      'Missing key value. Usage: /web-provider {id} key <value>',
  'toast.unknownCommand': 'Unknown command: {cmd}',
  'toast.notImplemented': '{cmd} — not yet implemented',

  // ── Parameter suggestion descriptions ──
  'sug.think.off': 'Disable thinking mode',
  'sug.think.low': 'Low reasoning effort',
  'sug.think.normal': 'Normal reasoning effort',
  'sug.think.adaptive': 'Adaptive reasoning (minimax only)',
  'sug.think.high': 'High reasoning effort',
  'sug.think.max': 'Maximum reasoning effort',
  'sug.view.verbose': 'Show all detail (current default)',
  'sug.view.vibe': 'Aggregated metadata boxes (denser)',
  'sug.temp.0.0': 'Fully deterministic',
  'sug.temp.0.3': 'Mostly deterministic',
  'sug.temp.0.7': 'Balanced',
  'sug.temp.1.0': 'Maximum creativity',
  'sug.tldr.concise': 'Fewer bullets, focus on the core message',
  'sug.tldr.default': 'Balanced summary (default if no level is given)',
  'sug.tldr.detailed': 'Thorough summary covering every section',

  // ── Chat chrome ──
  'chat.input.placeholder': 'Type a message...',
  'chat.input.placeholderImages': 'Type message to send with {n} image(s)...',
  'chat.input.ctrlCQuit': 'Press Ctrl+C again to quit...',
  'chat.input.queueHint': 'Enter message to queue — click the model button to interrupt, Ctrl+C×2 to quit',
  'chat.input.interrupted': 'Response was interrupted. Type a new message...',
  'chat.input.paste': 'paste',
  'chat.notes.title': 'my notes',
  'chat.notes.save': 'save',
  'chat.notes.close': 'close',
  'chat.notes.loading': 'loading…',
  'chat.vibe.prevFile': 'prev file',
  'chat.vibe.nextFile': 'next file',
  'chat.vibe.open': 'open',
  'chat.vibe.diff': 'diff',
  'chat.vibe.diffTitle': 'Diff',
  'chat.vibe.noFilesChanged': 'No files changed in this segment.',
  'chat.vibe.noReconstructable': '(no reconstructable changes)',
  'chat.vibe.think': 'think',
  'chat.vibe.tools': 'tools',
  'chat.vibe.files': 'files',
  'chat.bubble.you': 'You',
  'chat.bubble.crux': 'Crux',
  'chat.bubble.think': 'Think',
  'chat.vibe.vibe': 'vibe',
  'chat.vibe.verbose': 'verbose',
  'chat.notes.placeholder': '# my notes\n\n- [ ] a todo…',
  'chat.notes.openTodo': '{n} open todo',
  'chat.notes.openTodos': '{n} open todos',
  'chat.notes.doneCount': '{n} done',
  'chat.notes.saving': 'saving…',
  'chat.notes.unsaved': '● unsaved',
  'chat.notes.saved': '✓ saved',
  'chat.time.justNow': 'just now',
  'chat.time.minutesAgo': '{n}m ago',
  'chat.time.hoursAgo': '{n}h ago',
  'chat.time.daysAgo': '{n}d ago',
  'chat.time.weeksAgo': '{n}w ago',
  'chat.time.monthsAgo': '{n}mo ago',
  'chat.time.yearsAgo': '{n}y ago',
  'chat.time.minutesLongAgo': '{n} minutes ago',
  'chat.time.hoursLongAgo': '{n} hours ago',
  'chat.time.hoursMinutesAgo': '{h} hours {m} minutes ago',
  'chat.time.daysLongAgo': '{d} days ago',
  'chat.time.daysHoursMinutesAgo': '{d} days and {h} hours {m} minutes ago',
  'chat.toolbar.interrupt': 'Interrupt',
  'chat.toolbar.interruptHint': 'Interrupt\n(stop the response · {model})',
  'chat.toolbar.currentModel': 'Current model: {model}\n(click to change)',
  'chat.toolbar.acceptsImages': 'This model accepts image inputs',
  'chat.toolbar.thinkingMode': 'Thinking mode: {label}',
  'chat.toolbar.thinkingHint':
      'Thinking mode: {label}\n(click to cycle through effort levels)',
  'chat.toolbar.throughput':
      'Generation throughput (tokens/sec) and time to first token',
  'chat.toolbar.codingPlanHint': 'Coding-plan usage\n5h: short-window remaining\n1w: weekly remaining\nClick to refresh',
  'chat.toolbar.creditHint': 'Credit balance\nHover for granted / topped-up breakdown\nClick to refresh',
  'chat.toolbar.syncModels': '⟳ sync',
  'chat.toolbar.syncModelsHint': 'Sync the OpenRouter model list against its live catalog\n(stealth previews come and go — this refreshes them)',
  'chat.toolbar.auxRunning': 'Auxiliary model: {model}\n(cannot be changed while the agent is responding)',
  'chat.toolbar.auxIdle': 'Auxiliary model: {model}\n(used for /tldr summaries and title generation)',
  'chat.toolbar.clickRefresh': 'Click to refresh',
  'chat.toolbar.cacheHit': 'cache {pct}%',
  'chat.toolbar.stalled': 'quiet {secs}s',
  'chat.context.compact': 'Compact',
  'chat.context.skillsNone': 'Loaded skills : none',
  'chat.context.skills': 'Loaded skills : {names}',
  'chat.context.compactUnavailable': 'Context window usage.\nCompaction unavailable while the agent is responding.',
  'chat.context.compactAvailable':
      'Context window usage.\nClick to compact the session history.',
  'chat.sessions.sessions': 'Sessions',
  'chat.sessions.chats': 'Chats',
  'chat.sessions.pinned': 'Pinned',
  'chat.sessions.yesterday': 'Yesterday',
  'chat.sessions.threeDays': '3 Days',
  'chat.sessions.archived': 'Archived',
  'chat.sessions.chatsArchived': 'Chats Archived',
  'chat.sessions.newSession': 'New session',
  'chat.sessions.newChat': 'New chat',
  'chat.sessions.archivedCount': '{n} archived',
  'chat.sessions.archivedTag': ' archived ',
  'chat.sessions.mentionHint': '(#-mention a session)',
  'chat.sessions.noMatch': 'No matching sessions. Press Esc to dismiss.',
  'chat.sessions.untitled': 'Untitled',
  'chat.sessions.pinChat': 'Pin chat',
  'chat.sessions.pinSession': 'Pin session',
  'chat.sessions.delete': 'delete',
  'chat.sessions.rename': 'rename',
  'chat.sessions.confirmDelete': 'Confirm Delete',
  'chat.sessions.noSessions': 'No sessions found.',
  'chat.sessions.deleteConfirm':
      'Delete "{title}"? Ctrl+D to confirm, Esc to cancel',
  'chat.sessions.renameTitle': 'Rename Session',
  'chat.sessions.current': 'Current: {title}',
  'chat.sessions.newName': 'New: ',
  'chat.sessions.confirmHint': 'Enter to confirm, Esc to cancel',
  'chat.sessions.status': 'St',
  'chat.sessions.model': 'Model',
  'chat.sessions.title': ' Title',
  'chat.sessions.searchHint': 'type to search all sessions (incl. archived)',
  'chat.sessions.searchNoMatch': 'No sessions match "{query}".',
  'chat.sessions.count': '{n} sessions',
  'chat.sidebar.open': 'open',
  'chat.sidebar.switch': 'switch',
  'chat.sidebar.git': 'git',
  'chat.sidebar.project': 'project',
  'chat.sidebar.aux': 'aux',
  'chat.sidebar.auxHint': 'Auxiliary model\n(used for /tldr summaries and title generation — click to change)',

  // ── Git review fullpane ──
  'chat.gitReview.title': 'Git changes · {branch}',
  'chat.gitReview.all': 'all',
  'chat.gitReview.unstaged': 'unstaged',
  'chat.gitReview.noChanges': 'no changes in this view',
  'chat.gitReview.loading': 'loading changes…',
  'chat.gitReview.file': 'file',
  'chat.gitReview.chunk': 'chunk',
  'chat.gitReview.refresh': 'refresh',
  'chat.gitReview.generate': 'message',
  'chat.gitReview.generateMessage': 'generate message',
  'chat.gitReview.generating': 'generating…',
  'chat.gitReview.copy': 'copy',
  'chat.gitReview.stageFile': 'stage file',
  'chat.gitReview.unstageFile': 'unstage file',
  'chat.gitReview.stageChunk': 'stage chunk',
  'chat.gitReview.unstageChunk': 'unstage chunk',
  'chat.gitReview.resolveInChat': 'resolve in chat',
  'chat.gitReview.before': 'BEFORE',
  'chat.gitReview.after': 'AFTER',
  'chat.gitReview.stagedChanges': 'Staged changes',
  'chat.gitReview.unstagedChanges': 'Unstaged changes',
  'chat.gitReview.changeNumber': 'Change {current} of {total}',
  'chat.gitReview.previewUnavailable': 'Preview unavailable for this file',
  'chat.gitReview.searchFiles': 'Search files…',
  'chat.gitReview.noFilesMatch': 'No files match your search',
  'chat.gitReview.collapseAll': 'Collapse all',
  'chat.gitReview.expandAll': 'Expand all',
  'chat.gitReview.legendModified': 'M modified',
  'chat.gitReview.legendAdded': '+ new',
  'chat.gitReview.legendDeleted': '- deleted',
  'chat.gitReview.legendRenamed': 'R renamed',
  'chat.gitReview.legendUnstaged': '○ unstaged',
  'chat.gitReview.legendStaged': '● staged',
  'chat.gitReview.legendPartial': '◐ partial',
  'chat.gitReview.legendUntracked': '? new',
  'chat.gitReview.legendConflict': '! conflict',
  'chat.gitReview.diffTab': 'Changes',
  'chat.gitReview.commitTab': 'Commit details',
  'chat.gitReview.commitTitle': 'Commit title',
  'chat.gitReview.commitDescription': 'Detailed description',
  'chat.gitReview.noCommitTitle': 'Generate or provide a commit title first',
  'chat.gitReview.noCommitDescription': 'No detailed description',
  'chat.gitReview.stagedReady': '{count} staged files ready for review',
  'chat.gitReview.reviewHint': 'Review the staged diff before committing.',
  'chat.gitReview.commit': 'Commit',
  'chat.gitReview.commitAndPush': 'Commit + Push',
  'chat.gitReview.committing': 'Working…',

  // ── Tool detail pane ──
  'chat.tool.pretty': 'Pretty',
  'chat.tool.raw': 'Raw',
  'chat.tool.changes': 'Changes',
  'chat.tool.old': 'Old',
  'chat.tool.new': 'New',
  'chat.tool.arguments': 'Arguments',
  'chat.tool.result': 'Result',
  'chat.tool.empty': '(empty)',
  'chat.tool.noOutput': '(no output)',
  'chat.tool.noContent': '(no content)',
  'chat.tool.noMatches': '(no matches)',
  'chat.tool.noFiles': '(no files matched)',
  'chat.tool.noArguments': '(no arguments)',
  'chat.tool.noResult': '(no result yet)',
  'chat.tool.noChanges': '(no changes)',
  'chat.tool.andMore': '... and {n} more',
  'chat.tool.inFile': 'in {path}',
  'chat.tool.lsp': 'LSP · {n} {word}',
  'chat.tool.error': 'error',
  'chat.tool.errors': 'errors',
  'error.continue': 'continue (/continue)',

  // ── Fullpane + compaction ──
  'chat.fullpane.skill': 'Skill — {name}',
  'chat.fullpane.compaction': 'Compaction',
  'chat.fullpane.default': 'Fullpane',
  'chat.fullpane.placeholder': 'Fullpane placeholder content',
  'chat.compact.counterproductive':
      'Compaction is not worth it — no history to compact.',
  'chat.compact.saveOnly': 'Compaction would save only {pct}% (≈{tokens} tokens) — below the 5% threshold. Skipping.',
  'chat.compact.failed': 'Compaction failed: {error}',

  // ── Run summary (exit box) ──
  'summary.title': 'Crux Run Summary',
  'summary.duration': 'Duration:',
  'summary.turns': 'Turns:',
  'summary.status': 'Status:',
  'summary.noLlmCalls': 'no LLM calls this run',
  'summary.tokensIn': 'Tokens in:',
  'summary.tokensOut': 'Tokens out:',
  'summary.cacheSuffix': '(cache {pct}%)',
  'summary.cacheSuffixNone': '(cache —)',

  // ── Default (untitled) session / chat titles ──
  // An empty persisted title means "untitled"; these are the
  // locale-aware placeholders the display layer renders for it.
  'session.newPlaceholder': 'New Session',
  'chat.newPlaceholder': 'New Chat',

  // ── Diagram rendering ──
  'diagram.cycleWarning': 'cycle: {nodes}',

  // ── /language option labels (visible in /language <code> suggestions) ──
  'cmd.lang.sug.en': 'English',
  'cmd.lang.sug.zh': '中文',

  // ── /session placeholder suggestions (shown in the autocomplete panel) ──
  'cmd.session.sug.1': 'Build a TUI chat app',
  'cmd.session.sug.2': 'Debug rendering pipeline',
  'cmd.session.sug.3': 'Add markdown support',
  'cmd.session.sug.4': 'Refactor command registry',

  // ── /d-* debug command descriptions ──
  'cmd.d.state.desc': '[debug] Dump current session state',
  'cmd.d.messages.desc': '[debug] Dump all messages in current session',
  'cmd.d.context.desc': '[debug] Dump context window info and token estimates',
  'cmd.d.runtime.desc': '[debug] Dump runtime state (TTFT, tok/s, etc.)',
  'cmd.d.monitor.desc': '[debug] Show recent aux shell-monitor runs',
  'cmd.d.providers.desc': '[debug] List all loaded providers and models',
  'cmd.d.tools.desc': '[debug] List all registered tools',
  'cmd.d.paths.desc':
      '[debug] Print relevant file paths (DB, providers, project)',
  'cmd.d.env.desc': '[debug] Print environment info (Dart version, platform)',
  'cmd.d.toast.desc': '[debug] Display a toast — mode (info/error/status) is auto-detected from the message',
  'cmd.d.fullpane.desc':
      '[debug] Open the fullpane (near-full-screen modal) overlay',
  'cmd.d.profiler.desc': '[debug] Record per-frame timings: /d-profiler <secs> [path], /d-profiler stop',

  // ── URL handling (chat history + chat panel) ──
  'toast.urlRefused': 'Refused to open url: {url}',
  'toast.urlFailed': "Couldn't open url: {url}",

  // ── Chat history: loading progress + empty-state guidance ──
  'chat.history.loadingPct': 'Loading {total} messages… ({pct}%)',
  'chat.history.loadingKnown': 'Loading {total} messages…',
  'chat.history.loadingUnknown': 'Loading messages…',
  'chat.history.emptyWithKey': 'No messages yet.',
  'chat.history.emptyHint': 'Type / for commands, @ to mention files.',
  'chat.history.emptyNoKey': 'No provider configured yet.',
  'chat.history.emptyNoKeyHint': 'Run /provider <name> <key> to connect a model — type / to see all commands.',

  // ── File manager / file system toasts ──
  'toast.dirNotFoundCwd': 'Directory not found: {path}',
  'toast.fileManagerFailed': "Couldn't open file manager for {path}",
  'toast.fileNotFound': 'File not found: {path}',
  'toast.fileManagerGeneric': "Couldn't open file manager",
  'toast.unknownScreen': 'Unknown screen: {screen}',

  // ── Orchestrator-level error / status toasts ──
  'toast.responseInterrupted': 'Response interrupted',
  'toast.previousTurnStillFinishing': 'Previous response is still finishing — text restored, press Enter again to send.',
  'toast.failedStartResponse': 'Failed to start response: {error}',
  'toast.unhandledError': 'Unhandled error: {error}',

  // ── Manual compact toasts (orchestrator) ──
  'toast.compactNoSession': 'No active session',
  'toast.compactWhileResponding': 'Cannot compact while AI is responding',
  'toast.compactInProgress': 'Compacting context...',
  'toast.nothingToCompact': 'Nothing to compact',
  'toast.compactDone': 'Compacted — {n} messages (~{post} ← {pre} tokens)',
  'toast.autoCompactDone':
      'Context was getting full — compacted (~{post} ← {pre} tokens)',

  // ── BTW (side-question) missing-key toasts ──
  'toast.btwMissingKey': 'No API key for provider "{name}". Use /provider {name} to configure an API key, then try again.',
  'toast.btwNoProvider': 'No configured provider serves model "{model}". Use /provider to configure a provider and API key, then try again.',

  // ── Clipboard / image-attach toasts ──
  'toast.clipboardAttached': '📎 Clipboard image attached ({kb} KB). Type your message and press Enter to send.',
  'toast.clipboardEmpty': 'Clipboard is empty or unavailable',
  'toast.clipboardReadFailed': 'Failed to read clipboard: {error}',
  'toast.imageAttached': '📎 Attached: {label} ({kb} KB). Type your message and press Enter to send.',
  'toast.imageAttachFailed': 'Failed to attach image: {error}',
  'toast.imagesUnsupported':
      '🚫 Image not sent: {model} does not accept image input (its provider TOML declares image_support = false). Switch to an image-capable model and paste again — your text was sent.',
  'toast.droppedFileMissing': '⚠️ File(s) not found: {names}',
  'toast.droppedSummary': '📎 Dropped: {summary}',

  // ── Shell monitor toast (human-in-the-loop) ──
  // The verdict is the toast's loudest row: a localized verb sentence
  // plus the raw decision word, e.g.
  //   aux: making progress, next check in 30s (PROGRESS)
  'toast.monitorVerdictLine': 'aux: {verb}',
  'toast.monitorVerb.progress': 'making progress — next check in {secs}s',
  'toast.monitorVerb.stuck': 'stuck after {elapsed} — killing the process',
  'toast.monitorVerb.uncertain': 'uncertain — next check in {secs}s',
  'toast.monitorVerb.evalError': 'aux check failed — process kept running',
  'toast.monitorVerb.fallback': 'aux unavailable — timeout armed',
  'toast.monitorVerb.armed': 'monitoring — first check in {secs}s',
  'toast.monitorKilled': 'Shell killed by user',

  // ── Shell live view (executing row + fullpane) ──
  'shell.live.detail': 'detail',
  'shell.live.title': 'Shell',
  'shell.live.kill': '✕ kill',
  'shell.live.close': 'close',
  'shell.live.running': '● running',
  'shell.live.killed': 'killed',
  'shell.live.exit': 'exit {code}',
  'shell.live.gone': '(run details no longer available)',
  'shell.live.noOutput': '(no output yet)',
  'shell.live.noChecks': '(no aux monitor checks)',
  'shell.live.nextCheck': 'next check {secs}s',

  // ── Ctrl+C quit hint ──
  'toast.ctrlCQuit': 'A session is running. Press Ctrl+C again to quit.',

  // ── TLDR auxiliary-model warning ──
  'toast.tldrNoAux': 'No auxiliary model — set one with /auxiliary',

  // ── Picker overlay headers / empty states ──
  'picker.files.title': 'Files',
  'picker.files.mentionHint': '(@-mention a file)',
  'picker.files.searching': '(@{query})',
  'picker.files.noMatches': '  no matches',
  'picker.skills.title': 'Skills',
  'picker.skills.noMatches': 'No matching skills. Press Esc to dismiss.',

  // ── Wizard overlay chrome ──
  'wizard.step': 'Step {current}/{total}: ',

  // ── Ask form chrome ──
  'ask.chip': ' Ask ',
  'ask.submit': 'Submit',
  'ask.dismiss': 'Dismiss',
  'ask.hint.dismiss': ' Esc: dismiss ',
  'ask.hint.tab': 'Tab: switch region  ',
  'ask.notes': ' Notes: ',
  'ask.notePlaceholder': '(optional) add extra context for the agent',

  // ── Streaming / queued / compaction bubble chips ──
  'bubble.cruxPrefix': ' Crux: ',
  'bubble.waiting': ' (waiting for {secs})',
  'bubble.executing': ' (executing tools for {secs})',
  'bubble.executingFor': ' {preview}executing for {secs}',
  'bubble.compacting': ' Compacting: ',
  'bubble.compactFailed': ' Compact failed: ',
  'bubble.summary': ' Summary: ',
  'bubble.queued': ' ⏳ Queued: ',
  'bubble.queuedCount': '{n} message(s)',
  'bubble.tldrPrefix': ' TLDR: ',
  'bubble.tldrGenerating': 'generating...',

  // ── Compacted session header ──
  'compacted.from': 'Compacted from ',

  // ── Tool detail pane chrome ──
  'tool.label': 'Tool',
  'tool.labelIntent': 'Intent',
  'tool.abortedByCrux': 'Aborted mid-stream by Crux (early abort)',
  'tool.abortedUnknown': 'Aborted mid-stream: unknown tool',
  'tool.abortedUnknownNamed': "Aborted mid-stream: unknown tool '{name}'",
  'tool.pattern': 'Pattern: ',
  'tool.patternInPath': '  in {path}',
  'tool.patternFilter': '  filter: {filter}',
  'tool.url': 'URL: ',
  'tool.unchangedLines': '  {glyph} {n} unchanged lines',
  'tool.guardTriggered': 'Guard triggered',
  'tool.guardReason': 'Guard: {reason}',
  'tool.autoRead': 'Auto-read',
  'tool.autoReadReason': 'Auto-read: {reason}',
  'tool.fileHeaderIntent': '  {intent}',

  // ── Toolbar fixed-temperature chip ──
  'toolbar.fixedTemp.label': 'T:{value} (fixed)',
  'toolbar.fixedTemp.hint': 'Temperature: {value} (fixed by the provider — /temperature has no effect)',

  // ── Activity widget week labels ──
  'activity.weekLabel': 'W{n}  ',

  // ── Clipboard image labels (shown in input row + toast) ──
  'clipboard.png': 'clipboard (PNG)',
  'clipboard.jpeg': 'clipboard (JPEG)',
  'clipboard.tiff': 'clipboard (TIFF)',

  // ── A2UI surfaces (Table row folding) ──
  'surface.table.more': '… {n} more rows — click or press Enter to show',
  'surface.table.less': '… show fewer rows',
};

const Map<String, String> _zh = {
  // ── /language command ──
  'lang.unavailable': '语言服务不可用',
  'lang.current': '当前语言：{lang}。用法：/language <en|zh>',
  'lang.unknown': '未知语言 "{lang}"。可用：{list}',
  'lang.switched': '语言已切换为 {lang}',
  'lang.persistFailed': '语言已切换为 {lang}，但配置保存失败',

  // ── /reply-language command ──
  'replylang.unavailable': '回复语言服务不可用',
  'replylang.current': '当前回复语言：{mode}。用法：/reply-language <follow|auto>',
  'replylang.unknown': '未知回复语言 "{mode}"。可用：{list}',
  'replylang.switched': '回复语言已切换为 {mode}',
  'replylang.persistFailed': '回复语言已切换为 {mode}，但配置保存失败',
  'replylang.follow': '跟随设置语言',
  'replylang.auto': '自动',

  // ── Home screen chrome ──
  'home.editing': '编辑中',
  'home.noWorkspace': '(无工作区)',
  'home.notGitRepo': '非 git 仓库',
  'home.noBranch': '(无分支)',
  'home.fixedSize': '该盒子尺寸固定',
  'home.keepOne': '至少保留一个盒子',
  'home.noHidden': '没有隐藏的盒子',
  'home.footerEdit': '←→ 排序 · -/= 调整大小 · x 隐藏 · a 添加 · e/esc 完成',
  'home.footerNav': '↑↓ 选择 · ←→ 切换盒子 · tab 换行 · enter 打开 · e 编辑 · esc 对话',
  'home.weekdays': '周一,周二,周三,周四,周五,周六,周日',
  'home.months': '1月,2月,3月,4月,5月,6月,7月,8月,9月,10月,11月,12月',
  'home.date': '{month}{day}日 {weekday}',

  // ── Day labels ──
  'home.day.today': '今天',
  'home.day.yesterday': '昨天',
  'home.day.daysAgo': '{n} 天前',

  // ── Relative time ──
  'home.time.now': '刚刚',
  'home.time.minutes': '{n}分钟',
  'home.time.hours': '{n}小时',
  'home.time.days': '{n}天',
  'home.time.months': '{n}个月',

  // ── Widget titles ──
  'home.title.quickActions': '快捷操作',
  'home.title.recent': '最近',
  'home.title.skills': '技能',
  'home.title.workspace': '工作区',
  'home.title.notes': '我的笔记',
  'home.title.activity': '活跃度',
  'home.title.codingPlan': '用量计划',
  'home.title.settings': '设置',
  'home.title.git': 'Git',

  // ── Settings rows ──
  'home.settings.theme': '主题',
  'home.settings.auxiliary': '辅助模型',
  'home.settings.view': '视图',
  'home.settings.language': '语言',
  'home.settings.replyLanguage': '回复语言',
  'home.settings.openSetup': '设置向导',

  // ── 设置向导 ──
  'setup.header.exitHint': 'Esc 退出设置',

  // ── Quick actions ──
  'home.qa.freshSession': '开始新会话',
  'home.qa.chatSession': '打开聊天模式会话',
  'home.qa.resume': '继续上一个会话',
  'home.qa.switchProject': '切换项目…',

  // ── Recent sessions ──
  'home.recent.empty': '暂无会话 — 用 /new 开始',

  // ── Skills ──
  'home.skills.empty': '未找到技能',

  // ── Workspace ──
  'home.ws.dir': '目录',
  'home.ws.branch': '分支',
  'home.ws.model': '模型',
  'home.ws.sessions': '会话',
  'home.ws.noModel': '未配置模型 — 用 /provider 连接',
  'home.ws.sessionsCount': '本工作区 {n} 个',
  'home.ws.unknown': '(未知)',

  // ── Notes ──
  'home.notes.unavailable': '笔记功能不可用',
  'home.notes.noTodos': '暂无待办',
  'home.notes.todo': '{n} 个待办',
  'home.notes.todos': '{n} 个待办',
  'home.notes.open': '打开',

  // ── Activity ──
  'home.activity.counting': '统计 token…',
  'home.activity.total': '总计',
  'home.activity.less': '少 ',
  'home.activity.more': ' 多  ',
  'home.activity.weekdays': '一,二,三,四,五,六,日',

  // ── Tokens ──
  'home.tokens.loading': '加载中…',
  'home.tokens.noActivity': '暂无活动',
  'home.tokens.tokens': 'Token',
  'home.tokens.turns': '轮次',
  'home.tokens.sessions': '会话',
  'home.tokens.models': '模型',

  // ── Yesterday ──
  'home.yesterday.summarizing': '正在总结 {day}…',
  'home.yesterday.nothing': '{day} 无内容',
  'home.yesterday.sessionActive': '{n} 个会话活跃',
  'home.yesterday.sessionsActive': '{n} 个会话活跃',

  // ── Coding plan ──
  'home.cp.empty': '暂无用量数据',
  'home.cp.waiting': '等待中…',
  'home.cp.credit': '余额',
  'home.cp.window5h': '5时',
  'home.cp.window7d': '7天',

  // ── Git ──
  'home.git.clean': '干净',
  'home.git.staged': '已暂存',
  'home.git.modified': '已修改',
  'home.git.deleted': '已删除',
  'home.git.untracked': '未跟踪',
  'home.git.conflict': '冲突',

  // ── Command descriptions ──
  'cmd.overlay.title': '命令',
  'cmd.model.desc': '切换 AI 模型',
  'cmd.new.desc': '新建会话',
  'cmd.chat.desc': '开启无工作区的对话（全局、精简提示词）',
  'cmd.session.desc': '切换会话',
  'cmd.compact.desc': '压缩上下文窗口',
  'cmd.help.desc': '显示帮助（命令、快捷键、技巧）',
  'cmd.home.desc': '打开主页仪表盘',
  'cmd.setup.desc': '打开启动设置向导',
  'cmd.theme.desc': '更换界面主题',
  'cmd.provider.desc': '接入模型提供商（用法：/provider <name> [<key>|remove]）',
  'cmd.webProvider.desc':
      '配置搜索服务：/web-provider (list) | /web-provider <name> (status) | '
      '/web-provider <name> <key> | /web-provider <name> remove',
  'cmd.think.desc': '切换思考模式（off|low|normal|adaptive|high|max）',
  'cmd.view.desc': '切换对话日志显示模式（verbose|vibe）',
  'cmd.temperature.desc': '覆盖本次会话采样温度（限制 0.0–1.0）',
  'cmd.auxiliary.desc': '选择辅助模型（用于摘要、会话命名）',
  'cmd.tldr.desc': '为最后一条 AI 回复生成摘要',
  'cmd.project.desc': '切换到其他项目目录',
  'cmd.debug.desc': '开关调试命令',
  'cmd.continue.desc': '继续生成（重新提交上下文让模型继续）',
  'cmd.retry.desc': '重试（重新发送上一条输入）',
  'cmd.undo.desc': '撤销（抹掉上一轮，恢复提示词供编辑）',
  'cmd.btw.desc': '临时侧问——不保存，下一条真实消息即丢弃',
  'cmd.archive.desc': '归档当前会话（从侧栏隐藏）',
  'cmd.unarchive.desc': '按 id 取消归档会话（恢复到侧栏）',
  'cmd.rename.desc': '重命名当前会话',
  'cmd.quit.desc': '退出 Crux（打印运行摘要）',
  'cmd.language.desc': '切换界面语言（en|zh）',
  'cmd.replyLanguage.desc': '切换回复语言（follow|auto）',

  // ── Toast messages ──
  'toast.noSession': '没有活动会话',
  'toast.responding': 'AI 正在回复中',
  'toast.unknownModel': '未知模型：{model}',
  'toast.archived': '已归档 "{title}"',
  'toast.auxDisabled': '辅助模型已禁用',
  'toast.auxSet': '辅助模型已设为 {model}',
  'toast.auxUsage': '用法：/auxiliary <name>',
  'toast.btwUsage': '用法：/btw <prompt>',
  'toast.chatUnavailable': '此处无法使用 /chat',
  'toast.alreadyNewChat': '已经是新对话了',
  'toast.compactUnavailable': '压缩功能不可用',
  'toast.nothingContinue': '没有可继续的内容——会话为空',
  'toast.helpWritten': '帮助已写入对话历史',
  'toast.homeUnavailable': '主页不可用',

  // ── /upgrade 命令 ──
  'cmd.upgrade.desc': '下载并安装最新版本',
  'toast.upgradeChecking': '正在检查最新版本…',
  'toast.upgradeDone': '已升级到 v{version} —— 重启 Crux 生效',
  'toast.upgradeUpToDate': '已经是最新版本（v{version}）',
  'toast.upgradeDevBuild': '这是开发构建 —— /upgrade 只能管理已安装的发布版二进制',
  'toast.upgradeUnsupported': '没有 {target} 的发布包（已发布：{published}）',
  'toast.upgradeInstallMissing': '找不到安装目录：{directory}',
  'toast.upgradeNotWritable': '安装目录不可写：{directory}',
  'toast.upgradeFailed': '升级失败：{detail}',
  'toast.modelSwitched': '已切换到模型 {model}',
  'toast.modelUsage': '用法：/model <name>',
  'toast.alreadyNewSession': '已经是新会话了',
  'toast.dirNotFound': '目录不存在：{path}',
  'toast.switchedProject': '已切换到 {path}',
  'toast.projectUsage': '用法：/project <path>（当前：{path}）',
  'toast.providerList': '提供商：{names}。用法：/provider <name> [<key>|remove]',
  'toast.providerNotFound':
      '未找到提供商 "{name}"。可用：{names}。要添加它，请复制 '
      '~/.config/crux/providers/example.provider.toml 到 '
      '~/.config/crux/providers/{name}.toml 并编辑。',
  'toast.providerStatus':
      '{name}  [{type}]  endpoint={endpoint}  key={key}  models={models}',
  'toast.keySet': '已设置',
  'toast.keyMissing': '未设置',
  'toast.removedKey': '已移除 {name} 的 API 密钥',
  'toast.savedKey': '已保存 {name} 的 API 密钥',
  'toast.providerSyncUnsupported': '提供商 "{name}" 不支持同步，仅 openrouter-free 支持。',
  'toast.providerSyncPreview':
      'stealth 模型同步预览：\n{diff}\n运行 /provider openrouter-free sync confirm 应用。',
  'toast.providerSyncNoPending':
      '没有待应用的同步。请先运行 /provider openrouter-free sync。',
  'toast.providerSyncApplied': '已同步 stealth 模型（+{added} −{removed}）→ {path}',
  'toast.providerSyncError': '提供商同步失败：{error}',
  'sync.warnExpired': '已过期：{model} 于 {date} 过期——请移除，否则会 404',
  'sync.warnExpiringSoon': '{model} 将于 {date} 过期（{days} 天内）',
  'sync.warnVanished': '{model} 已从 OpenRouter 目录消失',
  'sync.remove': '移除 {model}（上游已下架）',
  'sync.add': '新增 {model}（上下文 {ctx}）',
  'sync.keep': '保留 {model}（已刷新）',
  'sync.noChanges': '（无变化——已是最新）',
  'toast.quitRunning': '有会话正在运行——点击模型按钮中断，Ctrl+C×2 退出',
  'toast.quitUnavailable': '无法退出（未绑定 TUI）',
  'toast.renameUsage': '用法：/rename <新标题>',
  'toast.titleUnchanged': '标题未变',
  'toast.renamed': '已重命名 "{old}" → "{new}"',
  'toast.retryResponding': 'AI 回复中无法重试',
  'toast.nothingRetry': '无可重试的内容——还没有用户消息',
  'toast.sessionUsage': '用法：/session #<id>',
  'toast.tempDefaultNoOverride': '温度：模型默认（未覆盖）',
  'toast.tempDefaultWithValue': '温度：模型默认 {value}（未覆盖）',
  'toast.tempOverride': '温度：{value}（覆盖；默认 {default}）',
  'toast.tempOverrideNoDefault': '温度：{value}（覆盖）',
  'toast.tempInvalid': '无效温度："{raw}"。用法：/temperature <0.0–1.0>',
  'toast.tempClamped': '温度已设为 {value}（从 {raw} 收窄；范围 0.0–1.0）',
  'toast.tempSet': '温度已设为 {value}（覆盖；本次会话生效）',
  'toast.themeUnavailable': '主题服务不可用',
  'toast.themeCurrent': '当前主题：{id}。用法：/theme <name>',
  'toast.themeUnknown': '未知主题 "{id}"。可用：{list}',
  'toast.themePersistFailed': '主题已切换为 {id}，但配置保存失败',
  'toast.themeSwitched': '主题已切换为 {id}',
  'toast.thinkOff': '思考模式：关闭',
  'toast.thinkLow': '思考模式：低',
  'toast.thinkNormal': '思考模式：{label}',
  'toast.thinkHigh': '思考模式：高',
  'toast.thinkMax': '思考模式：最高',
  'toast.thinkUsage': '用法：/think {levels}（当前：{current}）',
  'toast.tldrNoResponse': '没有可总结的 AI 回复',
  'toast.tldrUnknownLevel':
      '未知 /tldr 级别 "{level}"。请用 concise、default 或 detailed。',
  'toast.sessionNotFound': '未找到会话 #{id}',
  'toast.notArchived': '会话 #{id} 未归档',
  'toast.unarchived': '已取消归档 "{title}"',
  'toast.unarchiveUsage': '用法：/unarchive #<id>',
  'toast.noArchived': '没有已归档的会话',
  'toast.archivedList': '已归档会话：',
  'toast.undoResponding': 'AI 回复中无法撤销',
  'toast.nothingUndo': '无可撤销内容——还没有用户消息',
  'toast.undone': '已撤销——编辑提示词后回车重新发送',
  'toast.displayMode': '显示模式：{mode}',
  'toast.viewUnknown': '未知模式："{mode}"。用法：/view <verbose|vibe>',

  // ── Plan mode ──
  'cmd.plan.unavailable': '计划模式不可用',
  'cmd.plan.entered': '计划模式：{path}',
  'cmd.plan.exited': '已退出计划模式',
  'plan.pane.follow': '跟随',
  'plan.pane.free': '浏览',
  'plan.pane.jumpToLatest': '跳到最新',
  'plan.timeline.head': 'HEAD · v{version}',
  'plan.timeline.viewingVersion': '查看 v{version} · 当前 v{head}',
  'plan.timeline.revert': '回退到此版本',
  'plan.timeline.empty': '尚无版本',
  'plan.context.attached': '已附加计划上下文',
  'plan.pane.approved': '已批准',
  'plan.pane.approve': '批准',
  'plan.pane.unapprove': '取消批准',
  'plan.pane.exit': '退出',
  'cmd.plan.approved': '计划已批准——可编辑代码库',
  'cmd.plan.unapproved': '已取消批准——仅可编辑计划文档',
  'cmd.plan.sug.active': '当前计划',
  'cmd.plan.sug.recent': '近期计划',
  'cmd.plan.sug.byName': '名称含 "plan"',
  'toast.webNoProviders': '未注册任何搜索服务。',
  'toast.webUnknown':
      '未知搜索服务 "{id}"。{known} 用法：/web-provider <name> <key>|remove',
  'toast.webKnown': ' 已知：{list}。',
  'toast.webRemovedKey': '已移除 {name} 的 API 密钥。',
  'toast.webSavedKey': '已保存 {name} 的 API 密钥。',
  'toast.webMissingKey': '缺少密钥值。用法：/web-provider {id} key <value>',
  'toast.unknownCommand': '未知命令：{cmd}',
  'toast.notImplemented': '{cmd} — 尚未实现',

  // ── Parameter suggestion descriptions ──
  'sug.think.off': '关闭思考',
  'sug.think.low': '低强度推理',
  'sug.think.normal': '普通推理强度',
  'sug.think.adaptive': '自适应推理（仅 minimax）',
  'sug.think.high': '高强度推理',
  'sug.think.max': '最大推理强度',
  'sug.view.verbose': '显示全部细节（当前默认）',
  'sug.view.vibe': '聚合元数据盒子（更紧凑）',
  'sug.temp.0.0': '完全确定性',
  'sug.temp.0.3': '基本确定性',
  'sug.temp.0.7': '均衡',
  'sug.temp.1.0': '最大创造性',
  'sug.tldr.concise': '更少条目，聚焦核心信息',
  'sug.tldr.default': '均衡摘要（默认）',
  'sug.tldr.detailed': '详尽摘要，覆盖所有部分',

  // ── Chat chrome ──
  'chat.input.placeholder': '输入消息…',
  'chat.input.placeholderImages': '输入消息，随 {n} 张图片发送…',
  'chat.input.ctrlCQuit': '再按一次 Ctrl+C 退出…',
  'chat.input.queueHint': '输入消息排队——点击模型按钮中断，Ctrl+C×2 退出',
  'chat.input.interrupted': '回复已中断。输入新消息…',
  'chat.input.paste': '粘贴',
  'chat.notes.title': '我的笔记',
  'chat.notes.save': '保存',
  'chat.notes.close': '关闭',
  'chat.notes.loading': '加载中…',
  'chat.vibe.prevFile': '上一文件',
  'chat.vibe.nextFile': '下一文件',
  'chat.vibe.open': '打开',
  'chat.vibe.diff': '差异',
  'chat.vibe.diffTitle': '差异',
  'chat.vibe.noFilesChanged': '该片段没有文件变更。',
  'chat.vibe.noReconstructable': '（无可重建的变更）',
  'chat.vibe.think': '思考',
  'chat.vibe.tools': '工具',
  'chat.vibe.files': '文件',
  'chat.bubble.you': '你',
  'chat.bubble.crux': 'Crux',
  'chat.bubble.think': '思考',
  'chat.vibe.vibe': '极简',
  'chat.vibe.verbose': '详细',
  'chat.notes.placeholder': '# 我的笔记\n\n- [ ] 待办事项…',
  'chat.notes.openTodo': '{n} 个待办',
  'chat.notes.openTodos': '{n} 个待办',
  'chat.notes.doneCount': '{n} 个已完成',
  'chat.notes.saving': '保存中…',
  'chat.notes.unsaved': '● 未保存',
  'chat.notes.saved': '✓ 已保存',
  'chat.time.justNow': '刚刚',
  'chat.time.minutesAgo': '{n} 分钟前',
  'chat.time.hoursAgo': '{n} 小时前',
  'chat.time.daysAgo': '{n} 天前',
  'chat.time.weeksAgo': '{n} 周前',
  'chat.time.monthsAgo': '{n} 个月前',
  'chat.time.yearsAgo': '{n} 年前',
  'chat.time.minutesLongAgo': '{n} 分钟前',
  'chat.time.hoursLongAgo': '{n} 小时前',
  'chat.time.hoursMinutesAgo': '{h} 小时 {m} 分钟前',
  'chat.time.daysLongAgo': '{d} 天前',
  'chat.time.daysHoursMinutesAgo': '{d} 天 {h} 小时 {m} 分钟前',
  'chat.toolbar.interrupt': '中断',
  'chat.toolbar.interruptHint': '中断\n（停止回复 · {model}）',
  'chat.toolbar.currentModel': '当前模型：{model}\n（点击切换）',
  'chat.toolbar.acceptsImages': '该模型支持图片输入',
  'chat.toolbar.thinkingMode': '思考模式：{label}',
  'chat.toolbar.thinkingHint': '思考模式：{label}\n（点击循环切换强度）',
  'chat.toolbar.throughput': '生成吞吐（token/秒）与首 token 延迟',
  'chat.toolbar.codingPlanHint': '用量计划\n5时：短窗口剩余\n7天：每周剩余\n点击刷新',
  'chat.toolbar.creditHint': '余额\n悬停查看赠额/充值明细\n点击刷新',
  'chat.toolbar.syncModels': '⟳ 同步',
  'chat.toolbar.syncModelsHint':
      '将 OpenRouter 模型列表与线上目录同步\n（stealth 预览模型来去无常——此操作会刷新它们）',
  'chat.toolbar.auxRunning': '辅助模型：{model}\n（回复过程中无法更改）',
  'chat.toolbar.auxIdle': '辅助模型：{model}\n（用于 /tldr 摘要和标题生成）',
  'chat.toolbar.clickRefresh': '点击刷新',
  'chat.toolbar.cacheHit': '缓存 {pct}%',
  'chat.toolbar.stalled': '无数据 {secs}秒',
  'chat.context.compact': '压缩',
  'chat.context.skillsNone': '已加载技能：无',
  'chat.context.skills': '已加载技能：{names}',
  'chat.context.compactUnavailable': '上下文窗口占用。\n回复过程中无法压缩。',
  'chat.context.compactAvailable': '上下文窗口占用。\n点击压缩会话历史。',
  'chat.sessions.sessions': '会话',
  'chat.sessions.chats': '对话',
  'chat.sessions.pinned': '置顶',
  'chat.sessions.yesterday': '昨天',
  'chat.sessions.threeDays': '3 天',
  'chat.sessions.archived': '已归档',
  'chat.sessions.chatsArchived': '已归档对话',
  'chat.sessions.newSession': '新建会话',
  'chat.sessions.newChat': '新建对话',
  'chat.sessions.archivedCount': '{n} 个已归档',
  'chat.sessions.archivedTag': ' 已归档 ',
  'chat.sessions.mentionHint': '（# 引用一个会话）',
  'chat.sessions.noMatch': '无匹配会话。按 Esc 关闭。',
  'chat.sessions.untitled': '未命名',
  'chat.sessions.pinChat': '置顶对话',
  'chat.sessions.pinSession': '置顶会话',
  'chat.sessions.delete': '删除',
  'chat.sessions.rename': '重命名',
  'chat.sessions.confirmDelete': '确认删除',
  'chat.sessions.noSessions': '未找到会话。',
  'chat.sessions.deleteConfirm': '删除 "{title}"？Ctrl+D 确认，Esc 取消',
  'chat.sessions.renameTitle': '重命名会话',
  'chat.sessions.current': '当前：{title}',
  'chat.sessions.newName': '新名称：',
  'chat.sessions.confirmHint': '回车确认，Esc 取消',
  'chat.sessions.status': '状态',
  'chat.sessions.model': '模型',
  'chat.sessions.title': ' 标题',
  'chat.sessions.searchHint': '输入以搜索全部会话（含已归档）',
  'chat.sessions.searchNoMatch': '没有匹配 "{query}" 的会话。',
  'chat.sessions.count': '{n} 个会话',
  'chat.sidebar.open': '打开',
  'chat.sidebar.switch': '切换',
  'chat.sidebar.git': 'git',
  'chat.sidebar.project': '项目',
  'chat.sidebar.aux': '辅助',
  'chat.sidebar.auxHint': '辅助模型\n（用于 /tldr 摘要和标题生成——点击更改）',

  // ── Git 审查全屏面板 ──
  'chat.gitReview.title': 'Git 改动 · {branch}',
  'chat.gitReview.all': '全部',
  'chat.gitReview.unstaged': '未暂存',
  'chat.gitReview.noChanges': '当前视图没有改动',
  'chat.gitReview.loading': '正在加载改动…',
  'chat.gitReview.file': '文件',
  'chat.gitReview.chunk': '区块',
  'chat.gitReview.refresh': '刷新',
  'chat.gitReview.generate': '提交信息',
  'chat.gitReview.generateMessage': '生成提交信息',
  'chat.gitReview.generating': '正在生成…',
  'chat.gitReview.copy': '复制',
  'chat.gitReview.stageFile': '暂存文件',
  'chat.gitReview.unstageFile': '取消暂存文件',
  'chat.gitReview.stageChunk': '暂存区块',
  'chat.gitReview.unstageChunk': '取消暂存区块',
  'chat.gitReview.resolveInChat': '回到对话中解决冲突',
  'chat.gitReview.before': '改动前',
  'chat.gitReview.after': '改动后',
  'chat.gitReview.stagedChanges': '已暂存的改动',
  'chat.gitReview.unstagedChanges': '未暂存的改动',
  'chat.gitReview.changeNumber': '改动 {current} / {total}',
  'chat.gitReview.previewUnavailable': '暂不支持预览此文件',
  'chat.gitReview.searchFiles': '搜索文件…',
  'chat.gitReview.noFilesMatch': '没有匹配的文件',
  'chat.gitReview.collapseAll': '全部折叠',
  'chat.gitReview.expandAll': '全部展开',
  'chat.gitReview.legendModified': 'M 已修改',
  'chat.gitReview.legendAdded': '+ 新文件',
  'chat.gitReview.legendDeleted': '- 已删除',
  'chat.gitReview.legendRenamed': 'R 已重命名',
  'chat.gitReview.legendUnstaged': '○ 未暂存',
  'chat.gitReview.legendStaged': '● 已暂存',
  'chat.gitReview.legendPartial': '◐ 部分暂存',
  'chat.gitReview.legendUntracked': '? 新文件',
  'chat.gitReview.legendConflict': '! 冲突',
  'chat.gitReview.diffTab': '改动内容',
  'chat.gitReview.commitTab': '提交信息',
  'chat.gitReview.commitTitle': '提交标题',
  'chat.gitReview.commitDescription': '详细说明',
  'chat.gitReview.noCommitTitle': '请先生成或提供提交标题',
  'chat.gitReview.noCommitDescription': '没有详细说明',
  'chat.gitReview.stagedReady': '已暂存 {count} 个文件，等待确认',
  'chat.gitReview.reviewHint': '提交前请先确认已暂存的改动。',
  'chat.gitReview.commit': '提交',
  'chat.gitReview.commitAndPush': '提交并推送',
  'chat.gitReview.committing': '正在执行…',

  // ── Tool detail pane ──
  'chat.tool.pretty': '美观',
  'chat.tool.raw': '原始',
  'chat.tool.changes': '变更',
  'chat.tool.old': '旧',
  'chat.tool.new': '新',
  'chat.tool.arguments': '参数',
  'chat.tool.result': '结果',
  'chat.tool.empty': '（空）',
  'chat.tool.noOutput': '（无输出）',
  'chat.tool.noContent': '（无内容）',
  'chat.tool.noMatches': '（无匹配）',
  'chat.tool.noFiles': '（无匹配文件）',
  'chat.tool.noArguments': '（无参数）',
  'chat.tool.noResult': '（尚无结果）',
  'chat.tool.noChanges': '（无变更）',
  'chat.tool.andMore': '… 还有 {n} 个',
  'chat.tool.inFile': '在 {path} 中',
  'chat.tool.lsp': 'LSP · {n} {word}',
  'chat.tool.error': '错误',
  'chat.tool.errors': '错误',
  'error.continue': '继续 (/continue)',

  // ── Fullpane + compaction ──
  'chat.fullpane.skill': '技能 — {name}',
  'chat.fullpane.compaction': '压缩',
  'chat.fullpane.default': '全屏面板',
  'chat.fullpane.placeholder': '全屏面板占位内容',
  'chat.compact.counterproductive': '无需压缩——没有可压缩的历史。',
  'chat.compact.saveOnly': '压缩只能节省 {pct}%（约 {tokens} token）——低于 5% 阈值，跳过。',
  'chat.compact.failed': '压缩失败：{error}',

  // ── 运行摘要(退出框)──
  'summary.title': 'Crux 运行摘要',
  'summary.duration': '时长：',
  'summary.turns': '轮次：',
  'summary.status': '状态：',
  'summary.noLlmCalls': '本次运行没有 LLM 调用',
  'summary.tokensIn': '输入 token：',
  'summary.tokensOut': '输出 token：',
  'summary.cacheSuffix': '(缓存 {pct}%)',
  'summary.cacheSuffixNone': '(缓存 —)',

  // ── 默认(未命名)会话/对话标题 ──
  'session.newPlaceholder': '新会话',
  'chat.newPlaceholder': '新对话',

  // ── 图表渲染 ──
  'diagram.cycleWarning': '循环：{nodes}',

  // ── /language option labels ──
  'cmd.lang.sug.en': 'English',
  'cmd.lang.sug.zh': '中文',

  // ── /session 占位 suggestion ──
  'cmd.session.sug.1': '构建一个 TUI 聊天应用',
  'cmd.session.sug.2': '调试渲染流水线',
  'cmd.session.sug.3': '添加 Markdown 支持',
  'cmd.session.sug.4': '重构命令注册表',

  // ── /d-* 调试命令描述 ──
  'cmd.d.state.desc': '[调试] 打印当前会话状态',
  'cmd.d.messages.desc': '[调试] 打印当前会话全部消息',
  'cmd.d.context.desc': '[调试] 打印上下文窗口信息与 token 估算',
  'cmd.d.runtime.desc': '[调试] 打印运行时状态（首 token 时延、tok/s 等）',
  'cmd.d.monitor.desc': '[调试] 查看最近的辅助 shell-monitor 运行',
  'cmd.d.providers.desc': '[调试] 列出所有已加载的提供商与模型',
  'cmd.d.tools.desc': '[调试] 列出所有已注册的工具',
  'cmd.d.paths.desc': '[调试] 打印相关文件路径（数据库、提供商、项目）',
  'cmd.d.env.desc': '[调试] 打印环境信息（Dart 版本、平台）',
  'cmd.d.toast.desc': '[调试] 显示一条 toast——根据消息内容自动判断 info/error/status',
  'cmd.d.fullpane.desc': '[调试] 打开 fullpane（近全屏模态）覆盖层',
  'cmd.d.profiler.desc': '[调试] 记录逐帧耗时：/d-profiler <秒数> [路径]，/d-profiler stop',

  // ── URL 处理（chat 历史 + chat 面板） ──
  'toast.urlRefused': '拒绝打开链接：{url}',
  'toast.urlFailed': '无法打开链接：{url}',

  // ── 聊天历史：加载进度 + 空状态引导 ──
  'chat.history.loadingPct': '正在加载 {total} 条消息…（{pct}%）',
  'chat.history.loadingKnown': '正在加载 {total} 条消息…',
  'chat.history.loadingUnknown': '正在加载消息…',
  'chat.history.emptyWithKey': '暂无消息。',
  'chat.history.emptyHint': '输入 / 调用命令，输入 @ 引用文件。',
  'chat.history.emptyNoKey': '尚未配置任何提供商。',
  'chat.history.emptyNoKeyHint': '运行 /provider <名称> <密钥> 接入模型——输入 / 查看所有命令。',

  // ── 文件管理器 / 文件系统 toast ──
  'toast.dirNotFoundCwd': '目录不存在：{path}',
  'toast.fileManagerFailed': '无法为 {path} 打开文件管理器',
  'toast.fileNotFound': '文件不存在：{path}',
  'toast.fileManagerGeneric': '无法打开文件管理器',
  'toast.unknownScreen': '未知页面：{screen}',

  // ── 编排层错误 / 状态 toast ──
  'toast.responseInterrupted': '回复已中断',
  'toast.previousTurnStillFinishing': '上一条回复还在收尾——文本已还原，请再按一次回车发送。',
  'toast.failedStartResponse': '启动回复失败：{error}',
  'toast.unhandledError': '未处理错误：{error}',

  // ── 手动压缩 toast（编排层） ──
  'toast.compactNoSession': '没有活动会话',
  'toast.compactWhileResponding': 'AI 正在回复中，无法压缩',
  'toast.compactInProgress': '正在压缩上下文…',
  'toast.nothingToCompact': '没有可压缩的内容',
  'toast.compactDone': '已压缩 {n} 条消息（约 {post} ← {pre} token）',
  'toast.autoCompactDone': '上下文即将溢出——已自动压缩（约 {post} ← {pre} token）',

  // ── BTW（侧问）缺少密钥 toast ──
  'toast.btwMissingKey': '提供商 "{name}" 未配置 API 密钥。请用 /provider {name} 配置后重试。',
  'toast.btwNoProvider': '没有提供商能为模型 "{model}" 提供服务。请用 /provider 配置提供商和密钥后重试。',

  // ── 剪贴板 / 图片附件 toast ──
  'toast.clipboardAttached': '📎 已附加剪贴板图片（{kb} KB）。输入消息后回车即可发送。',
  'toast.clipboardEmpty': '剪贴板为空或不可用',
  'toast.clipboardReadFailed': '读取剪贴板失败：{error}',
  'toast.imageAttached': '📎 已附加：{label}（{kb} KB）。输入消息后回车即可发送。',
  'toast.imageAttachFailed': '附加图片失败：{error}',
  'toast.imagesUnsupported':
      '🚫 图片未发送：{model} 不支持图片输入（其 provider TOML 里 image_support = false）。请切换到支持图片的模型后重新粘贴——文字已发送。',
  'toast.droppedFileMissing': '⚠️ 找不到以下文件：{names}',
  'toast.droppedSummary': '📎 已拖入：{summary}',

  // ── shell 监控 toast（人在回路） ──
  // verdict 是 toast 上最醒目的一行：本地化动词句 + 原始判定词，如
  //   aux: 运行正常 —— 30s 后再次检查 (PROGRESS)
  'toast.monitorVerdictLine': 'aux：{verb}',
  'toast.monitorVerb.progress': '运行正常 —— {secs}s 后再次检查',
  'toast.monitorVerb.stuck': '疑似卡死（已运行 {elapsed}）—— 正在结束该进程',
  'toast.monitorVerb.uncertain': '无法判断 —— {secs}s 后再次检查',
  'toast.monitorVerb.evalError': '辅助检查失败 —— 进程继续运行',
  'toast.monitorVerb.fallback': '辅助模型不可用 —— 已启用超时兜底',
  'toast.monitorVerb.armed': '开始监控 —— {secs}s 后首次检查',
  'toast.monitorKilled': '用户已杀死 shell 命令',

  // ── shell 实时视图（执行中行 + fullpane） ──
  'shell.live.detail': '详情',
  'shell.live.title': 'Shell',
  'shell.live.kill': '✕ 终止',
  'shell.live.close': '关闭',
  'shell.live.running': '● 运行中',
  'shell.live.killed': '已终止',
  'shell.live.exit': '退出码 {code}',
  'shell.live.gone': '（运行详情已不可用）',
  'shell.live.noOutput': '（暂无输出）',
  'shell.live.noChecks': '（暂无辅助监控检查）',
  'shell.live.nextCheck': '{secs}s 后再次检查',

  // ── Ctrl+C 退出提示 ──
  'toast.ctrlCQuit': '有会话正在运行。再按一次 Ctrl+C 退出。',

  // ── TLDR 缺少辅助模型提示 ──
  'toast.tldrNoAux': '未设置辅助模型——用 /auxiliary 设置一个',

  // ── 选择器覆盖层标题 / 空状态 ──
  'picker.files.title': '文件',
  'picker.files.mentionHint': '（用 @ 引用文件）',
  'picker.files.searching': '（@{query}）',
  'picker.files.noMatches': '  无匹配',
  'picker.skills.title': '技能',
  'picker.skills.noMatches': '无匹配技能。按 Esc 关闭。',

  // ── 向导覆盖层 chrome ──
  'wizard.step': '第 {current}/{total} 步：',

  // ── Ask 表单 chrome ──
  'ask.chip': ' 询问 ',
  'ask.submit': '提交',
  'ask.dismiss': '取消',
  'ask.hint.dismiss': ' Esc：取消 ',
  'ask.hint.tab': 'Tab：切换区域  ',
  'ask.notes': ' 备注：',
  'ask.notePlaceholder': '（可选）为智能体补充上下文',

  // ── 流式 / 排队 / 压缩气泡 chip ──
  'bubble.cruxPrefix': ' Crux：',
  'bubble.waiting': ' （等待 {secs}）',
  'bubble.executing': ' （执行工具 {secs}）',
  'bubble.executingFor': ' {preview}执行中 {secs}',
  'bubble.compacting': ' 压缩中：',
  'bubble.compactFailed': ' 压缩失败：',
  'bubble.summary': ' 摘要：',
  'bubble.queued': ' ⏳ 已排队：',
  'bubble.queuedCount': '{n} 条消息',
  'bubble.tldrPrefix': ' TLDR：',
  'bubble.tldrGenerating': '生成中…',

  // ── 压缩会话头 ──
  'compacted.from': '从以下会话压缩：',

  // ── 工具详情面板 chrome ──
  'tool.label': '工具',
  'tool.labelIntent': '意图',
  'tool.abortedByCrux': '被 Crux 中途中止（early abort）',
  'tool.abortedUnknown': '中途中止：未知工具',
  'tool.abortedUnknownNamed': "中途中止：未知工具 '{name}'",
  'tool.pattern': '模式：',
  'tool.patternInPath': '  路径 {path}',
  'tool.patternFilter': '  过滤：{filter}',
  'tool.url': '链接：',
  'tool.unchangedLines': '  {glyph} {n} 行未变更',
  'tool.guardTriggered': '触发守卫',
  'tool.guardReason': '守卫：{reason}',
  'tool.autoRead': '自动读取',
  'tool.autoReadReason': '自动读取：{reason}',
  'tool.fileHeaderIntent': '  {intent}',

  // ── 工具栏固定温度 chip ──
  'toolbar.fixedTemp.label': 'T:{value}（固定）',
  'toolbar.fixedTemp.hint': '温度：{value}（由提供商固定——/temperature 不生效）',

  // ── 活跃度 widget 周标签 ──
  'activity.weekLabel': 'W{n}  ',

  // ── 剪贴板图片标签（在输入条和 toast 中显示） ──
  'clipboard.png': '剪贴板 (PNG)',
  'clipboard.jpeg': '剪贴板 (JPEG)',
  'clipboard.tiff': '剪贴板 (TIFF)',

  // ── A2UI surface（Table 行折叠） ──
  'surface.table.more': '… 还有 {n} 行 — 点击或回车展开',
  'surface.table.less': '… 收起',
};
