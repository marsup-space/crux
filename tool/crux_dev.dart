// Hot-reload dev harness for Crux UI work.
//
// Runs a Crux component fullscreen in a real terminal, with nocterm's
// file-watching hot reload active, so an agent (or you) can edit
// lib/src/components/... and see the result in place without a
// quit/relaunch cycle.
//
// Usage (in a spare terminal next to the agent's):
//
//   dart --enable-vm-service tool/crux_dev.dart home [--size WxH] [--stubs]
//
// Targets:
//   home    The home screen, live: real git service (pushed refresh),
//           Directory.current as the workspace, the five built-in boxes.
//           esc exits the harness (there is no chat behind it).
//
// Flags:
//   --size WxH   Start with a fake terminal size (e.g. --size 100x30)
//                to test grid reflow; removed on the first real resize.
//   --stubs      Fill the grid with StubHomeWidgets instead of the
//                built-ins, for pure layout work.
//
// Hot reload notes:
// - `--enable-vm-service` is required; without it nocterm's
//   HotReloadBinding logs a refusal to .dart_tool/nocterm_hot_reload.log
//   and just runs statically.
// - nocterm watches bin/, lib/, test/ and example/ relative to the CWD,
//   so launch from the repo root (package_config.json must be there —
//   that's also why this lives in tool/: `dart run` resolves the
//   project root from the entrypoint's location).
// - nocterm performs a full reassemble after each reload: State objects
//   are preserved but build() runs again from the root, so one-shot
//   service kick-offs belong in initState (as usual), not build.
// - tool/ itself is NOT watched; editing this file means restarting.

import 'dart:io';

import 'package:nocterm/nocterm.dart';

import 'package:crux/src/components/chat_panel.dart' show loadChatPanelBootState;
import 'package:crux/src/components/home/home_screen.dart';
import 'package:crux/src/components/home/home_widgets.dart';
import 'package:crux/src/services/skills/skill.dart';
import 'package:crux/src/components/home/widgets/stub_widget.dart';
import 'package:crux/src/services/auxiliary_service.dart';
import 'package:crux/src/models/session.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/theme/crux_theme.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  var target = 'home';
  Size? fakeSize;
  var stubs = false;
  var live = false;

  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--stubs') {
      stubs = true;
    } else if (arg == '--live') {
      live = true;
    } else if (arg == '--size' && i + 1 < args.length) {
      fakeSize = _parseSize(args[++i]);
      if (fakeSize == null) {
        stderr.writeln('Invalid --size "${args[i]}" (want WxH, e.g. 100x30)');
        exit(64);
      }
    } else if (arg.startsWith('-')) {
      stderr.writeln('Unknown flag: $arg');
      exit(64);
    } else {
      rest.add(arg);
    }
  }
  if (rest.isNotEmpty) target = rest.first;

  if (target != 'home') {
    stderr.writeln('Unknown target "$target" — only "home" exists for now.');
    exit(64);
  }

  final git = GitStatusService();
  // Push liveness: refresh now and keep polling, so the git box and the
  // hero branch line update while you iterate (matching how the real
  // app's boxes behave). Widgets that listen via addListener rebuild
  // without a hot reload too.
  git.start();

  final base = HomeContext.minimal(
    close: () => shutdownApp(),
  );

  HomeContext context;
  if (live) {
    // Live mode: real sessions + a real auxiliary summarizer, so the
    // Yesterday box exercises its LLM path instead of the static
    // fallback. Loads the same boot state the real panel uses (sessions
    // for this workspace), then wires an AuxiliaryService over the real
    // provider config / message store. Needs an auxiliary model
    // configured (`/auxiliary` in the real app); without one the box
    // falls back to the session list exactly as it does in production.
    // Mirror bin/crux.dart: user providers in ~/.config/crux/providers,
    // built-ins in the repo's providers/ dir. The built-in dir is where
    // the real providers (zhipu, deepseek, kimi, …) live — without it the
    // auxiliary model can't resolve and the Yesterday box always falls
    // back. API keys + auxiliaryModel come from the user-data auth.toml.
    final userProvidersDir = p.join(_home(), '.config', 'crux', 'providers');
    final builtInDir = p.join(Directory.current.path, 'providers');
    final boot = await loadChatPanelBootState(
      userProvidersDir: userProvidersDir,
      builtInProvidersDir: Directory(builtInDir).existsSync() ? builtInDir : null,
    );
    final aux = AuxiliaryService(boot.providerService, boot.store.messageStore);
    final sessions = [...boot.sessions, ...boot.chats]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    context = base.copyWithDev(
      gitStatusService: git,
      projectPath: Directory.current.path,
      sessions: () => sessions,
      currentSessionId: () => boot.currentSessionId,
      activeModel: () {
        final id = boot.currentSessionId;
        for (final s in sessions) {
          if (s.id == id) return s.model.isEmpty ? null : s.model;
        }
        return null;
      },
      summarizeYesterday: aux.summarizeYesterday,
    );
  } else {
    context = base.copyWithDev(
      gitStatusService: git,
      projectPath: Directory.current.path,
    );
  }

  await runApp(
    _DevApp(
      fakeSize: fakeSize,
      child: CruxTheme(
        data: CruxThemeData.draculaFallback,
        child: HomeScreen(
          onExit: () => shutdownApp(),
          context_: context,
          widgets: stubs ? _stubWidgets() : null,
          // quitApp: null on purpose — home's Ctrl+C falls back to
          // nocterm's default immediate exit, which is what a throwaway
          // dev process wants. esc/q go through [onExit] → shutdownApp.
        ),
      ),
    ),
  );
}

