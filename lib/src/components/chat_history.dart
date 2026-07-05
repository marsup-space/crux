// chat_history uses nocterm's internal TextLayoutEngine to pre-layout code-block
// content for hit-testing and selection measurement. Not part of nocterm's
// public API; importing here is intentional.
// ignore_for_file: implementation_imports

import 'dart:convert';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/text/text_layout_engine.dart';
import 'package:nocterm_bloc/nocterm_bloc.dart';
import '../models/message.dart';
import '../services/llm_provider.dart';
import '../services/provider_service.dart';
import '../utils/frame_profiler.dart';
import '../theme/crux_theme.dart';
import '../utils/markdown_headings.dart';
import '../utils/url_launcher.dart';
import '../tools/registry.dart';
import 'ui/toast.dart';
import 'annotated_scrollbar.dart';
import 'btw_bubble.dart';
import 'btw_cubit.dart';
import 'chat_turn_cubit.dart';
import 'chat_turn_orchestrator.dart';
import 'compacted_session_header.dart';
import 'compaction_divider.dart';
import 'message_bubble.dart';
import 'queued_messages_bubble.dart';
import 'session_controller.dart';
import 'session_cubit.dart';
import 'streaming_bubble.dart';
import 'streaming_controller.dart';
import 'tldr_bubble.dart';
import '../utils/quick_reply_parser.dart';
import '../utils/markdown_links.dart';

/// Lazy item-builder: produces the widget for items[index] only when
/// the ListView actually lays out that index. Lets us defer the
/// per-message expensive work (`extractHeadings`, the inner
/// `MessageBubble` tree build, the `StreamingBubble` construction,
/// the `TldrBubble` markdown scan) to the few items that are
/// actually on-screen, instead of running them for every message
/// up front.
///
/// Without this, a 500-message session would call
/// `extractHeadings(content)` for every AI message that has a TLDR
/// during `_buildInner` — even if only ~4 of those TLDRs are ever
/// visible. That's the cold-start cost the user noticed.
typedef LazyChatItem = Component Function(BuildContext context);

/// The scrollable message list that displays the chat history,
/// streaming bubbles, btw turns, queued messages, and tldr summaries.
class ChatHistory extends StatefulComponent {
  final AutoScrollController scrollController;
  final SessionController sessionController;
  final StreamingController streamingController;
  final ChatTurnOrchestrator turnOrchestrator;
  final ProviderService providerService;
  final ToolRegistry toolRegistry;
  final void Function(String message, {ToastMode mode}) showToast;
  final void Function() refresh;

  /// Callback when a tool call bubble is tapped. Receives the
  /// [ToolCallData] and the paired result [Message] (if any).
  final void Function(ToolCallData toolCall, Message? pairedResult)?
  onToolCallTap;

  /// Callback fired when the user clicks a `ses://<id>` reference
  /// inside an assistant message bubble. The chat panel implements
  /// this to switch to the referenced session (or toast "not found"
  /// if the id is stale).
  final void Function(int sessionId)? onSessionLinkTap;

  /// Callback fired when the user clicks a quick-reply token
  /// (`ask://label{answer}` or `ask://label`) inside an assistant
  /// message bubble. The chat panel implements this to submit the
  /// reply as a new user message or append it to the current
  /// draft, depending on whether the chat input is empty — see
  /// `docs/design-quick-reply.md`.
  final void Function(QuickReply reply)? onQuickReplyTap;

  /// Callback fired when the user clicks a markdown link
  /// (`[label](url)`) inside an assistant message bubble. The
  /// chat panel implements this to open the URL in the user's
  /// default browser via [openUrl], falling back to a toast on
  /// launch failure. Filtering of unsafe schemes (anything other
  /// than `http(s):`) happens inside [openUrl] — the chat panel
  /// just forwards the click and surfaces the result.
  final void Function(MarkdownLink link)? onLinkTap;

