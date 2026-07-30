// Cross-isolate markdown parser.
//
// Why this exists
// ---------------
// During a streaming LLM response the reasoning block grows by
// 1–4 characters every frame. The [HighlightedMarkdownText]
// widget rebuilds on every grow, and its `build` runs the full
// `parseMarkdownToInlineSpans` pass on the **main** isolate:
//
//   * 5–15 ms for a 5 kB chunk of reasoning
//   * in the worst case (long thinking preamble) the main
//     isolate spends 30+ ms per frame on markdown parse alone,
//     dropping the chat panel from 60 fps to 25 fps
//
// The `perf-roadmap.md` notes: "136.3 ms … six animation
// timers fire simultaneously … 127.6 ms in layout alone." The
// markdown parse is a substantial fraction of that pre-layout
// cost, and it scales with text size — exactly the wrong
// shape as the reasoning block grows.
//
// Design
// ------
// 1. A long-lived worker isolate is spawned on first use and
//    kept alive for the rest of the app's lifetime. The cost
//    of spawning (~5 ms) is paid once.
// 2. The main isolate submits parse requests with a
//    monotonically increasing request id. Each request
//    carries:
//      * `text` — the full reasoning-block text. Markdown is
//        context-dependent; we cannot safely parse only the
//        appended tail (a code fence might span the boundary).
//      * `parsedIndex` — a hint: the worker can short-circuit
//        re-parsing if `text.length <= parsedIndex` (the text
//        has not actually changed since the last parse).
//      * `maxWidth` and a flat [MarkdownParseTheme] snapshot
//        (all the colors the parser needs, packed as ints).
// 3. The worker re-parses the text, then sends back
//    [MarkdownSpanData] — a list of flat text+style records.
//    We don't ship TextSpan / TextStyle / Color across the
//    isolate boundary because Dart isolates are restrictive
//    about which types are sendable; the flat records are
//    primitives, list of records, and strings — all
//    trivially sendable.
// 4. The main isolate reconstructs the TextSpan tree from the
//    flat records on the next frame.
// 5. Coalescing: when a new request lands while an older one
//    is in flight, the older request's result is dropped on
//    receipt. This bounds the worker's queue depth to 1 —
//    important for the streaming case where new chars land
//    every frame and we don't want the worker to be working
//    on a parse for text that was already superseded.
//
// Caveat: code-block syntax highlighting (via
// [HighlightService]) runs out-of-process in nocterm's host.
// The worker doesn't initialize the highlighter; instead it
// renders code blocks as unhighlighted rows. Once the
// streaming block is done and the bubble collapses into a
// regular [MessageBubble], the user sees the
// properly-highlighted code the next time the bubble is
// rebuilt (sync path with `HighlightService` available).
//
// Interface: [MarkdownThemeFields]
// --------------------------------
// The parser reads ~25 color getters from the theme object
// (see the [MarkdownThemeFields] interface). [CruxThemeData]
// implements the interface (it already has all those
// getters). The worker constructs a [WorkerTheme] that
// implements the same interface, with colors stored as
// packed ARGB ints. This keeps the parser code shared
// between sync and async paths.

import 'dart:async';
import 'dart:isolate';

import 'package:nocterm/nocterm.dart';

import 'highlighted_markdown_text.dart';

