import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/coding_plan_usage.dart';
import '../../models/provider_config.dart';
import '../codex_oauth.dart';
import 'deepseek_provider.dart';
import 'coding_plan_provider.dart';

/// Normalizes both the legacy `/wham/usage` shape and the newer multi-bucket
/// Codex rate-limit shape into Crux's two-window coding-plan display.
///
/// ChatGPT's current response may provide `primary`/`secondary` directly, or
/// put them under `rateLimitsByLimitId` / `additional_rate_limits`. Selecting
/// by window length keeps the five-hour and weekly readouts intact when extra
/// per-model buckets are present.
CodingPlanUsage parseCodexCodingPlanUsage(
  Map<String, dynamic> root, {
  DateTime? now,
}) {
  final fetchedAt = now ?? DateTime.now();
  final windows = <Map<String, dynamic>>[];

  void addWindow(dynamic value) {
    if (value is! Map) return;
    final window = Map<String, dynamic>.from(value);
    if (window['used_percent'] is num || window['usedPercent'] is num) {
      windows.add(window);
    }
  }

  void collect(dynamic value) {
    if (value is List) {
      for (final item in value) {
        collect(item);
      }
      return;
    }
    if (value is! Map) return;
    final map = Map<String, dynamic>.from(value);
    addWindow(map);
    addWindow(map['primary']);
    addWindow(map['secondary']);
    addWindow(map['primary_window']);
    addWindow(map['secondary_window']);
    for (final entry in map.values) {
      if (entry is Map) {
        final nested = Map<String, dynamic>.from(entry);
        addWindow(nested['primary']);
        addWindow(nested['secondary']);
        addWindow(nested['primary_window']);
        addWindow(nested['secondary_window']);
      }
    }
  }

  collect(root['rate_limit']);
  collect(root['rate_limits']);
  collect(root['rateLimits']);
  collect(root['rateLimitsByLimitId']);
  collect(root['additional_rate_limits']);
  if (windows.isEmpty) {
    throw const CodingPlanUsageError(
      CodingPlanUsageErrorKind.parse,
      'Codex usage response has no rate-limit windows',
    );
  }

  int minutes(Map<String, dynamic> window) {
    final value =
        window['window_minutes'] ??
        window['windowMinutes'] ??
        window['windowDurationMins'];
    if (value is num) return value.round();
    final seconds =
        window['limit_window_seconds'] ?? window['limitWindowSeconds'];
    return seconds is num ? (seconds / 60).round() : 0;
  }

  // The short window is normally 300 minutes and the long one is normally a
  // week. Prefer those ranges but retain a useful display for plans with only
  // a single bucket or a different server-defined duration.
  final shortWindows = windows
      .where((window) => minutes(window) > 0 && minutes(window) <= 12 * 60)
      .toList(growable: false);
  final short = shortWindows.fold<Map<String, dynamic>?>(null, (best, window) {
    if (best == null) return window;
    return (minutes(window) - 300).abs() < (minutes(best) - 300).abs()
        ? window
        : best;
  });
  final weeklyWindows = windows
      .where((window) => minutes(window) >= 24 * 60)
      .toList(growable: false);
  final weekly = weeklyWindows.fold<Map<String, dynamic>?>(
    null,
    (best, window) =>
        best == null || minutes(window) > minutes(best) ? window : best,
  );
  // Keep the generic percentage fields populated for callers that predate
  // optional windows, but make visibility explicit. In particular, do not
  // duplicate a weekly-only Codex limit under the misleading "5h" label.
  final fallbackInterval = windows.first;
  final fallbackWeekly = windows.length > 1 ? windows[1] : fallbackInterval;
  final intervalWindow = short ?? weekly ?? fallbackInterval;
  final weeklyWindow = weekly ?? short ?? fallbackWeekly;

  int remaining(Map<String, dynamic> window) =>
      (100 - ((window['used_percent'] ?? window['usedPercent']) as num).round())
          .clamp(0, 100);
  Duration? reset(Map<String, dynamic> window) {
    final seconds =
        window['resets_at'] ??
        window['resetsAt'] ??
        window['reset_at'] ??
        window['resetAt'];
    if (seconds is num) {
      final at = DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);
      return at.difference(fetchedAt).isNegative
          ? Duration.zero
          : at.difference(fetchedAt);
    }
    final after = window['reset_after_seconds'] ?? window['resetAfterSeconds'];
    return after is num ? Duration(seconds: after.round()) : null;
  }

  return CodingPlanUsage(
    providerName: 'codex',
    modelName: 'codex',
    intervalRemainingPct: remaining(intervalWindow),
    weeklyRemainingPct: remaining(weeklyWindow),
    intervalRemains: reset(intervalWindow),
    weeklyRemains: reset(weeklyWindow),
    // Older / workspace-scoped responses can omit duration metadata. In that
    // case retain the legacy two-window presentation rather than hiding the
    // complete usage display. When either duration is known, only show the
    // windows we can identify truthfully.
    hasIntervalWindow: short != null || weekly == null,
    hasWeeklyWindow: weekly != null || short == null,
    fetchedAt: fetchedAt,
  );
}

