import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../commands/command_executor.dart';
import '../commands/registry.dart';
import '../components/ui/toast.dart';
import '../storage/shell_monitor_log_store.dart';
import '../utils/frame_profiler.dart';
import '../utils/terminal_symbols.dart';
import '../utils/user_data_directory.dart';
import '../services/wire_format.dart';

/// Debug commands — only callable when debug mode is enabled.
///
/// Extracted from `CommandExecutor` so the 12 `/d-*` diagnostic commands
/// live in their own file.
class CommandDebug {
  Future<void> executeDebug(List<String> parts, CommandContext ctx) async {
    final registry = CommandRegistry.instance;
    final on = registry.toggleDebug();
    if (on) {
      final count = registry.all.where((c) => c.name.startsWith('/d-')).length;
      ctx.showToast(
        'Debug mode ON — $count debug commands registered',
        mode: ToastMode.status,
      );
    } else {
      ctx.showToast('Debug mode OFF', mode: ToastMode.status);
    }
  }

  Future<void> executeDebugState(CommandContext ctx) async {
    final s = ctx.currentSession;
    final buf = StringBuffer();
    buf.writeln('Session:');
    buf.writeln('  id:              ${s.id}');
    buf.writeln('  title:           ${s.title}');
    buf.writeln('  slug:            ${s.slug}');
    buf.writeln('  status:          ${s.status.name}');
    buf.writeln('  model:           ${s.model}');
    buf.writeln('  agent:           ${s.agent}');
    buf.writeln('  parentId:        ${s.parentId}');
    buf.writeln('  projectPath:     ${s.projectPath}');
    buf.writeln('  tokensIn:        ${s.tokensIn}');
    buf.writeln('  tokensOut:       ${s.tokensOut}');
    buf.writeln('  contextTokens:   ${s.contextTokens}');
    buf.writeln('  ttftMs:          ${s.ttftMs.toStringAsFixed(1)}');
    buf.writeln('  tokPerSec:       ${s.tokPerSec.toStringAsFixed(2)}');
    buf.writeln('  cacheHitTokens:  ${s.promptCacheHitTokens}');
    buf.writeln('  thinkingMode:    ${s.thinkingMode}');
    buf.writeln('  reasoningEffort: ${s.reasoningEffort ?? "—"}');
    buf.writeln('  createdAt:       ${s.createdAt.toIso8601String()}');
    buf.writeln('  updatedAt:       ${s.updatedAt.toIso8601String()}');
    buf.writeln('  archivedAt:      ${s.archivedAt?.toIso8601String() ?? "—"}');
    buf.writeln('  messageCount:    ${ctx.currentMessages.length}');
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugMessages(CommandContext ctx) async {
    if (ctx.currentMessages.isEmpty) {
      ctx.showToast('No messages in current session');
      return;
    }
    final buf = StringBuffer();
    buf.writeln('Messages (${ctx.currentMessages.length}):');
    for (final m in ctx.currentMessages) {
      buf.writeln(
        '  #${m.id} [${m.role}] '
        '${m.model.isEmpty ? "" : "model=${m.model} "}'
        'in=${m.tokensIn} out=${m.tokensOut} '
        'reason=${m.reasoningTokens}t '
        'thinkMs=${m.thinkingDurationMs} '
        'effort=${m.reasoningEffort ?? "—"} '
        'tldr=${m.tldr.isEmpty ? "—" : "\"${_truncate(m.tldr, 30)}\""} '
        'parent=${m.parentMsgId ?? "—"} '
        'toolCallId=${m.toolCallId.isEmpty ? "—" : m.toolCallId} '
        'toolCalls=${m.toolCalls.length} '
        'err=${m.error ?? "—"}',
      );
    }
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugContext(CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    final rt = ctx.runtime(ctx.currentSessionId!);
    final session = ctx.currentSessionId == null
        ? null
        : ctx.sessions.firstWhere(
            (s) => s.id == ctx.currentSessionId,
            orElse: () => ctx.currentSession,
          );
    final buf = StringBuffer();
    buf.writeln('Context:');
    buf.writeln('  session.contextTokens:  ${session?.contextTokens ?? 0}');
    buf.writeln('  session.tokensIn:       ${session?.tokensIn ?? 0}');
    buf.writeln('  session.tokensOut:      ${session?.tokensOut ?? 0}');
    buf.writeln('  turnBaseTokens:         ${rt.turnBaseTokens}');
    buf.writeln('  accumulatedToolTokens:  ${rt.accumulatedToolTokens}');
    buf.writeln('  contextTargetTokens:    ${rt.contextTargetTokens}');
    buf.writeln(
      '  contextDisplayTokens:   ${rt.contextDisplayTokens.toStringAsFixed(0)}',
    );
    buf.writeln(
      '  effectiveStreamingMs:   ${rt.effectiveStreamingMs.toStringAsFixed(1)}',
    );
    buf.writeln(
      '  thinkingDurationMs:     ${rt.thinkingDurationMs.toStringAsFixed(1)}',
    );
    final modelKey = session?.model ?? '';
    final modelEntry = modelKey.isEmpty
        ? null
        : ctx.providerService.modelByCompositeKey(modelKey);
    final contextSize = modelEntry?.contextSize;
    final maxTokens = modelEntry?.maxTokens;
    if (contextSize != null) {
      final threshold = computeCompactionReserveAndThreshold(
        contextSize: contextSize,
      );
      buf.writeln('  modelConfig.contextSize: $contextSize');
      buf.writeln('  modelConfig.maxTokens:   ${maxTokens ?? "—"}');
      buf.writeln('  compaction.reserve:      ${threshold.reserve}');
      buf.writeln('  compaction.threshold:    ${threshold.threshold}');
    } else {
      buf.writeln('  modelConfig.contextSize: (model not resolved)');
    }
    buf.writeln('  turnsSinceLastCompact:   ${rt.turnsSinceLastCompact}');
    buf.writeln('  compactFailures:         ${rt.consecutiveCompactionFailures}');
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugRuntime(CommandContext ctx) async {
    if (ctx.currentSessionId == null) {
      ctx.showToast('No active session', mode: ToastMode.error);
      return;
    }
    final rt = ctx.runtime(ctx.currentSessionId!);
    final buf = StringBuffer();
    buf.writeln('Runtime:');
    buf.writeln('  isResponding:              ${rt.isResponding}');
    buf.writeln('  roundStreaming:            ${rt.roundStreaming}');
    buf.writeln('  ttftMs:                    ${rt.ttftMs.toStringAsFixed(1)}');
    buf.writeln('  ttftReceived:              ${rt.ttftReceived}');
    buf.writeln(
      '  tokPerSec:                 ${rt.tokPerSec.toStringAsFixed(2)}',
    );
    buf.writeln(
      '  tokCount:                  ${rt.tokCount.toStringAsFixed(0)}',
    );
    buf.writeln(
      '  streamingDurationMs:       ${rt.streamingDurationMs.toStringAsFixed(1)}',
    );
    buf.writeln(
      '  cumulativeGenMs:           ${rt.cumulativeGenMs.toStringAsFixed(1)}',
    );
    buf.writeln(
      '  cumulativeCompletionTokens: ${rt.cumulativeCompletionTokens}',
    );
    buf.writeln(
      '  responseStartTime:         ${rt.responseStartTime?.toIso8601String() ?? "—"}',
    );
    buf.writeln(
      '  contentStartTime:          ${rt.contentStartTime?.toIso8601String() ?? "—"}',
    );
    buf.writeln(
      '  firstTokenTime:            ${rt.firstTokenTime?.toIso8601String() ?? "—"}',
    );
    buf.writeln(
      '  roundStartTime:            ${rt.roundStartTime?.toIso8601String() ?? "—"}',
    );
    buf.writeln(
      '  roundFirstTokenTime:       ${rt.roundFirstTokenTime?.toIso8601String() ?? "—"}',
    );
    buf.writeln('  thinkingMode:              ${rt.thinkingMode}');
    buf.writeln('  reasoningEffort:           ${rt.reasoningEffort ?? "—"}');
    buf.writeln('  cacheHitPct:               ${rt.cacheHitPct ?? "—"}');
    buf.writeln('  isGeneratingTldr:          ${rt.isGeneratingTldr}');
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugProviders(CommandContext ctx) async {
    if (!ctx.providerServiceReady) {
      ctx.showToast('ProviderService not ready', mode: ToastMode.error);
      return;
    }
    final buf = StringBuffer();
    buf.writeln('Providers:');
    for (final name in ctx.providerService.providerNames()) {
      final hasKey = ctx.providerService.getApiKey(name) != null;
      buf.writeln('  $name  key=${hasKey ? "set" : "missing"}');
    }
    buf.writeln('Models:');
    for (final entry in ctx.providerService.allModelEntries()) {
      final ctxStr = entry.model.contextSize >= 1000000
          ? '${(entry.model.contextSize / 1048576).toStringAsFixed(0)}M'
          : '${(entry.model.contextSize / 1000).toStringAsFixed(0)}K';
      final img = entry.model.imageSupport ? ', img' : '';
      final think = entry.model.thinking ? ', think' : '';
      buf.writeln('  ${entry.compositeKey}  ($ctxStr ctx$img$think)');
    }
    buf.writeln(
      'Auxiliary model: ${ctx.providerService.auxiliaryModel ?? "—"}',
    );
    buf.writeln('Last used model: ${ctx.providerService.lastUsedModel ?? "—"}');
    buf.writeln('Tldr threshold:  ${ctx.providerService.tldrThreshold}');
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugTools(CommandContext ctx) async {
    ctx.showToast(
      'Tools: see lib/src/tools/. Use /d-paths to locate the providers dir.',
    );
  }

  Future<void> executeDebugPaths(CommandContext ctx) async {
    final dataDir = resolveUserDataDirectory();
    final buf = StringBuffer();
    buf.writeln('Paths:');
    buf.writeln('  projectPath:    ${ctx.projectPath}');
    buf.writeln('  providersDir:   ${ctx.providerService.providersDir}');
    buf.writeln(
      '  builtInProvDir: ${ctx.providerService.builtInProvidersDir ?? "—"}',
    );
    buf.writeln('  authTomlPath:   ${ctx.providerService.authTomlPath}');
    buf.writeln('  authJsonPath:   ${ctx.providerService.authJsonPath}');
    buf.writeln('  dataDir:        $dataDir');
    buf.writeln('  databaseFile:   ${p.join(dataDir, "crux.db")}');
    buf.writeln('  recentProjects: ${p.join(dataDir, "recent_projects.toml")}');
    buf.writeln('  cwd:            ${Directory.current.path}');
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugEnv(CommandContext ctx) async {
    final buf = StringBuffer();
    buf.writeln('Environment:');
    buf.writeln(
      '  platform:      ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
    buf.writeln('  dartVersion:   ${Platform.version}');
    buf.writeln('  numProcessors: ${Platform.numberOfProcessors}');
    buf.writeln('  localeName:    ${Platform.localeName}');
    buf.writeln(
      '  XDG_DATA_HOME: ${Platform.environment['XDG_DATA_HOME'] ?? "—"}',
    );
    buf.writeln('  HOME:          ${Platform.environment['HOME'] ?? "—"}');
    buf.writeln(
      '  PATH (first 80): ${_truncate(Platform.environment['PATH'] ?? "—", 80)}',
    );
    ctx.showToast(buf.toString().trimRight());
  }

  Future<void> executeDebugToast(List<String> parts, CommandContext ctx) async {
    if (parts.length < 2 || parts[1].trim().isEmpty) {
      ctx.showToast('Usage: /d-toast <message>');
      return;
    }
    final message = parts.skip(1).join(' ').trim();
    ctx.showToast(message);
  }

  Future<void> executeDebugFullpane(CommandContext ctx) async {
    if (ctx.showFullpane != null) {
      ctx.showFullpane!();
    } else {
      ctx.showToast('Fullpane not available', mode: ToastMode.error);
    }
  }

  Future<void> executeDebugProfiler(
    List<String> parts,
    CommandContext ctx,
  ) async {
    final profiler = FrameProfiler.instance;
    final first = parts.length > 1 ? parts[1].trim() : '';
    final second = parts.length > 2 ? parts[2].trim() : '';

    if (first.isEmpty) {
      if (!profiler.isRecording) {
        ctx.showToast(
          'Profiler idle. Usage: /d-profiler <secs> [path], '
          '/d-profiler stop',
        );
        return;
      }
      final elapsed = profiler.startedAt == null
          ? 0
          : DateTime.now().difference(profiler.startedAt!).inSeconds;
      final requested = profiler.requestedDuration.inSeconds;
      ctx.showToast(
        'Profiler recording: ${elapsed}s / ${requested}s, '
        '${profiler.capturedFrameCount} frames so far',
      );
      return;
    }

    if (first == 'stop' || first == '--stop') {
      if (!profiler.isRecording) {
        ctx.showToast('Profiler is not recording');
        return;
      }
      final report = profiler.stop();
      final path = second.isEmpty ? _profilerDefaultPath() : second;
      await FrameProfiler.writeReport(path, report);
      _showProfilerSummary(ctx, report, path);
      return;
    }

    final secs = double.tryParse(first);
    if (secs == null || secs <= 0) {
      ctx.showToast(
        'Invalid duration: "$first". Usage: /d-profiler <secs> [path]',
        mode: ToastMode.error,
      );
      return;
    }
    if (profiler.isRecording) {
      ctx.showToast('Profiler is already recording');
      return;
    }

    final path = second.isEmpty ? _profilerDefaultPath() : second;
    final duration = Duration(
      microseconds: (secs * Duration.microsecondsPerSecond).round(),
    );
    ctx.showToast(
      '${terminalSymbol('●', '*')} Profiler recording for '
      '${secs}s → $path',
      mode: ToastMode.status,
    );
    unawaited(
      profiler
          .recordFor(duration, outputPath: path)
          .then((result) {
            _showProfilerSummary(ctx, result.report, result.path);
          })
          .catchError((Object e, StackTrace st) {
            ctx.showToast('Profiler failed: $e', mode: ToastMode.error);
          }),
    );
  }

  static String _profilerDefaultPath() {
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    return p.join(resolveUserDataDirectory(), 'profile-$ts.toml');
  }

  static void _showProfilerSummary(
    CommandContext ctx,
    Map<String, dynamic> report,
    String path,
  ) {
    if (report.containsKey('error')) {
      ctx.showToast('Profiler: ${report['error']}', mode: ToastMode.error);
      return;
    }
    final frames = report['frameCount'] ?? 0;
    final fps = report['observedFps'] ?? '0.00';
    final totals = report['percentilesUs']?['total'] as Map?;
    final p99 = totals?['p99'] ?? 0;
    final maxUs = totals?['max'] ?? 0;
    final byReason = (report['byReason'] as Map?)?.length ?? 0;

    final byLayout = report['byLayout'] as Map?;
    final byType = byLayout?['byType'] as Map?;
    String layoutHotspot = '';
    if (byType != null && byType.isNotEmpty) {
      final first = byType.entries.first;
      final name = first.key;
      final short = name.startsWith('Render') ? name.substring(6) : name;
      final totalUs = (first.value as Map)['totalUs'] ?? 0;
      layoutHotspot = ' layoutHot=$short(${totalUs ~/ 1000}ms)';
    }

    ctx.showToast(
      'Profiler: $frames frames, ${fps}fps, '
      'p99=${p99}us max=${maxUs}us, '
      '$byReason reason(s)$layoutHotspot. Report: $path',
    );
  }

  static String _truncate(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  /// `/d-monitor [n]` — show the last [n] aux shell-monitor runs
  /// (default 5, max 20), newest first. Each run is one monitored
  /// shell command: the run-start event, every per-check verdict the
  /// aux model returned (with its self-chosen next-check interval and
  /// reason), any EVAL_ERROR / FALLBACK the loop recorded, and the
  /// FINISH event with the exit code. Reads `shell_monitor_logs` via
  /// the store wired into [CommandContext.shellMonitorLogStore].
  Future<void> executeDebugMonitor(
    List<String> parts,
    CommandContext ctx,
  ) async {
    final store = ctx.shellMonitorLogStore;
    if (store == null) {
      ctx.showToast(
        'Monitor log unavailable (no database on this context)',
        mode: ToastMode.error,
      );
      return;
    }
    var limit = 5;
    if (parts.length > 1) {
      final parsed = int.tryParse(parts[1]);
      if (parsed == null || parsed <= 0) {
        ctx.showToast(
          'Usage: /d-monitor [n] — n is a positive run count',
          mode: ToastMode.error,
        );
        return;
      }
      limit = parsed.clamp(1, 20);
    }

    final runs = await store.recentRuns(
      sessionId: ctx.currentSessionId,
      limit: limit,
    );
    if (runs.isEmpty) {
      ctx.showToast(
        'No shell-monitor runs logged yet. The monitor only fires on '
        'commands that outlive the first check '
        '(${20}s) with an auxiliary model configured.',
      );
      return;
    }

    final buf = StringBuffer();
    buf.writeln('Shell monitor — last ${runs.length} run(s):');
    for (final run in runs) {
      _renderMonitorRun(buf, run);
    }
    ctx.showToast(buf.toString().trimRight());
  }

  static void _renderMonitorRun(
    StringBuffer buf,
    List<ShellMonitorLogEntry> run,
  ) {
    if (run.isEmpty) return;
    final first = run.first;
    buf.writeln(
      '  run ${first.runId}  ses ${first.sessionId}  '
      '${_fmtTime(first.createdAt)}',
    );
    buf.writeln('    cmd:    ${_truncate(first.command, 120)}');
    if (first.intent.isNotEmpty) {
      buf.writeln('    intent: ${_truncate(first.intent, 120)}');
    }
    for (final e in run) {
      // Skip the run-start marker (checkNumber 0, no verdict) — the
      // header already covers it. Keep every event that carries a
      // verdict, including EVAL_ERROR / FALLBACK / FINISH.
      if (e.checkNumber == 0 && e.verdict == null) continue;
      buf.writeln('    ${_renderMonitorEvent(e)}');
    }
  }

  static String _renderMonitorEvent(ShellMonitorLogEntry e) {
    final t = '+${e.elapsedSeconds}s';
    final verdict = e.verdict ?? '—';
    final interval =
        e.intervalSeconds != null ? ' next=${e.intervalSeconds}s' : '';
    final bytes = e.newOutputBytes != null
        ? ' +${e.newOutputBytes}B (tot ${e.totalOutputBytes ?? 0}B)'
        : '';
    final reason = (e.reason != null && e.reason!.isNotEmpty)
        ? ' — ${_truncate(e.reason!, 80)}'
        : '';
    final check = e.checkNumber > 0 ? '#${e.checkNumber} ' : '';
    return '$t $check$verdict$interval$bytes$reason';
  }

  static String _fmtTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
