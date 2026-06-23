import 'dart:async';

/// Abstract base for every web backend that can serve the
/// `webfetch` / `websearch` tools.
///
/// Why a single base class (vs. separate `WebSearchProvider` /
/// `WebFetchProvider` interfaces):
/// - A single provider often supports both capabilities behind
///   one key (TinyFish). Splitting them into two interfaces
///   would force the implementation to declare both `implements`
///   while we still have to look them up by the same id.
/// - Some providers only support one (Exa = search, Firecrawl
///   = fetch). With this base class, those just don't override
///   the method they don't support and the inherited default
///   throws `UnimplementedError` with a friendly message.
/// - Key storage and registration metadata are shared by every
///   provider, so they live on the base.
///
/// New providers subclass [WebServiceProvider] and override
/// [id], [displayName], and whichever of [search] / [fetch] they
/// support. Capability flags [supportsSearch] / [supportsFetch]
/// default to `false`; concrete providers set the ones they
/// implement to `true`. The tool layer uses the flags to decide
/// which tool to register and which provider to dispatch to.
abstract class WebServiceProvider {
  /// Persistent identifier used in slash commands, config, and
  /// `auth.toml` (e.g. `tinyfish`). Lowercase, no spaces.
  String get id;

  /// Human-readable label for the suggestion overlay and the
  /// `/webfetch` / `/websearch` status toasts.
  String get displayName;

  String? _apiKey;

  /// Current API key. `null` when no key is configured. The
  /// registry calls [setApiKey] before any request to refresh
  /// this value, so the provider can rely on it being current
  /// at request time.
  String? get apiKey => _apiKey;

  /// Update the in-memory key. Called by [WebProviderRegistry]
  /// after reading `auth.toml` and on every `/<provider> apikey`
  /// command. Subclasses that pre-compute expensive clients can
  /// override to invalidate them when the key changes.
  void setApiKey(String? key) {
    _apiKey = key;
  }

  /// True iff [apiKey] is non-null and non-empty. Used by the
  /// registry to decide whether a provider is "active" for a
  /// given capability. Reads through the [apiKey] getter so
  /// subclass overrides (e.g. env-var fallback) are honored
  /// automatically.
  bool get isConfigured => apiKey != null && apiKey!.isNotEmpty;

  /// Whether this provider can serve web search calls. The
  /// `websearch` tool is only registered when at least one
  /// provider reports `supportsSearch && isConfigured`.
  bool get supportsSearch => false;

  /// Whether this provider can serve page fetch / extraction
  /// calls. The `webfetch` tool falls back to a raw HTTP fetch
  /// when no provider reports `supportsFetch && isConfigured`.
  bool get supportsFetch => false;

  /// Run a web search. Default impl throws — concrete
  /// providers override when [supportsSearch] is `true`.
  ///
  /// Implementations should:
  /// - Return parsed [WebSearchResponse]
  /// - Throw [WebProviderException] on failure
  /// - Apply 429/5xx retry internally (consistent across
  ///   providers so the LLM sees a predictable failure mode)
  Future<WebSearchResponse> search({
    required String query,
    String? location,
    String? language,
    int? page,
    bool includeThumbnail = false,
  }) {
    throw UnimplementedError(
      '$displayName ($id) does not support web search',
    );
  }

  /// Fetch and extract one or more URLs. Default impl throws —
  /// concrete providers override when [supportsFetch] is `true`.
  Future<WebFetchResponse> fetch(
    List<String> urls, {
    String format = 'markdown',
    bool links = false,
    bool imageLinks = false,
    int? ttl,
    int? perUrlTimeoutMs,
  }) {
    throw UnimplementedError(
      '$displayName ($id) does not support web fetch',
    );
  }
}

/// Public-facing error from any web provider. The `message` is
/// surfaced to the LLM as the tool-failure text so the model can
/// react (back off, give up, switch approach).
class WebProviderException implements Exception {
  final String message;
  const WebProviderException(this.message);
  @override
  String toString() => message;
}

// ────────────────────────── Response models ──────────────────────────
//
// These live next to the provider interface because they're
// the shared contract between every implementation and the
// tools that consume the results. Providers are free to expose
// richer per-error/per-result models internally (TinyFish has
// a structured `errors[]` with HTTP status codes, for
// instance), but at the provider boundary we normalize to
// these so swapping in a different backend (Firecrawl, Exa,
// …) doesn't ripple through the tool layer.

class WebSearchResult {
  final int position;
  final String siteName;
  final String title;
  final String snippet;
  final String url;
  final String? thumbnailUrl;

  const WebSearchResult({
    required this.position,
    required this.siteName,
    required this.title,
    required this.snippet,
    required this.url,
    this.thumbnailUrl,
  });
}

class WebSearchResponse {
  final String query;
  final List<WebSearchResult> results;
  final int totalResults;
  final int page;

  const WebSearchResponse({
    required this.query,
    required this.results,
    required this.totalResults,
    required this.page,
  });
}

class WebFetchResult {
  final String url;
  final String? finalUrl;
  final String? title;
  final String? description;
  final String? language;
  final String? author;
  final String? publishedDate;

  /// Extracted text content. Format depends on what the
  /// provider was called with — usually `markdown` (LLM-friendly)
  /// or `html`. `null` when the URL failed and the result is an
  /// error rather than a success.
  final String? text;
  final String? format;
  final int? latencyMs;

  const WebFetchResult({
    required this.url,
    this.finalUrl,
    this.title,
    this.description,
    this.language,
    this.author,
    this.publishedDate,
    this.text,
    this.format,
    this.latencyMs,
  });
}

class WebFetchError {
  /// Structured error code identifying the failure type
  /// (`target_http_error`, `page_not_found`, `timeout`, …).
  /// Free-form for now — providers may emit provider-specific
  /// codes; the tool layer treats it as a label.
  final String code;
  final String url;
  final int? status;

  const WebFetchError({
    required this.code,
    required this.url,
    this.status,
  });
}

class WebFetchResponse {
  /// One entry per URL that was fetched successfully. Length is
  /// `<= urls.length`; failed URLs are in [errors].
  final List<WebFetchResult> results;

  /// One entry per URL that failed. Empty list when every URL
  /// succeeded.
  final List<WebFetchError> errors;

  const WebFetchResponse({required this.results, required this.errors});
}
