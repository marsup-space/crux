import 'package:bloc/bloc.dart';
import 'package:nocterm/nocterm.dart';

import '../models/slash_command.dart';
import '../utils/at_mention_parser.dart';
import '../utils/file_searcher.dart';
import 'overlay_types.dart';

const _unset = Object();

class OverlayState {
  OverlayState({
    this.overlayMode = OverlayMode.off,
    List<SlashCommand> filteredCommands = const [],
    this.selectedCommandIndex = 0,
    this.commandScrollOffset = 0,
    this.activeCommand,
    this.currentParamIndex = 0,
    List<CommandSuggestion> filteredSuggestions = const [],
    this.selectedSuggestionIndex = 0,
    this.suggestionScrollOffset = 0,
    this.activeWizardSubcommand,
    this.builtinProviderName,
    this.showSessionManager = false,
    this.showFullpane = false,
    this.atMentionQuery = '',
    this.atMentionOffset,
    List<FileMatch> filteredFiles = const [],
    this.selectedFileIndex = 0,
    this.fileScrollOffset = 0,
    this.isSearching = false,
  }) : filteredCommands = List.unmodifiable(filteredCommands),
       filteredSuggestions = List.unmodifiable(filteredSuggestions),
       filteredFiles = List.unmodifiable(filteredFiles);

  final OverlayMode overlayMode;
  final List<SlashCommand> filteredCommands;
  final int selectedCommandIndex;
  final int commandScrollOffset;
  final SlashCommand? activeCommand;
  final int currentParamIndex;
  final List<CommandSuggestion> filteredSuggestions;
  final int selectedSuggestionIndex;
  final int suggestionScrollOffset;
  final ProviderWizardSubcommand? activeWizardSubcommand;
  final String? builtinProviderName;
  final bool showSessionManager;
  final bool showFullpane;
  final String atMentionQuery;
  final int? atMentionOffset;
  final List<FileMatch> filteredFiles;
  final int selectedFileIndex;
  final int fileScrollOffset;
  final bool isSearching;

  static OverlayState off() => OverlayState();

  OverlayState copyWith({
    OverlayMode? overlayMode,
    List<SlashCommand>? filteredCommands,
    int? selectedCommandIndex,
    int? commandScrollOffset,
    Object? activeCommand = _unset,
    int? currentParamIndex,
    List<CommandSuggestion>? filteredSuggestions,
    int? selectedSuggestionIndex,
    int? suggestionScrollOffset,
    Object? activeWizardSubcommand = _unset,
    Object? builtinProviderName = _unset,
    bool? showSessionManager,
    bool? showFullpane,
    String? atMentionQuery,
    Object? atMentionOffset = _unset,
    List<FileMatch>? filteredFiles,
    int? selectedFileIndex,
    int? fileScrollOffset,
    bool? isSearching,
  }) {
    return OverlayState(
      overlayMode: overlayMode ?? this.overlayMode,
      filteredCommands: filteredCommands ?? this.filteredCommands,
      selectedCommandIndex: selectedCommandIndex ?? this.selectedCommandIndex,
      commandScrollOffset: commandScrollOffset ?? this.commandScrollOffset,
      activeCommand: identical(activeCommand, _unset)
          ? this.activeCommand
          : activeCommand as SlashCommand?,
      currentParamIndex: currentParamIndex ?? this.currentParamIndex,
      filteredSuggestions: filteredSuggestions ?? this.filteredSuggestions,
      selectedSuggestionIndex:
          selectedSuggestionIndex ?? this.selectedSuggestionIndex,
      suggestionScrollOffset:
          suggestionScrollOffset ?? this.suggestionScrollOffset,
      activeWizardSubcommand: identical(activeWizardSubcommand, _unset)
          ? this.activeWizardSubcommand
          : activeWizardSubcommand as ProviderWizardSubcommand?,
      builtinProviderName: identical(builtinProviderName, _unset)
          ? this.builtinProviderName
          : builtinProviderName as String?,
      showSessionManager: showSessionManager ?? this.showSessionManager,
      showFullpane: showFullpane ?? this.showFullpane,
      atMentionQuery: atMentionQuery ?? this.atMentionQuery,
      atMentionOffset: identical(atMentionOffset, _unset)
          ? this.atMentionOffset
          : atMentionOffset as int?,
      filteredFiles: filteredFiles ?? this.filteredFiles,
      selectedFileIndex: selectedFileIndex ?? this.selectedFileIndex,
      fileScrollOffset: fileScrollOffset ?? this.fileScrollOffset,
      isSearching: isSearching ?? this.isSearching,
    );
  }

