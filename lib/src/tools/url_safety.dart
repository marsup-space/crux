import 'dart:io';

/// SSRF guard for the raw `webfetch` path.
///
/// The agent can be instructed (maliciously or via prompt injection
/// in fetched page content) to fetch internal URLs. The most
/// damaging target on a developer machine or cloud VM is the
/// link-local metadata endpoint (169.254.169.254 on AWS/GCP/Azure),
/// which hands out instance credentials. This guard blocks that
/// class of targets while deliberately *allowing* the addresses a
/// developer legitimately wants the agent to read:
///
///   BLOCKED                        ALLOWED
///   169.254.0.0/16 (link-local)    10.0.0.0/8, 172.16.0.0/12,
///   100.64.0.0/10 (CGNAT)          192.168.0.0/16 (private nets,
///   0.0.0.0/8 (unspecified)        e.g. intranet wikis)
///   fe80::/10 (v6 link-local)      127.0.0.0/8, ::1 (localhost
///   :: (v6 unspecified)            dev servers)
///   non-http(s) schemes
///
/// Enforcement points:
///  - pre-flight on the requested URL ([check]);
///  - per-hop on every redirect target (webfetch follows redirects
///    manually so each hop is re-validated — an open redirect on a
///    public host must not become a metadata-endpoint proxy);
///  - DNS answers for hostnames: if *any* resolved address is
///    blocked, the URL is refused (DNS-rebinding mitigation).
///
/// The provider path (TinyFish) is NOT guarded here — it fetches
/// from the provider's cloud, not from this machine, so it is not
/// a local-SSRF vector.
class UrlSafety {
  UrlSafety._();

  /// Returns a human-readable reason when [uri] must not be
  /// fetched, or `null` when it is allowed. Resolves hostnames via
  /// DNS; a failed lookup returns `null` (allowed) so the fetch
  /// itself surfaces the DNS error to the caller.
  static Future<String?> check(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return 'scheme "${uri.scheme}" is not fetchable (http/https only)';
    }
    final host = uri.host;
    if (host.isEmpty) {
      return 'URL has no host';
    }
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      return blockedAddressReason(literal);
    }
    final List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host);
    } catch (_) {
      // DNS failure is not a safety decision — let the fetch
      // report the resolution error.
      return null;
    }
    for (final addr in addresses) {
      final reason = blockedAddressReason(addr);
      if (reason != null) {
        return '$reason (host "$host" resolved to ${addr.address})';
      }
    }
    return null;
  }

  /// Whether [uri] can only be reached from this machine / the
  /// local network — loopback, RFC1918 private ranges, IPv6 ULA,
  /// link-local, CGNAT, or unspecified. A cloud web provider
  /// (TinyFish) fetches from *its* network and could never reach
  /// these, so callers should route such URLs to the local raw
  /// fetch instead. Blocked addresses ([blockedAddressReason])
  /// are a subset of local targets, so the raw path still refuses
  /// them after routing.
  static Future<bool> isLocalTarget(Uri uri) async {
    final host = uri.host;
    if (host.isEmpty) return false;
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      return isLocalAddress(literal);
    }
    final List<InternetAddress> addresses;
    try {
      addresses = await InternetAddress.lookup(host);
    } catch (_) {
      // Unresolvable — treat as remote and let the provider try.
      return false;
    }
    // Every answer must be local; a mixed public/private answer
    // set means the name is reachable remotely.
    return addresses.isNotEmpty && addresses.every(isLocalAddress);
  }

  /// Pure, network-free predicate behind [isLocalTarget].
  static bool isLocalAddress(InternetAddress addr) {
    final bytes = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv6) {
      // IPv4-mapped IPv6 — judge the embedded IPv4 address.
      if (bytes.length == 16 &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff &&
          bytes.sublist(0, 10).every((b) => b == 0)) {
        return _isLocalV4(bytes[12], bytes[13]);
      }
      if (bytes.every((b) => b == 0)) return true; // ::
      if (bytes.sublist(0, 15).every((b) => b == 0) && bytes[15] == 1) {
        return true; // ::1
      }
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
        return true; // fe80::/10 link-local
      }
      if ((bytes[0] & 0xfe) == 0xfc) return true; // fc00::/7 ULA
      return false;
    }
    return _isLocalV4(bytes[0], bytes[1]);
  }

  static bool _isLocalV4(int a, int b) {
    if (a == 127) return true; // loopback
    if (a == 10) return true; // private 10/8
    if (a == 172 && (b & 0xf0) == 0x10) return true; // 172.16/12
    if (a == 192 && b == 168) return true; // 192.168/16
    if (a == 169 && b == 254) return true; // link-local
    if (a == 100 && (b & 0xc0) == 0x40) return true; // CGNAT /10
    if (a == 0) return true; // unspecified
    return false;
  }

  /// Pure, network-free check against an already-parsed address.
  /// Returns a reason string when blocked, `null` when allowed.
  static String? blockedAddressReason(InternetAddress addr) {
    final bytes = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv6) {
      // IPv4-mapped IPv6 (::ffff:a.b.c.d) must be judged by the
      // embedded IPv4 address, otherwise ::ffff:169.254.169.254
      // would slip past the IPv4 rules.
      if (bytes.length == 16 &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff &&
          bytes.sublist(0, 10).every((b) => b == 0)) {
        return _blockedV4(
          bytes[12],
          bytes[13],
          bytes[14],
          bytes[15],
          note: 'IPv4-mapped IPv6',
        );
      }
      if (bytes.every((b) => b == 0)) {
        return 'IPv6 unspecified address (::)';
      }
      if (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) {
        return 'IPv6 link-local address (fe80::/10)';
      }
      return null;
    }
    return _blockedV4(bytes[0], bytes[1], bytes[2], bytes[3]);
  }

  static String? _blockedV4(int a, int b, int c, int d, {String? note}) {
    final suffix = note == null ? '' : ' [$note]';
    if (a == 0) {
      return 'unspecified address 0.0.0.0/8$suffix';
    }
    if (a == 169 && b == 254) {
      return 'link-local / cloud-metadata address 169.254.0.0/16$suffix';
    }
    // 100.64.0.0/10: second octet 64–127 (top two bits 01).
    if (a == 100 && (b & 0xc0) == 0x40) {
      return 'CGNAT shared address 100.64.0.0/10$suffix';
    }
    return null;
  }
}
