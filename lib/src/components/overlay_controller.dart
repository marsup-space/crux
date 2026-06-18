import 'package:nocterm/nocterm.dart';
import '../models/slash_command.dart';
import '../utils/at_mention_parser.dart';
import '../utils/file_searcher.dart';

enum OverlayMode { off, command, parameter, wizard, atMention }

enum ProviderWizardSubcommand { builtin }

class OverlayController {
  OverlayMode overlayMode = OverlayMode.off;
  List<SlashCommand> filteredCommands = [];
  int selectedCommandIndex = 0;
  int commandScrollOffset = 0;
  SlashCommand? activeCommand;
  int currentParamIndex = 0;
  List<CommandSuggestion> filteredSuggestions = [];
  int selectedSuggestionIndex = 0;
  int suggestionScrollOffset = 0;
  ProviderWizardSubcommand? activeWizardSubcommand;
  String? builtinProviderName;
  bool showSessionManager = false;
  bool showFullpane = false;

  /// @-mention file browser state. The popover shows while
  /// [overlayMode] is [OverlayMode.atMention]; [atMentionQuery] is
  /// the text after the `@` up to the cursor, and [filteredFiles] is
  /// the fuzzy-search result for it.
  String atMentionQuery = '';
  List<FileMatch> filteredFiles = [];
  int selectedFileIndex = 0;
  int fileScrollOffset = 0;

  /// True while the file search is still working — either the
  /// index is being built (first time after construction or after
  /// a `/project` switch) or a debounced scan is in flight. The
  /// file browser overlay reads this to show a "Searching..."
  /// placeholder instead of an empty list, so the user knows
  /// the empty popover is a temporary state.
  bool isSearching = false;

  final int maxVisibleItems;
  final TextEditingController textController;
  final void Function(String) executeCommandCallback;

  OverlayController({
    required this.maxVisibleItems,
    required this.textController,
    required this.executeCommandCallback,
  });

  void setOverlayOff() {
    overlayMode = OverlayMode.off;
    filteredCommands = [];
    selectedCommandIndex = 0;
    commandScrollOffset = 0;
    filteredSuggestions = [];
    activeCommand = null;
    currentParamIndex = 0;
    selectedSuggestionIndex = 0;
    suggestionScrollOffset = 0;
    atMentionQuery = '';
    filteredFiles = [];
    selectedFileIndex = 0;
    fileScrollOffset = 0;
    isSearching = false;
    showSessionManager = false;
    showFullpane = false;
  }

  int computeScrollOffset(
    int selectedIndex,
    int currentOffset,
    int maxVisible,
  ) {
    if (selectedIndex < currentOffset) return selectedIndex;
    if (selectedIndex >= currentOffset + maxVisible) {
      return selectedIndex - maxVisible + 1;
    }
    return currentOffset;
  }

  void moveCommandSelectionUp() {
    selectedCommandIndex = selectedCommandIndex > 0
        ? selectedCommandIndex - 1
        : filteredCommands.length - 1;
    commandScrollOffset = computeScrollOffset(
      selectedCommandIndex,
      commandScrollOffset,
      maxVisibleItems,
    );
  }

  void moveCommandSelectionDown() {
    selectedCommandIndex = selectedCommandIndex < filteredCommands.length - 1
        ? selectedCommandIndex + 1
        : 0;
    commandScrollOffset = computeScrollOffset(
      selectedCommandIndex,
      commandScrollOffset,
      maxVisibleItems,
    );
  }

  void moveSuggestionSelectionUp() {
    selectedSuggestionIndex = selectedSuggestionIndex > 0
        ? selectedSuggestionIndex - 1
        : filteredSuggestions.length - 1;
    suggestionScrollOffset = computeScrollOffset(
      selectedSuggestionIndex,
      suggestionScrollOffset,
      maxVisibleItems,
    );
  }