/// Color getters the markdown parser needs from the theme.
/// Implemented by [CruxThemeData] (in the main isolate) and
/// by [WorkerTheme] (in the worker isolate).
///
/// This is intentionally a small interface — the parser
/// reads exactly these getters and nothing else. Adding a
/// new field here is a breaking change for both
/// implementations, which is what we want.
abstract class MarkdownThemeFields {
  Color get markdownText;
  Color get thinkingExpandedText;
  Color get mdH1;
  Color get mdH2;
  Color get mdH3;
  Color get mdH4;
  Color get mdH5;
  Color get mdH6;
  Color get mdBold;
  Color get mdItalic;
  Color get mdStrikethrough;
  Color get mdInlineCode;
  Color get mdInlineCodeBg;
  Color get mdCodeBlockText;
  Color get mdBlockquote;
  Color get mdLink;
  Color get codeBlockBackground;
  Color get codeBlockGutter;
  Color get codeBlockHeader;
  Color get outline;
  Color get surface;
  Color get surfaceVariant;
  Color get highlightDefault;
  Color get highlightKeyword;
  Color get highlightStorage;
  Color get highlightFunction;
  Color get highlightType;
  Color get highlightAttribute;
  Color get highlightString;
  Color get highlightComment;
  Color get highlightConstant;
  Color get highlightNumeric;
  Color get highlightVariable;
  Color get highlightTag;
  Color get highlightPunctuation;
  Color get syntaxOperator;
}

/// Long-lived worker that parses markdown off the main
/// isolate.
///
/// Use [MarkdownIsolate.parse] to request a parse. The
/// returned future completes with the result; older
/// in-flight requests are silently dropped on receipt
/// (their results never reach the main isolate, so the
/// stale work the worker did is wasted but harmless).
///
/// All public methods are safe to call from the main isolate.
///
/// ## Multi-session streaming
///
/// Crux lets the user switch sessions freely, and a
/// background session can keep streaming while the user
/// is on a different session. The chat_service runs one
/// stream per session; the [StreamingBubble] widget is
/// mounted only for the *currently viewed* session, so
/// the parse traffic to the worker is naturally bounded
/// by "one bubble at a time" — even with N sessions
/// streaming in parallel, only the visible one submits
/// parse requests.
///
/// When the user switches back to a previously-streaming
/// session, the new [StreamingBubble] mounts, reads the
/// latest content from the controller, and submits a
/// fresh parse. The worker's previous (now-stale) parses
/// for that session's old bubble instance are silently
/// discarded on the main side (the widget's
/// `_lastSubmittedId` no longer matches the response id).
///
/// The worker itself stays alive for the app's lifetime
/// — the ~5 ms spawn cost is paid once, and the steady-
/// state is just a one-deep request queue per call.
class MarkdownIsolate {
  MarkdownIsolate._();

  static MarkdownIsolate? _instance;
  static MarkdownIsolate get instance {
    return _instance ??= MarkdownIsolate._();
  }

  /// Whether the worker isolate has been spawned. Reads
  /// return `false` during the brief startup window between
  /// first request and handshake completion; callers should
  /// treat a `false` value as "fall back to sync parsing".
  bool get isReady => _sendPort != null;

  SendPort? _sendPort;
  ReceivePort? _receivePort;
  StreamSubscription<dynamic>? _subscription;
  Isolate? _isolate;
  int _nextRequestId = 1;
  Completer<void>? _spawnCompleter;

  /// Pending requests keyed by id. We don't strictly need
  /// the map — the worker echoes the id back and the main
  /// side uses the latest id to discard stale results — but
  /// keeping the map lets tests inspect in-flight work.
  final Map<int, _MarkdownParseRequest> _inflight = {};

  /// Ensure the worker is alive. Idempotent.
  Future<void> ensureSpawned() async {
    if (_sendPort != null) return;
    if (_spawnCompleter != null) return _spawnCompleter!.future;

    _spawnCompleter = Completer<void>();
    final readyPort = ReceivePort();
    final handshake = Completer<SendPort>();

    late final StreamSubscription<dynamic> sub;
    sub = readyPort.listen((message) {
      if (!handshake.isCompleted && message is SendPort) {
        handshake.complete(message);
        return;
      }
      _onWorkerMessage(message);
    });

    final isolate = await Isolate.spawn(
      _workerEntryPoint,
      readyPort.sendPort,
      debugName: 'crux-markdown-worker',
    );
    _isolate = isolate;
    _receivePort = readyPort;
    _subscription = sub;

    final sendPort = await handshake.future;
    _sendPort = sendPort;
    _spawnCompleter!.complete();
    _spawnCompleter = null;
  }

