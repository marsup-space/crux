// Base class for LSP server actors.
//
// Each concrete actor (e.g. DartServerActor, TypescriptServerActor) owns:
//   - A LspServerSpec resolved from the manager's request
//   - A Process spawned from that spec
//   - An peer_lib.RpcPeer wrapping the process's stdin/stdout
//   - A set of standard JSON-RPC handlers (publishDiagnostics, etc.)
//
// The actor exposes a fire-and-forget command interface via [handle]
// and emits events via [emit]. Concrete subclasses implement [resolveSpec]
// to provide the server-specific bits (binary path, init options, etc.).
//
// Lifecycle (run by the actor's host, not by the actor itself):
//   1. new instance via factory
//   2. attach(emit)
//   3. handle(LspCmdStart(root, file))  → spec → spawn → initialize
//   4. handle(LspCmdOpenDocument(...)) repeatedly
//   5. handle(LspCmdShutdownRoot) or LspCmdShutdown
//
// All of the above runs inside whatever isolate the host uses. The
// [channel.dart] layer decides whether the actor is in the main
// isolate (InProcessChannel) or its own isolate (IsolateChannel).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'peer.dart' as peer_lib;
import 'protocol.dart';

/// Abstract base class for LSP server actors.
///
/// Subclasses override [id], [extensions], [bareFilenames], [resolveSpec],
/// and optionally [registerHandlers] (call `super.registerHandlers(peer)`
/// first to keep the standard set).
abstract class LspServerActor {
  /// Stable identifier (e.g. "dart", "typescript", "rust").
  String get id;

  /// File extensions this server handles (e.g. ['.ts', '.tsx']).
  /// Empty means "no extension-based matching".
  List<String> get extensions => const [];

  /// Bare filenames this server handles (e.g. ['Dockerfile']).
  /// Used for files that have no extension.
  List<String> get bareFilenames => const [];

  /// Resolve the server spec for the given file + root. Return null
  /// if the binary is missing or the file isn't in a project this
  /// server handles — the manager will record the (serverId, root)
  /// pair in its broken set and skip future requests.
  Future<LspServerSpec?> resolveSpec(String root, String file);

  /// Register server-specific JSON-RPC handlers. Called after
  /// `initialize` succeeds. The default registers the standard set
  /// Crux needs for diagnostics. Override and call `super` to extend.
  void registerHandlers(peer_lib.RpcPeer peer) {
    _registerStandardHandlers(peer);
  }

  // ---------------------------------------------------------------------------
  // Framework state — subclasses don't touch this.
  // ---------------------------------------------------------------------------

  void Function(LspEvent)? _emit;
  final Map<String, _ActiveServer> _servers = {};
  bool _shutdown = false;
  bool _attached = false;

  /// Called once by the host (channel) after construction. Wires the
  /// actor's outbound events to whatever the host provides (in-process
  /// stream controller for InProcessChannel, SendPort for IsolateChannel).
  void attach(void Function(LspEvent) emit) {
    if (_attached) {
      throw StateError('[$id] actor already attached');
    }
    _attached = true;
    _emit = emit;
  }

  /// Top-level command dispatcher. The host calls this for each
  /// incoming [LspCommand]. Fire-and-forget; outputs are emitted as
  /// [LspEvent]s via the [attach] callback.
  Future<void> handle(LspCommand cmd) async {
    if (_shutdown && cmd is! LspCmdShutdown) return;
    switch (cmd) {
      case LspCmdStart():
        await _runStart(cmd.root, cmd.file);
      case LspCmdOpenDocument():
        await _runOpenDocument(
          cmd.root,
          cmd.path,
          cmd.content,
          cmd.version,
        );
      case LspCmdCloseDocument():
        await _runCloseDocument(cmd.root, cmd.path);
      case LspCmdShutdownRoot():
        await _runShutdownRoot(cmd.root);
      case LspCmdShutdown():
        await _runShutdownAll();
    }
  }

  // ---------------------------------------------------------------------------
  // Command handlers — run inside the actor's isolate.
  // ---------------------------------------------------------------------------