  void moveSuggestionSelectionDown() {
    selectedSuggestionIndex =
        selectedSuggestionIndex < filteredSuggestions.length - 1
        ? selectedSuggestionIndex + 1
        : 0;
    suggestionScrollOffset = computeScrollOffset(
      selectedSuggestionIndex,
      suggestionScrollOffset,
      maxVisibleItems,
    );
  }

  void onHoverCommand(int index) {
    selectedCommandIndex = index;
    commandScrollOffset = computeScrollOffset(
      index,
      commandScrollOffset,
      maxVisibleItems,
    );
  }

  void onTapCommand(int index) {
    final selected = filteredCommands[index];
    if (selected.params.isEmpty) {
      setOverlayOff();
      textController.clear();
      executeCommandCallback(selected.name);
    } else {
      textController.text = '${selected.name} ';
      textController.selection = TextSelection.collapsed(
        offset: textController.text.length,
      );
    }
  }

  void onScrollCommand(MouseEvent event) {
    final maxOffset = filteredCommands.length > maxVisibleItems
        ? filteredCommands.length - maxVisibleItems
        : 0;
    if (event.button == MouseButton.wheelUp && commandScrollOffset > 0) {
      commandScrollOffset = (commandScrollOffset - maxVisibleItems).clamp(
        0,
        maxOffset,
      );
    } else if (event.button == MouseButton.wheelDown &&
        commandScrollOffset < maxOffset) {
      commandScrollOffset = (commandScrollOffset + maxVisibleItems).clamp(
        0,
        maxOffset,
      );
    }
  }

  void onHoverSuggestion(int index) {
    selectedSuggestionIndex = index;
    suggestionScrollOffset = computeScrollOffset(
      index,
      suggestionScrollOffset,
      maxVisibleItems,
    );
  }

  void onTapSuggestion(int index) {
    final selected = filteredSuggestions[index];
    final trimmed = textController.text.replaceFirst(RegExp(r'^\s+'), '');
    final commandAndSpace = '${activeCommand!.name} ';
    final restOfText = trimmed.substring(activeCommand!.name.length + 1);

    String prefix;
    if (restOfText.isEmpty || restOfText.endsWith(' ')) {
      prefix = trimmed;
    } else {
      final lastSpace = restOfText.lastIndexOf(' ');
      prefix = lastSpace >= 0
          ? commandAndSpace + restOfText.substring(0, lastSpace + 1)
          : commandAndSpace;
    }

    final nextParamIndex = currentParamIndex + 1;
    final isLastParam = nextParamIndex >= activeCommand!.params.length;

    if (isLastParam) {
      final commandText = prefix + selected.value;
      setOverlayOff();
      textController.clear();
      executeCommandCallback(commandText);
    } else {
      final newText = '$prefix${selected.value} ';
      textController.text = newText;
      textController.selection = TextSelection.collapsed(
        offset: newText.length,
      );
    }
  }

  void onScrollSuggestion(MouseEvent event) {
    final maxOffset = filteredSuggestions.length > maxVisibleItems
        ? filteredSuggestions.length - maxVisibleItems
        : 0;
    if (event.button == MouseButton.wheelUp && suggestionScrollOffset > 0) {
      suggestionScrollOffset = (suggestionScrollOffset - maxVisibleItems).clamp(
        0,
        maxOffset,
      );
    } else if (event.button == MouseButton.wheelDown &&
        suggestionScrollOffset < maxOffset) {
      suggestionScrollOffset = (suggestionScrollOffset + maxVisibleItems).clamp(
        0,
        maxOffset,
      );
    }
  }

  // ── @-mention file browser ──────────────────────────────────────
  //
  // The `@` popover behaves a lot like the command parameter
  // suggestions: arrow keys move the cursor, Enter inserts the
  // selected path into the text controller (replacing the
  // `@<query>` fragment the user typed so far), and ESC dismisses.
  //
  // The two differences vs. command params:
  // 1. There is no fixed command prefix — the trigger is just an
  //    `@` character somewhere in the message (not at offset 0).
  //    The chat input computes the start offset of the `@<query>`
  //    fragment and passes it to [insertAtMention].
  // 2. Files/directories are typed via the `FileMatch` model
  //    (relative path + kind + score) instead of generic
  //    `CommandSuggestion` values.