  /// Request a parse. Returns the latest result when the
  /// worker finishes. The returned future is unique to the
  /// call — the worker may have already moved on to a newer
  /// request by the time this one is answered; in that case
  /// the result delivered here is still the *response* to
  /// this call's text, not a newer one.
  Future<MarkdownParseResponse> parse({
    required String text,
    required int parsedIndex,
    int? maxWidth,
    required MarkdownParseTheme theme,
  }) async {
    await ensureSpawned();
    final id = _nextRequestId++;
    final completer = Completer<MarkdownParseResponse>();
    _inflight[id] = _MarkdownParseRequest(
      completer: completer,
      text: text,
      parsedIndex: parsedIndex,
    );

    _sendPort!.send(
      _MarkdownParseRequestMessage(
        id: id,
        text: text,
        parsedIndex: parsedIndex,
        maxWidth: maxWidth,
        theme: theme,
      ),
    );

    return completer.future;
  }

  void _onWorkerMessage(dynamic message) {
    if (message is! _MarkdownParseResponseMessage) return;
    final id = message.id;
    final pending = _inflight.remove(id);
    final response = MarkdownParseResponse(
      id: id,
      text: message.text,
      spans: message.spans,
    );
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(response);
    }
  }

  /// Dispose the worker. After this the next `parse` call
  /// respawns it.
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    for (final pending in _inflight.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          StateError('MarkdownIsolate disposed before response'),
        );
      }
    }
    _inflight.clear();
  }
}

class _MarkdownParseRequest {
  _MarkdownParseRequest({
    required this.completer,
    required this.text,
    required this.parsedIndex,
  });

  final Completer<MarkdownParseResponse> completer;
  final String text;
  final int parsedIndex;
}

/// Wire message: main → worker.
class _MarkdownParseRequestMessage {
  _MarkdownParseRequestMessage({
    required this.id,
    required this.text,
    required this.parsedIndex,
    required this.maxWidth,
    required this.theme,
  });

  final int id;
  final String text;
  final int parsedIndex;
  final int? maxWidth;
  final MarkdownParseTheme theme;
}

/// Wire message: worker → main.
class _MarkdownParseResponseMessage {
  _MarkdownParseResponseMessage({
    required this.id,
    required this.text,
    required this.spans,
  });

  final int id;
  final String text;
  final List<MarkdownSpanData> spans;
}

/// Public response shape returned to widget code.
class MarkdownParseResponse {
  MarkdownParseResponse({
    required this.id,
    required this.text,
    required this.spans,
  });

  final int id;
  final String text;
  final List<MarkdownSpanData> spans;
}

/// Single styled text segment. The worker flattens the
/// TextSpan tree to a list of these so we don't have to
/// send TextSpan / TextStyle / Color across the isolate
/// boundary.
class MarkdownSpanData {
  const MarkdownSpanData({
    required this.text,
    this.colorArgb,
    this.backgroundColorArgb,
    this.fontWeight = 0,
    this.fontStyle = 0,
    this.decorationMask = 0,
  });

  final String text;

  /// Packed ARGB color (0xAARRGGBB), or null to inherit.
  final int? colorArgb;

  /// Packed ARGB background, or null.
  final int? backgroundColorArgb;

  /// 0 = normal, 1 = bold, 2 = dim. Matches
  /// [FontWeight.index].
  final int fontWeight;

  /// 0 = normal, 1 = italic. Matches [FontStyle.index].
  final int fontStyle;

  /// Bitmask of underline / lineThrough / overline flags.
  /// Stored as an int so it survives the isolate boundary
  /// without enum registration.
  final int decorationMask;
}