/// ChatGPT Codex provider.
///
/// This mirrors OpenCode's Codex auth plugin at the HTTP boundary: requests
/// use the OpenAI Responses input-item format but are sent to ChatGPT's Codex
/// backend with an OAuth access token in the normal Bearer slot. The backend
/// does not accept the sampling knobs or caller-selected output cap that the
/// public API accepts, so they are deliberately omitted.
///
/// Configure the current ChatGPT OAuth access token with
/// `/provider codex <token>`. Crux persists it as a provider credential; its
/// normal API-key environment override is `CRUX_API_KEY_CODEX`.
class CodexProvider extends DeepSeekProvider with CodingPlanProvider {
  String? _accountId;

  // A cold `codex app-server` may initialize model/plugin state before it
  // acknowledges its first JSON-RPC call. Ten seconds is routinely too short
  // on a desktop installation even though the actual usage read is quick.
  static const Duration _appServerRequestTimeout = Duration(seconds: 30);

  @override
  String get name => 'codex';

  @override
  WireFamily get wire => WireFamily.responsesApi;

  @override
  AuthStyle get authStyle => AuthStyle.bearer;

  /// Codex reuses DeepSeek's Responses API request implementation, but the
  /// inherited provider also carries DeepSeek's `/user/balance` machinery.
  /// ChatGPT Codex exposes subscription quota windows instead, which this
  /// class surfaces through [CodingPlanProvider]. Keep the credit capability
  /// disabled so the UI never renders a DeepSeek balance cell or polls that
  /// endpoint with a Codex OAuth credential.
  @override
  bool get isCreditBalance => false;

  @override
  String canonicalModelId(String modelId) => switch (modelId) {
    'gpt-5.5-codex' || 'gpt-5.6-codex' => 'gpt-5.6-sol',
    _ => modelId,
  };

  /// Crux's five-level UI maps cleanly to the Responses API's effort names.
  /// `max` maps to the strongest Codex level while preserving compatibility
  /// with models that treat it as an alias for `high`.
  @override
  String mapEffort(String? effort) {
    switch (effort) {
      case 'low':
        return 'low';
      case 'normal':
        return 'medium';
      case 'max':
        return 'xhigh';
      case 'high':
      default:
        return 'high';
    }
  }

  @override
  Map<String, String> requestHeaders({String? userId}) {
    final headers = <String, String>{
      'originator': 'crux',
      'User-Agent': 'crux',
      // Keep a stable identifier across one Crux chat. The standard chat
      // executor supplies its install-scoped session id as `userId`.
      'session-id': userId ?? 'crux-auxiliary',
    };
    final accountId = _accountId;
    if (accountId != null && accountId.isNotEmpty) {
      headers['ChatGPT-Account-Id'] = accountId;
    }
    return headers;
  }

  @override
  Future<String> resolveApiKey(String apiKey) async {
    final credential = CodexCredential.decode(apiKey);
    _accountId =
        credential?.accountId ??
        (credential == null
            ? CodexCredential.extractAccountId(apiKey)
            : CodexCredential.extractAccountId(credential.accessToken));
    if (credential == null ||
        credential.expiresAt.isAfter(
          DateTime.now().add(const Duration(minutes: 2)),
        )) {
      return credential?.accessToken ?? apiKey;
    }
    final refreshed = await CodexOAuth.refresh(
      credential.refreshToken,
      accountId: _accountId,
    );
    final refreshedCredential = CodexCredential.decode(refreshed)!;
    _accountId =
        refreshedCredential.accountId ??
        CodexCredential.extractAccountId(refreshedCredential.accessToken) ??
        _accountId;
    // The provider service persists the encoded credential. A refreshed token
    // remains valid for this request; the next device login replaces storage.
    return refreshedCredential.accessToken;
  }

  String? _credential;

  @override
  void startCodingPlanPolling({
    required String apiKey,
    Duration? interval,
    String? baseUrl,
  }) {
    _credential = apiKey;
    super.startCodingPlanPolling(
      apiKey: apiKey,
      interval: interval,
      baseUrl: baseUrl,
    );
  }

