// Markdown text rendering needs nocterm's internal unicode-width helpers to
// measure CJK and emoji segments for wrapping. Not re-exported publicly.
// ignore_for_file: implementation_imports

import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/utils/unicode_width.dart';

import 'highlight_service.dart';
import 'markdown_isolate.dart';
import '../../theme/crux_theme.dart';
import '../../utils/frame_profiler.dart';
import '../../utils/markdown_links.dart';
import '../../utils/quick_reply_parser.dart';
import '../../utils/session_refs.dart';

class HighlightedMarkdownText extends StatefulComponent {
  const HighlightedMarkdownText(
    this.data, {
    super.key,
    this.textAlign = TextAlign.left,
    this.softWrap = true,
    this.overflow = TextOverflow.clip,
    this.maxLines,
    this.styleSheet,
    this.highlightText,
    this.useIsolate = false,
    this.onSessionLinkTap,
    this.sessionLinkStyle,
    this.sessionLinkHoverStyle,
    this.onQuickReplyTap,
    this.quickReplyStyle,
    this.quickReplyHoverStyle,
    this.onLinkTap,
    this.linkStyle,
    this.linkHoverStyle,
  });

  final String data;
  final TextAlign textAlign;
  final bool softWrap;
  final TextOverflow overflow;
  final int? maxLines;
  final HighlightMarkdownStyleSheet? styleSheet;
  final String? highlightText;

  /// Whether to parse markdown on a background isolate.
  /// Defaults to `false` — sync parsing is the simpler
  /// path and works well for the common case of short
  /// static content (a finished message, a tool result,
  /// a TLDR summary).
  ///
  /// Set to `true` for content that updates at frame
  /// rate — i.e. the streaming reasoning block in the
  /// live bubble, where the markdown parse would
  /// otherwise run on the main isolate every frame and
  /// starve the chat panel. The streaming bubble is
  /// the only call site that currently opts in; the rest
  /// of the app is fine with sync.
  final bool useIsolate;

  /// Callback fired when the user clicks a `ses://<id>` reference
  /// in the rendered text. Receives the parsed session id.
  ///
  /// When `null` (the default), the widget skips parsing session
  /// refs entirely — there's zero per-build cost for callers that
  /// don't care. The feature is also skipped on the isolate parse
  /// path (`useIsolate: true`); streaming bubbles don't typically
  /// carry clickable refs and the main-isolate overlay pass would
  /// race with the worker's per-frame span updates.
  final void Function(int sessionId)? onSessionLinkTap;

  /// Override the style applied to recognized `ses://` regions.
  /// Defaults to the theme's `tldrLink` color + underline.
  final TextStyle? sessionLinkStyle;

  /// Override the hover style. Defaults to a reverse-video treatment
  /// using `tldrLink` as the background.
  final TextStyle? sessionLinkHoverStyle;

  /// Callback fired when the user clicks a quick-reply token
  /// (`ask://label{answer}` or `ask://label`) in the rendered text.
  /// Receives the parsed [QuickReply].
  ///
  /// When `null` (the default), the widget skips parsing quick
  /// replies entirely — zero per-build cost for callers that don't
  /// care. Like `onSessionLinkTap`, this is also skipped on the
  /// isolate parse path (`useIsolate: true`).
  final void Function(QuickReply reply)? onQuickReplyTap;

  /// Override the style applied to recognized `ask://` regions.
  /// Defaults to the theme's button background as the cell color
  /// with bold text — gives the rendered label a clear button-like
  /// affordance. The label replaces the source `ask://…` text in
  /// the rendered output; this style is what makes it look like a
  /// button rather than ordinary prose.
  final TextStyle? quickReplyStyle;

  /// Override the hover style. Defaults to a reverse-video treatment
  /// using `buttonBackgroundHover` as the background.
  final TextStyle? quickReplyHoverStyle;

  /// Callback fired when the user clicks a markdown link
  /// (`[label](url)`) in the rendered text. Receives the parsed
  /// [MarkdownLink] (label, url, and offsets). The caller is
  /// responsible for filtering unsafe URL schemes (e.g. `file:`,
  /// `javascript:`) before opening — the parser passes the URL
  /// through verbatim.
  ///
  /// When `null` (the default), the widget still hides the URL
  /// when a label is present (so `[Flutter](https://flutter.dev)`
  /// renders as just `Flutter`), but doesn't wire up any click
  /// handling. The link-styled spans are still emitted so they
  /// look clickable, but the user can only copy the URL by
  /// selecting the underlying text. Set this to make the link
  /// actually clickable.
  ///
  /// The feature is skipped on the isolate parse path
  /// (`useIsolate: true`); streaming bubbles don't typically
  /// carry clickable links and the main-isolate overlay pass
  /// would race with the worker's per-frame span updates.
  final void Function(MarkdownLink link)? onLinkTap;

  /// Override the style applied to recognized markdown links.
  /// Defaults to the theme's `mdLink` color + underline.
  final TextStyle? linkStyle;

  /// Override the hover style. Defaults to a reverse-video
  /// treatment using `mdLink` as the background.
  final TextStyle? linkHoverStyle;

  @override
  State<HighlightedMarkdownText> createState() =>
      _HighlightedMarkdownTextState();
}

class _HighlightedMarkdownTextState extends State<HighlightedMarkdownText> {
  /// Latest parse result from the worker isolate (or
  /// the synchronous path). The widget renders whatever
  /// is here — the main isolate does no parsing, no
  /// plain-text fallback, no incremental merging. The
  /// worker returns the parsed result and the main
  /// isolate paints it; the latest result always wins.
  ///
  /// This is the simplest design that achieves the
  /// user's stated goal: "main thread does nothing,
  /// patient wait for the worker, send the latest
  /// content after the worker returns". All the
  /// in-flight coalescing / plain-text tail tricks
  /// tried in earlier iterations were attempts to
  /// bridge the data-arrives-faster-than-parse gap,
  /// but the cleaner outcome is to just accept that
  /// the parsed view is always a few chars behind
  /// the raw stream — the user sees formatted markdown
  /// once the parse lands, and the unparsed tail
  /// simply isn't visible until the next parse.
  List<InlineSpan> _spans = const [];

  /// True while a parse is in flight on the worker
  /// isolate. Used for simple coalescing: while one
  /// parse is running, the main isolate doesn't enqueue
  /// another — the in-flight parse covers "all data so
  /// far", and we submit a follow-up from the .then()
  /// callback if the data has changed in the meantime.
  bool _inFlight = false;

  /// Last parameters seen by the build. Used to
  /// short-circuit re-submitting a parse when nothing
  /// has actually changed (e.g. the chat panel rebuilds
  /// for an unrelated reason).
  int? _lastMaxWidth;
  String? _lastData;
  HighlightMarkdownStyleSheet? _lastStyleSheet;
  String? _lastThemeId;

  /// Session refs parsed from the current spans. Cached per data
  /// change alongside `_spans` — the overlay pass in [_buildInner]
  /// re-runs cheaply on every hover/state change without re-parsing.
  List<SessionRef> _sessionRefs = const [];

  /// Quick-reply tokens parsed from the current spans. Same
  /// caching policy as `_sessionRefs`.
  List<QuickReply> _quickReplies = const [];

  /// Markdown links (`[label](url)`) parsed from the current
  /// spans. Same caching policy as `_sessionRefs`. Populated by
  /// the visitor during the markdown parse (sync path only) and
  /// surfaces the visible label and underlying href along with
  /// the rendered-text offset so the hit-tester can locate them.
  List<MarkdownLink> _markdownLinks = const [];