/// Flat, sendable snapshot of the colors the markdown
/// parser needs. Constructed on the main side from a
/// [CruxThemeData], consumed on the worker side to build a
/// [WorkerTheme] for the parser.
class MarkdownParseTheme {
  const MarkdownParseTheme({
    required this.markdownTextArgb,
    required this.thinkingExpandedTextArgb,
    required this.mdH1Argb,
    required this.mdH2Argb,
    required this.mdH3Argb,
    required this.mdH4Argb,
    required this.mdH5Argb,
    required this.mdH6Argb,
    required this.mdBoldArgb,
    required this.mdItalicArgb,
    required this.mdStrikethroughArgb,
    required this.mdInlineCodeArgb,
    required this.mdInlineCodeBgArgb,
    required this.mdCodeBlockTextArgb,
    required this.mdBlockquoteArgb,
    required this.mdLinkArgb,
    required this.codeBlockBackgroundArgb,
    required this.codeBlockGutterArgb,
    required this.codeBlockHeaderArgb,
    required this.outlineArgb,
    required this.surfaceArgb,
    required this.surfaceVariantArgb,
    required this.highlightDefaultArgb,
    required this.highlightKeywordArgb,
    required this.highlightStorageArgb,
    required this.highlightFunctionArgb,
    required this.highlightTypeArgb,
    required this.highlightAttributeArgb,
    required this.highlightStringArgb,
    required this.highlightCommentArgb,
    required this.highlightConstantArgb,
    required this.highlightNumericArgb,
    required this.highlightVariableArgb,
    required this.highlightTagArgb,
    required this.highlightPunctuationArgb,
    required this.syntaxOperatorArgb,
  });

  final int markdownTextArgb;
  final int thinkingExpandedTextArgb;
  final int mdH1Argb;
  final int mdH2Argb;
  final int mdH3Argb;
  final int mdH4Argb;
  final int mdH5Argb;
  final int mdH6Argb;
  final int mdBoldArgb;
  final int mdItalicArgb;
  final int mdStrikethroughArgb;
  final int mdInlineCodeArgb;
  final int mdInlineCodeBgArgb;
  final int mdCodeBlockTextArgb;
  final int mdBlockquoteArgb;
  final int mdLinkArgb;
  final int codeBlockBackgroundArgb;
  final int codeBlockGutterArgb;
  final int codeBlockHeaderArgb;
  final int outlineArgb;
  final int surfaceArgb;
  final int surfaceVariantArgb;
  final int highlightDefaultArgb;
  final int highlightKeywordArgb;
  final int highlightStorageArgb;
  final int highlightFunctionArgb;
  final int highlightTypeArgb;
  final int highlightAttributeArgb;
  final int highlightStringArgb;
  final int highlightCommentArgb;
  final int highlightConstantArgb;
  final int highlightNumericArgb;
  final int highlightVariableArgb;
  final int highlightTagArgb;
  final int highlightPunctuationArgb;
  final int syntaxOperatorArgb;
}

// ============================================================================
// Worker isolate entry point
// ============================================================================

/// Entry point for the markdown worker isolate.
///
/// Sends its incoming [SendPort] to main as the handshake,
/// then loops on a [ReceivePort] — each request is parsed
/// synchronously on the worker's event loop, and the flat
/// span list is shipped back. Parsing is sync (Dart isolates
/// are single-threaded), but it runs on the worker's own
/// event loop — so the main isolate's event loop keeps
/// moving and the chat panel keeps repainting at 60 fps.
void _workerEntryPoint(SendPort mainPort) {
  final port = ReceivePort();
  mainPort.send(port.sendPort);

  port.listen((message) {
    if (message is! _MarkdownParseRequestMessage) return;
    List<MarkdownSpanData> spans;
    try {
      spans = _parseInWorker(
        text: message.text,
        maxWidth: message.maxWidth,
        theme: message.theme,
      );
    } catch (_) {
      // Defensive: an unparseable chunk should not crash
      // the worker. Send back an empty span list; the main
      // side will fall back to plain text rendering.
      spans = const [];
    }
    mainPort.send(
      _MarkdownParseResponseMessage(
        id: message.id,
        text: message.text,
        spans: spans,
      ),
    );
  });
}

