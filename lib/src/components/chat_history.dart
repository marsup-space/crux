import 'package:nocterm/nocterm.dart';
import 'package:nocterm/src/text/text_layout_engine.dart';
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
import 'chat_turn_orchestrator.dart';
import 'message_bubble.dart';
import 'queued_messages_bubble.dart';
import 'session_controller.dart';
import 'streaming_bubble.dart';
import 'streaming_controller.dart';
import 'tldr_bubble.dart';

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
    final messages = component.sessionController.currentMessages;
    final sessionId = component.sessionController.currentSessionId;
    final rt = sessionId != null
        ? component.sessionController.runtime(sessionId)
        : null;
    final isStreaming = rt?.isResponding ?? false;

    final lastRoundStart = isStreaming
        ? -1
        : messages.lastIndexWhere((m) => m.role == 'user');

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
      if (sessionId != null &&
          component.sessionController.isLoadingMessages(sessionId)) {
        return Center(
          child: Text(
            _loadingLabel(component.sessionController, sessionId),
            style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
          ),
        );
      }
      final hasBtwTurns =
          sessionId != null &&
          component.sessionController.btwTurnsFor(sessionId).isNotEmpty;
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

    // Resolve the reasoning-effort display mapping once for the
    // entire build. The mapping depends only on the current
    // session's model/provider (see [_currentReasoningPresets]),
    // not on the individual message, so calling it per-message in
    // the loop was redundant — N redundant provider/model lookups
    // for an N-message session.
    final reasoningPresets = _currentReasoningPresets();

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final collapsed = i < lastRoundStart;
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

      // Build the MessageBubble inside a closure so the inner
      // widget tree (and the markdown parse in
      // [HighlightedMarkdownText.build]) only runs when
      // `itemBuilder` is called for this index — i.e. when the
      // bubble is actually laid out. Off-screen bubbles stay
      // un-built, which is the whole point of the change.
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
          onOpenPreviousSession: (targetSessionId) {
            component.sessionController.switchSession(targetSessionId).then((
              error,
            ) {
              if (error != null) {
                component.showToast(error, mode: ToastMode.error);
                return;
              }
              component.refresh();
            });
          },
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

    // Render the in-memory `/btw` chain.
    if (sessionId != null) {
      final btwTurns = component.sessionController.btwTurnsFor(sessionId);
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
  String _loadingLabel(SessionController controller, int sessionId) {
    final total = controller.loadingMessageTotal(sessionId);
    final loaded = controller.loadingMessageLoaded(sessionId);
    if (total != null && total > 0 && loaded != null && loaded > 0) {
      final pct = ((loaded * 100) / total).clamp(0, 100).round();
      return 'Loading $total messages… ($pct%)';
    }
    if (total != null && total > 0) {
      return 'Loading $total messages…';
    }
    return 'Loading messages…';
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