/// The built-ins as the real home screen would create them, but with
/// stubs — see [HomeScreen]'s `_defaultWidgets`.
List<HomeWidget> _stubWidgets() => [
  StubHomeWidget('alpha'),
  StubHomeWidget('beta'),
  StubHomeWidget('gamma', supportedSpans: const {1}),
  StubHomeWidget('delta', supportedSpans: const {1}),
  StubHomeWidget('epsilon'),
];

Size? _parseSize(String s) {
  final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(s);
  if (m == null) return null;
  return Size(
    double.parse(m.group(1)!),
    double.parse(m.group(2)!),
  );
}

/// The user's home directory (for locating `~/.config/crux/providers`).
String _home() =>
    Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';

extension on HomeContext {
  /// HomeContext has no copyWith; the harness overrides the live fields
  /// on top of [HomeContext.minimal]. Null args keep the base value.
  HomeContext copyWithDev({
    GitStatusService? gitStatusService,
    String? projectPath,
    List<Session> Function()? sessions,
    int? Function()? currentSessionId,
    String? Function()? activeModel,
    Future<String?> Function(List<Session>)? summarizeYesterday,
    void Function(SkillInfo)? showSkill,
  }) {
    return HomeContext(
      runCommand: runCommand,
      close: close,
      seedInput: seedInput,
      gitStatusService: gitStatusService ?? this.gitStatusService,
      sessions: sessions ?? this.sessions,
      currentSessionId: currentSessionId ?? this.currentSessionId,
      switchSession: switchSession,
      projectPath: projectPath ?? this.projectPath,
      activeModel: activeModel ?? this.activeModel,
      summarizeYesterday: summarizeYesterday ?? this.summarizeYesterday,
      showSkill: showSkill ?? this.showSkill,
    );
  }
}

/// Root component: theme is provided by the caller's [child]; this just
/// applies the optional fake-size wrapper.
class _DevApp extends StatelessComponent {
  final Size? fakeSize;
  final Component child;

  const _DevApp({this.fakeSize, required this.child});

  @override
  Component build(BuildContext context) {
    var content = child;
    final size = fakeSize;
    if (size != null) {
      // Fixed-size window into the app: lets a wide real terminal
      // pretend to be narrow so grid reflow is testable. Overflow is
      // clipped by the container bounds.
      content = Container(
        width: size.width,
        height: size.height,
        child: content,
      );
    }
    return NoctermApp(title: 'Crux Dev — home', child: content);
  }
}