List<MarkdownSpanData> _parseInWorker({
  required String text,
  required int? maxWidth,
  required MarkdownParseTheme theme,
}) {
  final workerTheme = WorkerTheme(theme);

  // The worker doesn't initialize HighlightService (the
  // textmate grammars are heavy and live on the main
  // isolate). The parser falls back to unhighlighted code
  // blocks when no highlighter is available — see the
  // sync path's check for `highlightService?.highlighterFor`.
  // The worker doesn't see code-block highlighting, but the
  // user only loses that for code in the *streaming*
  // reasoning block; the next rebuild after the stream
  // settles goes through the sync path and gets the full
  // treatment.
  final spans = parseMarkdownToInlineSpans(
    text,
    workerTheme,
    maxWidth: maxWidth,
  );

  return _flattenWorker(spans);
}

List<MarkdownSpanData> _flattenWorker(List<InlineSpan> spans) {
  final result = <MarkdownSpanData>[];
  for (final span in spans) {
    _flattenOne(span, null, result);
  }
  return result;
}

void _flattenOne(
  InlineSpan span,
  TextStyle? inheritedStyle,
  List<MarkdownSpanData> out,
) {
  if (span is! TextSpan) return;
  final mergedStyle = span.style == null
      ? inheritedStyle
      : inheritedStyle == null
      ? span.style
      : TextStyle(
          color: span.style!.color ?? inheritedStyle.color,
          backgroundColor:
              span.style!.backgroundColor ?? inheritedStyle.backgroundColor,
          fontWeight: span.style!.fontWeight ?? inheritedStyle.fontWeight,
          fontStyle: span.style!.fontStyle ?? inheritedStyle.fontStyle,
          decoration: span.style!.decoration ?? inheritedStyle.decoration,
        );

  final text = span.text;
  if (text != null && text.isNotEmpty) {
    out.add(_toData(text, mergedStyle));
  }
  final children = span.children;
  if (children != null) {
    for (final child in children) {
      _flattenOne(child, mergedStyle, out);
    }
  }
}

MarkdownSpanData _toData(String text, TextStyle? style) {
  return MarkdownSpanData(
    text: text,
    colorArgb: style?.color == null ? null : _argbFromColor(style!.color!),
    backgroundColorArgb: style?.backgroundColor == null
        ? null
        : _argbFromColor(style!.backgroundColor!),
    fontWeight: style?.fontWeight?.index ?? 0,
    fontStyle: style?.fontStyle?.index ?? 0,
    decorationMask: _decorationMaskFromStyle(style?.decoration),
  );
}

int _argbFromColor(Color c) {
  return ((c.alpha & 0xFF) << 24) |
      ((c.red & 0xFF) << 16) |
      ((c.green & 0xFF) << 8) |
      (c.blue & 0xFF);
}

int _decorationMaskFromStyle(TextDecoration? decoration) {
  if (decoration == null) return 0;
  int mask = 0;
  if (decoration == TextDecoration.underline) mask |= 1;
  return mask;
}

/// Worker-side implementation of [MarkdownThemeFields].
/// All colors are stored as packed ARGB ints on the
/// incoming [MarkdownParseTheme] and converted to [Color]
/// on access. The Color objects are not sendable across
/// isolates, but they're cheap to construct — and the
/// worker constructs them lazily on first read.
class WorkerTheme implements MarkdownThemeFields {
  WorkerTheme(this._theme);

  final MarkdownParseTheme _theme;
  final Map<int, Color> _cache = {};

  Color _color(int argb) {
    return _cache.putIfAbsent(argb, () {
      return Color.fromARGB(
        (argb >> 24) & 0xFF,
        (argb >> 16) & 0xFF,
        (argb >> 8) & 0xFF,
        argb & 0xFF,
      );
    });
  }

