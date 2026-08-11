import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:path/path.dart' as p;

import '../models/image_attachment.dart';
import '../services/provider_service.dart';
import '../utils/clipboard_image.dart';
import '../utils/clipboard_text.dart';
import '../utils/dropped_file_handler.dart';
import 'session_controller.dart';
import 'chat_turn_orchestrator.dart';
import 'ui/toast.dart';

/// Handles clipboard paste, drag-and-drop, and image attachment for the
/// chat input.
///
/// Extracted from `ChatInputState` so the ~350 lines of paste/drag-drop/
/// image logic live in their own class with explicit dependencies.
class InputPaste {
  final SessionController sessionController;
  final ChatTurnOrchestrator turnOrchestrator;
  final ProviderService providerService;
  final bool providerServiceReady;
  final TextEditingController textController;
  final String projectPath;
  final void Function(ImageAttachment image)? onAttachClipboardImage;
  final void Function() onStateChanged;

  InputPaste({
    required this.sessionController,
    required this.turnOrchestrator,
    required this.providerService,
    required this.providerServiceReady,
    required this.textController,
    required this.projectPath,
    required this.onAttachClipboardImage,
    required this.onStateChanged,
  });

  /// Attempt to read an image from the system clipboard and add it as
  /// a pending attachment. Called on Ctrl+V when the current model
  /// supports images.
  Future<bool> tryClipboardImage(
    int sessionId, {
    bool showEmptyToast = false,
  }) async {
    try {
      final result = await ClipboardImageReader.readImage();
      if (result != null) {
        final image = ImageAttachment.fromBytes(
          bytes: result.bytes,
          mediaType: result.mediaType,
          label: result.label,
        );
        onAttachClipboardImage?.call(image);
        final sizeKB = (result.bytes.length / 1024).toStringAsFixed(0);
        turnOrchestrator.showToast(
          '📎 Clipboard image attached ($sizeKB KB). '
          'Type your message and press Enter to send.',
          mode: ToastMode.status,
        );
        onStateChanged();
        return true;
      } else if (showEmptyToast) {
        turnOrchestrator.showToast(
          'Clipboard is empty or unavailable',
          mode: ToastMode.error,
        );
      }
    } catch (e) {
      if (showEmptyToast) {
        turnOrchestrator.showToast(
          'Failed to read clipboard: $e',
          mode: ToastMode.error,
        );
      }
    }
    return false;
  }

  Future<void> pasteFromButton(int? sessionId) async {
    if (sessionId != null && currentModelSupportsImages()) {
      final attached = await tryClipboardImage(sessionId);
      if (attached) return;
    }

    // Same source order as Ctrl+V: OSC 52 straight from the terminal (no
    // external tool needed on Ghostty/WezTerm/kitty), then the OS tools
    // (wl-paste/xclip/…), then the session-internal buffer. The button
    // previously skipped OSC 52, so it failed on tool-less Wayland where
    // Ctrl+V already worked.
    final text = await _readClipboardText();
    if (text != null && text.isNotEmpty) {
      pasteText(text, sessionId);
      return;
    }

    turnOrchestrator.showToast(
      'Clipboard is empty or unavailable',
      mode: ToastMode.error,
    );
  }

  /// Resolve clipboard text using the same source order as Ctrl+V in a
  /// TextField: OSC 52 from the terminal first, then OS tools, then the
  /// internal session buffer.
  Future<String?> _readClipboardText() async {
    try {
      final viaOsc = await TerminalBinding.readClipboardViaOsc52();
      if (viaOsc != null && viaOsc.isNotEmpty) return viaOsc;
    } catch (_) {
      // Fall through to tool-based read.
    }
    return await ClipboardTextReader.readText() ?? ClipboardManager.paste();
  }

  void pasteText(String clipboardText, int? sessionId) {
    final normalized = clipboardText
        .replaceAll(RegExp(r'\r\n'), '\n')
        .replaceAll(RegExp(r'\r'), '\n');
    final handled = handlePaste(normalized, sessionId);
    if (handled) return;

    final text = textController.text;
    final selection = textController.selection;
    final start = selection.start.clamp(0, text.length);
    final end = selection.end.clamp(0, text.length);
    final replaceStart = start < end ? start : end;
    final replaceEnd = start < end ? end : start;
    final newText = text.replaceRange(replaceStart, replaceEnd, normalized);
    textController.text = newText;
    textController.selection = TextSelection.collapsed(
      offset: replaceStart + normalized.length,
    );
    onStateChanged();
  }

