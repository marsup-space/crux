import 'dart:io';

/// Outcome of an [openUrl] call. We surface this rather than throwing
/// because the caller (the chat panel) wants to decide whether to
/// surface a toast on failure — and a missing browser tool is not a
/// programming error.
enum UrlLaunchResult {
  /// The OS-level launcher was invoked with a URL the platform
  /// should be able to open.
  launched,

  /// The URL is not one we want to hand to the OS launcher (e.g.
  /// `javascript:` or `file:` or anything that is not `http(s):`).
  rejected,

  /// The platform-specific helper binary (`xdg-open`, `open`, ...)
  /// could not be found on `$PATH`, or `Process.start` itself failed.
  failed,
}

/// Opens [url] in the user default browser using the platform
/// standard "open URL" helper. Returns a [UrlLaunchResult] describing
/// what happened.
///
/// Only `http://` and `https://` URLs are accepted. Anything else
/// (including `file:`, `javascript:`, custom schemes) is rejected
/// with [UrlLaunchResult.rejected] to avoid the LLM-emitted
/// `[Heading](...)` text ever being able to launch a local program
/// or run script content.
UrlLaunchResult openUrl(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed == null || !parsed.hasScheme) {
    return UrlLaunchResult.rejected;
  }
  final scheme = parsed.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    return UrlLaunchResult.rejected;
  }

  // Spawn the helper in detached mode and do not wait for it — the
  // browser process can outlive our TUI without any issue, and
  // blocking on a slow OS call would freeze the chat.
  try {
    final helper = _urlHelperForPlatform();
    if (helper == null) {
      return UrlLaunchResult.failed;
    }
    Process.start(helper.executable, [
      ...helper.args,
      url,
    ], mode: ProcessStartMode.detached);
    return UrlLaunchResult.launched;
  } catch (_) {
    return UrlLaunchResult.failed;
  }
}

/// Outcome of an [openDirectory] call. Same shape conceptually as
/// [UrlLaunchResult] so the call site can show a single toast for
/// either kind of failure.
enum OpenDirectoryResult {
  /// The OS-level helper was invoked with a directory the platform
  /// should be able to open.
  launched,

  /// [path] does not exist or is not a directory.
  notFound,

  /// The platform-specific helper binary (`xdg-open`, `open`, ...)
  /// could not be found on `$PATH`, or `Process.start` itself failed.
  failed,
}

/// Opens [path] in the system file explorer (Finder on macOS, the
/// default file manager on Linux, Explorer on Windows). Returns an
/// [OpenDirectoryResult] describing what happened.
///
/// The path must exist and be a directory — missing or non-directory
/// paths are reported as [OpenDirectoryResult.notFound] rather than
/// thrown, so the caller (e.g. the project path button) can show a
/// toast explaining the failure without crashing the TUI.
OpenDirectoryResult openDirectory(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    return OpenDirectoryResult.notFound;
  }

  try {
    final helper = _fileManagerForPlatform();
    if (helper == null) {
      return OpenDirectoryResult.failed;
    }
    Process.start(helper.executable, [
      ...helper.args,
      dir.absolute.path,
    ], mode: ProcessStartMode.detached);
    return OpenDirectoryResult.launched;
  } catch (_) {
    return OpenDirectoryResult.failed;
  }
}

/// Outcome of a [revealInFileManager] call. Mirrors [OpenDirectoryResult]
/// so the call site can surface a single toast for either failure kind.
enum RevealResult {
  /// The OS-level helper was invoked to reveal the file.
  launched,

  /// [path] does not exist.
  notFound,

  /// The platform-specific helper could not be started.
  failed,
}

/// Reveals [path] in the system file manager with the file **selected**
/// where the platform supports it (Finder on macOS via `open -R`,
/// Explorer on Windows via `explorer /select,`). On Linux there is no
/// reliable cross-file-manager "select" verb, so we fall back to opening
/// the file's parent directory.
///
/// [path] may be relative; it is resolved against [workingDirectory]. A
/// missing file is reported as [RevealResult.notFound] rather than thrown
/// so the caller can toast without crashing the TUI.
RevealResult revealInFileManager(String path, {String? workingDirectory}) {
  final resolved = _resolveFilePath(path, workingDirectory);
  if (resolved == null) return RevealResult.notFound;

  try {
    final helper = _revealHelperForPlatform(resolved);
    if (helper == null) return RevealResult.failed;
    Process.start(
      helper.executable,
      helper.args,
      mode: ProcessStartMode.detached,
    );
    return RevealResult.launched;
  } catch (_) {
    return RevealResult.failed;
  }
}