  @override
  Color get markdownText => _color(_theme.markdownTextArgb);
  @override
  Color get thinkingExpandedText => _color(_theme.thinkingExpandedTextArgb);
  @override
  Color get mdH1 => _color(_theme.mdH1Argb);
  @override
  Color get mdH2 => _color(_theme.mdH2Argb);
  @override
  Color get mdH3 => _color(_theme.mdH3Argb);
  @override
  Color get mdH4 => _color(_theme.mdH4Argb);
  @override
  Color get mdH5 => _color(_theme.mdH5Argb);
  @override
  Color get mdH6 => _color(_theme.mdH6Argb);
  @override
  Color get mdBold => _color(_theme.mdBoldArgb);
  @override
  Color get mdItalic => _color(_theme.mdItalicArgb);
  @override
  Color get mdStrikethrough => _color(_theme.mdStrikethroughArgb);
  @override
  Color get mdInlineCode => _color(_theme.mdInlineCodeArgb);
  @override
  Color get mdInlineCodeBg => _color(_theme.mdInlineCodeBgArgb);
  @override
  Color get mdCodeBlockText => _color(_theme.mdCodeBlockTextArgb);
  @override
  Color get mdBlockquote => _color(_theme.mdBlockquoteArgb);
  @override
  Color get mdLink => _color(_theme.mdLinkArgb);
  @override
  Color get codeBlockBackground => _color(_theme.codeBlockBackgroundArgb);
  @override
  Color get codeBlockGutter => _color(_theme.codeBlockGutterArgb);
  @override
  Color get codeBlockHeader => _color(_theme.codeBlockHeaderArgb);
  @override
  Color get outline => _color(_theme.outlineArgb);
  @override
  Color get surface => _color(_theme.surfaceArgb);
  @override
  Color get surfaceVariant => _color(_theme.surfaceVariantArgb);
  @override
  Color get highlightDefault => _color(_theme.highlightDefaultArgb);
  @override
  Color get highlightKeyword => _color(_theme.highlightKeywordArgb);
  @override
  Color get highlightStorage => _color(_theme.highlightStorageArgb);
  @override
  Color get highlightFunction => _color(_theme.highlightFunctionArgb);
  @override
  Color get highlightType => _color(_theme.highlightTypeArgb);
  @override
  Color get highlightAttribute => _color(_theme.highlightAttributeArgb);
  @override
  Color get highlightString => _color(_theme.highlightStringArgb);
  @override
  Color get highlightComment => _color(_theme.highlightCommentArgb);
  @override
  Color get highlightConstant => _color(_theme.highlightConstantArgb);
  @override
  Color get highlightNumeric => _color(_theme.highlightNumericArgb);
  @override
  Color get highlightVariable => _color(_theme.highlightVariableArgb);
  @override
  Color get highlightTag => _color(_theme.highlightTagArgb);
  @override
  Color get highlightPunctuation => _color(_theme.highlightPunctuationArgb);
  @override
  Color get syntaxOperator => _color(_theme.syntaxOperatorArgb);
}

// ============================================================================
// Reconstructing TextSpan from MarkdownSpanData
// ============================================================================

/// Rebuild a `List<InlineSpan>` from a flat list of
/// [MarkdownSpanData]. Used by widget code on the main
/// isolate after receiving a parse result.
List<InlineSpan> reconstructInlineSpans(List<MarkdownSpanData> data) {
  return data
      .map(
        (d) => TextSpan(
          text: d.text,
          style: TextStyle(
            color: d.colorArgb == null
                ? null
                : Color.fromARGB(
                    (d.colorArgb! >> 24) & 0xFF,
                    (d.colorArgb! >> 16) & 0xFF,
                    (d.colorArgb! >> 8) & 0xFF,
                    d.colorArgb! & 0xFF,
                  ),
            backgroundColor: d.backgroundColorArgb == null
                ? null
                : Color.fromARGB(
                    (d.backgroundColorArgb! >> 24) & 0xFF,
                    (d.backgroundColorArgb! >> 16) & 0xFF,
                    (d.backgroundColorArgb! >> 8) & 0xFF,
                    d.backgroundColorArgb! & 0xFF,
                  ),
            fontWeight: _fontWeightFromIndex(d.fontWeight),
            fontStyle: _fontStyleFromIndex(d.fontStyle),
            decoration: _decorationFromMask(d.decorationMask),
          ),
        ),
      )
      .toList();
}