  void moveFileSelectionUp() {
    selectedFileIndex = selectedFileIndex > 0
        ? selectedFileIndex - 1
        : filteredFiles.length - 1;
    fileScrollOffset = computeScrollOffset(
      selectedFileIndex,
      fileScrollOffset,
      maxVisibleItems,
    );
  }

  void moveFileSelectionDown() {
    selectedFileIndex = selectedFileIndex < filteredFiles.length - 1
        ? selectedFileIndex + 1
        : 0;
    fileScrollOffset = computeScrollOffset(
      selectedFileIndex,
      fileScrollOffset,
      maxVisibleItems,
    );
  }

  /// The currently highlighted file match, or `null` if the
  /// popover is empty / out of range. Used by the chat input's
  /// right-arrow handler to drill into directories.
  FileMatch? get selectedFile {
    if (selectedFileIndex < 0 || selectedFileIndex >= filteredFiles.length) {
      return null;
    }
    return filteredFiles[selectedFileIndex];
  }

  void onHoverFile(int index) {
    selectedFileIndex = index;
    fileScrollOffset = computeScrollOffset(index, fileScrollOffset, maxVisibleItems);
  }

  void onScrollFile(MouseEvent event) {
    final maxOffset = filteredFiles.length > maxVisibleItems
        ? filteredFiles.length - maxVisibleItems
        : 0;
    if (event.button == MouseButton.wheelUp && fileScrollOffset > 0) {
      fileScrollOffset = (fileScrollOffset - maxVisibleItems).clamp(0, maxOffset);
    } else if (event.button == MouseButton.wheelDown &&
        fileScrollOffset < maxOffset) {
      fileScrollOffset = (fileScrollOffset + maxVisibleItems).clamp(0, maxOffset);
    }
  }

  /// Insert the currently-selected file at the given `@` start
  /// position. The `@<query>` fragment is replaced with `@<path> `
  /// (or `@<path>/ ` for directories so the user can keep typing to
  /// drill in). The trailing space is what makes the popover dismiss
  /// itself — the next char typed will land in the chat message body
  /// rather than the query. The cursor is placed at the end of the
  /// inserted text.
  ///
  /// If [atStart] is `null`, falls back to [findActiveMentionInText]
  /// to locate the active `@` in the buffer — this is the common
  /// case when the popover was just dismissed by Enter and we know
  /// which `@` to replace. The mouse-tap path in `chat_panel.dart`
  /// also passes `null` and relies on this fallback.
  void insertAtMention(int? atStart) {
    if (filteredFiles.isEmpty) return;
    final selected = filteredFiles[selectedFileIndex];
    final text = textController.text;
    final cursor = textController.selection.extentOffset;

    // If the caller didn't tell us where the @ is, find the
    // in-progress mention ourselves. This honours the same rules
    // the chat input uses (including the "allow whitespace inside
    // a path component" rule for files in directories whose names
    // contain spaces), and rejects email-style mentions.
    final resolvedStart = atStart ??
        findActiveMentionInText(text, cursor)?.atOffset;
    if (resolvedStart == null || resolvedStart < 0) return;

    // Always append a trailing space — whether the user picked a
    // file or a directory — so the @-mention ends and they can
    // keep typing prose. To drill *into* a directory the chat
    // input's right-arrow handler takes a different path (it
    // appends `/` and keeps the popover open).
    final insertion = '@${selected.relativePath} ';

    // The query runs from resolvedStart to the current cursor; we
    // replace that span in place. The new cursor lands right after
    // the inserted path.
    final newText = text.replaceRange(resolvedStart, cursor, insertion);
    textController.text = newText;
    textController.selection = TextSelection.collapsed(
      offset: resolvedStart + insertion.length,
    );

    setOverlayOff();
  }
}
