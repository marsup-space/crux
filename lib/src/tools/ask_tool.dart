import 'dart:async';

import 'package:bloc/bloc.dart';

import 'tool_def.dart';

/// One selectable option in an [AskGroup]. `value` is what the agent
/// gets back in the serialized prose; `label` is what the user sees.
/// When `value` is empty it defaults to `label` at construction time.
class AskOption {
  final String label;
  final String value;

  AskOption({required this.label, String? value})
    : value = value == null || value.isEmpty ? label : value;

  @override
  bool operator ==(Object other) =>
      other is AskOption && other.label == label && other.value == value;

  @override
  int get hashCode => Object.hash(label, value);
}

/// A group of options under a shared prompt. `multi` selects the row
/// mode: `false` → single-select (radio, at most one pick); `true` →
/// multi-select (checkbox, zero or more picks).
class AskGroup {
  final String name;
  final bool multi;
  final List<AskOption> options;

  const AskGroup({
    required this.name,
    required this.options,
    this.multi = false,
  });

  @override
  bool operator ==(Object other) =>
      other is AskGroup &&
      other.name == name &&
      other.multi == multi &&
      _listEq(other.options, options);

  @override
  int get hashCode => Object.hash(name, multi, Object.hashAll(options));

  static bool _listEq(List<AskOption> a, List<AskOption> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Full declaration the agent emits as the tool-call input. `prompt`
/// is an optional directive shown above the groups.
class AskSpec {
  final String prompt;
  final List<AskGroup> groups;

  const AskSpec({required this.groups, this.prompt = ''});

  @override
  bool operator ==(Object other) =>
      other is AskSpec && other.prompt == prompt && _listEq(other.groups, groups);

  @override
  int get hashCode => Object.hash(prompt, Object.hashAll(groups));

  static bool _listEq(List<AskGroup> a, List<AskGroup> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// In-flight ask, held by [PendingAskRegistry] while [AskTool.execute]
/// awaits the user's response. Resolution comes from the UI: either
/// [complete] with the serialized prose, or [dismiss] with the
/// `(dismissed)` sentinel. Either way the registry drops the entry.
class PendingAsk {
  final int sessionId;
  final String callId;
  final AskSpec spec;
  final Completer<ToolResult> completer;

  PendingAsk({
    required this.sessionId,
    required this.callId,
    required this.spec,
    required this.completer,
  });

  /// Resolve the ask with a serialized prose body. Idempotent.
  void complete(String prose) {
    if (completer.isCompleted) return;
    completer.complete(ToolResult(title: 'Ask', output: prose));
  }

  /// Resolve the ask with the dismiss sentinel. Idempotent.
  void dismiss() {
    if (completer.isCompleted) return;
    completer.complete(ToolResult(title: 'Ask', output: '(dismissed)'));
  }

  /// Abort the ask because the session is closing or the turn is being
  /// cancelled. Resolves with the dismiss sentinel so the awaiting
  /// turn executor still gets a result. Idempotent.
  void abort() => dismiss();
}

/// State for [PendingAskCubit]. Carries the single pending ask for the
/// current session, or null when no form is on screen. At most one ask
/// is pending per session at a time — the turn executor is blocked on
/// it, so a second `ask` call cannot arrive until the first resolves.
class PendingAskState {
  final PendingAsk? pending;

  const PendingAskState({this.pending});

  @override
  bool operator ==(Object other) =>
      other is PendingAskState && other.pending == pending;

  @override
  int get hashCode => pending.hashCode;
}

/// Observable holder for the in-flight ask. The [AskTool] registers a
/// pending ask when the agent calls it; the UI ([AskForm]) reads the
/// state to know whether to render; submit/dismiss from the UI drive
/// `complete` / `dismiss`.
///
/// Single-session-scoped by design: the cubit holds the ask for the
/// *current* session only. Switching sessions while an ask is pending
/// is not supported (the turn is blocked, the agent never switches on
/// its own), and aborting a turn drops the pending ask via [clearFor].
class PendingAskCubit extends Cubit<PendingAskState> {
  PendingAskCubit() : super(const PendingAskState());

  PendingAsk? get pending => state.pending;

  /// Register a new pending ask. Replaces any existing one (shouldn't
  /// happen in normal flow, but is defensive — the previous pending
  /// ask is dimissed first so its completer resolves).
  void register(PendingAsk ask) {
    final prev = state.pending;
    if (prev != null && !prev.completer.isCompleted) {
      prev.dismiss();
    }
    emit(PendingAskState(pending: ask));
  }

  /// Resolve the pending ask with the serialized prose, then drop it.
  void complete(String prose) {
    final p = state.pending;
    if (p == null) return;
    p.complete(prose);
    emit(const PendingAskState());
  }

  /// Resolve the pending ask with the dismiss sentinel, then drop it.
  void dismiss() {
    final p = state.pending;
    if (p == null) return;
    p.dismiss();
    emit(const PendingAskState());
  }

  /// Drop the pending ask for the given session without touching other
  /// sessions' state. Used when a turn is cancelled or the session is
  /// closing. No-op when there's nothing pending (or the pending ask
  /// belongs to a different session).
  void clearFor(int sessionId) {
    final p = state.pending;
    if (p == null || p.sessionId != sessionId) return;
    p.abort();
    emit(const PendingAskState());
  }
}

/// The `ask` tool. When the agent needs a structured multi-part answer
/// from the user — multiple groups of selectable options, multi-select
/// within a group — it calls this tool. The turn pauses, the input box
/// region swaps to an interactive [AskForm], the user picks options
/// (and optionally types a free-text note), and submits. The serialized
/// selection comes back as the tool result.
///
/// For simple yes/no / A/B/C confirmations, the agent should prefer the
/// inline `ask://` quick-reply tokens instead — they're far cheaper
/// (no tool round-trip, no form component). This tool is for the cases
/// `ask://` can't handle: multiple answers at once, multi-select, and
/// structured groups.
class AskTool extends ToolDef {
  final PendingAskCubit pendingAskCubit;

  AskTool({required this.pendingAskCubit});

  @override
  String get name => 'ask';

  @override
  String get description => 'Ask the user a structured multi-part '
      'question with groups of selectable options. Use this when you '
      'need MULTIPLE answers at once (e.g. pick several modules to '
      'refactor AND pick a runtime), or when you need a MULTI-SELECT '
      '(the user can pick more than one option in a group). For simple '
      'yes/no or A/B/C single-choice confirmations, prefer the inline '
      '`ask://label{answer}` quick-reply tokens instead — they are '
      'far cheaper (no tool round-trip, no form). The user can also '
      'type a free-text note alongside their picks. Dismissing the '
      'form cancels the turn entirely (no tool result comes back) — '
      'the user wants to type in the chat box instead.';

  @override
  Map<String, dynamic> get parametersSchema => {
    'type': 'object',
    'required': ['groups'],
    'properties': {
      'prompt': {
        'type': 'string',
        'description': "Optional directive shown above the group(s), "
            "e.g. 'Pick modules to refactor'. Omit when the groups are "
            'self-explanatory.',
      },
      'groups': {
        'type': 'array',
        'minItems': 1,
        'description': 'One or more groups of options. Each group '
            'renders as a labeled row of checkboxes (multi) or radios '
            '(single). The user submits one combined answer for all '
            'groups at once.',
        'items': {
          'type': 'object',
          'required': ['name', 'options'],
          'properties': {
            'name': {
              'type': 'string',
              'description': 'Group heading shown to the user, e.g. '
                  "'modules', 'runtime'. Used as the key in the "
                  'serialized result.',
            },
            'multi': {
              'type': 'boolean',
              'default': false,
              'description': 'true → multi-select (checkbox, zero or '
                  'more picks). false → single-select (radio, at most '
                  'one pick).',
            },
            'options': {
              'type': 'array',
              'minItems': 1,
              'items': {
                'type': 'object',
                'required': ['label'],
                'properties': {
                  'label': {
                    'type': 'string',
                    'description': 'Text the user sees for this option.',
                  },
                  'value': {
                    'type': 'string',
                    'description': 'Value returned in the serialized '
                        'result when this option is picked. Defaults '
                        'to the label when omitted.',
                  },
                },
              },
            },
          },
        },
      },
    },
  };

  @override
  Future<ToolResult> execute(Map<String, dynamic> args, ToolContext ctx) async {
    final spec = parseAskSpec(args);
    if (spec == null) {
      return ToolResult.error(
        'Invalid ask: could not parse groups. Expected an object with '
        'a non-empty "groups" array, each group having a "name" and a '
        'non-empty "options" array.',
      );
    }

    final completer = Completer<ToolResult>();
    final pending = PendingAsk(
      sessionId: ctx.sessionId,
      callId: ctx.callId ?? '',
      spec: spec,
      completer: completer,
    );
    pendingAskCubit.register(pending);

    // Block the turn until the user submits or dismisses the form.
    // Dismiss resolves with the sentinel "(dismissed)" and the agent
    // is told (via system prompt) to treat that as "the user chose to
    // answer free-form instead".
    return completer.future;
  }

  @override
  CollapsedSummary collapsedSummary(
    Map<String, dynamic> args,
    ToolResult result,
  ) {
    final spec = parseAskSpec(args);
    final groupCount = spec?.groups.length ?? 0;
    final optionCount = spec?.groups.fold<int>(
          0,
          (sum, g) => sum + g.options.length,
        ) ??
        0;
    return CollapsedSummary(
      text: 'ask form ($groupCount group${groupCount == 1 ? '' : 's'}, '
          '$optionCount option${optionCount == 1 ? '' : 's'})',
      argsTokens: 0,
      totalTokens: 0,
    );
  }

  @override
  bool get skipInPrune => false;
}

/// Parse the tool-call `args` into an [AskSpec], or return null when
/// the structure is invalid. Defensive: the schema is enforced by the
/// LLM API, but a malformed call still needs a clean error path.
AskSpec? parseAskSpec(Map<String, dynamic> args) {
  final groupsRaw = args['groups'];
  if (groupsRaw is! List || groupsRaw.isEmpty) return null;

  final groups = <AskGroup>[];
  for (final gRaw in groupsRaw) {
    if (gRaw is! Map) return null;
    final name = gRaw['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final optsRaw = gRaw['options'];
    if (optsRaw is! List || optsRaw.isEmpty) return null;

    final options = <AskOption>[];
    for (final oRaw in optsRaw) {
      if (oRaw is! Map) return null;
      final label = oRaw['label'];
      if (label is! String || label.trim().isEmpty) return null;
      final value = oRaw['value'];
      options.add(
        AskOption(
          label: label.trim(),
          value: value is String && value.isNotEmpty ? value.trim() : null,
        ),
      );
    }

    groups.add(
      AskGroup(
        name: name.trim(),
        options: options,
        multi: gRaw['multi'] == true,
      ),
    );
  }

  final prompt = args['prompt'];
  return AskSpec(
    groups: groups,
    prompt: prompt is String ? prompt.trim() : '',
  );
}

/// Serialize the user's selections into the prose form the agent
/// receives as the tool result. Layout:
///
///     [prompt] <prompt text>
///
///     [group1] value1, value2
///     [group2] value3
///
///     [note] <free text>
///
/// - The `[prompt]` line is emitted only when the spec has a prompt.
/// - Each group emits one line. Multi-select values join with ", ".
/// - An empty multi-select still gets a line: `[group] (none)` — so the
///   agent sees explicit "picked nothing," never silence.
/// - Single-select with no pick (possible if the user submits without
///   choosing) emits `[group] (none)` too.
/// - The `[note]` block is emitted only when the note is non-empty.
///   Multi-line notes preserve newlines verbatim.
String serializeAskAnswer(
  AskSpec spec,
  Map<String, List<AskOption>> selections,
  String note,
) {
  final buf = StringBuffer();
  if (spec.prompt.isNotEmpty) {
    buf.writeln('[prompt] ${spec.prompt}');
    buf.writeln();
  }
  for (final group in spec.groups) {
    final picks = selections[group.name] ?? const <AskOption>[];
    if (picks.isEmpty) {
      buf.writeln('[${group.name}] (none)');
    } else {
      buf.writeln('[${group.name}] ${picks.map((o) => o.value).join(', ')}');
    }
  }
  final trimmedNote = note.trim();
  if (trimmedNote.isNotEmpty) {
    buf.writeln();
    buf.writeln('[note] $trimmedNote');
  }
  return buf.toString().trimRight();
}
