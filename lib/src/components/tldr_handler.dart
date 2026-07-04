import 'dart:async';

import '../models/message.dart';
import '../services/auxiliary_prompts.dart';
import '../services/chat_service.dart';
import '../services/provider_service.dart';
import '../storage/message_store.dart';
import 'session_controller.dart';
import 'ui/toast.dart';

typedef ShowToastCallback = void Function(String message, {ToastMode mode});

/// Handles TLDR summary generation.
///
/// Extracted from `ChatTurnOrchestrator` so the TLDR generation
/// logic lives in its own class.
class TldrHandler {
  final SessionController sessionController;
  final ProviderService providerService;
  final ChatService chatService;
  final MessageStore messageStore;
  final ShowToastCallback showToast;
  final void Function() refresh;

  TldrHandler({
    required this.sessionController,
    required this.providerService,
    required this.chatService,
    required this.messageStore,
    required this.showToast,
    required this.refresh,
  });

  Future<void> maybeGenerateTldr(
    int sessionId,
    Message aiMsg, {
    bool force = false,
    TldrDetail detail = TldrDetail.defaultLevel,
    String? userQuestion,
  }) async {
    final rt = sessionController.runtime(sessionId);
    final hasAuxModel =
        providerService.auxiliaryModel != null &&
        providerService.auxiliaryModel != 'none';

    if (!hasAuxModel) {
      if (force) {
        showToast(
          'No auxiliary model — set one with /auxiliary',
          mode: ToastMode.error,
        );
      }
      refresh();
      return;
    }

    if (!force) {
      final threshold = providerService.tldrThreshold;
      if (aiMsg.content.length < threshold) return;
      if (aiMsg.tldr.isNotEmpty) return;
    } else if (rt.isGeneratingTldr) {
      return;
    }

    if (force && aiMsg.tldr.isNotEmpty) {
      await messageStore.updateMessageTldr(aiMsg.id, '');
      final msgs = sessionController.messageCache[sessionId];
      if (msgs != null) {
        for (var i = 0; i < msgs.length; i++) {
          if (msgs[i].id == aiMsg.id) {
            // Rebuild the list with the modified message and route
            // through putCachedMessages so the SessionCubit's
            // BlocSelector (list identity compare) fires for the
            // clear. In-place `msgs[i] = msgs[i].copyWith(...)`
            // keeps the same list reference, so the cubit would
            // not see the change and chat_history would keep
            // rendering the previous tldr field.
            final updated = <Message>[
              for (var j = 0; j < msgs.length; j++)
                if (j == i) msgs[j].copyWith(tldr: '') else msgs[j],
            ];
            sessionController.putCachedMessages(sessionId, updated);
            break;
          }
        }
      }
    }

    rt.isGeneratingTldr = true;
    refresh();

    try {
      final tldrText = await chatService.generateTldr(
        aiMsg.content,
        userQuestion: userQuestion,
        detail: detail,
      );
      if (tldrText != null && tldrText.isNotEmpty) {
        await messageStore.updateMessageTldr(aiMsg.id, tldrText);
        final msgs = sessionController.messageCache[sessionId];
        if (msgs != null) {
          for (var i = 0; i < msgs.length; i++) {
            if (msgs[i].id == aiMsg.id) {
              final updated = <Message>[
                for (var j = 0; j < msgs.length; j++)
                  if (j == i) msgs[j].copyWith(tldr: tldrText) else msgs[j],
              ];
              sessionController.putCachedMessages(sessionId, updated);
              break;
            }
          }
        }
      }
    } finally {
      rt.isGeneratingTldr = false;
      refresh();
    }
  }
}