  /// Callback fired when the user clicks a [CompactionDivider] in
  /// the chat history. Receives the [Message] whose
  /// `role: 'compaction'` produced the divider — the chat panel
  /// opens a fullpane showing the raw compaction content +
  /// metadata. The host wires this only in debug mode (see
  /// `CommandRegistry.debugEnabled`); in production the divider
  /// renders as a static marker.
  ///
  /// Previously this callback also received a 1-based compaction
  /// index; under the "replace from scratch" model there is at
  /// most ONE compaction per session at a time, so the index is
  /// always meaningless.
  final void Function(Message message)? onCompactionTap;

  /// Callback fired when the user clicks the `▶ retry (/continue)`
  /// affordance on a `stream_error` bubble. The chat panel wires
  /// this to the command executor's `/continue` flow so the
  /// retry button skips the input pipeline entirely (which would
  /// otherwise interpret `/continue` as a literal user message
  /// and call the LLM with that string).
  final VoidCallback? onRetryContinue;

  const ChatHistory({
    super.key,
    required this.scrollController,
    required this.sessionController,
    required this.streamingController,
    required this.turnOrchestrator,
    required this.providerService,
    required this.toolRegistry,
    required this.showToast,
    required this.refresh,
    this.onToolCallTap,
    this.onSessionLinkTap,
    this.onQuickReplyTap,
    this.onLinkTap,
    this.onCompactionTap,
    this.onRetryContinue,
  });

  @override
  State<ChatHistory> createState() => _ChatHistoryState();
}

class _ChatHistoryState extends State<ChatHistory> {
  String? _highlightText;
  int? _highlightMessageId;
  final int _lastContentWidth = 120;

  @override
  Component build(BuildContext context) {
    // The chat history is the most expensive widget to
    // build in the chat panel: it iterates over every
    // message in the session and creates a MessageBubble
    // for each, even though only the visible ones are
    // actually laid out and painted. Wrapping the whole
    // build in a profiler section makes a slow frame
    // attributable to "the chat history had N messages
    // to iterate" rather than just "build took 12ms".
    return FrameProfiler.instance.timed(
      'chatHistory.build',
      () => _buildInner(context),
    );
  }