  /// Which ref (if any) the mouse is currently over. Drives the
  /// hover-style overlay and the click target.
  SessionRef? _hoveredSessionRef;

  /// Which quick reply (if any) the mouse is currently over. Mutually
  /// exclusive with [_hoveredSessionRef] — a single mouse position
  /// can only hover one clickable region at a time.
  QuickReply? _hoveredQuickReply;

  /// Which markdown link (if any) the mouse is currently over.
  /// Mutually exclusive with [_hoveredSessionRef] and
  /// [_hoveredQuickReply] — a single mouse position can only
  /// hover one clickable region at a time.
  MarkdownLink? _hoveredMarkdownLink;

  /// Key on the inner [RichText] used to locate the [RenderParagraph]
  /// for hit-testing — see [_linkAtEvent].
  final GlobalKey _richTextKey = GlobalKey();

  @override
  Component build(BuildContext context) {
    return FrameProfiler.instance.timed(
      'highlightedMarkdownText.build',
      () => _buildInner(context),
    );
  }

  Component _buildInner(BuildContext context) {
    final theme = CruxTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth.toInt()
            : null;

        final data = component.data;
        final styleSheet = component.styleSheet;
        final highlight = component.highlightText;
        final wantLinks =
            component.onSessionLinkTap != null && !component.useIsolate;
        final wantQuickReplies =
            component.onQuickReplyTap != null && !component.useIsolate;
        final wantMarkdownLinks =
            component.onLinkTap != null && !component.useIsolate;

        final dataChanged = data != _lastData;
        final paramsChanged = styleSheet != _lastStyleSheet ||
            theme.id != _lastThemeId ||
            maxWidth != _lastMaxWidth;
        if (dataChanged || paramsChanged) {
          _lastData = data;
          _lastStyleSheet = styleSheet;
          _lastMaxWidth = maxWidth;
          _lastThemeId = theme.id;
          if (component.useIsolate) {
            // Fire-and-forget. The worker processes
            // requests in order, so the latest result
            // is the one we want. If a parse is already
            // in flight, the .then() callback checks
            // whether data has changed and submits a
            // follow-up — no need to enqueue here.
            _scheduleParse(theme, data, maxWidth);
          } else {
            // Sync path — used for short static content
            // where a one-shot parse is cheaper than
            // spinning up the isolate. The result is
            // cached in `_spans` and reused on every
            // rebuild until `data` changes.
            //
            // The visitor collects markdown links alongside
            // the spans so we don't pay a second walk over
            // the rendered text just to recover the offsets
            // (which would be brittle — see the
            // _HighlightMarkdownVisitor notes).
            final collectedLinks = <MarkdownLink>[];
            _spans = parseMarkdownToInlineSpans(
              data,
              theme,
              maxWidth: maxWidth,
              styleSheet: styleSheet,
              collectedLinks: collectedLinks,
            );
            _markdownLinks = collectedLinks;
          }
          // Re-parse session refs and quick replies alongside the
          // markdown parse so they stay in lockstep. Each is a
          // cheap single-pass regex over the rendered text outside
          // code spans.
          //
          // Quick replies are parsed UNCONDITIONALLY (not gated on
          // `wantQuickReplies`) because the renderer also uses the
          // result in label-only mode for stale turns — see the
          // build branch below. The parse is a single regex pass
          // over the rendered spans, comparable in cost to the
          // session-refs pass.
          _sessionRefs =
              wantLinks ? parseSessionRefs(_spans) : const [];
          _hoveredSessionRef = null;
          _quickReplies = component.useIsolate
              ? const []
              : parseQuickReplies(_spans);
          _hoveredQuickReply = null;
          // Markdown links are collected by the visitor itself on
          // the sync path (see _spans above); the isolate path
          // yields an empty list because we don't ship link
          // metadata across the worker boundary. The click
          // handling is also disabled for isolate-mode callsites
          // (see the wantMarkdownLinks gate).
          if (component.useIsolate) {
            _markdownLinks = const [];
          }
          _hoveredMarkdownLink = null;
        }

        // Apply search highlight as a sync overlay. Cheap
        // (no parse, just a flat scan + style merge). The
        // highlight is independent of the parse so we don't
        // need to invalidate the parsed cache when it
        // changes.
        var renderedSpans = _spans;
        if (highlight != null && highlight.isNotEmpty) {
          renderedSpans = _applyHighlight(
            _spans,
            highlight,
            theme,
            selectionColor: theme.selection,
            onSelection: (c) => theme.onColor(c),
          );
        }

        // Decide whether any clickable region exists. Each feature
        // can independently contribute — neither requires the other.
        //
        // Quick replies have two display modes:
        //   * **Button mode** (`wantQuickReplies` true — i.e. the
        //     message is the latest AI turn and no turn is
        //     currently streaming): the label is rendered with
        //     button styling and the click handler is wired up.
        //   * **Label-only mode** (stale turn — `wantQuickReplies`
        //     false but there ARE `ask://` tokens in the spans):
        //     the source text is replaced with the label, but with
        //     no styling and no click handler. The result is
        //     indistinguishable from ordinary prose — a user
        //     scrolling up to an old turn sees just the labels as
        //     normal text, with no `ask://…` syntax leaking
        //     through.
        final haveSessionLinks = wantLinks && _sessionRefs.isNotEmpty;
        final haveMarkdownLinks = wantMarkdownLinks && _markdownLinks.isNotEmpty;
        final haveButtonReplies =
            wantQuickReplies && _quickReplies.isNotEmpty;
        final haveStaleReplies =
            !wantQuickReplies && _quickReplies.isNotEmpty;
        final haveAnyReplies = haveButtonReplies || haveStaleReplies;

        // Overlay session-link styles on top of the highlight pass
        // so links inherit the search-highlight background. The
        // hover style wins over the link style for the specific
        // ref under the cursor.
        if (haveSessionLinks) {
          final linkStyle = component.sessionLinkStyle ??
              TextStyle(
                color: theme.tldrLink,
                decoration: TextDecoration.underline,
              );
          final hoverStyle = component.sessionLinkHoverStyle ??
              TextStyle(
                color: theme.onColor(theme.tldrLink),
                backgroundColor: theme.tldrLink,
                fontWeight: FontWeight.bold,
              );
          renderedSpans = applySessionLinkStyles(
            renderedSpans,
            _sessionRefs,
            linkStyle,
            hoverStyle,
            _hoveredSessionRef,
          );
        }

        // Overlay markdown-link styles on top of the highlight and
        // session-link passes. The hover style wins over the link
        // style for the specific link under the cursor. We run this
        // AFTER session links so the visitor's link style (already
        // emitted on the raw span) wins on the non-hovered state —
        // the overlay only kicks in to (a) layer in the theme's
        // `mdLink` color when the caller's style sheet omitted one
        // and (b) swap to the hover style for the hovered link.
        //
        // When `component.linkStyle` is null we still apply the
        // overlay so the underline + color from the theme's
        // `mdLink` is preserved uniformly across callers. The
        // visitor already styles link spans with the same color, so
        // the no-op merge is cheap.
        if (haveMarkdownLinks) {
          final linkStyle = component.linkStyle ??
              TextStyle(
                color: theme.mdLink,
                decoration: TextDecoration.underline,
              );
          final hoverStyle = component.linkHoverStyle ??
              TextStyle(
                color: theme.onColor(theme.mdLink),
                backgroundColor: theme.mdLink,
                fontWeight: FontWeight.bold,
              );
          renderedSpans = applyMarkdownLinkStyles(
            renderedSpans,
            _markdownLinks,
            linkStyle,
            hoverStyle,
            _hoveredMarkdownLink,
          );
        }

        // Overlay quick-reply rendering on top of whatever came
        // before. The renderer ALWAYS substitutes the source
        // `ask://…` text with the reply's `label` — the wire
        // syntax is never shown to the user. The button styling
        // is applied only in button mode; in stale mode the label
        // is emitted with the surrounding baseStyle so the result
        // is indistinguishable from normal prose. The renderer
        // also records each reply's `renderedStart` / `renderedLength`
        // so hit-testing (in button mode only) can locate the
        // substituted label.
        if (haveButtonReplies) {
          final buttonStyle = component.quickReplyStyle ??
              TextStyle(
                color: theme.buttonTextDisabled,
                backgroundColor: theme.buttonBackground,
                fontWeight: FontWeight.bold,
              );
          final hoverStyle = component.quickReplyHoverStyle ??
              TextStyle(
                color: theme.buttonTextHover,
                backgroundColor: theme.buttonBackgroundHover,
                fontWeight: FontWeight.bold,
                decoration: TextDecoration.underline,
              );
          renderedSpans = applyQuickReplyTokens(
            renderedSpans,
            _quickReplies,
            buttonStyle: buttonStyle,
            hoverStyle: hoverStyle,
            hoveredReply: _hoveredQuickReply,
          );
        } else if (haveStaleReplies) {
          renderedSpans = applyQuickReplyTokens(
            renderedSpans,
            _quickReplies,
          );
        }

        final richText = RichText(
          key: _richTextKey,
          text: TextSpan(children: renderedSpans),
          textAlign: component.textAlign,
          softWrap: component.softWrap,
          overflow: component.overflow,
          maxLines: component.maxLines,
          selectionTextTransformer: _stripCodeBlockSelectionChrome,
          selectionHighlightPredicate: _shouldHighlightMarkdownSelection,
        );

        if (!haveSessionLinks && !haveAnyReplies && !haveMarkdownLinks) {
          return richText;
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleTap,
          child: MouseRegion(
            opaque: true,
            onHover: _handleHover,
            onExit: (_) {
              if (_hoveredSessionRef != null ||
                  _hoveredQuickReply != null ||
                  _hoveredMarkdownLink != null) {
                setState(() {
                  _hoveredSessionRef = null;
                  _hoveredQuickReply = null;
                  _hoveredMarkdownLink = null;
                });
              }
            },
            child: richText,
          ),
        );
      },
    );
  }

  RenderParagraph? get _renderParagraph {
    final ctx = _richTextKey.currentContext;
    if (ctx == null) return null;
    final el = ctx as Element;
    if (el is RenderObjectElement) {
      final ro = el.renderObject;
      if (ro is RenderParagraph) return ro;
    }
    return null;
  }

  void _handleHover(MouseEvent event) {
    final hit = _linkAtEvent(event);
    final newSession = hit is SessionRef ? hit : null;
    final newReply = hit is QuickReply ? hit : null;
    final newLink = hit is MarkdownLink ? hit : null;

    final sessionChanged = newSession?.sessionId != _hoveredSessionRef?.sessionId;
    final replyChanged = !_sameQuickReply(newReply, _hoveredQuickReply);
    final linkChanged = !_sameMarkdownLink(newLink, _hoveredMarkdownLink);

    if (!sessionChanged && !replyChanged && !linkChanged && hit == null) return;

    setState(() {
      _hoveredSessionRef = newSession;
      _hoveredQuickReply = newReply;
      _hoveredMarkdownLink = newLink;
    });
  }

  void _handleTap() {
    final ref = _hoveredSessionRef;
    if (ref != null) {
      component.onSessionLinkTap?.call(ref.sessionId);
      return;
    }
    final link = _hoveredMarkdownLink;
    if (link != null) {
      component.onLinkTap?.call(link);
      return;
    }
    final reply = _hoveredQuickReply;
    if (reply != null) {
      component.onQuickReplyTap?.call(reply);
    }
  }

  Object? _linkAtEvent(MouseEvent event) {
    if (_sessionRefs.isEmpty &&
        _quickReplies.isEmpty &&
        _markdownLinks.isEmpty) {
      return null;
    }
    final rp = _renderParagraph;
    if (rp == null) return null;

    final localX = event.x.toDouble() - rp.globalPaintOffset.dx;
    final localY = event.y.toDouble() - rp.globalPaintOffset.dy;
    if (localX < 0 || localY < 0) return null;

    final charIndex = rp.getCharacterIndexAtLocalPosition(
      Offset(localX, localY),
    );

    // Session refs take precedence — they're the more established
    // feature. If both happen to land on the same char (extremely
    // unlikely in practice), the session ref wins.
    for (final ref in _sessionRefs) {
      if (ref.containsIndex(charIndex)) return ref;
    }
    // Markdown links come next. They're more specific to the
    // current text than quick replies (which are wire-format
    // tokens the user shouldn't normally see), so a click on
    // `[Open](https://example.com)` opens the URL even if the
    // surrounding text contains an `ask://` token. The two
    // regions overlap only by extreme coincidence.
    for (final link in _markdownLinks) {
      if (link.containsIndex(charIndex)) return link;
    }
    // Quick-reply hit-testing reads [renderedStart] (NOT
    // [sourceStart]) because the renderer has substituted the
    // source `ask://…` text with the (typically shorter) label.
    // The `charIndex` from the layout engine is in the rendered
    // text's coordinate space, so it would not align with the
    // source offsets after substitution. See
    // [QuickReply.containsRenderedIndex].
    for (final reply in _quickReplies) {
      if (reply.containsRenderedIndex(charIndex)) return reply;
    }
    return null;
  }

  static bool _sameQuickReply(QuickReply? a, QuickReply? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    // Match on rendered position when both are populated (the
    // common case after at least one render pass). Fall back to
    // source position so two never-rendered replies still compare
    // correctly during the brief window between parse and first
    // render — defensive only.
    final aR = a.renderedStart;
    final bR = b.renderedStart;
    if (aR != null && bR != null) {
      return aR == bR && a.renderedLength == b.renderedLength;
    }
    return a.sourceStart == b.sourceStart && a.sourceLength == b.sourceLength;
  }

  static bool _sameMarkdownLink(MarkdownLink? a, MarkdownLink? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    // Compare by rendered position so a re-parse that produces a
    // fresh MarkdownLink instance for the same region doesn't
    // count as a hover change (which would re-trigger a
    // setState + repaint on every cursor move). Compare URLs as
    // a tiebreaker in case two adjacent links happen to share
    // offsets — defensive only.
    return a.offset == b.offset &&
        a.length == b.length &&
        a.url == b.url;
  }

  /// Submit a parse request to the worker. The result is
  /// applied in [_applyParse] when it arrives. If a
  /// parse is already in flight, this is a no-op — the
  /// in-flight parse covers "all data so far", and
  /// [_applyParse] will submit a follow-up if more data
  /// arrived in the meantime.
  void _scheduleParse(
    MarkdownThemeFields theme,
    String data,
    int? maxWidth,
  ) {
    if (_inFlight) return;
    _inFlight = true;
    _drainParse(theme, data, maxWidth);
  }

  /// Send a single parse to the worker. On success,
  /// apply the result and check whether the data has
  /// grown since submission; if so, submit a follow-up.
  /// On failure, just clear `_inFlight` — the next
  /// build will retry.
  void _drainParse(
    MarkdownThemeFields theme,
    String data,
    int? maxWidth,
  ) {
    MarkdownIsolate.instance.ensureSpawned().then((_) async {
      try {
        final response = await MarkdownIsolate.instance.parse(
          text: data,
          parsedIndex: 0,
          maxWidth: maxWidth,
          theme: buildMarkdownParseTheme(theme),
        );
        if (!mounted) {
          _inFlight = false;
          return;
        }
        _applyParse(response, data);
        // If data has grown since the parse was
        // submitted, fire a follow-up for the latest
        // text. This is the only place we enqueue a
        // new parse while `_inFlight` was true — we
        // recurse into `_drainParse` directly rather
        // than going through `_scheduleParse` (which
        // would short-circuit on the in-flight check).
        final current = _lastData ?? '';
        if (current != data) {
          _drainParse(theme, current, maxWidth);
        } else {
          _inFlight = false;
        }
      } catch (_) {
        // Errors are swallowed: a failed parse simply
        // means the user keeps seeing whatever the
        // last successful result was, until the next
        // data change retries.
        _inFlight = false;
      }
    });
  }

  /// Apply a parse response. Always takes the result —
  /// the "latest wins" semantics the user asked for.
  /// A stale result (i.e. the data has since changed)
  /// is still applied, since the rendering cost is
  /// trivial and the user would rather see slightly
  /// stale formatting than nothing.
  void _applyParse(MarkdownParseResponse response, String submittedFor) {
    if (!mounted) return;
    _spans = reconstructInlineSpans(response.spans);
    setState(() {});
  }
}