FontWeight? _fontWeightFromIndex(int index) {
  switch (index) {
    case 0:
      return FontWeight.normal;
    case 1:
      return FontWeight.bold;
    case 2:
      return FontWeight.dim;
    default:
      return null;
  }
}

FontStyle? _fontStyleFromIndex(int index) {
  switch (index) {
    case 0:
      return FontStyle.normal;
    case 1:
      return FontStyle.italic;
    default:
      return null;
  }
}

TextDecoration? _decorationFromMask(int mask) {
  if (mask == 0) return null;
  if ((mask & 1) != 0) return TextDecoration.underline;
  return null;
}

// ============================================================================
// Building MarkdownParseTheme from CruxThemeData
// ============================================================================

/// Build a [MarkdownParseTheme] (the cross-isolate snapshot)
/// from a [CruxThemeData]. Cheap: just packs colors.
MarkdownParseTheme buildMarkdownParseTheme(MarkdownThemeFields theme) {
  int argb(Color c) =>
      ((c.alpha & 0xFF) << 24) |
      ((c.red & 0xFF) << 16) |
      ((c.green & 0xFF) << 8) |
      (c.blue & 0xFF);

  return MarkdownParseTheme(
    markdownTextArgb: argb(theme.markdownText),
    thinkingExpandedTextArgb: argb(theme.thinkingExpandedText),
    mdH1Argb: argb(theme.mdH1),
    mdH2Argb: argb(theme.mdH2),
    mdH3Argb: argb(theme.mdH3),
    mdH4Argb: argb(theme.mdH4),
    mdH5Argb: argb(theme.mdH5),
    mdH6Argb: argb(theme.mdH6),
    mdBoldArgb: argb(theme.mdBold),
    mdItalicArgb: argb(theme.mdItalic),
    mdStrikethroughArgb: argb(theme.mdStrikethrough),
    mdInlineCodeArgb: argb(theme.mdInlineCode),
    mdInlineCodeBgArgb: argb(theme.mdInlineCodeBg),
    mdCodeBlockTextArgb: argb(theme.mdCodeBlockText),
    mdBlockquoteArgb: argb(theme.mdBlockquote),
    mdLinkArgb: argb(theme.mdLink),
    codeBlockBackgroundArgb: argb(theme.codeBlockBackground),
    codeBlockGutterArgb: argb(theme.codeBlockGutter),
    codeBlockHeaderArgb: argb(theme.codeBlockHeader),
    outlineArgb: argb(theme.outline),
    surfaceArgb: argb(theme.surface),
    surfaceVariantArgb: argb(theme.surfaceVariant),
    highlightDefaultArgb: argb(theme.highlightDefault),
    highlightKeywordArgb: argb(theme.highlightKeyword),
    highlightStorageArgb: argb(theme.highlightStorage),
    highlightFunctionArgb: argb(theme.highlightFunction),
    highlightTypeArgb: argb(theme.highlightType),
    highlightAttributeArgb: argb(theme.highlightAttribute),
    highlightStringArgb: argb(theme.highlightString),
    highlightCommentArgb: argb(theme.highlightComment),
    highlightConstantArgb: argb(theme.highlightConstant),
    highlightNumericArgb: argb(theme.highlightNumeric),
    highlightVariableArgb: argb(theme.highlightVariable),
    highlightTagArgb: argb(theme.highlightTag),
    highlightPunctuationArgb: argb(theme.highlightPunctuation),
    syntaxOperatorArgb: argb(theme.syntaxOperator),
  );
}