  /// Build the inner widget tree for the chat history. The expensive
  /// per-message work (markdown parsing in `MessageBubble`, heading
  /// extraction in `TldrBubble`, the streaming/queued bubble
  /// construction) is deferred to layout time via the [LazyChatItem]
  /// closures in `items` — so for an N-message session, only the
  /// ~20 visible items pay the full cost, not all N.
  Component _buildInner(BuildContext context) {
    // Capture the current session id from the cubit so the entire
    // build is pinned to whatever the cubit reports at entry. The
    // chat panel also reads currentSessionId elsewhere, but chat
    // history's view of "which session am I rendering" now flows
    // through SessionCubit, not the controller.
    final sessionId = context.select<SessionCubit, int?>(
      (cubit) => cubit.state.currentSessionId,
    );
    final rt = sessionId != null
        ? component.sessionController.runtime(sessionId)
        : null;
    // Read the streaming-bubble visibility flag from ChatTurnCubit
    // instead of the controller's runtime. The mirror in
    // SessionController.mirrorTurnFlags keeps the cubit's phase in
    // lockstep with the runtime's `isResponding` flip at every
    // meaningful transition (turn start, completion, error,
    // interrupt, btw start/end), so this read returns the same
    // value as rt.isResponding without chat_history depending on the
    // runtime being mutated directly.
    final isStreaming = sessionId != null &&
        context.select<ChatTurnCubit, bool>(
          (cubit) => cubit.state.sessionState(sessionId).isResponding,
        );

    // ─── Cubit subscriptions captured up front ─────────────────
    //
    // Each subscription is registered at the very top of the build so
    // the selector is consistently called once per build (no
    // conditional re-registration). List identity differs across
    // emits because SessionCubit / BtwCubit store unmodifiable
    // snapshots; List.== defaults to identity, so any new emit fires
    // the selector and triggers chat_history to rebuild — which is
    // exactly what we want for chunks/delivered messages.
    //
    // The loading-state record only changes when the chunked loader
    // updates its progress counters, so the rebuild rate there is
    // bounded.
    final messages = context.select<SessionCubit, List<Message>>(
      (cubit) =>
          sessionId == null ? const <Message>[] : cubit.state.messagesFor(sessionId),
    );
    final loadingState = context.select<
        SessionCubit, ({bool isLoading, int? total, int? loaded})>(
      (cubit) {
        if (sessionId == null) {
          return (isLoading: false, total: null, loaded: null);
        }
        return (
          isLoading: cubit.state.isLoadingMessages(sessionId),
          total: cubit.state.loadingMessageTotal(sessionId),
          loaded: cubit.state.loadingMessageLoaded(sessionId),
        );
      },
    );
    final btwTurns = context.select<BtwCubit, List<BtwTurn>>(
      (cubit) =>
          sessionId == null ? const <BtwTurn>[] : cubit.state.turnsFor(sessionId),
    );

    final lastRoundStart = isStreaming
        ? -1
        : messages.lastIndexWhere((m) => m.role == 'user');

    // An agent turn can span several rounds: the LLM emits reasoning
    // + tool_use, the tools run, then the LLM emits more reasoning +
    // (more) tool_use, … Each round's reasoning is persisted on its
    // own Message row. We want at most ONE reasoning block expanded
    // on screen at any time — that "one" is whichever reasoning the
    // user can most recently read: the live round's reasoning inside
    // the [StreamingBubble] (when new reasoning is actually being
    // streamed), otherwise the most-recent persisted reasoning
    // ([lastReasoningIndex]). Every older reasoning collapses into a
    // summary line ("Think: 5.2s, 1234 tokens [normal]") matching
    // the previous-agent-turn style. Without this filter, a
    // multi-round turn would render every round's reasoning expanded
    // at once — a wall of text the user has to scroll past.
    int? lastReasoningIndex;
    for (var j = messages.length - 1; j >= 0; j--) {
      final m = messages[j];
      if ((m.role == 'ai' || m.role == 'tool_call') &&
          m.reasoningContent.isNotEmpty) {
        lastReasoningIndex = j;
        break;
      }
    }

    // Has the *current* round started streaming new reasoning content
    // yet? Until that first reasoning delta lands, the most-recent
    // persisted reasoning stays expanded — collapsing it the moment
    // a new round starts (but before any new thinking has been
    // emitted) would feel like a flicker. Once the live round starts
    // emitting reasoning, the streaming bubble takes over as "the
    // one" expanded reasoning block, and every persisted reasoning
    // collapses into a summary line.
    //
    // `streamingReasoningFor` is empty between rounds
    // (`clearStreamingFor` / `beginWaitingForModel` reset it on
    // every round boundary) and only becomes non-empty once the
    // current round's first reasoning delta lands. So this flag is
    // exactly the "a new think has appeared" signal we need.
    final newReasoningStarted = isStreaming &&
        component.streamingController
            .streamingReasoningFor(sessionId)
            .isNotEmpty;

    // Find the index of the most-recently-persisted `ai` message.
    // This is the bubble where quick-reply buttons should be live —
    // choices from older turns are stale and would mislead the user
    // (the conversation has moved on, the proposed action was either
    // taken or abandoned). While a new turn is streaming, the
    // *persisted* latest is technically the previous turn, but we
    // suppress its buttons too: the streaming bubble is the active
    // response and the user shouldn't be re-engaging old choices
    // mid-stream. Source text still renders normally, just without
    // button styling or click handling.
    int? latestAiIndex;
    for (var j = messages.length - 1; j >= 0; j--) {
      if (messages[j].role == 'ai') {
        latestAiIndex = j;
        break;
      }
    }

    final resultByCallId = <String, Message>{};
    for (final m in messages) {
      if (m.role == 'tool' && m.toolCallId.isNotEmpty) {
        resultByCallId[m.toolCallId] = m;
      }
    }

    if (messages.isEmpty && !isStreaming) {
      // Switching to a session whose message cache is empty (i.e.
      // never visited in this Crux instance). If the controller has
      // already kicked off a chunked load for this session, show a
      // progress line so the user sees instant feedback ("Loading N
      // messages…" or "Loading 247 messages… (48%)") instead of the
      // misleading "No messages yet." which would imply the session
      // is genuinely empty.
      if (loadingState.isLoading) {
        return Center(
          child: Text(
            _loadingLabel(loadingState.total, loadingState.loaded),
            style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
          ),
        );
      }
      // Empty-state check: any /btw turn for this session is enough
      // to clear the 'No messages yet.' placeholder. Derived from the
      // list we already captured at the top of this method, so this
      // site does NOT register a separate cubit subscription.
      final hasBtwTurns = btwTurns.isNotEmpty;
      if (!hasBtwTurns) {
        return Center(
          child: Text(
            'No messages yet.',
            style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
          ),
        );
      }
    }

    final items = <LazyChatItem>[];
    final userItemIndices = <int>[];
    final userItemLabels = <String>[];

    // If the current session was created via compaction, prepend a
    // header that links back to the source session. Goes BEFORE any
    // message — including the compaction summary itself — so the
    // user sees the link immediately on arrival without scrolling.
    final compactionSource = _findCompactionSource(messages);
    if (compactionSource != null) {
      items.add(
        (ctx) => CompactedSessionHeader(
          sourceSessionId: compactionSource.id,
          sourceTitle: compactionSource.title,
          onSessionLinkTap: component.onSessionLinkTap,
        ),
      );
      items.add(
        (ctx) => Divider(color: CruxTheme.of(ctx).divider, height: 1),
      );
    }

    // Resolve the reasoning-effort display mapping once for the
    // entire build. The mapping depends only on the current
    // session's model/provider (see [_currentReasoningPresets]),
    // not on the individual message, so calling it per-message in
    // the loop was redundant — N redundant provider/model lookups
    // for an N-message session.
    final reasoningPresets = _currentReasoningPresets();

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      // Reasoning-bearing messages — `ai` and `tool_call` rows that
      // carry `reasoningContent` — collapse to a summary line unless
      // they're the most-recent reasoning the user can currently see
      // (the "one" expanded block). That "one" is:
      //   * the live round's reasoning in the streaming bubble, when
      //     new reasoning is actually being streamed (`newReasoningStarted`),
      //   * otherwise the most-recent persisted reasoning
      //     ([lastReasoningIndex]).
      // Anything older than that collapses into a `Think: 5.2s,
      // 1234 tokens [normal]` summary line, matching how a previous
      // agent turn's think bubble renders. For other roles (`user`,
      // `tool`, system bubbles) `reasoningCollapsed` is ignored by
      // [MessageBubble], so the original `lastRoundStart` rule is
      // fine.
      final isReasoningMsg =
          (msg.role == 'ai' || msg.role == 'tool_call') &&
              msg.reasoningContent.isNotEmpty;
      final collapsed = isReasoningMsg
          ? i != lastReasoningIndex || newReasoningStarted
          : i < lastRoundStart;
      Message? pairedResult;
      final pairedResultsByCallId = <String, Message>{};
      if (msg.role == 'tool_call') {
        for (final tc in msg.toolCalls) {
          final result = resultByCallId[tc.callId];
          if (result != null) {
            pairedResultsByCallId[tc.callId] = result;
            pairedResult ??= result;
          }
        }
      }

      if (msg.role == 'user') {
        userItemIndices.add(items.length);
        final text = msg.content.replaceAll('\n', ' ').trim();
        userItemLabels.add(text);
      }

      // Compaction messages render as a divider instead of a
      // [MessageBubble] — the chat log content is meant for the
      // LLM, not the user; the divider is the user-facing marker
      // that this boundary exists. In debug mode the divider is
      // clickable and opens a fullpane showing the raw content
      // + metadata for inspection. Under the "replace from
      // scratch" compaction model there is at most ONE such
      // divider per session, so it carries no per-session index.
      if (msg.role == 'compaction') {
        items.add(
          (ctx) => CompactionDivider(
            onTap: component.onCompactionTap == null
                ? null
                : () => component.onCompactionTap!(msg),
          ),
        );
        continue;
      }

      // Build the MessageBubble inside a closure so the inner
      // widget tree (and the markdown parse in
      // [HighlightedMarkdownText.build]) only runs when
      // `itemBuilder` is called for this index — i.e. when the
      // bubble is actually laid out. Off-screen bubbles stay
      // un-built, which is the whole point of the change.
      //
      // Quick-reply buttons are gated to the latest `ai` message
      // and only when no turn is currently streaming. Every other
      // message (older AI, user, tool, compaction summary) gets
      // `onQuickReplyTap: null` — with the callback null,
      // [HighlightedMarkdownText] skips parsing `ask://` tokens
      // entirely, so the source text renders as plain markdown
      // (no button styling, no hover, no click handling). The
      // answer is effectively invisible — what shows is just the
      // literal `ask://label{answer}` or `ask://label` text.
      final isLatestAi = i == latestAiIndex;
      final enableQuickReplies = isLatestAi && !isStreaming;
      items.add((ctx) {
        return MessageBubble(
          message: msg,
          reasoningCollapsed: collapsed,
          pairedResult: pairedResult,
          resultByCallId: pairedResultsByCallId,
          toolRegistry: component.toolRegistry,
          highlightText:
              msg.id == _highlightMessageId ? _highlightText : null,
          reasoningPresets: reasoningPresets,
          onToolCallTap: component.onToolCallTap,
          onSessionLinkTap: component.onSessionLinkTap,
          onQuickReplyTap:
              enableQuickReplies ? component.onQuickReplyTap : null,
          onLinkTap: component.onLinkTap,
          // The retry button on a `stream_error` bubble should
          // always be live when the bubble is rendered (i.e. NOT
          // suppressed by the "latest AI" / streaming rules that
          // gate quick-reply tokens). Stream errors don't appear
          // in the middle of an active turn — they only get
          // persisted when the turn has fully errored out — so
          // there's no stale-retry concern here.
          onRetryContinue: component.onRetryContinue,
        );
      });

      if (msg.role == 'ai' && msg.id > 0 && rt != null) {
        final hasTldr = msg.tldr.isNotEmpty;
        if (hasTldr || rt.isGeneratingTldr) {
          final aiMessageItemIndex = items.length - 1;
          final aiMessageId = msg.id;
          final aiMessageContent = msg.content;
          items.add(
            (ctx) => Divider(color: CruxTheme.of(ctx).divider, height: 1),
          );
          items.add((ctx) {
            // Defer [extractHeadings] until the TldrBubble is
            // actually laid out. For a 500-message session with
            // ~80 TLDR bubbles, the eager path was parsing 80
            // markdown ASTs up front — now only the 2–4 that fit
            // in the viewport pay that cost.
            return TldrBubble(
              tldrText: msg.tldr,
              headings: extractHeadings(msg.content),
              isGenerating: rt.isGeneratingTldr && !hasTldr,
              hasAuxiliaryModel:
                  component.providerService.auxiliaryModel != null &&
                  component.providerService.auxiliaryModel != 'none',
              onHeadingTap: (heading, url) => _handleTldrReferenceTap(
                itemIndex: aiMessageItemIndex,
                messageId: aiMessageId,
                messageContent: aiMessageContent,
                heading: heading,
                url: url,
              ),
            );
          });
          items.add(
            (ctx) => Divider(color: CruxTheme.of(ctx).divider, height: 1),
          );
        } else {
          final nextIsUser =
              i + 1 < messages.length && messages[i + 1].role == 'user';
          if (nextIsUser) {
            items.add(
              (ctx) => Divider(color: CruxTheme.of(ctx).divider, height: 1),
            );
          }
        }
      }
    }