bool _shouldHighlightMarkdownSelection(String text) {
  if (text.isEmpty) return true;
  if (_isCodeBlockTopBorder(text) || _isCodeBlockBottomBorder(text)) {
    return false;
  }
  if (text == '│' || text == '│ ' || text == ' │') {
    return false;
  }
  if (RegExp(r'^[┌└─┐┘ ]+$').hasMatch(text) &&
      (text.contains('┌') || text.contains('└') || text.contains('─'))) {
    return false;
  }
  return true;
}

String _stripCodeBlockSelectionChrome(String text) {
  if (!text.contains('│') && !text.contains('┌') && !text.contains('└')) {
    return text;
  }

  final endsWithNewline = text.endsWith('\n');
  final lines = text.split('\n');
  if (endsWithNewline && lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }

  final cleaned = <String>[];
  var inCodeBlock = false;
  for (final line in lines) {
    if (_isCodeBlockTopBorder(line)) {
      inCodeBlock = true;
      continue;
    }
    if (_isCodeBlockBottomBorder(line)) {
      inCodeBlock = false;
      continue;
    }
    if (inCodeBlock || _looksLikePartialCodeBlockRow(line)) {
      cleaned.add(_stripCodeBlockRowChrome(line));
    } else {
      cleaned.add(line);
    }
  }

  final result = cleaned.join('\n');
  return endsWithNewline ? '$result\n' : result;
}