  bool currentModelSupportsImages() {
    if (onAttachClipboardImage == null) return false;
    if (!providerServiceReady) return false;
    final modelKey = sessionController.currentSession.model;
    return providerService.imageModelKeys().contains(modelKey);
  }

  /// Handle text pasted into the input. Routes drag-and-drop, images,
  /// and plain text.
  bool handlePaste(String pastedText, int? sessionId) {
    if (sessionId == null) return false;
    final trimmed = pastedText.trim();
    if (trimmed.isEmpty) return false;

    // ── 1) Drag-and-drop routing ───────────────────────────────
    final candidates = extractDroppedPaths(trimmed);
    if (candidates.isNotEmpty) {
      final classified = classifyDroppedPaths(
        candidates,
        projectRoot: projectPath,
      );
      if (looksLikeFileDrop(classified)) {
        _processDroppedFiles(classified, sessionId);
        return true;
      }
    }

    // ── 2) Legacy single-image path ────────────────────────────
    if (!currentModelSupportsImages()) return false;

    var candidate = trimmed;
    if (candidate.startsWith("'") && candidate.endsWith("'") ||
        candidate.startsWith('"') && candidate.endsWith('"')) {
      candidate = candidate.substring(1, candidate.length - 1);
    }
    if (candidate.startsWith('file://')) {
      candidate = candidate.substring('file://'.length);
    }

    if (!_looksLikeImagePath(candidate)) return false;
    final file = File(candidate);
    if (!file.existsSync()) return false;

    _tryAttachImageFile(file, sessionId);
    return true;
  }

  void _processDroppedFiles(List<DroppedFile> files, int sessionId) {
    final text = textController.text;
    final selection = textController.selection;
    final start = selection.start.clamp(0, text.length);
    final end = selection.end.clamp(0, text.length);
    final replaceStart = start < end ? start : end;
    final replaceEnd = start < end ? end : start;

    final supportsImages = currentModelSupportsImages();
    var imageCount = 0;
    var refCount = 0;
    final missingNames = <String>[];

    for (final f in files) {
      switch (f.kind) {
        case DroppedFileKind.image:
          if (supportsImages) {
            _tryAttachImageFile(File(f.absolutePath), sessionId);
            imageCount++;
          } else {
            refCount++;
          }
          break;
        case DroppedFileKind.file:
        case DroppedFileKind.directory:
          refCount++;
          break;
        case DroppedFileKind.missing:
          missingNames.add(p.basename(f.originalPath));
          break;
      }
    }

    final textPortion = formatDroppedFilesForInput(
      files
          .where((f) => f.kind != DroppedFileKind.missing)
          .where((f) => !(f.kind == DroppedFileKind.image && supportsImages))
          .toList(),
    );

    if (textPortion.isNotEmpty) {
      final newText = text.replaceRange(replaceStart, replaceEnd, textPortion);
      textController.text = newText;
      textController.selection = TextSelection.collapsed(
        offset: replaceStart + textPortion.length,
      );
    }

    if (missingNames.isNotEmpty) {
      turnOrchestrator.showToast(
        '⚠️ File(s) not found: ${missingNames.join(', ')}',
        mode: ToastMode.error,
      );
    }
    if (refCount > 0) {
      final parts = <String>[];
      if (imageCount > 0) parts.add('$imageCount image(s) attached');
      if (refCount > 0) parts.add('$refCount path(s) inserted');
      turnOrchestrator.showToast(
        '📎 Dropped: ${parts.join(', ')}',
        mode: ToastMode.status,
      );
    }

    onStateChanged();
  }

  bool _looksLikeImagePath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1 || dot == path.length - 1) return false;
    final ext = path.substring(dot + 1).toLowerCase();
    return ImageAttachment.isImageExtension(ext);
  }

  Future<void> _tryAttachImageFile(File file, int sessionId) async {
    try {
      final image = await ImageAttachment.fromFile(file.path);
      onAttachClipboardImage?.call(image);
      final sizeKB = (file.lengthSync() / 1024).toStringAsFixed(0);
      turnOrchestrator.showToast(
        '📎 Attached: ${image.label} ($sizeKB KB). '
        'Type your message and press Enter to send.',
        mode: ToastMode.status,
      );
    } catch (e) {
      turnOrchestrator.showToast(
        'Failed to attach image: $e',
        mode: ToastMode.error,
      );
    }
  }
}
