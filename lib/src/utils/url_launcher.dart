import 'dart:io';

/// Outcome of a [openUrl] call. We surface this rather than throwing
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
    final helper = _helperForPlatform();
    if (helper == null) {
      return UrlLaunchResult.failed;
    }
    Process.start(
      helper.executable,
      [...helper.args, url],
      mode: ProcessStartMode.detached,
    );
    return UrlLaunchResult.launched;
  } catch (_) {
    return UrlLaunchResult.failed;
  }
}

class _Helper {
  final String executable;
  final List<String> args;
  const _Helper(this.executable, this.args);
}

/// Returns the platform-specific "open a URL" helper, or null if the
/// current platform has no known helper.
_Helper? _helperForPlatform() {
  if (Platform.isMacOS) {
    return const _Helper('open', []);
  }
  if (Platform.isLinux) {
    // `xdg-open` is the de-facto standard on every mainstream desktop
    // distribution. If a user is on a headless box without it, the
    // `Process.start` will throw and we will fall through to
    // [UrlLaunchResult.failed].
    return const _Helper('xdg-open', []);
  }
  if (Platform.isWindows) {
    // `start` is a cmd.exe builtin, not a real binary, so we have to
    // go through `cmd /c`. The empty title argument (`""`) keeps
    // `start` from interpreting the URL as a window title.
    return const _Helper('cmd', ['/c', 'start', '""']);
  }
  return null;
}