  Future<void> _runStart(String root, String file) async {
    if (_servers.containsKey(root)) return;     // idempotent
    if (_shutdown) return;

    final LspServerSpec? spec;
    try {
      spec = await resolveSpec(root, file);
    } catch (e) {
      _emit?.call(LspEventStartFailed(
        root: root,
        serverId: id,
        reason: 'resolveSpec threw: $e',
      ));
      return;
    }
    if (spec == null) {
      _emit?.call(LspEventStartFailed(
        root: root,
        serverId: id,
        reason: 'resolveSpec returned null (binary missing or unsupported file)',
      ));
      return;
    }

    Process process;
    try {
      process = await _spawnProcess(spec);
    } catch (e) {
      _emit?.call(LspEventStartFailed(
        root: root,
        serverId: id,
        reason: 'Process.start failed: $e',
      ));
      return;
    }

    _wireStderr(process, root);

    final peer = peer_lib.RpcPeer.create(
      input: process.stdout,
      output: process.stdin,
      tag: '$id:$root',
      onFatal: (e, st) {
        _emit?.call(LspEventRpcFatal(
          root: root,
          serverId: id,
          reason: e.toString(),
        ));
      },
    );

    try {
      await peer.request('initialize', _buildInitializeParams(root, spec));
      peer.notify('initialized', spec.initialization);
      registerHandlers(peer);
    } catch (e) {
      await _cleanupDeadServer(process, peer);
      _emit?.call(LspEventStartFailed(
        root: root,
        serverId: id,
        reason: 'initialize failed: $e',
      ));
      return;
    }

    _servers[root] = _ActiveServer(
      process: process,
      peer: peer,
      spec: spec,
      documents: {},
    );

    _emit?.call(LspEventStarted(root: root, serverId: id));

    process.exitCode.then((code) {
      _servers.remove(root);
      _emit?.call(LspEventProcessExited(
        root: root,
        serverId: id,
        exitCode: code,
      ));
    });
  }

  Future<void> _runOpenDocument(
    String root,
    String path,
    String content,
    int version,
  ) async {
    final server = _servers[root];
    if (server == null) return;
    final ext = p.extension(path);
    final languageId = _languageIdFor(ext);
    server.peer.notify('textDocument/didOpen', {
      'textDocument': {
        'uri': Uri.file(path).toString(),
        'languageId': languageId,
        'version': version,
        'text': content,
      },
    });
    server.documents[path] = version;
  }

  Future<void> _runCloseDocument(String root, String path) async {
    final server = _servers[root];
    if (server == null) return;
    if (server.documents.remove(path) == null) return;
    server.peer.notify('textDocument/didClose', {
      'textDocument': {'uri': Uri.file(path).toString()},
    });
  }

  Future<void> _runShutdownRoot(String? root) async {
    if (root == null) {
      final all = _servers.keys.toList();
      for (final r in all) {
        await _shutdownServer(r);
      }
    } else {
      await _shutdownServer(root);
    }
  }

  Future<void> _runShutdownAll() async {
    _shutdown = true;
    final roots = _servers.keys.toList();
    for (final r in roots) {
      await _shutdownServer(r);
    }
  }

  Future<void> _shutdownServer(String root) async {
    final server = _servers.remove(root);
    if (server == null) return;
    try {
      await server.peer.request('shutdown')
          .timeout(const Duration(seconds: 2));
      server.peer.notify('exit');
    } catch (_) {
      // Server probably already dead; ignore.
    }
    server.peer.cancelAll(peer_lib.ShuttingDown('$id:$root'));
    // Give the process a moment to exit cleanly; then signal.
    unawaited(_killAfter(server.process, const Duration(seconds: 1)));
  }

  Future<void> _killAfter(Process process, Duration grace) async {
    try {
      await process.exitCode.timeout(grace);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
    } catch (_) {
      // Already exited.
    }
  }

