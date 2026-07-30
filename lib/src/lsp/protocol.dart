// LSP protocol types used inside Crux. Only the subset we actually
// read or produce is modeled — full LSP is much bigger. Anything we
// don't model passes through as `Map<String, dynamic>`.
//
// Spec references: https://microsoft.github.io/language-server-protocol/

import 'dart:convert';

/// A position in a text document. Both line and character are 0-based,
/// per the LSP spec. Character is in UTF-16 code units, also per spec.
class LspPosition {
  final int line;
  final int character;

  const LspPosition(this.line, this.character);

  factory LspPosition.fromJson(Map<String, dynamic> json) =>
      LspPosition(json['line'] as int? ?? 0, json['character'] as int? ?? 0);

  Map<String, dynamic> toJson() => {'line': line, 'character': character};

  @override
  bool operator ==(Object other) =>
      other is LspPosition &&
      other.line == line &&
      other.character == character;

  @override
  int get hashCode => Object.hash(line, character);

  @override
  String toString() => 'LspPosition($line:$character)';
}

/// A range in a text document. [start] must precede or equal [end].
class LspRange {
  final LspPosition start;
  final LspPosition end;

  const LspRange(this.start, this.end);

  factory LspRange.fromJson(Map<String, dynamic> json) => LspRange(
    LspPosition.fromJson(
      (json['start'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    LspPosition.fromJson(
      (json['end'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
  );

  Map<String, dynamic> toJson() => {
    'start': start.toJson(),
    'end': end.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is LspRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'LspRange($start..$end)';
}

/// Diagnostic severity per LSP spec. Integer values match the wire format.
enum LspDiagnosticSeverity {
  error(1),
  warning(2),
  information(3),
  hint(4);

  final int wireValue;
  const LspDiagnosticSeverity(this.wireValue);

  static LspDiagnosticSeverity? fromJson(Object? value) {
    if (value is! int) return null;
    for (final s in LspDiagnosticSeverity.values) {
      if (s.wireValue == value) return s;
    }
    return null;
  }
}

/// A single diagnostic reported by the server.
///
/// We only model the fields Crux reads. Unknown fields are dropped on
/// parse; we never round-trip diagnostics back to the server in Phase 1.
class LspDiagnostic {
  final LspRange range;
  final String message;
  final LspDiagnosticSeverity? severity;
  final String? source;
  final String? code; // server-reported; may be a string or number
  final List<LspDiagnosticRelatedInformation>? relatedInformation;

  const LspDiagnostic({
    required this.range,
    required this.message,
    this.severity,
    this.source,
    this.code,
    this.relatedInformation,
  });

  factory LspDiagnostic.fromJson(Map<String, dynamic> json) {
    final related = json['relatedInformation'];
    return LspDiagnostic(
      range: LspRange.fromJson(
        (json['range'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      message: json['message'] as String? ?? '',
      severity: LspDiagnosticSeverity.fromJson(json['severity']),
      source: json['source'] as String?,
      code: _codeToString(json['code']),
      relatedInformation: related is List
          ? related
                .whereType<Map>()
                .map(
                  (m) => LspDiagnosticRelatedInformation.fromJson(
                    m.cast<String, dynamic>(),
                  ),
                )
                .toList(growable: false)
          : null,
    );
  }

  static String? _codeToString(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is num) return value.toString();
    return value.toString();
  }

  @override
  String toString() =>
      'LspDiagnostic(${severity?.name ?? 'unknown'} '
      '${range.start}: $message)';

  @override
  bool operator ==(Object other) {
    if (other is! LspDiagnostic) return false;
    if (other.message != message) return false;
    if (other.severity != severity) return false;
    if (other.source != source) return false;
    if (other.code != code) return false;
    if (other.range != range) return false;
    if (other.relatedInformation == null && relatedInformation == null) {
      return true;
    }
    if (other.relatedInformation == null || relatedInformation == null) {
      return false;
    }
    if (other.relatedInformation!.length != relatedInformation!.length) {
      return false;
    }
    for (var i = 0; i < relatedInformation!.length; i++) {
      if (other.relatedInformation![i] != relatedInformation![i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    message,
    severity,
    source,
    code,
    range,
    Object.hashAll(relatedInformation ?? const []),
  );
}

/// Reference to another location, attached to a diagnostic.
class LspDiagnosticRelatedInformation {
  final String uri;
  final LspRange range;
  final String message;

  const LspDiagnosticRelatedInformation({
    required this.uri,
    required this.range,
    required this.message,
  });

  factory LspDiagnosticRelatedInformation.fromJson(Map<String, dynamic> json) {
    return LspDiagnosticRelatedInformation(
      uri: json['uri'] as String? ?? '',
      range: LspRange.fromJson(
        (json['range'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      message: json['message'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LspDiagnosticRelatedInformation &&
      other.uri == uri &&
      other.range == range &&
      other.message == message;

  @override
  int get hashCode => Object.hash(uri, range, message);

  @override
  String toString() => 'LspDiagnosticRelatedInformation($uri $range: $message)';
}

/// A batch of diagnostics for one file, pushed by the server via
/// `textDocument/publishDiagnostics`.
///
/// [version] is whatever the server sent (may be null if the server
/// doesn't track versions). [receivedAt] is when we observed the
/// message locally — used by [LspManager] to debounce and decide
/// whether a batch is "fresh" relative to a recent edit.
class DiagnosticBatch {
  final String path;
  final int? version;
  final List<LspDiagnostic> diagnostics;
  final DateTime receivedAt;

  const DiagnosticBatch({
    required this.path,
    required this.version,
    required this.diagnostics,
    required this.receivedAt,
  });
}

/// Commands sent from the manager (main isolate) to an actor.
///
/// All commands are fire-and-forget in Phase 1 — responses come back
/// as events, not as command replies. See [design-lsp-actors.md] §3.1.
sealed class LspCommand {
  const LspCommand();
}

/// Resolve and start the server for [root]. Idempotent.
class LspCmdStart extends LspCommand {
  final String root;
  final String file;
  const LspCmdStart({required this.root, required this.file});
}

/// Open or update a document on the server started for [root].
class LspCmdOpenDocument extends LspCommand {
  final String root;
  final String path;
  final String content;
  final int version;
  const LspCmdOpenDocument({
    required this.root,
    required this.path,
    required this.content,
    required this.version,
  });
}

/// Close a document on the server for [root].
class LspCmdCloseDocument extends LspCommand {
  final String root;
  final String path;
  const LspCmdCloseDocument({required this.root, required this.path});
}

/// Stop everything for [root] (or all roots if null).
class LspCmdShutdownRoot extends LspCommand {
  final String? root;
  const LspCmdShutdownRoot({this.root});
}

/// Stop everything and terminate the actor.
class LspCmdShutdown extends LspCommand {
  const LspCmdShutdown();
}

/// Events sent from an actor (worker isolate) back to the manager.
///
/// Every event carries [root] and [serverId] so the manager can route
/// events to the right slot even when multiple servers are multiplexed
/// onto the same actor (Phase 2.x). Phase 1 only multiplexes when the
/// user has multiple roots active in one session.
sealed class LspEvent {
  final String root;
  final String serverId;

  const LspEvent({required this.root, required this.serverId});
}

/// Server for [root] is initialized and ready.
class LspEventStarted extends LspEvent {
  const LspEventStarted({required super.root, required super.serverId});
}

/// Server for [root] failed to start. Manager records the root as
/// "broken" and skips future requests until the backoff clears.
class LspEventStartFailed extends LspEvent {
  final String reason;
  const LspEventStartFailed({
    required super.root,
    required super.serverId,
    required this.reason,
  });
}

/// Server process exited (clean or otherwise). Manager removes the
/// client from its active set.
class LspEventProcessExited extends LspEvent {
  final int exitCode;
  const LspEventProcessExited({
    required super.root,
    required super.serverId,
    required this.exitCode,
  });
}

/// Diagnostics batch pushed by the server for a document.
class LspEventDiagnostics extends LspEvent {
  final DiagnosticBatch batch;
  const LspEventDiagnostics({
    required super.root,
    required super.serverId,
    required this.batch,
  });
}

/// Server wrote a line to stderr. Surfaced for debugging — manager
/// rate-limits and forwards to the logger.
class LspEventServerStderr extends LspEvent {
  final String line;
  const LspEventServerStderr({
    required super.root,
    required super.serverId,
    required this.line,
  });
}

/// JSON-RPC peer became unusable (malformed JSON, oversized message,
/// peer closed the stream). Manager should drop the client.
class LspEventRpcFatal extends LspEvent {
  final String reason;
  const LspEventRpcFatal({
    required super.root,
    required super.serverId,
    required this.reason,
  });
}

/// JSON-RPC error returned by a server. Carries the LSP error code
/// (e.g. -32601 = MethodNotFound) and the message.
class LspRpcError implements Exception {
  final int code;
  final String message;
  final String method;
  final Object? data;

  const LspRpcError({
    required this.code,
    required this.message,
    required this.method,
    this.data,
  });

  factory LspRpcError.fromJson(
    Map<String, dynamic> json, {
    required String method,
  }) {
    return LspRpcError(
      code: json['code'] as int? ?? -32000,
      message: json['message'] as String? ?? 'unknown error',
      method: method,
      data: json['data'],
    );
  }

  @override
  String toString() =>
      'LspRpcError(code=$code, message=$message, method=$method)';
}

/// Resolved LSP server spec. Subclasses of [LspServerActor] return
/// one of these from `resolveSpec` to drive process spawn.
///
/// [command] is the binary plus args. [env] is merged on top of the
/// current process env. [initialization] is the JSON object sent as
/// `initializationOptions` in the `initialize` request.
class LspServerSpec {
  final String root;
  final List<String> command;
  final Map<String, String> env;
  final Map<String, dynamic> initialization;

  const LspServerSpec({
    required this.root,
    required this.command,
    this.env = const {},
    this.initialization = const {},
  });
}

/// Context passed to an actor's [LspServerActor.resolveSpec] so it
/// can locate the project root for a given file.
class LspResolveCtx {
  /// The Crux session's working directory (typically the project root
  /// the user invoked Crux with).
  final String workingDirectory;

  const LspResolveCtx({required this.workingDirectory});
}

/// Utilities for the protocol types — only one for now (JSON
/// round-trip helpers for testing).
extension LspDiagnosticJson on LspDiagnostic {
  /// Encode back to JSON. Used by tests and by future code that wants
  /// to forward diagnostics through a different channel.
  String toJsonString() => jsonEncode({
    'range': range.toJson(),
    'message': message,
    if (severity != null) 'severity': severity!.wireValue,
    if (source != null) 'source': source,
    if (code != null) 'code': code,
    if (relatedInformation != null)
      'relatedInformation': relatedInformation!
          .map(
            (r) => {
              'uri': r.uri,
              'range': r.range.toJson(),
              'message': r.message,
            },
          )
          .toList(),
  });
}