bool _isCodeBlockTopBorder(String line) =>
    line.startsWith('┌') && line.contains('─');

bool _isCodeBlockBottomBorder(String line) =>
    line.startsWith('└') && line.contains('─');

bool _looksLikePartialCodeBlockRow(String line) {
  if (!line.startsWith('│ ')) return false;
  final rest = line.substring(2);
  return !rest.contains('│') || rest.endsWith(' │');
}

String _stripCodeBlockRowChrome(String line) {
  var result = line;
  if (result.startsWith('│ ')) {
    result = result.substring(2);
  } else if (result.startsWith('│')) {
    result = result.substring(1);
  }

  if (result.endsWith(' │')) {
    result = result.substring(0, result.length - 2).trimRight();
  } else if (result.endsWith('│')) {
    result = result.substring(0, result.length - 1).trimRight();
  }
  return result;
}

List<InlineSpan> _applyHighlight(
  List<InlineSpan> spans,
  String search,
  MarkdownThemeFields theme, {
  required Color selectionColor,
  required Color Function(Color) onSelection,
}) {
  final flat = _flattenSpans(spans);
  final plainText = flat.map((e) => e.$1).join();

  final matchRange = _findHighlightRange(plainText, search);
  if (matchRange == null) return spans;

  final (index, end) = matchRange;
  final result = <_FlatSpan>[];
  int pos = 0;
  for (final span in flat) {
    final spanStart = pos;
    final spanEnd = pos + span.$1.length;
    if (spanEnd <= index || spanStart >= end) {
      result.add(span);
    } else {
      final before = index > spanStart
          ? span.$1.substring(0, index - spanStart)
          : '';
      final match = span.$1.substring(
        index.clamp(spanStart, spanEnd) - spanStart,
        end.clamp(spanStart, spanEnd) - spanStart,
      );
      final after = end < spanEnd ? span.$1.substring(end - spanStart) : '';
      if (before.isNotEmpty) result.add((before, span.$2));
      result.add(
        (match, _mergedWithHighlight(span.$2, selectionColor, onSelection)),
      );
      if (after.isNotEmpty) result.add((after, span.$2));
    }
    pos = spanEnd;
  }
  return _unflattenSpans(result);
}

(int, int)? _findHighlightRange(String plainText, String search) {
  if (search.isEmpty) return null;

  final exact = plainText.indexOf(search);
  if (exact >= 0) return (exact, exact + search.length);

  final normText = _norm(plainText);
  final normSearch = _norm(search);
  final normIdx = normText.indexOf(normSearch);
  if (normIdx >= 0) {
    return _recoverRange(plainText, normText, normIdx, normSearch.length);
  }

  return _wordOverlapRange(plainText, search);
}

String _norm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

(int, int)? _recoverRange(
  String text,
  String normText,
  int normStart,
  int normLen,
) {
  int charPos = 0;
  int normPos = 0;
  int start = -1;

  while (charPos < text.length && normPos < normStart) {
    final ch = text[charPos];
    charPos++;
    if (ch == ' ' || ch == '\n' || ch == '\t') {
      while (charPos < text.length &&
          (text[charPos] == ' ' ||
              text[charPos] == '\n' ||
              text[charPos] == '\t')) {
        charPos++;
      }
    }
    normPos++;
  }

  start = charPos;
  int normEnd = normStart + normLen;
  while (charPos < text.length && normPos < normEnd) {
    final ch = text[charPos];
    charPos++;
    if (ch == ' ' || ch == '\n' || ch == '\t') {
      while (charPos < text.length &&
          (text[charPos] == ' ' ||
              text[charPos] == '\n' ||
              text[charPos] == '\t')) {
        charPos++;
      }
    }
    normPos++;
  }

  return (start, charPos);
}

(int, int)? _wordOverlapRange(String plainText, String search) {
  final excerptWords = _norm(
    search,
  ).split(' ').where((w) => w.length > 2).toList();
  if (excerptWords.isEmpty) return null;

  final windowSize = search.length * 2;
  final step = (windowSize / 2).floor();

  int bestStart = 0;
  double bestScore = 0;

  for (int start = 0; start < plainText.length; start += step) {
    final end = (start + windowSize).clamp(0, plainText.length);
    final window = plainText.substring(start, end);
    final windowNorm = _norm(window);

    int matched = 0;
    for (final word in excerptWords) {
      if (windowNorm.contains(word)) matched++;
    }

    final score = matched / excerptWords.length;
    if (score > bestScore) {
      bestScore = score;
      bestStart = start;
    }
  }

  if (bestScore >= 0.6) {
    final end = (bestStart + windowSize).clamp(0, plainText.length);
    return (bestStart, end);
  }
  return null;
}