  Future<void> _cleanupDeadServer(Process process, peer_lib.RpcPeer peer) async {
    try {
      peer.cancelAll(const peer_lib.ShuttingDown('cleanup'));
      process.kill(ProcessSignal.sigterm);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Standard JSON-RPC handlers — registered by default.
  // ---------------------------------------------------------------------------

  void _registerStandardHandlers(peer_lib.RpcPeer peer) {
    peer.onNotification('textDocument/publishDiagnostics', (params) {
      final uri = params['uri'] as String?;
      if (uri == null) return;
      final path = Uri.parse(uri).toFilePath();
      final diagnostics = (params['diagnostics'] as List? ?? [])
          .whereType<Map>()
          .map((m) => LspDiagnostic.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false);
      final batch = DiagnosticBatch(
        path: path,
        version: params['version'] as int?,
        diagnostics: diagnostics,
        receivedAt: DateTime.now(),
      );
      // Find which root this document belongs to.
      final root = _findRootForPath(path);
      if (root == null) return;
      _emit?.call(LspEventDiagnostics(
        root: root,
        serverId: id,
        batch: batch,
      ));
    });
    peer.onRequest('workspace/configuration', (params) async {
      final items = (params['items'] as List? ?? []);
      // Per server spec, return null for each requested section.
      // Servers interpret null as "use default".
      return <String, dynamic>{
        'items': List<dynamic>.filled(items.length, null),
      };
    });
    peer.onRequest('workspace/workspaceFolders', (_) async {
      return <String, dynamic>{
        'folders': _servers.keys.map((r) {
          return <String, dynamic>{
            'uri': Uri.file(r).toString(),
            'name': p.basename(r),
          };
        }).toList(),
      };
    });
    peer.onRequest('window/workDoneProgress/create', (_) async {
      return const <String, dynamic>{};
    });
    peer.onRequest('client/registerCapability', (_) async => const {});
    peer.onRequest('client/unregisterCapability', (_) async => const {});
  }

  String? _findRootForPath(String path) {
    // Most LSP servers publish diagnostics for documents they've
    // seen via didOpen. Track which root a path belongs to.
    for (final entry in _servers.entries) {
      if (entry.value.documents.containsKey(path)) {
        return entry.key;
      }
    }
    // Fallback: if exactly one server is active, assume that root.
    if (_servers.length == 1) return _servers.keys.first;
    return null;
  }

  // ---------------------------------------------------------------------------
  // Process spawn — overridable in tests.
  // ---------------------------------------------------------------------------

  /// Spawn the server process. Default uses `Process.start` with the
  /// command and env from the spec. Tests override to inject a fake.
  Future<Process> spawnProcess(LspServerSpec spec) async {
    return Process.start(
      spec.command[0],
      spec.command.skip(1).toList(),
      workingDirectory: spec.root,
      environment: spec.env.isEmpty ? null : spec.env,
    );
  }

  // Indirection so tests can override `spawnProcess` without
  // re-implementing the full _runStart pipeline.
  Future<Process> _spawnProcess(LspServerSpec spec) => spawnProcess(spec);

  // ---------------------------------------------------------------------------
  // Wiring.
  // ---------------------------------------------------------------------------

  void _wireStderr(Process process, String root) {
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      _emit?.call(LspEventServerStderr(
        root: root,
        serverId: id,
        line: line,
      ));
    }, onError: (_) {});
  }

  Map<String, dynamic> _buildInitializeParams(String root, LspServerSpec spec) {
    return {
      'processId': pid,
      'rootUri': Uri.file(root).toString(),
      'capabilities': const {
        'workspace': {
          'configuration': true,
          'didChangeWatchedFiles': {'dynamicRegistration': true},
        },
        'textDocument': {
          'synchronization': {'didSave': true, 'willSave': false},
          'publishDiagnostics': {'versionSupport': false},
        },
        'window': {'workDoneProgress': true},
      },
      'initializationOptions': spec.initialization,
      'workspaceFolders': [
        {'uri': Uri.file(root).toString(), 'name': p.basename(root)},
      ],
    };
  }

  String _languageIdFor(String ext) {
    // Small inline map; full version lives in language.dart.
    const map = {
      '.dart': 'dart',
      '.ts': 'typescript',
      '.tsx': 'typescriptreact',
      '.js': 'javascript',
      '.jsx': 'javascriptreact',
      '.mjs': 'javascript',
      '.cjs': 'javascript',
      '.mts': 'typescript',
      '.cts': 'typescript',
      '.py': 'python',
      '.pyi': 'python',
      '.rs': 'rust',
      '.go': 'go',
      '.rb': 'ruby',
      '.rake': 'ruby',
      '.lua': 'lua',
      '.sh': 'shellscript',
      '.bash': 'shellscript',
      '.zsh': 'shellscript',
      '.yaml': 'yaml',
      '.yml': 'yaml',
    };
    return map[ext] ?? 'plaintext';
  }

  // ---------------------------------------------------------------------------
  // Test hooks.
  // ---------------------------------------------------------------------------

  /// Number of active servers across all roots. Used by tests.
  int get activeServerCount => _servers.length;

  /// Currently active roots. Used by tests.
  List<String> get activeRoots => _servers.keys.toList();
}

/// Per-root server state held by an actor.
class _ActiveServer {
  final Process process;
  final peer_lib.RpcPeer peer;
  final LspServerSpec spec;
  final Map<String, int> documents;     // path → version

  _ActiveServer({
    required this.process,
    required this.peer,
    required this.spec,
    required this.documents,
  });
}