  FileMatch? get selectedFile {
    if (selectedFileIndex < 0 || selectedFileIndex >= filteredFiles.length) {
      return null;
    }
    return filteredFiles[selectedFileIndex];
  }

  @override
  bool operator ==(Object other) {
    return other is OverlayState &&
        other.overlayMode == overlayMode &&
        _listEquals(other.filteredCommands, filteredCommands) &&
        other.selectedCommandIndex == selectedCommandIndex &&
        other.commandScrollOffset == commandScrollOffset &&
        identical(other.activeCommand, activeCommand) &&
        other.currentParamIndex == currentParamIndex &&
        _listEquals(other.filteredSuggestions, filteredSuggestions) &&
        other.selectedSuggestionIndex == selectedSuggestionIndex &&
        other.suggestionScrollOffset == suggestionScrollOffset &&
        other.activeWizardSubcommand == activeWizardSubcommand &&
        other.builtinProviderName == builtinProviderName &&
        other.showSessionManager == showSessionManager &&
        other.showFullpane == showFullpane &&
        other.atMentionQuery == atMentionQuery &&
        other.atMentionOffset == atMentionOffset &&
        _listEquals(other.filteredFiles, filteredFiles) &&
        other.selectedFileIndex == selectedFileIndex &&
        other.fileScrollOffset == fileScrollOffset &&
        other.isSearching == isSearching;
  }

  @override
  int get hashCode => Object.hash(
    overlayMode,
    Object.hashAll(filteredCommands),
    selectedCommandIndex,
    commandScrollOffset,
    identityHashCode(activeCommand),
    currentParamIndex,
    Object.hashAll(filteredSuggestions),
    selectedSuggestionIndex,
    suggestionScrollOffset,
    activeWizardSubcommand,
    builtinProviderName,
    showSessionManager,
    showFullpane,
    atMentionQuery,
    atMentionOffset,
    Object.hashAll(filteredFiles),
    selectedFileIndex,
    fileScrollOffset,
    isSearching,
  );
}

class OverlayCubit extends Cubit<OverlayState> {
  OverlayCubit({
    required this.maxVisibleItems,
    required this.textController,
    required this.executeCommandCallback,
  }) : super(OverlayState.off());

  final int maxVisibleItems;
  final TextEditingController textController;
  final void Function(String) executeCommandCallback;

