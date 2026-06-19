import 'dart:async';
import 'dart:io';

import 'system_proxy.dart';

/// Returns `true` if [error] looks like a network connectivity failure
/// that could plausibly succeed if we retried through a proxy.
///
/// We catch the `dart:io` errors that signal "we couldn't reach the
/// destination" — DNS failure, connection refused, TLS handshake, HTTP
/// protocol error mid-stream, request timeout. We deliberately do NOT
/// treat `FormatException` as a connection error (that's bad payload
/// data, not a network problem) and we don't catch arbitrary
/// [Exception]s (the caller might want to see them).
///
/// [IOException] is the documented base class of
/// [SocketException] / [HandshakeException] / [HttpException] in
/// `dart:io`, so checking the base class is sufficient — but listing
/// them out in the docs above makes the intent obvious.
bool isConnectionError(Object error) {
  if (error is SocketException) return true;
  if (error is HandshakeException) return true;
  if (error is HttpException) return true;
  if (error is TimeoutException) return true;
  return false;
}

/// Runs [attempt] with system-proxy fallback on connection errors.
///
/// Behaviour:
/// 1. Calls `attempt(null)` — direct connection.
/// 2. If that throws and the error matches [isRetriableError]
///    (default [isConnectionError]) AND a system proxy is configured,
///    calls `attempt(proxy)` once more with the system proxy in scope.
/// 3. If step 1 succeeds, step 2 is skipped.
/// 4. If step 1 throws a non-retriable error, it propagates immediately.
/// 5. If step 1 throws but no system proxy is configured, the error
///    propagates unchanged.
/// 6. If both attempts fail, the second error propagates.
///
/// [enabled] is `true` by default. Set it to `false` to disable the
/// fallback entirely (the wrapper still runs [attempt] once, with
/// `proxy == null`).
///
/// Setting the env var `CRUX_NO_PROXY_FALLBACK=1` before launching
/// Crux also disables the fallback globally. This is the documented
/// opt-out for users whose direct connection works fine and who want
/// to guarantee Crux never reaches for a proxy.
Future<T> withProxyRetry<T>({
  required Future<T> Function(SystemProxy? proxy) attempt,
  bool Function(Object error)? isRetriableError,
  bool enabled = true,
}) async {
  if (!enabled) return attempt(null);
  try {
    return await attempt(null);
  } catch (e) {
    final retriable = isRetriableError ?? isConnectionError;
    if (!retriable(e)) rethrow;
    final proxy = SystemProxyDetector.detect();
    if (proxy == null || proxy.isEmpty) rethrow;
    return await attempt(proxy);
  }
}

/// Returns `true` if the process-wide auto-fallback to the system proxy
/// is enabled. Defaults to `true`; set `CRUX_NO_PROXY_FALLBACK=1` to
/// disable.
bool isSystemProxyFallbackGloballyEnabled() {
  return Platform.environment['CRUX_NO_PROXY_FALLBACK'] != '1';
}