    // Render the in-memory `/btw` chain. Read from the list captured
    // at the top of this method (BtwCubit subscription) instead of
    // from the controller. The chat panel's _refresh() callback
    // rebuilds chat_history on every btw delta as before, so the
    // streaming AI-text updates on the in-flight turn still land at
    // the same cadence — the rebuild trigger just gained a cubit
    // path alongside the controller one.
    if (sessionId != null) {
      final lastIndex = btwTurns.length - 1;
      for (var i = 0; i < btwTurns.length; i++) {
        final turn = btwTurns[i];
        items.add((ctx) => BtwBubble.user(content: turn.userText));
        final isPendingLast =
            i == lastIndex && (rt?.btwMode ?? false) && isStreaming;
        if (!isPendingLast) {
          items.add((ctx) => BtwBubble.ai(content: turn.aiText));
        }
        items.add((ctx) => const SizedBox(height: 1));
      }
    }

    // Streaming bubble.
    if (isStreaming) {
      if (rt?.btwMode ?? false) {
        items.add((ctx) {
          return BtwBubble.ai(
            content: component.streamingController.streamingContentFor(
              component.sessionController.currentSessionId ?? 0,
            ),
            streaming: true,
          );
        });
      } else {
        items.add((ctx) {
          return StreamingBubble(
            // The streaming bubble owns its own [State] and a 33ms
            // poll Timer — the chat history no longer needs to feed
            // the current content in on every build. The session id
            // is passed so the bubble can look up the right
            // controller maps; tool-call snapshots still come in via
            // prop because they only change on round boundaries.
            streamingController: component.streamingController,
            sessionId: component.sessionController.currentSessionId ?? 0,
            streamingToolCalls: component.streamingController
                .streamingToolCallsFor(
                  component.sessionController.currentSessionId ?? 0,
                ),
            toolRegistry: component.toolRegistry,
            runtimeState: rt,
          );
        });
      }
    }