  void setOverlayOff() {
    emit(OverlayState.off());
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

  void showCommands(List<SlashCommand> commands) {
    if (commands.isEmpty) {
      setOverlayOff();
      return;
    }
    emit(
      state.copyWith(
        overlayMode: OverlayMode.command,
        filteredCommands: commands,
        selectedCommandIndex: 0,
        commandScrollOffset: 0,
        filteredSuggestions: const [],
        activeCommand: null,
        currentParamIndex: 0,
        selectedSuggestionIndex: 0,
        suggestionScrollOffset: 0,
        filteredFiles: const [],
        atMentionOffset: null,
        atMentionQuery: '',
        isSearching: false,
      ),
    );
  }

  void showParameterSuggestions({
    required SlashCommand command,
    required int paramIndex,
    required List<CommandSuggestion> suggestions,
  }) {
    if (suggestions.isEmpty) {
      setOverlayOff();
      return;
    }
    emit(
      state.copyWith(
        overlayMode: OverlayMode.parameter,
        activeCommand: command,
        currentParamIndex: paramIndex,
        filteredSuggestions: suggestions,
        selectedSuggestionIndex: 0,
        suggestionScrollOffset: 0,
        filteredCommands: const [],
        selectedCommandIndex: 0,
        commandScrollOffset: 0,
        filteredFiles: const [],
        atMentionOffset: null,
        atMentionQuery: '',
        isSearching: false,
      ),
    );
  }

  void showAtMention({
    required int atOffset,
    required String query,
    bool resetResults = false,
  }) {
    emit(
      state.copyWith(
        overlayMode: OverlayMode.atMention,
        atMentionOffset: atOffset,
        atMentionQuery: query,
        selectedFileIndex: resetResults ? 0 : state.selectedFileIndex,
        fileScrollOffset: resetResults ? 0 : state.fileScrollOffset,
        filteredFiles: resetResults ? const [] : state.filteredFiles,
        isSearching: true,
        filteredCommands: const [],
        selectedCommandIndex: 0,
        commandScrollOffset: 0,
        filteredSuggestions: const [],
        activeCommand: null,
        currentParamIndex: 0,
        selectedSuggestionIndex: 0,
        suggestionScrollOffset: 0,
      ),
    );
  }

  void setAtMentionSearching(bool searching) {
    emit(state.copyWith(isSearching: searching));
  }

  void setAtMentionResults(List<FileMatch> results) {
    emit(
      state.copyWith(
        filteredFiles: results,
        selectedFileIndex: 0,
        fileScrollOffset: 0,
        isSearching: false,
      ),
    );
  }

  void setSessionManagerVisible(bool visible) {
    emit(state.copyWith(showSessionManager: visible));
  }

  void setFullpaneVisible(bool visible) {
    emit(state.copyWith(showFullpane: visible));
  }

  void moveCommandSelectionUp() {
    if (state.filteredCommands.isEmpty) return;
    final selectedIndex = state.selectedCommandIndex > 0
        ? state.selectedCommandIndex - 1
        : state.filteredCommands.length - 1;
    emit(
      state.copyWith(
        selectedCommandIndex: selectedIndex,
        commandScrollOffset: computeScrollOffset(
          selectedIndex,
          state.commandScrollOffset,
          maxVisibleItems,
        ),
      ),
    );
  }

  void moveCommandSelectionDown() {
    if (state.filteredCommands.isEmpty) return;
    final selectedIndex =
        state.selectedCommandIndex < state.filteredCommands.length - 1
        ? state.selectedCommandIndex + 1
        : 0;
    emit(
      state.copyWith(
        selectedCommandIndex: selectedIndex,
        commandScrollOffset: computeScrollOffset(
          selectedIndex,
          state.commandScrollOffset,
          maxVisibleItems,
        ),
      ),
    );
  }

  void moveSuggestionSelectionUp() {
    if (state.filteredSuggestions.isEmpty) return;
    final selectedIndex = state.selectedSuggestionIndex > 0
        ? state.selectedSuggestionIndex - 1
        : state.filteredSuggestions.length - 1;
    emit(
      state.copyWith(
        selectedSuggestionIndex: selectedIndex,
        suggestionScrollOffset: computeScrollOffset(
          selectedIndex,
          state.suggestionScrollOffset,
          maxVisibleItems,
        ),
      ),
    );
  }

  void moveSuggestionSelectionDown() {
    if (state.filteredSuggestions.isEmpty) return;
    final selectedIndex =
        state.selectedSuggestionIndex < state.filteredSuggestions.length - 1
        ? state.selectedSuggestionIndex + 1
        : 0;
    emit(
      state.copyWith(
        selectedSuggestionIndex: selectedIndex,
        suggestionScrollOffset: computeScrollOffset(
          selectedIndex,
          state.suggestionScrollOffset,
          maxVisibleItems,
        ),
      ),
    );
  }

  void moveFileSelectionUp() {
    if (state.filteredFiles.isEmpty) return;
    final selectedIndex = state.selectedFileIndex > 0
        ? state.selectedFileIndex - 1
        : state.filteredFiles.length - 1;
    emit(
      state.copyWith(
        selectedFileIndex: selectedIndex,
        fileScrollOffset: computeScrollOffset(
          selectedIndex,
          state.fileScrollOffset,
          maxVisibleItems,
        ),
      ),
    );
  }

  void moveFileSelectionDown() {
    if (state.filteredFiles.isEmpty) return;
    final selectedIndex =
        state.selectedFileIndex < state.filteredFiles.length - 1
        ? state.selectedFileIndex + 1
        : 0;
    emit(
      state.copyWith(
        selectedFileIndex: selectedIndex,
        fileScrollOffset: computeScrollOffset(
          selectedIndex,
          state.fileScrollOffset,
          maxVisibleItems,
        ),
      ),
    );
  }

  void onHoverCommand(int index) {
    emit(
      state.copyWith(
        selectedCommandIndex: index,
        commandScrollOffset: computeScrollOffset(
          index,
          state.commandScrollOffset,
          maxVisibleItems,
        ),
      ),
    );
  }

  void onHoverSuggestion(int index) {
    emit(
      state.copyWith(
        selectedSuggestionIndex: index,
        suggestionScrollOffset: computeScrollOffset(
          index,
          state.suggestionScrollOffset,
          maxVisibleItems,
        ),
      ),
    );
  }

  void onHoverFile(int index) {
    emit(
      state.copyWith(
        selectedFileIndex: index,
        fileScrollOffset: computeScrollOffset(
          index,
          state.fileScrollOffset,
          maxVisibleItems,
        ),
      ),
    );
  }

  void onScrollCommand(MouseEvent event) {
    final maxOffset = state.filteredCommands.length > maxVisibleItems
        ? state.filteredCommands.length - maxVisibleItems
        : 0;
    if (event.button == MouseButton.wheelUp && state.commandScrollOffset > 0) {
      emit(
        state.copyWith(
          commandScrollOffset: (state.commandScrollOffset - maxVisibleItems)
              .clamp(0, maxOffset),
        ),
      );
    } else if (event.button == MouseButton.wheelDown &&
        state.commandScrollOffset < maxOffset) {
      emit(
        state.copyWith(
          commandScrollOffset: (state.commandScrollOffset + maxVisibleItems)
              .clamp(0, maxOffset),
        ),
      );
    }
  }

  void onScrollSuggestion(MouseEvent event) {
    final maxOffset = state.filteredSuggestions.length > maxVisibleItems
        ? state.filteredSuggestions.length - maxVisibleItems
        : 0;
    if (event.button == MouseButton.wheelUp &&
        state.suggestionScrollOffset > 0) {
      emit(
        state.copyWith(
          suggestionScrollOffset:
              (state.suggestionScrollOffset - maxVisibleItems).clamp(
                0,
                maxOffset,
              ),
        ),
      );
    } else if (event.button == MouseButton.wheelDown &&
        state.suggestionScrollOffset < maxOffset) {
      emit(
        state.copyWith(
          suggestionScrollOffset:
              (state.suggestionScrollOffset + maxVisibleItems).clamp(
                0,
                maxOffset,
              ),
        ),
      );
    }
  }

  void onScrollFile(MouseEvent event) {
    final maxOffset = state.filteredFiles.length > maxVisibleItems
        ? state.filteredFiles.length - maxVisibleItems
        : 0;
    if (event.button == MouseButton.wheelUp && state.fileScrollOffset > 0) {
      emit(
        state.copyWith(
          fileScrollOffset: (state.fileScrollOffset - maxVisibleItems).clamp(
            0,
            maxOffset,
          ),
        ),
      );
    } else if (event.button == MouseButton.wheelDown &&
        state.fileScrollOffset < maxOffset) {
      emit(
        state.copyWith(
          fileScrollOffset: (state.fileScrollOffset + maxVisibleItems).clamp(
            0,
            maxOffset,
          ),
        ),
      );
    }
  }

  void onTapCommand(int index) {
    final selected = state.filteredCommands[index];
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

  void onTapSuggestion(int index) {
    final selected = state.filteredSuggestions[index];
    final command = state.activeCommand;
    if (command == null) return;

    final trimmed = textController.text.replaceFirst(RegExp(r'^\s+'), '');
    final commandAndSpace = '${command.name} ';
    final restOfText = trimmed.substring(command.name.length + 1);

    String prefix;
    if (restOfText.isEmpty || restOfText.endsWith(' ')) {
      prefix = trimmed;
    } else {
      final lastSpace = restOfText.lastIndexOf(' ');
      prefix = lastSpace >= 0
          ? commandAndSpace + restOfText.substring(0, lastSpace + 1)
          : commandAndSpace;
    }

    final nextParamIndex = state.currentParamIndex + 1;
    final isLastParam = nextParamIndex >= command.params.length;

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

  void insertAtMention(int? atStart) {
    if (state.filteredFiles.isEmpty) return;
    final selected = state.filteredFiles[state.selectedFileIndex];
    final text = textController.text;
    final cursor = textController.selection.extentOffset;

    final resolvedStart =
        atStart ?? findActiveMentionInText(text, cursor)?.atOffset;
    if (resolvedStart == null || resolvedStart < 0) return;

    final insertion = '@${selected.relativePath} ';
    final newText = text.replaceRange(resolvedStart, cursor, insertion);
    textController.text = newText;
    textController.selection = TextSelection.collapsed(
      offset: resolvedStart + insertion.length,
    );

    setOverlayOff();
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i]) && a[i] != b[i]) return false;
  }
  return true;
}
