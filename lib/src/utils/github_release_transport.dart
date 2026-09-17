/// Reaches GitHub release resources on networks where `github.com` is blocked.
///
/// Three transports, ordered by how much they ask the user to trust:
///
///   1. **direct** — plain connection.
///   2. **the system proxy** — the user configured it (Clash / Surge / V2Ray /
///      env vars / OS settings, all detected by [SystemProxyDetector]), so it is
///      the intended path rather than a workaround.
///   3. **a public GitHub mirror** — the gh-proxy convention, i.e. the original
///      absolute URL appended to a mirror prefix.
///
/// Mirrors come last on purpose. They are third-party relays, so a binary that
/// arrives through one has passed through someone else's machine, and the
/// release workflow publishes no checksum, so tampering is not detectable
/// client-side. Putting them behind the user's own proxy keeps that exposure to
/// the case where it is the only way through.
///
/// `CRUX_NO_GITHUB_PROXY=1` disables the mirror step; `CRUX_GITHUB_PROXIES`
/// (comma or space separated) replaces the list, because these services come and
/// go and a user whose mirror isn't in this list should not need a release to add
/// it.
///
/// Measured behaviour of the shipped mirrors — they are *not* interchangeable:
///
///   * `gh-proxy.com` — downloads only; answers an HTML request with
///     "Web page content is not allowed. This service is for resource downloads
///     only."
///   * `ghfast.top` — downloads and pages.
///   * `ghproxy.net` — downloads.
///
/// That is why callers walk the chain once for the resource they actually need
/// instead of assuming one transport serves both the release page and the asset.
library;

import 'dart:io';

import 'proxy_aware_http.dart';
import 'system_proxy.dart';

/// Mirrors tried, in order, when the direct and system-proxy transports fail.
const List<String> kDefaultGithubMirrors = [
  'https://gh-proxy.com/',
  'https://ghfast.top/',
  'https://ghproxy.net/',
];

/// The mirror list in force, honouring `CRUX_GITHUB_PROXIES`.
///
/// An empty env value is treated as "no mirrors", not as "use the defaults" —
/// the explicit way to opt out of third-party relays without also opting out of
/// the system-proxy fallback.
List<String> githubMirrors() {
  final raw = Platform.environment['CRUX_GITHUB_PROXIES'];
  if (raw == null) return kDefaultGithubMirrors;
  return raw
      .split(RegExp(r'[,\s]+'))
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
}

/// Whether the mirror transport is enabled at all.
bool githubMirrorsEnabled() =>
    Platform.environment['CRUX_NO_GITHUB_PROXY'] != '1';

/// Rewrites [url] onto [mirror].
///
/// Every gh-proxy instance uses the same shape: the mirror prefix followed by
/// the absolute original URL, e.g.
/// `https://gh-proxy.com/https://github.com/o/r/releases/download/v1/a.zip`.
/// Verified against three live mirrors.
String mirrorUrl(String mirror, String url) =>
    mirror.endsWith('/') ? '$mirror$url' : '$mirror/$url';

/// Runs [attempt] against each transport until one returns.
///
/// [attempt] receives the URL to try and the system proxy to route through
/// (`null` for a direct connection). It signals "this transport didn't work" by
/// throwing — including when it got a response it cannot use, such as a
/// download-only mirror answering a page request or a 200 that isn't the
/// payload. Only errors satisfying [isRetriableError] (connection failures by
/// default) move on to the next transport; anything else propagates at once, so
/// a genuine failure is never buried under a pile of retries.
///
/// The last error is rethrown when every transport is exhausted, which keeps the
/// caller's failure message about the real reason rather than about the last
/// mirror.
Future<T> withGithubTransports<T>({
  required String url,
  required Future<T> Function(String url, SystemProxy? proxy) attempt,
  bool Function(Object error)? isRetriableError,
  List<String>? mirrors,
}) async {
  final retriable = isRetriableError ?? isConnectionError;
  Object? lastError;

  Future<T?> tryTransport(String candidateUrl, SystemProxy? proxy) async {
    try {
      return await attempt(candidateUrl, proxy);
    } catch (error) {
      if (!retriable(error)) rethrow;
      lastError = error;
      return null;
    }
  }

  final direct = await tryTransport(url, null);
  if (direct != null) return direct;

  if (isSystemProxyFallbackGloballyEnabled()) {
    final proxy = SystemProxyDetector.detect();
    if (proxy != null && proxy.isNotEmpty) {
      final viaProxy = await tryTransport(url, proxy);
      if (viaProxy != null) return viaProxy;
    }
  }

  for (final mirror in _resolveMirrors(mirrors)) {
    final viaMirror = await tryTransport(mirrorUrl(mirror, url), null);
    if (viaMirror != null) return viaMirror;
  }

  throw lastError ?? const HttpException('no transport reached the resource');
}

/// An explicitly supplied [mirrors] list wins over the environment, so tests and
/// future callers can pin the transport set. Otherwise `CRUX_NO_GITHUB_PROXY`
/// and `CRUX_GITHUB_PROXIES` decide.
List<String> _resolveMirrors(List<String>? mirrors) {
  if (mirrors != null) return mirrors;
  if (!githubMirrorsEnabled()) return const [];
  return githubMirrors();
}