  @override
  void stopCodingPlanPolling() {
    super.stopCodingPlanPolling();
    _credential = null;
  }

  /// ChatGPT exposes Codex subscription limits as used percentages. Convert
  /// the primary window and (when available) secondary window into the
  /// generic CodingPlanUsage surface used by Crux's toolbar and home widget.
  @override
  Future<CodingPlanUsage> getCodingPlanUsage() async {
    final raw = _credential;
    if (raw == null) {
      throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.noApiKey,
        'Codex is not signed in',
      );
    }
    final token = await resolveApiKey(raw);
    final accountId = _accountId;
    if (accountId != null && accountId.isNotEmpty) {
      try {
        final rateLimits = await _readRateLimitsFromAppServer(
          accessToken: token,
          accountId: accountId,
        );
        return parseCodexCodingPlanUsage(rateLimits);
      } on Exception {
        // The CLI can be missing, cold-start too slowly, exit during JSON-RPC
        // initialization, or temporarily reject the external-token login.
        // All of those are recoverable because the account-scoped legacy
        // endpoint exposes the same quota windows. Previously only a missing
        // executable triggered this fallback, which made the plan appear to
        // fail at random depending on app-server startup health.
      }
    }
    return _readRateLimitsFromLegacyEndpoint(token);
  }

  Future<CodingPlanUsage> _readRateLimitsFromLegacyEndpoint(
    String token,
  ) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://chatgpt.com/backend-api/wham/usage'),
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      // Usage is scoped to the same ChatGPT workspace as Responses calls.
      // Omitting ChatGPT-Account-Id here can make this endpoint return a
      // default/empty quota view even though the chat request is correctly
      // rate-limited for the signed-in workspace.
      for (final entry in requestHeaders().entries) {
        request.headers.set(entry.key, entry.value);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw CodingPlanUsageError(
          CodingPlanUsageErrorKind.network,
          'Codex usage request failed (HTTP ${response.statusCode})',
        );
      }
      return parseCodexCodingPlanUsage(
        jsonDecode(body) as Map<String, dynamic>,
      );
    } on TimeoutException {
      throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.network,
        'Codex usage request timed out',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Read the same account-scoped quota view exposed by the current Codex
  /// desktop client. The external-token login avoids touching the user's
  /// existing Codex CLI credential store; this short-lived app-server process
  /// receives only Crux's already-resolved OAuth token.
  Future<Map<String, dynamic>> _readRateLimitsFromAppServer({
    required String accessToken,
    required String accountId,
  }) async {
    Process process;
    try {
      process = await _startCodexAppServer();
    } on ProcessException catch (_) {
      throw const _CodexAppServerUnavailable();
    }

    final pending = <int, Completer<Map<String, dynamic>>>{};
    late final StreamSubscription<String> outputSubscription;
    Future<void> writeMessage(Map<String, dynamic> message) async {
      process.stdin.writeln(jsonEncode(message));
      // `Process.stdin` is an IOSink. Explicitly flushing each JSONL frame is
      // required here: otherwise a cold app-server can remain blocked waiting
      // for `initialize` / `initialized` while Crux waits for its reply.
      await process.stdin.flush();
    }

    Future<Map<String, dynamic>> request(
      int id,
      String method, [
      Map<String, dynamic>? params,
    ]) async {
      final completer = Completer<Map<String, dynamic>>();
      pending[id] = completer;
      final payload = <String, dynamic>{'method': method, 'id': id};
      if (params != null) payload['params'] = params;
      await writeMessage(payload);
      try {
        return await completer.future.timeout(_appServerRequestTimeout);
      } finally {
        // A timed-out future must not remain in [pending]. Completing that
        // orphan again during process cleanup can surface as an unhandled
        // asynchronous error after the legacy fallback has already started.
        pending.remove(id);
      }
    }

    outputSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final message = jsonDecode(line) as Map<String, dynamic>;
            final method = message['method'];
            // An external token may be rejected while the request is in
            // flight. The token was freshly resolved above, so reply with it
            // and let app-server retry the original request as designed.
            if (method == 'account/chatgptAuthTokens/refresh' &&
                message['id'] is int) {
              unawaited(
                writeMessage({
                  'id': message['id'],
                  'result': {
                    'accessToken': accessToken,
                    'chatgptAccountId': accountId,
                  },
                }),
              );
              return;
            }
            final id = message['id'];
            if (id is! int) return;
            final completer = pending.remove(id);
            if (completer == null) return;
            final error = message['error'];
            if (error != null) {
              completer.completeError(
                CodingPlanUsageError(
                  CodingPlanUsageErrorKind.network,
                  'Codex app-server error: $error',
                ),
              );
              return;
            }
            final result = message['result'];
            if (result is! Map) {
              completer.completeError(
                const CodingPlanUsageError(
                  CodingPlanUsageErrorKind.parse,
                  'Codex app-server returned no rate-limit result',
                ),
              );
              return;
            }
            completer.complete(Map<String, dynamic>.from(result));
          } catch (_) {
            // Ignore non-JSON diagnostics; JSON-RPC replies are line-delimited.
          }
        });
    unawaited(
      process.exitCode.then((_) {
        for (final completer in pending.values.toList()) {
          if (!completer.isCompleted) {
            completer.completeError(const _CodexAppServerUnavailable());
          }
        }
        pending.clear();
      }),
    );
    try {
      await request(1, 'initialize', {
        'clientInfo': {'name': 'crux', 'title': 'Crux', 'version': '0.1'},
        'capabilities': {'experimentalApi': true},
      });
      await writeMessage({'method': 'initialized', 'params': {}});
      await request(2, 'account/login/start', {
        'type': 'chatgptAuthTokens',
        'accessToken': accessToken,
        'chatgptAccountId': accountId,
      });
      return await request(3, 'account/rateLimits/read');
    } on TimeoutException {
      throw const CodingPlanUsageError(
        CodingPlanUsageErrorKind.network,
        'Codex app-server rate-limit request timed out',
      );
    } finally {
      for (final completer in pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(const _CodexAppServerUnavailable());
        }
      }
      // Cleanup must never replace a successful quota response with an I/O
      // error when the short-lived child has already exited on its own.
      try {
        await outputSubscription.cancel();
      } catch (_) {}
      try {
        await process.stdin.close();
      } catch (_) {}
      try {
        process.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
  }

  Future<Process> _startCodexAppServer() async {
    final candidates = <String>['codex'];
    // A GUI-launched Crux process does not necessarily inherit the shell PATH
    // where `codex` is installed. Codex Desktop ships its CLI at this default
    // macOS location, so use it as a second, non-invasive lookup.
    const desktopCli = '/Applications/Codex.app/Contents/Resources/codex';
    if (Platform.isMacOS && await File(desktopCli).exists()) {
      candidates.add(desktopCli);
    }
    // A Windows GUI process often does not inherit the interactive shell's
    // PATH. Codex Desktop installs versioned CLI binaries below this folder;
    // discover the newest one so usage polling works regardless of how Crux
    // itself was launched.
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        final binDir = Directory(
          '$localAppData${Platform.pathSeparator}OpenAI'
          '${Platform.pathSeparator}Codex${Platform.pathSeparator}bin',
        );
        if (await binDir.exists()) {
          final installed = <File>[];
          await for (final entry in binDir.list(followLinks: false)) {
            final executable = File(
              '${entry.path}${Platform.pathSeparator}codex.exe',
            );
            if (entry is Directory && await executable.exists()) {
              installed.add(executable);
            }
          }
          installed.sort((a, b) {
            final aModified = a.lastModifiedSync();
            final bModified = b.lastModifiedSync();
            return bModified.compareTo(aModified);
          });
          candidates.addAll(installed.map((file) => file.path));
        }
      }
    }
    for (final executable in candidates) {
      try {
        return await Process.start(executable, ['app-server', '--stdio']);
      } on ProcessException {
        // Try the next known installation location.
      }
    }
    throw const _CodexAppServerUnavailable();
  }

  @override
  Map<String, dynamic> buildRequestBody(
    String modelId,
    List<Map<String, dynamic>> messages, {
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    double temperature = 0,
    double topP = 1.0,
    List<Map<String, dynamic>>? tools,
    String? userId,
  }) {
    final body = super.buildRequestBody(
      modelId,
      messages,
      thinkingMode: thinkingMode,
      reasoningEffort: reasoningEffort,
      thinkingBudget: thinkingBudget,
      maxTokens: maxTokens,
      temperature: temperature,
      topP: topP,
      tools: tools,
      userId: userId,
    );
    // ChatGPT's Codex backend requires stateless Responses requests. This is
    // deliberately Codex-only: public OpenAI API providers retain their own
    // storage policy.
    body['store'] = false;
    body
      ..remove('temperature')
      ..remove('top_p')
      ..remove('max_output_tokens')
      ..remove('user');
    return body;
  }
}

class _CodexAppServerUnavailable implements Exception {
  const _CodexAppServerUnavailable();
}
