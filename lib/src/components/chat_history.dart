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
  final void Function(ToolCallData toolCall, Message? pairedResult)? onToolCallTap;

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
      final hasBtwTurns = sessionId != null &&
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

    final items = <Component>[];
    final userItemIndices = <int>[];
    final userItemLabels = <String>[];

    for (var i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final collapsed = i < lastRoundStart;
      Message? pairedResult;
      if (msg.role == 'tool_call') {
        for (final tc in msg.toolCalls) {
          if (resultByCallId.containsKey(tc.callId)) {
            pairedResult = resultByCallId[tc.callId]!;
            break;
          }
        }
      }

      if (msg.role == 'user') {
        userItemIndices.add(items.length);
        final text = msg.content.replaceAll('\n', ' ').trim();
        userItemLabels.add(text);
      }

      items.add(
        MessageBubble(
          message: msg,
          reasoningCollapsed: collapsed,
          pairedResult: pairedResult,
          toolRegistry: component.toolRegistry,
          highlightText:
              msg.id == _highlightMessageId ? _highlightText : null,
          reasoningPresets: _currentReasoningPresets(),
          onToolCallTap: component.onToolCallTap,
        ),
      );

      if (msg.role == 'ai' && msg.id > 0 && rt != null) {
        final hasTldr = msg.tldr.isNotEmpty;
        if (hasTldr || rt.isGeneratingTldr) {
          final headings = extractHeadings(msg.content);
          final aiMessageItemIndex = items.length - 1;
          final aiMessageId = msg.id;
          final aiMessageContent = msg.content;
          items.add(
              Divider(color: CruxTheme.of(context).divider, height: 1));
          items.add(
            TldrBubble(
              tldrText: msg.tldr,
              headings: headings,
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
            ),
          );
          items.add(
              Divider(color: CruxTheme.of(context).divider, height: 1));
        } else {
          final nextIsUser =
              i + 1 < messages.length && messages[i + 1].role == 'user';
          if (nextIsUser) {
            items.add(
                Divider(color: CruxTheme.of(context).divider, height: 1));
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
        items.add(BtwBubble.user(content: turn.userText));
        final isPendingLast =
            i == lastIndex && (rt?.btwMode ?? false) && isStreaming;
        if (!isPendingLast) {
          items.add(BtwBubble.ai(content: turn.aiText));
        }
        items.add(SizedBox(height: 1));
      }
    }

    // Streaming bubble.
    if (isStreaming) {
      if (rt?.btwMode ?? false) {
        items.add(
          BtwBubble.ai(
            content: component.streamingController.streamingContentFor(
              component.sessionController.currentSessionId ?? 0,
            ),
            streaming: true,
          ),
        );
      } else {
        items.add(
          StreamingBubble(
            // The streaming bubble now owns its own [State]
            // and a 33ms poll Timer — the chat history no
            // longer needs to feed the current content in
            // on every build. That removes the dependency
            // on the chat panel rebuilding during streaming,
            // which is what was causing 30ms of layout per
            // 16ms chunk arrival. The session id is passed
            // so the bubble can look up the right
            // controller maps; tool-call snapshots still
            // come in via prop because they only change on
            // round boundaries.
            streamingController: component.streamingController,
            sessionId: component.sessionController.currentSessionId ?? 0,
            streamingToolCalls:
                component.streamingController.streamingToolCallsFor(
              component.sessionController.currentSessionId ?? 0,
            ),
            toolRegistry: component.toolRegistry,
            runtimeState: rt,
          ),
        );
      }
    }

    // Queued messages bubble.
    if (sessionId != null && isStreaming) {
      final queue =
          component.sessionController.messageQueueFor(sessionId);
      if (queue.isNotEmpty) {
        items.add(SizedBox(height: 1));
        items.add(
          QueuedMessagesBubble(
            messages: queue.messages,
            onDiscard: (queueId) {
              component.sessionController
                  .discardQueuedMessage(sessionId, queueId);
              component.refresh();
            },
          ),
        );
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
          itemBuilder: (context, index) => items[index],
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
          component.showToast(
            "Couldn't open url: $url",
            mode: ToastMode.error,
          );
          return;
      }
    }

    setState(() {
      _highlightText = heading;
      _highlightMessageId = messageId;
    });
    _clearHighlightAfterDelay();

    final itemInfo =
        component.scrollController.getItemIndexOffsetAndExtent(itemIndex);
    if (itemInfo != null) {
      final lineOffset =
          _findExcerptLineOffset(messageContent, heading);
      component.scrollController.jumpTo(itemInfo.$1 + lineOffset);
    }
  }

  double _findExcerptLineOffset(String content, String excerpt) {
    int idx = content.indexOf(excerpt);
    if (idx < 0) {
      final normContent =
          content.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      final normExcerpt =
          excerpt.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
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

  /// Resolve the display label for an internal reasoning effort value,
  /// using the current session's provider's [reasoningPresets].
  List<ReasoningPreset> _currentReasoningPresets() {
    final modelKey = component.sessionController.currentSession.model;
    final slashIdx = modelKey.indexOf('/');
    final providerName =
        slashIdx > 0 ? modelKey.substring(0, slashIdx) : '';
    final llm =
        component.providerService.llmProviderByName(providerName);
    if (llm == null) return const [];
    final modelId =
        slashIdx > 0 ? modelKey.substring(slashIdx + 1) : modelKey;
    final provider =
        component.providerService.providerByName(providerName);
    final modelConfig = provider?.modelById(modelId);
    return llm.reasoningPresetsFor(
      modelId,
      providerLabels: provider?.reasoningLabels ?? const {},
      modelLabels: modelConfig?.reasoningLabels ?? const {},
    );
  }
}
