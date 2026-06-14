import 'package:nocterm/nocterm.dart';
import '../models/slash_command.dart';

enum OverlayMode { off, command, parameter, wizard }

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
}