    // Queued messages bubble.
    if (sessionId != null && isStreaming) {
      final queue = component.sessionController.messageQueueFor(sessionId);
      if (queue.isNotEmpty) {
        items.add((ctx) => const SizedBox(height: 1));
        items.add((ctx) {
          return QueuedMessagesBubble(
            messages: queue.messages,
            onDiscard: (queueId) {
              component.sessionController.discardQueuedMessage(
                sessionId,
                queueId,
              );
              component.refresh();
            },
          );
        });
      }
    }

    final markers = List.generate(userItemIndices.length, (i) {
      return ScrollbarMarker(
        itemIndex: userItemIndices[i],
        color: CruxTheme.of(context).userPrefix,
        label: userItemLabels[i],
      );
    });

    return SelectionArea(
      onSelectionCompleted: (text) {
        if (text.isNotEmpty) {
          ClipboardManager.copy(text);
        }
      },
      child: AnnotatedScrollbar(
        controller: component.scrollController,
        thumbVisibility: true,
        markers: markers,
        child: ListView.builder(
          controller: component.scrollController,
          padding: EdgeInsets.all(1),
          itemCount: items.length,
          itemBuilder: (ctx, index) => items[index](ctx),
        ),
      ),
    );
  }

  void _handleTldrReferenceTap({
    required int itemIndex,
    required int messageId,
    required String messageContent,
    required String heading,
    required String? url,
  }) {
    if (url != null && url.isNotEmpty) {
      final result = openUrl(url);
      switch (result) {
        case UrlLaunchResult.launched:
          return;
        case UrlLaunchResult.rejected:
          component.showToast(
            'Refused to open url: $url',
            mode: ToastMode.error,
          );
          return;
        case UrlLaunchResult.failed:
          component.showToast("Couldn't open url: $url", mode: ToastMode.error);
          return;
      }
    }

    setState(() {
      _highlightText = heading;
      _highlightMessageId = messageId;
    });
    _clearHighlightAfterDelay();

    final itemInfo = component.scrollController.getItemIndexOffsetAndExtent(
      itemIndex,
    );
    if (itemInfo != null) {
      final lineOffset = _findExcerptLineOffset(messageContent, heading);
      component.scrollController.jumpTo(itemInfo.$1 + lineOffset);
    }
  }

  double _findExcerptLineOffset(String content, String excerpt) {
    int idx = content.indexOf(excerpt);
    if (idx < 0) {
      final normContent = content.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      final normExcerpt = excerpt.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      final normIdx = normContent.indexOf(normExcerpt);
      if (normIdx < 0) return 0;
      int charPos = 0;
      int normPos = 0;
      while (charPos < content.length && normPos < normIdx) {
        final ch = content[charPos];
        charPos++;
        if (ch == ' ' || ch == '\n' || ch == '\t') {
          while (charPos < content.length &&
              (content[charPos] == ' ' ||
                  content[charPos] == '\n' ||
                  content[charPos] == '\t')) {
            charPos++;
          }
        }
        normPos++;
      }
      idx = charPos;
    }
    final textBeforeExcerpt = content.substring(0, idx);
    final maxWidth = _lastContentWidth - 4;
    final config = TextLayoutConfig(
      softWrap: true,
      overflow: TextOverflow.clip,
      maxWidth: maxWidth - 4,
    );
    final result = TextLayoutEngine.layout(textBeforeExcerpt, config);
    return result.actualHeight.toDouble();
  }

  void _clearHighlightAfterDelay() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _highlightText = null;
          _highlightMessageId = null;
        });
      }
    });
  }

  /// Build the progress label for the empty-state branch when the
  /// session's message cache is being filled in by a chunked load.
  ///
  /// Three shapes, in order of preference:
  ///   1. "Loading 247 messages… (48%)" — once at least one chunk has
  ///      landed (so `loaded > 0`) and the total is known.
  ///   2. "Loading 247 messages…" — total known but no chunk yet
  ///      (the very first paint after `completeSwitchSession` fires
  ///      its COUNT(*) callback before the first chunk query).
  ///   3. "Loading messages…" — total not known yet (rare; the
  ///      COUNT(*) query is in flight but hasn't returned).
  ///
  /// `loaded` is the *post-cap* count — sessions with more than the
  /// 1000-message cap will show "… (100%)" once the cap is hit and
  /// the loop exits, even if the underlying DB has more rows.
  String _loadingLabel(int? total, int? loaded) {
    if (total != null && total > 0 && loaded != null && loaded > 0) {
      final pct = ((loaded * 100) / total).clamp(0, 100).round();
      return 'Loading $total messages… ($pct%)';
    }
    if (total != null && total > 0) {
      return 'Loading $total messages…';
    }
    return 'Loading messages…';
  }

  /// Find the session id and title of the conversation this
  /// session was compacted from, if any.
  ///
  /// Compaction creates a new session whose first message has role
  /// `compaction` with `meta.sourceSessionId` pointing at the old
  /// session. We pick the FIRST match — the original source — so
  /// re-compaction of the new session still points back to the
  /// pre-compaction history rather than the intermediate summary.
  ///
  /// `meta` is a JSON-encoded string; tolerate unparseable values
  /// gracefully (older rows, future schema drift). Title is
  /// resolved via [SessionController.findSession]; if the source
  /// session was deleted the title comes back `null` and the
  /// header falls back to rendering `ses://<id>` instead.
  ({int id, String? title})? _findCompactionSource(List<Message> messages) {
    for (final m in messages) {
      if (m.role != 'compaction' || m.meta.isEmpty) continue;
      try {
        final decoded = jsonDecode(m.meta);
        if (decoded is! Map<String, dynamic>) continue;
        final value = decoded['sourceSessionId'];
        int? id;
        if (value is int) id = value;
        if (value is String) id = int.tryParse(value);
        if (id == null) continue;

        final sourceSession = component.sessionController.findSession(id);
        final title = (sourceSession != null && sourceSession.title.isNotEmpty)
            ? sourceSession.title
            : null;
        return (id: id, title: title);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Resolve the display label for an internal reasoning effort value,
  /// using the current session's provider's [reasoningPresets].
  List<ReasoningPreset> _currentReasoningPresets() {
    final modelKey = component.sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName = slashIdx > 0 ? modelKey.substring(0, slashIdx) : '';
    final llm = component.providerService.llmProviderByName(providerName);
    if (llm == null) return const [];
    final modelId = slashIdx > 0 ? modelKey.substring(slashIdx + 1) : modelKey;
    final provider = component.providerService.providerByName(providerName);
    final modelConfig = provider?.modelById(modelId);
    return llm.reasoningPresetsFor(
      modelId,
      providerLabels: provider?.reasoningLabels ?? const {},
      modelLabels: modelConfig?.reasoningLabels ?? const {},
    );
  }
}