/// Resolve [path] to an absolute file path, or null when it doesn't name
/// an existing file. Relative paths are joined onto [workingDirectory]
/// (falling back to the process CWD). The path must point at a file —
/// a directory yields null so "open" on a directory-shaped row degrades
/// to a toast instead of a confusing no-op.
String? _resolveFilePath(String path, String? workingDirectory) {
  if (path.isEmpty) return null;
  var candidate = path;
  if (!_isAbsolute(candidate)) {
    final base = workingDirectory ?? Directory.current.path;
    candidate = _joinPath(base, candidate);
  }
  final file = File(candidate);
  return file.existsSync() ? file.absolute.path : null;
}

bool _isAbsolute(String path) {
  if (Platform.isWindows) {
    return path.length >= 2 && path[1] == ':' || path.startsWith('\\\\');
  }
  return path.startsWith('/');
}

String _joinPath(String a, String b) {
  final sep = Platform.isWindows ? '\\' : '/';
  if (a.endsWith(sep)) return '$a$b';
  return '$a$sep$b';
}

class _Helper {
  final String executable;
  final List<String> args;
  const _Helper({required this.executable, required this.args});
}

/// Returns the platform-specific "reveal this file in the file manager"
/// helper for an absolute [filePath], or null when the platform has no
/// known reveal verb.
_Helper? _revealHelperForPlatform(String filePath) {
  if (Platform.isMacOS) {
    // `open -R` opens Finder with the file selected.
    return _Helper(executable: 'open', args: ['-R', filePath]);
  }
  if (Platform.isWindows) {
    // `explorer /select,<path>` opens Explorer with the file selected.
    return _Helper(executable: 'explorer', args: ['/select,$filePath']);
  }
  if (Platform.isLinux) {
    // No portable "select" verb — open the containing directory instead.
    final parent = Directory(filePath).parent.path;
    return _Helper(executable: 'xdg-open', args: [parent]);
  }
  return null;
}

/// Returns the platform-specific "open a URL" helper, or null if the
/// current platform has no known helper.
_Helper? _urlHelperForPlatform() {
  if (Platform.isMacOS) {
    return const _Helper(executable: 'open', args: []);
  }
  if (Platform.isLinux) {
    // `xdg-open` is the de-facto standard on every mainstream desktop
    // distribution. If a user is on a headless box without it, the
    // `Process.start` will throw and we will fall through to
    // [UrlLaunchResult.failed].
    return const _Helper(executable: 'xdg-open', args: []);
  }
  if (Platform.isWindows) {
    // `start` is a cmd.exe builtin, not a real binary, so we have to
    // go through `cmd /c`. The empty title argument (`""`) keeps
    // `start` from interpreting the URL as a window title.
    return const _Helper(executable: 'cmd', args: ['/c', 'start', '""']);
  }
  return null;
}

/// Returns the platform-specific "open a directory in the file
/// manager" helper. Today every mainstream desktop uses the same
/// binary as URL launching, but we keep a separate function so the
/// two concerns can diverge later (e.g. switch Linux to `dbus-send`
/// to target a specific file manager) without touching [openUrl].
_Helper? _fileManagerForPlatform() {
  if (Platform.isMacOS) {
    return const _Helper(executable: 'open', args: []);
  }
  if (Platform.isLinux) {
    return const _Helper(executable: 'xdg-open', args: []);
  }
  if (Platform.isWindows) {
    // `explorer` is the only binary that reliably opens a folder
    // window in a fresh process; passing the path as a single arg
    // works regardless of spaces in the path because
    // `Process.start` quotes it for us.
    return const _Helper(executable: 'explorer', args: []);
  }
  return null;
}