TextStyle? _mergedWithHighlight(
  TextStyle? base,
  Color selectionColor,
  Color Function(Color) onSelection,
) {
  return TextStyle(
    color: onSelection(selectionColor),
    backgroundColor: selectionColor,
    fontWeight: FontWeight.bold,
    fontStyle: base?.fontStyle,
    decoration: base?.decoration,
  );
}

/// Parses [text] as GitHub-Flavored Markdown and returns a flat list of
/// [InlineSpan]s suitable for terminal rendering.
///
/// This is the shared entry point used by every markdown-aware widget
/// in the app (the main chat response renderer, the TLDR summary
/// renderer, the BTW bubble, tool detail panes, etc.) so they all
/// produce visually consistent output — including tables, code
/// blocks, and the full box-drawing border treatment.
///
/// Pass [maxWidth] to constrain the rendered width to the available
/// terminal columns; tables, code blocks, and HR rules respect this
/// value. [styleSheet] overrides the theme-derived default styles.
///
/// When [collectedLinks] is supplied, the visitor records every
/// markdown link it emits into that list (in source order) along
/// with the visible label, the underlying URL, and the offset /
/// length in the rendered text. This is the cheapest way to surface
/// clickable regions: tracking happens during the same walk that
/// builds the spans, so there's no post-hoc flat-scan cost. When
/// omitted, the visitor skips the bookkeeping entirely.
List<InlineSpan> parseMarkdownToInlineSpans(
  String text,
  MarkdownThemeFields theme, {
  int? maxWidth,
  HighlightMarkdownStyleSheet? styleSheet,
  List<MarkdownLink>? collectedLinks,
}) {
  // Build the per-call style sheet from the theme when none
  // is supplied. The [HighlightMarkdownStyleSheet] factory
  // reads the same `MarkdownThemeFields` getters the
  // visitor does, so a [WorkerTheme] from the markdown
  // isolate also works here.
  final effectiveStyleSheet = styleSheet ??
      HighlightMarkdownStyleSheet.fromThemeFields(theme);
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  final nodes = document.parse(text);

  final visitor = _HighlightMarkdownVisitor(
    effectiveStyleSheet,
    theme: theme,
    maxWidth: maxWidth,
    collectedLinks: collectedLinks,
  );
  return visitor.visitNodes(nodes);
}

typedef _FlatSpan = (String, TextStyle?);

List<_FlatSpan> _flattenSpans(List<InlineSpan> spans) {
  final result = <_FlatSpan>[];
  for (final span in spans) {
    if (span is TextSpan) {
      if (span.text != null && span.text!.isNotEmpty) {
        result.add((span.text!, span.style));
      }
      if (span.children != null) {
        result.addAll(_flattenSpans(span.children!));
      }
    }
  }
  return result;
}

List<InlineSpan> _unflattenSpans(List<_FlatSpan> flat) {
  return flat.map((e) => TextSpan(text: e.$1, style: e.$2)).toList();
}

class HighlightMarkdownStyleSheet {
  const HighlightMarkdownStyleSheet({
    this.h1Style,
    this.h2Style,
    this.h3Style,
    this.h4Style,
    this.h5Style,
    this.h6Style,
    this.paragraphStyle,
    this.boldStyle,
    this.italicStyle,
    this.strikethroughStyle,
    this.codeStyle,
    this.codeBlockStyle,
    this.blockquoteStyle,
    this.linkStyle,
    this.listBullet = '• ',
    this.horizontalRule = '─',
    this.codeBlockBackground,
    this.codeBlockHeaderStyle,
  });

  factory HighlightMarkdownStyleSheet.terminalDark(CruxThemeData theme) {
    return HighlightMarkdownStyleSheet.fromTheme(theme);
  }

  factory HighlightMarkdownStyleSheet.thinking(CruxThemeData theme) {
    return _build(theme, theme.thinkingExpandedText);
  }

  factory HighlightMarkdownStyleSheet.fromTheme(CruxThemeData theme) {
    return _build(theme, theme.markdownText);
  }

  /// Build from any [MarkdownThemeFields]. Used by the
  /// worker isolate (which has a [WorkerTheme] that
  /// implements the interface but isn't a full
  /// [CruxThemeData]).
  factory HighlightMarkdownStyleSheet.fromThemeFields(
    MarkdownThemeFields theme,
  ) {
    return _build(theme, theme.markdownText);
  }

  factory HighlightMarkdownStyleSheet.thinkingFromFields(
    MarkdownThemeFields theme,
  ) {
    return _build(theme, theme.thinkingExpandedText);
  }

  static HighlightMarkdownStyleSheet _build(
    MarkdownThemeFields theme,
    Color baseColor,
  ) {
    return HighlightMarkdownStyleSheet(
      paragraphStyle: TextStyle(color: baseColor),
      h1Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH1),
      h2Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH2),
      h3Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH3),
      h4Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH4),
      h5Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH5),
      h6Style: TextStyle(fontWeight: FontWeight.bold, color: theme.mdH6),
      boldStyle: TextStyle(fontWeight: FontWeight.bold, color: theme.mdBold),
      italicStyle: TextStyle(
        fontStyle: FontStyle.italic,
        color: theme.mdItalic,
      ),
      strikethroughStyle: TextStyle(
        decoration: TextDecoration.lineThrough,
        color: theme.mdStrikethrough,
      ),
      codeStyle: TextStyle(
        color: theme.mdInlineCode,
        backgroundColor: theme.mdInlineCodeBg,
      ),
      codeBlockStyle: TextStyle(
        color: theme.mdCodeBlockText,
        backgroundColor: theme.codeBlockBackground,
      ),
      blockquoteStyle: TextStyle(
        color: theme.mdBlockquote,
        fontStyle: FontStyle.italic,
      ),
      linkStyle: TextStyle(
        color: theme.mdLink,
        decoration: TextDecoration.underline,
      ),
      codeBlockBackground: theme.codeBlockBackground,
      codeBlockHeaderStyle: TextStyle(color: theme.codeBlockHeader),
    );
  }

  final TextStyle? h1Style;
  final TextStyle? h2Style;
  final TextStyle? h3Style;
  final TextStyle? h4Style;
  final TextStyle? h5Style;
  final TextStyle? h6Style;
  final TextStyle? paragraphStyle;
  final TextStyle? boldStyle;
  final TextStyle? italicStyle;
  final TextStyle? strikethroughStyle;
  final TextStyle? codeStyle;
  final TextStyle? codeBlockStyle;
  final TextStyle? blockquoteStyle;
  final TextStyle? linkStyle;
  final String listBullet;
  final String horizontalRule;
  final Color? codeBlockBackground;
  final TextStyle? codeBlockHeaderStyle;
}

class _HighlightMarkdownVisitor {
  _HighlightMarkdownVisitor(
    this.styleSheet, {
    required this.theme,
    this.maxWidth,
    this.collectedLinks,
  });

  final HighlightMarkdownStyleSheet styleSheet;
  final MarkdownThemeFields theme;
  final int? maxWidth;
  int _listDepth = 0;

  /// Optional sink for markdown links discovered during the walk.
  /// When non-null the visitor records every `<a>` element into
  /// this list (in source order) along with the visible label, the
  /// underlying URL, and the offset / length in the rendered text.
  /// When null, the visitor skips the bookkeeping entirely so the
  /// hot path stays allocation-free for callers that don't care
  /// about clickable links (e.g. the worker isolate).
  final List<MarkdownLink>? collectedLinks;

  /// Running offset (in characters) of the next span we emit, in
  /// the same coordinate space [RenderParagraph.getCharacterIndexAtLocalPosition]
  /// expects. Updated by [visitNode] for every emitted span, so
  /// [case 'a'] can read it before returning to know where its
  /// link text lands in the rendered output. Reset to 0 at the
  /// start of each `visitNodes` call.
  int _currentOffset = 0;

  List<InlineSpan> visitNodes(List<md.Node> nodes) {
    // Reset the running offset at the start of every parse so
    // successive calls to `visitNodes` (e.g. for nested
    // paragraphs or `<blockquote>` bodies that recurse through
    // `visitChildren`) don't double-count. The visitor is
    // constructed fresh per `parseMarkdownToInlineSpans` call,
    // so this is belt-and-suspenders, but cheap.
    _currentOffset = 0;
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      final span = visitNode(node);
      if (span != null) {
        spans.add(span);
      }
    }
    if (spans.isNotEmpty) {
      spans[spans.length - 1] = _trimTrailingNewlines(spans.last);
    }
    return spans;
  }

  static InlineSpan _trimTrailingNewlines(InlineSpan span) {
    if (span is! TextSpan) return span;

    final children = span.children;
    if (children != null && children.isNotEmpty) {
      final last = children.last;
      if (last is TextSpan &&
          last.text != null &&
          RegExp(r'^\n+$').hasMatch(last.text!)) {
        final trimmed = children.sublist(0, children.length - 1);
        return TextSpan(children: trimmed, style: span.style);
      }
      final trimmedLast = _trimTrailingNewlines(last);
      if (trimmedLast != last) {
        final updated = [...children];
        updated[updated.length - 1] = trimmedLast;
        return TextSpan(children: updated, style: span.style);
      }
    } else if (span.text != null && span.text!.endsWith('\n')) {
      return TextSpan(text: span.text!.trimRight(), style: span.style);
    }

    return span;
  }

  InlineSpan? visitNode(md.Node node) {
    InlineSpan? span;
    if (node is md.Element) {
      span = visitElement(node);
    } else if (node is md.Text) {
      span = TextSpan(text: node.text);
    }
    if (span != null) {
      // Advance the running offset by the total text length of
      // the emitted span (text + all children). The visitor
      // emits spans in render order, so the running offset is
      // always the absolute position of the next emitted span
      // in the rendered text. The `<a>` case reads this counter
      // BEFORE this increment to compute the link's start offset.
      _currentOffset += _textLength(span);
    }
    return span;
  }

  /// Recursive text-length of a span tree. Counts UTF-16 code
  /// units (the same measure `RenderParagraph.getCharacterIndexAtLocalPosition`
  /// uses), not graphemes — they're equivalent for the ASCII
  /// URLs and labels we expect to see.
  static int _textLength(InlineSpan span) {
    if (span is! TextSpan) return 0;
    var len = span.text?.length ?? 0;
    if (span.children != null) {
      for (final child in span.children!) {
        len += _textLength(child);
      }
    }
    return len;
  }

  InlineSpan? visitElement(md.Element element) {
    switch (element.tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final style = element.tag == 'h1'
            ? styleSheet.h1Style
            : element.tag == 'h2'
            ? styleSheet.h2Style
            : element.tag == 'h3'
            ? styleSheet.h3Style
            : element.tag == 'h4'
            ? styleSheet.h4Style
            : element.tag == 'h5'
            ? styleSheet.h5Style
            : styleSheet.h6Style;
        return TextSpan(
          children: [
            ...visitChildren(element),
            const TextSpan(text: '\n\n'),
          ],
          style: style,
        );
      case 'p':
        return TextSpan(
          children: [
            ...visitChildren(element),
            const TextSpan(text: '\n\n'),
          ],
          style: styleSheet.paragraphStyle,
        );
      case 'strong':
      case 'b':
        return TextSpan(
          children: visitChildren(element),
          style: styleSheet.boldStyle,
        );
      case 'em':
      case 'i':
        return TextSpan(
          children: visitChildren(element),
          style: styleSheet.italicStyle,
        );
      case 'del':
      case 's':
        return TextSpan(
          children: visitChildren(element),
          style: styleSheet.strikethroughStyle,
        );
      case 'code':
        return TextSpan(text: element.textContent, style: styleSheet.codeStyle);
      case 'pre':
        return _renderCodeBlock(element);
      case 'blockquote':
        final children = visitChildren(element);
        return TextSpan(
          children: [
            TextSpan(text: '│ ', style: styleSheet.blockquoteStyle),
            ...children,
            const TextSpan(text: '\n'),
          ],
          style: styleSheet.blockquoteStyle,
        );
      case 'a':
        final href = element.attributes['href'] ?? '';
        final label = element.textContent;
        // User contract: when a label is provided, render just
        // the label — no URL appendix in parentheses or brackets.
        // When no label is provided (`[](https://…)`), fall back
        // to the URL itself so the link is still visible (and
        // clickable, when an `onLinkTap` handler is wired).
        final displayText = label.isNotEmpty ? label : href;

        // Record the link BEFORE the visitNode offset increment
        // above — `_currentOffset` still points at the start of
        // the link's text at this point. The link's length is the
        // displayed text length (label, or URL when no label was
        // given). Skipping the bookkeeping when the caller didn't
        // ask for it keeps the hot path allocation-free.
        collectedLinks?.add(
          MarkdownLink(
            label: displayText,
            url: href,
            offset: _currentOffset,
            length: displayText.length,
          ),
        );

        return TextSpan(
          text: displayText,
          style: styleSheet.linkStyle,
        );
      case 'img':
        final alt = element.attributes['alt'] ?? 'image';
        return TextSpan(
          text: '[Image: $alt]',
          style: const TextStyle(fontStyle: FontStyle.italic),
        );
      case 'ul':
      case 'ol':
        _listDepth++;
        final children = visitChildren(element);
        _listDepth--;
        return TextSpan(
          children: [
            ...children,
            if (_listDepth == 0) const TextSpan(text: '\n'),
          ],
        );
      case 'li':
        final indent = '  ' * _listDepth;
        final bullet = styleSheet.listBullet;
        final children = <InlineSpan>[TextSpan(text: indent + bullet)];

        if (element.children != null) {
          for (final child in element.children!) {
            if (child is md.Element &&
                (child.tag == 'ul' || child.tag == 'ol')) {
              if (children.length > 1) {
                children.add(const TextSpan(text: '\n'));
              }
            }

            final span = visitNode(child);
            if (span != null) {
              children.add(span);
            }
          }
        }

        children.add(const TextSpan(text: '\n'));
        return TextSpan(children: children);
      case 'hr':
        final width = maxWidth ?? 40;
        return TextSpan(
          text: styleSheet.horizontalRule * width + '\n\n',
          style: TextStyle(color: theme.outline),
        );
      case 'br':
        return const TextSpan(text: '\n');
      case 'table':
        return _renderTable(element);
      default:
        return TextSpan(children: visitChildren(element));
    }
  }

  InlineSpan _renderCodeBlock(md.Element element) {
    final codeElement = element.children != null && element.children!.isNotEmpty
        ? element.children!.first
        : null;
    final code = codeElement?.textContent ?? element.textContent;

    String? language;
    if (codeElement is md.Element) {
      final cls = codeElement.attributes['class'];
      if (cls != null && cls.startsWith('language-')) {
        language = cls.substring(9);
      }
    }

    final bgColor = styleSheet.codeBlockBackground ?? theme.codeBlockBackground;
    final codeStyle =
        styleSheet.codeBlockStyle ??
        TextStyle(
          color: theme.mdCodeBlockText,
          backgroundColor: theme.codeBlockBackground,
        );

    final width = math.max(4, maxWidth ?? 80);
    final codeLineWidth = math.max(0, width - 4);
    final langLabel = language ?? '';
    final headerContent = langLabel.isNotEmpty ? ' $langLabel ' : '';
    final headerPrefix = '┌─$headerContent';
    final headerPadding = width - headerPrefix.length - 1;
    final headerLine = '$headerPrefix${'─' * math.max(0, headerPadding)}┐';
    final footerLine = '└${'─' * math.max(0, width - 2)}┘';

    // Strip a single trailing newline (markdown code blocks always end in `\n`)
    // so we don't render an extra empty line after the gutter.
    final stripped = code.endsWith('\n')
        ? code.substring(0, code.length - 1)
        : code;

    final spans = <InlineSpan>[];

    spans.add(
      TextSpan(
        text: '$headerLine\n',
        style: TextStyle(
          color: theme.codeBlockGutter,
          backgroundColor: bgColor,
        ),
      ),
    );

    void emitSpan(String text, {TextStyle? style}) {
      if (text.isEmpty) return;
      spans.add(
        TextSpan(
          text: text,
          style: (style ?? const TextStyle()).copyWith(
            backgroundColor: bgColor,
          ),
        ),
      );
    }

    void emitBorderSpan(String text, TextStyle style) {
      if (text.isEmpty) return;
      spans.add(
        TextSpan(
          text: text,
          style: style.copyWith(backgroundColor: bgColor),
        ),
      );
    }

    final gutterStyle = TextStyle(
      backgroundColor: bgColor,
      color: theme.codeBlockGutter,
    );

    void emitCodeRows(List<_FlatSpan> segments) {
      var lineWidth = 0;
      var lineOpen = false;

      void openLine() {
        if (lineOpen) return;
        emitBorderSpan('│ ', gutterStyle);
        lineOpen = true;
        lineWidth = 0;
      }

      void closeLine() {
        openLine();
        final padding = codeLineWidth - lineWidth;
        if (padding > 0) {
          emitSpan(' ' * padding, style: codeStyle);
        }
        emitBorderSpan(' │\n', gutterStyle);
        lineOpen = false;
        lineWidth = 0;
      }

      for (final segment in segments) {
        final text = segment.$1;
        final style = segment.$2 ?? codeStyle;
        for (final grapheme in text.characters) {
          if (grapheme == '\n') {
            closeLine();
            continue;
          }

          final graphemeWidth = UnicodeWidth.graphemeWidth(grapheme);
          if (graphemeWidth == 0) continue;
          openLine();

          if (codeLineWidth > 0 &&
              lineWidth > 0 &&
              lineWidth + graphemeWidth > codeLineWidth) {
            closeLine();
            openLine();
          }

          emitSpan(grapheme, style: style);
          lineWidth += graphemeWidth;
        }
      }

      if (segments.isEmpty || lineOpen) {
        closeLine();
      }
    }

    if (stripped.isEmpty) {
      // Empty code block — still render a single gutter so the box has height.
      emitCodeRows(const []);
    } else {
      final highlightService = HighlightService.instance;
      final highlighter =
          (highlightService != null && language != null && language.isNotEmpty)
          ? highlightService.highlighterFor(language)
          : null;

      if (highlighter == null) {
        // No highlighter available: render the whole block in [codeStyle],
        // emitting a complete bordered row at every newline.
        emitCodeRows([(stripped, codeStyle)]);
      } else {
        // IMPORTANT: highlight the entire code block as a single string, not
        // line-by-line. Dart's `///` doc-comment grammar (and many other
        // grammars) uses `begin`/`while`/`end` pairs that span across lines,
        // which only work when the highlighter sees the full context.
        final styleService = highlightService!;
        final tokens = highlighter.highlight(stripped);
        final codeSegments = <_FlatSpan>[];

        int cursor = 0;
        int tokenIdx = 0;

        // Advance past any tokens we have already emitted.
        void skipFinishedTokens() {
          while (tokenIdx < tokens.length && cursor >= tokens[tokenIdx].end) {
            tokenIdx++;
          }
        }

        while (cursor < stripped.length) {
          skipFinishedTokens();
          final token = tokenIdx < tokens.length ? tokens[tokenIdx] : null;

          int boundary;
          TextStyle segmentStyle;

          if (token != null && cursor >= token.start && cursor < token.end) {
            // Cursor sits inside the current token: emit up to the next
            // newline or the end of the token, whichever comes first. This
            // ensures we re-emit the gutter between every line, even when a
            // multi-line token (e.g. a `///` doc comment or `/* ... */` block)
            // spans several lines.
            final nlInToken = stripped.indexOf('\n', cursor);
            if (nlInToken != -1 && nlInToken < token.end) {
              boundary = nlInToken + 1;
            } else {
              boundary = token.end;
            }
            final color = colorForScopes(token.scopes, theme);
            final tmStyle = styleService.styleForScopes(token.scopes);
            segmentStyle = TextStyle(
              color: color,
              fontWeight: tmStyle?.bold == true
                  ? FontWeight.bold
                  : FontWeight.normal,
              fontStyle: tmStyle?.italic == true
                  ? FontStyle.italic
                  : FontStyle.normal,
            );
          } else if (token != null && cursor < token.start) {
            // Cursor sits in a gap before the next token: emit unstyled
            // fallback text up to the next newline or the token start.
            final nlInGap = stripped.indexOf('\n', cursor);
            if (nlInGap != -1 && nlInGap < token.start) {
              boundary = nlInGap + 1;
            } else {
              boundary = token.start;
            }
            segmentStyle = codeStyle;
          } else {
            // No more tokens: emit the rest as unstyled, splitting at newlines.
            codeSegments.add((stripped.substring(cursor), codeStyle));
            cursor = stripped.length;
            continue;
          }

          codeSegments.add((
            stripped.substring(cursor, boundary),
            segmentStyle,
          ));
          cursor = boundary;
        }
        emitCodeRows(codeSegments);
      }
    }

    spans.add(
      TextSpan(
        text: '$footerLine\n\n',
        style: TextStyle(
          color: theme.codeBlockGutter,
          backgroundColor: bgColor,
        ),
      ),
    );

    return TextSpan(children: spans);
  }

  List<InlineSpan> visitChildren(md.Element element) {
    final spans = <InlineSpan>[];
    if (element.children != null) {
      for (final child in element.children!) {
        final span = visitNode(child);
        if (span != null) {
          spans.add(span);
        }
      }
    }
    return spans;
  }

  InlineSpan _renderTable(md.Element table) {
    final rows = <List<String>>[];
    final naturalWidths = <int>[];

    if (table.children != null) {
      for (final child in table.children!) {
        if (child is md.Element) {
          if (child.tag == 'thead' || child.tag == 'tbody') {
            if (child.children != null) {
              for (final row in child.children!) {
                if (row is md.Element && row.tag == 'tr') {
                  final cells = <String>[];
                  if (row.children != null) {
                    for (final cell in row.children!) {
                      if (cell is md.Element &&
                          (cell.tag == 'th' || cell.tag == 'td')) {
                        cells.add(cell.textContent);
                      }
                    }
                  }
                  rows.add(cells);

                  for (int i = 0; i < cells.length; i++) {
                    if (i >= naturalWidths.length) {
                      naturalWidths.add(0);
                    }
                    final cellWidth = UnicodeWidth.stringWidth(cells[i]);
                    naturalWidths[i] = naturalWidths[i] > cellWidth
                        ? naturalWidths[i]
                        : cellWidth;
                  }
                }
              }
            }
          }
        }
      }
    }

    if (rows.isEmpty || naturalWidths.isEmpty) {
      return const TextSpan(text: '');
    }

    final columnWidths = _distributeColumnWidths(naturalWidths);

    final wrappedRows = <List<List<String>>>[];
    for (final row in rows) {
      final wrappedCells = <List<String>>[];
      for (int c = 0; c < naturalWidths.length; c++) {
        final content = c < row.length ? row[c] : '';
        wrappedCells.add(_wrapCell(content, columnWidths[c]));
      }
      wrappedRows.add(wrappedCells);
    }

    final spans = <InlineSpan>[];
    final borderStyle = TextStyle(color: theme.outline);
    final textStyle =
        styleSheet.paragraphStyle ?? TextStyle(color: theme.markdownText);
    final headerStyle = textStyle.copyWith(
      fontWeight: FontWeight.bold,
      backgroundColor: theme.surfaceVariant.withOpacity(0.5),
    );

    void addBorder(String text) {
      spans.add(TextSpan(text: text, style: borderStyle));
    }

    void addText(String text, TextStyle style) {
      spans.add(TextSpan(text: text, style: style));
    }

    void addHorizontalBorder(
      String left,
      String fill,
      String middle,
      String right,
    ) {
      addBorder(
        '${_horizontalBorderString(columnWidths, left, fill, middle, right)}\n',
      );
    }

    addHorizontalBorder('┌', '─', '┬', '┐');

    for (int r = 0; r < wrappedRows.length; r++) {
      final rowCells = wrappedRows[r];
      final rowHeight = rowCells.fold(
        1,
        (max, cell) => math.max(max, cell.length),
      );
      final isHeader = r == 0;
      final rowBackground = isHeader
          ? theme.surfaceVariant.withOpacity(0.5)
          : ((r - 1).isEven ? theme.surface : theme.surfaceVariant).withOpacity(
              0.5,
            );
      final rowTextStyle = (isHeader ? headerStyle : textStyle).copyWith(
        backgroundColor: rowBackground,
      );

      for (int l = 0; l < rowHeight; l++) {
        addBorder('│');
        for (int c = 0; c < columnWidths.length; c++) {
          final lines = c < rowCells.length ? rowCells[c] : const [''];
          final line = l < lines.length ? lines[l] : '';
          final displayWidth = UnicodeWidth.stringWidth(line);
          final paddingNeeded = columnWidths[c] - displayWidth;
          addText(' ', rowTextStyle);
          addText(line, rowTextStyle);
          if (paddingNeeded > 0) {
            addText(' ' * paddingNeeded, rowTextStyle);
          }
          addText(' ', rowTextStyle);
          addBorder('│');
        }
        spans.add(const TextSpan(text: '\n'));
      }

      if (r == 0 && wrappedRows.length > 1) {
        addHorizontalBorder('├', '─', '┼', '┤');
      }
    }

    addHorizontalBorder('└', '─', '┴', '┘');

    return TextSpan(children: spans);
  }

  List<int> _distributeColumnWidths(List<int> naturalWidths) {
    final numCols = naturalWidths.length;
    final overhead = 3 * numCols + 1;
    final naturalTotal = naturalWidths.fold(0, (sum, w) => sum + w) + overhead;

    if (maxWidth == null || naturalTotal <= maxWidth!) {
      return List.of(naturalWidths);
    }

    const minColWidth = 3;
    final available = maxWidth! - overhead;

    if (available < numCols * minColWidth) {
      return List.filled(numCols, minColWidth);
    }

    final result = List<int>.filled(numCols, 0);
    final totalNatural = naturalWidths.fold(0, (sum, w) => sum + w);

    int allocated = 0;
    for (int i = 0; i < numCols; i++) {
      result[i] = math.max(
        minColWidth,
        (naturalWidths[i] * available / totalNatural).floor(),
      );
      allocated += result[i];
    }

    var remaining = available - allocated;
    while (remaining > 0) {
      int bestIdx = 0;
      int bestDeficit = 0;
      for (int i = 0; i < numCols; i++) {
        final deficit = naturalWidths[i] - result[i];
        if (deficit > bestDeficit) {
          bestDeficit = deficit;
          bestIdx = i;
        }
      }
      if (bestDeficit == 0) break;
      result[bestIdx]++;
      remaining--;
    }

    while (remaining < 0) {
      int bestIdx = 0;
      int bestExcess = 0;
      for (int i = 0; i < numCols; i++) {
        final excess = result[i] - minColWidth;
        if (excess > bestExcess) {
          bestExcess = excess;
          bestIdx = i;
        }
      }
      if (bestExcess == 0) break;
      result[bestIdx]--;
      remaining++;
    }

    return result;
  }

  static List<String> _wrapCell(String content, int cellWidth) {
    if (cellWidth <= 0) return [''];
    if (UnicodeWidth.stringWidth(content) <= cellWidth) return [content];

    final lines = <String>[];
    final words = content.split(' ');
    var currentLine = '';
    var currentWidth = 0;

    for (final word in words) {
      final wordWidth = UnicodeWidth.stringWidth(word);

      if (currentWidth == 0) {
        if (wordWidth > cellWidth) {
          lines.addAll(_breakLongWord(word, cellWidth));
          final lastLine = lines.removeLast();
          currentLine = lastLine;
          currentWidth = UnicodeWidth.stringWidth(lastLine);
        } else {
          currentLine = word;
          currentWidth = wordWidth;
        }
      } else if (currentWidth + 1 + wordWidth <= cellWidth) {
        currentLine += ' $word';
        currentWidth += 1 + wordWidth;
      } else {
        lines.add(currentLine);
        if (wordWidth > cellWidth) {
          lines.addAll(_breakLongWord(word, cellWidth));
          final lastLine = lines.removeLast();
          currentLine = lastLine;
          currentWidth = UnicodeWidth.stringWidth(lastLine);
        } else {
          currentLine = word;
          currentWidth = wordWidth;
        }
      }
    }

    if (currentLine.isNotEmpty) {
      lines.add(currentLine);
    }

    return lines.isEmpty ? [''] : lines;
  }

  static List<String> _breakLongWord(String word, int maxWidth) {
    final parts = <String>[];
    var current = '';
    var currentWidth = 0;

    for (final grapheme in word.characters) {
      final w = UnicodeWidth.graphemeWidth(grapheme);
      if (currentWidth + w > maxWidth && current.isNotEmpty) {
        parts.add(current);
        current = grapheme;
        currentWidth = w;
      } else {
        current += grapheme;
        currentWidth += w;
      }
    }
    if (current.isNotEmpty) parts.add(current);
    return parts.isEmpty ? [''] : parts;
  }

  static String _horizontalBorderString(
    List<int> columnWidths,
    String left,
    String fill,
    String middle,
    String right,
  ) {
    final buffer = StringBuffer(left);
    for (int i = 0; i < columnWidths.length; i++) {
      buffer.write(fill * (columnWidths[i] + 2));
      if (i < columnWidths.length - 1) {
        buffer.write(middle);
      }
    }
    buffer.write(right);
    return buffer.toString();
  }
}
