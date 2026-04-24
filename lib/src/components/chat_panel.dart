import 'dart:async';
import 'dart:math';
import 'package:nocterm/nocterm.dart';
import '../models/message.dart';
import '../models/slash_command.dart';
import '../commands/registry.dart';
import 'button.dart';
import 'toast.dart';

enum _OverlayMode { off, command, parameter }

class ChatPanel extends StatefulComponent {
  const ChatPanel({super.key});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final List<Message> messages = [];
  final AutoScrollController scrollController = AutoScrollController();
  final TextEditingController textController = TextEditingController();

  // Current model displayed in toolbar
  String _currentModel = 'openai/gpt-4o';

  // Overlay mode
  _OverlayMode _overlayMode = _OverlayMode.off;

  // Command mode state
  List<SlashCommand> _filteredCommands = [];
  int _selectedCommandIndex = 0;
  int _commandScrollOffset = 0;

  // Parameter mode state
  SlashCommand? _activeCommand;
  int _currentParamIndex = 0;
  List<CommandSuggestion> _filteredSuggestions = [];
  int _selectedSuggestionIndex = 0;
  int _suggestionScrollOffset = 0;

  // Toast state
  bool _toastVisible = false;
  String _toastMessage = '';

  // Mock chat response state
  bool _isResponding = false;
  Timer? _responseTimer;
  int _mockResponseIndex = 0;

  static const List<String> _mockResponses = [
    "I've analyzed your request. Here's my approach...",
    "That's an interesting question. Let me break it down for you.",
    "I can help with that. Let me outline a solution.",
    "Good thinking! Here's what I'd suggest...",
    "Let me consider the options and recommend the best path forward.",
  ];

  static const int _infoPanelMinWidth = 100;
  static const double _infoPanelWidth = 28;
  static const int _maxVisibleItems = 6;

  @override
  void initState() {
    super.initState();
    textController.addListener(_onTextChanged);
    messages.addAll([
      Message(
        role: 'ai',
        content:
            "Hello! I'm Crux, your coding assistant. What would you like to work on today?",
      ),
      Message(
        role: 'user',
        content: 'Can you help me build a TUI application with a chat interface?',
      ),
      Message(
        role: 'ai',
        content:
            'Absolutely! I can help you build a TUI chat application using Nocterm. What specific features are you looking for?',
      ),
    ]);
  }

  @override
  void dispose() {
    textController.removeListener(_onTextChanged);
    _responseTimer?.cancel();
    scrollController.dispose();
    textController.dispose();
    super.dispose();
  }

  void _setOverlayOff() {
    _overlayMode = _OverlayMode.off;
    _filteredCommands = [];
    _selectedCommandIndex = 0;
    _commandScrollOffset = 0;
    _filteredSuggestions = [];
    _activeCommand = null;
    _currentParamIndex = 0;
    _selectedSuggestionIndex = 0;
    _suggestionScrollOffset = 0;
  }

  /// Parse input text to determine overlay mode and update state.
  void _onTextChanged() {
    final text = textController.text;
    final trimmed = text.replaceFirst(RegExp(r'^\s+'), '');

    if (!trimmed.startsWith('/')) {
      _setOverlayOff();
      setState(() {});
      return;
    }

    final spaceIndex = trimmed.indexOf(' ');

    // No space after / → command mode
    if (spaceIndex == -1) {
      _filteredCommands = filterCommands(trimmed);
      if (_filteredCommands.isEmpty) {
        _setOverlayOff();
      } else {
        _overlayMode = _OverlayMode.command;
        _selectedCommandIndex = 0;
        _commandScrollOffset = 0;
      }
      setState(() {});
      return;
    }

    // Has a space → check for parameter mode
    final commandName = trimmed.substring(0, spaceIndex);
    final command = findCommand(commandName);

    if (command == null || !command.hasSuggestionsForParam(0)) {
      _setOverlayOff();
      setState(() {});
      return;
    }

    // Parse which param we're completing and what's been typed
    final afterCommand = trimmed.substring(spaceIndex + 1);
    int paramIndex;
    String currentInput;

    if (afterCommand.isEmpty) {
      // Just typed "/command ", starting first param
      paramIndex = 0;
      currentInput = '';
    } else if (afterCommand.endsWith(' ')) {
      // Completed a param, starting the next one
      final completedParts = afterCommand
          .trimRight()
          .split(' ')
          .where((s) => s.isNotEmpty)
          .toList();
      paramIndex = completedParts.length;
      currentInput = '';
    } else {
      // Currently typing a param value
      final parts = afterCommand.split(' ');
      currentInput = parts.last;
      paramIndex = parts.length - 1;
    }

    if (!command.hasSuggestionsForParam(paramIndex)) {
      _setOverlayOff();
      setState(() {});
      return;
    }

    final suggestions = command.suggestionsPerParam[paramIndex];
    _filteredSuggestions = filterSuggestions(suggestions, currentInput);

    if (_filteredSuggestions.isEmpty) {
      _setOverlayOff();
      setState(() {});
      return;
    }

    _overlayMode = _OverlayMode.parameter;
    _activeCommand = command;
    _currentParamIndex = paramIndex;
    _selectedSuggestionIndex = 0;
    _suggestionScrollOffset = 0;
    setState(() {});
  }

  /// Compute scroll offset so the selected item is always visible.
  int _computeScrollOffset(int selectedIndex, int currentOffset, int maxVisible) {
    if (selectedIndex < currentOffset) return selectedIndex;
    if (selectedIndex >= currentOffset + maxVisible) {
      return selectedIndex - maxVisible + 1;
    }
    return currentOffset;
  }

  /// Intercept key events when the overlay is visible.
  /// Handles arrow navigation, Enter to select, and Escape to dismiss
  /// in both command and parameter modes.
  bool _handleInputKeyEvent(KeyboardEvent event) {
    if (_overlayMode == _OverlayMode.off) return false;

    // ── Command mode ──
    if (_overlayMode == _OverlayMode.command) {
      if (_filteredCommands.isEmpty) return false;

      if (event.logicalKey == LogicalKey.arrowUp) {
        setState(() {
          _selectedCommandIndex = _selectedCommandIndex > 0
              ? _selectedCommandIndex - 1
              : _filteredCommands.length - 1;
          _commandScrollOffset = _computeScrollOffset(
            _selectedCommandIndex,
            _commandScrollOffset,
            _maxVisibleItems,
          );
        });
        return true;
      }

      if (event.logicalKey == LogicalKey.arrowDown) {
        setState(() {
          _selectedCommandIndex =
              _selectedCommandIndex < _filteredCommands.length - 1
                  ? _selectedCommandIndex + 1
                  : 0;
          _commandScrollOffset = _computeScrollOffset(
            _selectedCommandIndex,
            _commandScrollOffset,
            _maxVisibleItems,
          );
        });
        return true;
      }

      if (event.logicalKey == LogicalKey.enter) {
        final selected = _filteredCommands[_selectedCommandIndex];
        textController.text = selected.name + ' ';
        textController.selection =
            TextSelection.collapsed(offset: textController.text.length);
        // _onTextChanged fires and transitions to parameter mode if applicable
        return true;
      }

      if (event.logicalKey == LogicalKey.escape) {
        textController.clear();
        _setOverlayOff();
        setState(() {});
        return true;
      }

      return false;
    }

    // ── Parameter mode ──
    if (_overlayMode == _OverlayMode.parameter) {
      if (_filteredSuggestions.isEmpty) return false;

      if (event.logicalKey == LogicalKey.arrowUp) {
        setState(() {
          _selectedSuggestionIndex = _selectedSuggestionIndex > 0
              ? _selectedSuggestionIndex - 1
              : _filteredSuggestions.length - 1;
          _suggestionScrollOffset = _computeScrollOffset(
            _selectedSuggestionIndex,
            _suggestionScrollOffset,
            _maxVisibleItems,
          );
        });
        return true;
      }

      if (event.logicalKey == LogicalKey.arrowDown) {
        setState(() {
          _selectedSuggestionIndex =
              _selectedSuggestionIndex < _filteredSuggestions.length - 1
                  ? _selectedSuggestionIndex + 1
                  : 0;
          _suggestionScrollOffset = _computeScrollOffset(
            _selectedSuggestionIndex,
            _suggestionScrollOffset,
            _maxVisibleItems,
          );
        });
        return true;
      }

      if (event.logicalKey == LogicalKey.enter) {
        final selected = _filteredSuggestions[_selectedSuggestionIndex];
        final trimmed =
            textController.text.replaceFirst(RegExp(r'^\s+'), '');
        final commandAndSpace = _activeCommand!.name + ' ';
        final restOfText =
            trimmed.substring(_activeCommand!.name.length + 1);

        // Compute the prefix: everything before the currently-typed param value
        String prefix;
        if (restOfText.isEmpty || restOfText.endsWith(' ')) {
          // At the start of a new param (empty or just completed one)
          prefix = trimmed;
        } else {
          // Currently typing a param — replace just the incomplete portion
          final lastSpace = restOfText.lastIndexOf(' ');
          prefix = lastSpace >= 0
              ? commandAndSpace + restOfText.substring(0, lastSpace + 1)
              : commandAndSpace;
        }

        final newText = prefix + selected.value + ' ';
        textController.text = newText;
        textController.selection =
            TextSelection.collapsed(offset: newText.length);
        // _onTextChanged fires and transitions to next param or off
        return true;
      }

      if (event.logicalKey == LogicalKey.escape) {
        // Dismiss overlay but keep the command text in the input
        _setOverlayOff();
        setState(() {});
        return true;
      }

      return false;
    }

    return false;
  }

  void _onHoverCommand(int index) {
    setState(() {
      _selectedCommandIndex = index;
      _commandScrollOffset = _computeScrollOffset(
        index,
        _commandScrollOffset,
        _maxVisibleItems,
      );
    });
  }

  void _onTapCommand(int index) {
    final selected = _filteredCommands[index];
    textController.text = selected.name + ' ';
    textController.selection =
        TextSelection.collapsed(offset: textController.text.length);
  }

  void _onScrollCommand(MouseEvent event) {
    final maxOffset = _filteredCommands.length > _maxVisibleItems
        ? _filteredCommands.length - _maxVisibleItems
        : 0;
    if (event.button == MouseButton.wheelUp && _commandScrollOffset > 0) {
      setState(() {
        _commandScrollOffset =
            (_commandScrollOffset - _maxVisibleItems).clamp(0, maxOffset);
      });
    } else if (event.button == MouseButton.wheelDown &&
        _commandScrollOffset < maxOffset) {
      setState(() {
        _commandScrollOffset =
            (_commandScrollOffset + _maxVisibleItems).clamp(0, maxOffset);
      });
    }
  }

  void _onHoverSuggestion(int index) {
    setState(() {
      _selectedSuggestionIndex = index;
      _suggestionScrollOffset = _computeScrollOffset(
        index,
        _suggestionScrollOffset,
        _maxVisibleItems,
      );
    });
  }

  void _onTapSuggestion(int index) {
    final selected = _filteredSuggestions[index];
    final trimmed =
        textController.text.replaceFirst(RegExp(r'^\s+'), '');
    final commandAndSpace = _activeCommand!.name + ' ';
    final restOfText =
        trimmed.substring(_activeCommand!.name.length + 1);

    String prefix;
    if (restOfText.isEmpty || restOfText.endsWith(' ')) {
      prefix = trimmed;
    } else {
      final lastSpace = restOfText.lastIndexOf(' ');
      prefix = lastSpace >= 0
          ? commandAndSpace + restOfText.substring(0, lastSpace + 1)
          : commandAndSpace;
    }

    final newText = prefix + selected.value + ' ';
    textController.text = newText;
    textController.selection =
        TextSelection.collapsed(offset: newText.length);
  }

  void _onScrollSuggestion(MouseEvent event) {
    final maxOffset = _filteredSuggestions.length > _maxVisibleItems
        ? _filteredSuggestions.length - _maxVisibleItems
        : 0;
    if (event.button == MouseButton.wheelUp &&
        _suggestionScrollOffset > 0) {
      setState(() {
        _suggestionScrollOffset =
            (_suggestionScrollOffset - _maxVisibleItems).clamp(0, maxOffset);
      });
    } else if (event.button == MouseButton.wheelDown &&
        _suggestionScrollOffset < maxOffset) {
      setState(() {
        _suggestionScrollOffset =
            (_suggestionScrollOffset + _maxVisibleItems).clamp(0, maxOffset);
      });
    }
  }

  void _sendMessage() {
    final text = textController.text.trim();
    if (text.isEmpty) return;

    textController.clear();

    // Slash commands are not added to chat log
    if (text.startsWith('/')) {
      _executeCommand(text);
      return;
    }

    setState(() {
      messages.add(Message(role: 'user', content: text));
      _isResponding = true;
    });

    // Mock AI response after 5 seconds
    _responseTimer?.cancel();
    _responseTimer = Timer(const Duration(seconds: 5), () {
      setState(() {
        _isResponding = false;
        messages.add(Message(
          role: 'ai',
          content: _mockResponses[_mockResponseIndex % _mockResponses.length],
        ));
        _mockResponseIndex++;
      });
    });
  }

  void _executeCommand(String text) {
    final parts = text.split(' ');
    final commandName = parts[0];
    final command = findCommand(commandName);

    if (commandName == '/model') {
      if (parts.length > 1 && parts[1].isNotEmpty) {
        setState(() {
          _currentModel = parts[1];
          _toastVisible = true;
          _toastMessage = 'Model switched to ${parts[1]}';
        });
      } else {
        setState(() {
          _toastVisible = true;
          _toastMessage = 'Usage: /model <name>';
        });
      }
    } else if (command != null) {
      setState(() {
        _toastVisible = true;
        _toastMessage = '$commandName — not yet implemented';
      });
    } else {
      setState(() {
        _toastVisible = true;
        _toastMessage = 'Unknown command: $commandName';
      });
    }
  }

  void _dismissToast() {
    setState(() {
      _toastVisible = false;
      _toastMessage = '';
    });
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (_) => false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showInfoPanel = constraints.maxWidth >= _infoPanelMinWidth;

          if (showInfoPanel) {
            return Row(
              children: [
                Expanded(child: _buildMainInterface()),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Color.fromRGB(50, 50, 70),
                ),
                SizedBox(
                  width: _infoPanelWidth,
                  child: _ExtraInfoPanel(messages: messages),
                ),
              ],
            );
          }

          return _buildMainInterface();
        },
      ),
    );
  }

  Component _buildMainInterface() {
    final children = <Component>[];

    children.add(Expanded(child: _buildMessageList()));

    if (_overlayMode == _OverlayMode.command &&
        _filteredCommands.isNotEmpty) {
      children.add(
        MouseRegion(
          onHover: _onScrollCommand,
          opaque: false,
          child: _CommandOverlay(
            commands: _filteredCommands,
            selectedIndex: _selectedCommandIndex,
            scrollOffset: _commandScrollOffset,
            maxVisible: _maxVisibleItems,
            onHover: _onHoverCommand,
            onTap: _onTapCommand,
          ),
        ),
      );
    } else if (_overlayMode == _OverlayMode.parameter &&
        _filteredSuggestions.isNotEmpty) {
      final paramLabel = _currentParamIndex < _activeCommand!.params.length
          ? _activeCommand!.params[_currentParamIndex]
          : 'value';
      children.add(
        MouseRegion(
          onHover: _onScrollSuggestion,
          opaque: false,
          child: _SuggestionOverlay(
            suggestions: _filteredSuggestions,
            selectedIndex: _selectedSuggestionIndex,
            scrollOffset: _suggestionScrollOffset,
            maxVisible: _maxVisibleItems,
            headerLabel: paramLabel,
            onHover: _onHoverSuggestion,
            onTap: _onTapSuggestion,
          ),
        ),
      );
    }

    if (_toastVisible) {
      children.add(
        Toast(
          message: _toastMessage,
          onDismissed: _dismissToast,
        ),
      );
    }

    children.add(_buildToolbar());
    children.add(Divider(color: Color.fromRGB(50, 50, 70), height: 1));
    children.add(_buildInputRow());

    return Column(children: children);
  }

  Component _buildMessageList() {
    if (messages.isEmpty) {
      return Center(
        child: Text(
          'No messages yet.',
          style: TextStyle(color: Colors.gray),
        ),
      );
    }

    return Scrollbar(
      controller: scrollController,
      thumbVisibility: true,
      child: ListView.builder(
        controller: scrollController,
        padding: EdgeInsets.all(1),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          return _MessageBubble(message: messages[index]);
        },
      ),
    );
  }

  Component _buildToolbar() {
    final modelButton = _isResponding
        ? _GlossyModelButton(
            label: _currentModel,
            isAnimating: true,
            onPressed: _onModelButtonPressed,
          )
        : Button(
            label: _currentModel,
            onPressed: _onModelButtonPressed,
            color: Color.fromRGB(120, 100, 160),
            hoverColor: Colors.brightCyan,
            bgColor: Color.fromRGB(25, 20, 45),
            hoverBgColor: Color.fromRGB(40, 30, 80),
            padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          );

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      child: Row(
        children: [
          modelButton,
        ],
      ),
    );
  }

  void _onModelButtonPressed() {
    final newText = '/model ';
    textController.text = newText;
    textController.selection =
        TextSelection.collapsed(offset: newText.length);
  }

  Component _buildInputRow() {
    return Container(
      padding: EdgeInsets.all(1),
      child: Row(
        children: [
          Text(
            '> ',
            style: TextStyle(color: Colors.gray),
          ),
          Expanded(
            child: TextField(
              controller: textController,
              focused: true,
              style: TextStyle(color: Colors.white),
              placeholder: 'Type a message...',
              onSubmitted: (_) => _sendMessage(),
              onKeyEvent: _handleInputKeyEvent,
            ),
          ),
        ],
      ),
    );
  }
}

/// Overlay panel showing slash command suggestions.
/// Appears inline above the input row when the user types a `/` command prefix.
class _CommandOverlay extends StatelessComponent {
  final List<SlashCommand> commands;
  final int selectedIndex;
  final int scrollOffset;
  final int maxVisible;
  final void Function(int)? onHover;
  final void Function(int)? onTap;

  const _CommandOverlay({
    required this.commands,
    required this.selectedIndex,
    required this.scrollOffset,
    required this.maxVisible,
    this.onHover,
    this.onTap,
  });

  @override
  Component build(BuildContext context) {
    final visibleCommands =
        commands.skip(scrollOffset).take(maxVisible).toList();

    final rows = <Component>[];


    rows.add(Divider(color: Color.fromRGB(80, 60, 120), height: 1));

    // Header row
    rows.add(
      Container(
        padding: EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            Text(
              'Commands',
              style: TextStyle(
                color: Colors.brightMagenta,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
    rows.add(Divider(color: Color.fromRGB(80, 60, 120), height: 1));

    // Command rows
    for (int i = 0; i < visibleCommands.length; i++) {
      final cmd = visibleCommands[i];
      final actualIndex = scrollOffset + i;
      final isSelected = actualIndex == selectedIndex;

      rows.add(
          MouseRegion(
            onEnter: (_) => onHover?.call(actualIndex),
            opaque: false,
            child: GestureDetector(
              onTap: () => onTap?.call(actualIndex),
              behavior: HitTestBehavior.opaque,
              child: _buildCommandRow(cmd, isSelected),
            ),
          ),
        );
      }

      rows.add(Divider(color: Color.fromRGB(80, 60, 120), height: 1));

      return Container(
        decoration: BoxDecoration(
          color: Color.fromRGB(20, 15, 40),
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Component _buildCommandRow(SlashCommand cmd, bool isSelected) {
    return Container(
      decoration: isSelected
          ? BoxDecoration(color: Color.fromRGB(40, 30, 80))
          : null,
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Text(
            isSelected ? '> ' : '  ',
            style: TextStyle(
              color: isSelected ? Colors.brightYellow : Colors.gray,
            ),
          ),
          Text(
            cmd.displayName,
            style: TextStyle(
              color: isSelected ? Colors.brightCyan : Colors.white,
              fontWeight: isSelected ? FontWeight.bold : null,
            ),
          ),
          SizedBox(width: 1),
          Expanded(
            child: Text(
              cmd.description,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.gray,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Overlay panel showing parameter autocomplete suggestions.
/// Appears inline above the input row when the user types a param value
/// after selecting a command that has suggestions.
class _SuggestionOverlay extends StatelessComponent {
  final List<CommandSuggestion> suggestions;
  final int selectedIndex;
  final int scrollOffset;
  final int maxVisible;
  final String headerLabel;
  final void Function(int)? onHover;
  final void Function(int)? onTap;

  const _SuggestionOverlay({
    required this.suggestions,
    required this.selectedIndex,
    required this.scrollOffset,
    required this.maxVisible,
    required this.headerLabel,
    this.onHover,
    this.onTap,
  });

  @override
  Component build(BuildContext context) {
    final visibleSuggestions =
        suggestions.skip(scrollOffset).take(maxVisible).toList();

    final rows = <Component>[];

    // Header row with param label
    rows.add(
      Container(
        padding: EdgeInsets.symmetric(horizontal: 1),
        child: Row(
          children: [
            Text(
              headerLabel,
              style: TextStyle(
                color: Colors.brightMagenta,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
    rows.add(Divider(color: Color.fromRGB(80, 60, 120), height: 1));

    // Suggestion rows
    for (int i = 0; i < visibleSuggestions.length; i++) {
      final suggestion = visibleSuggestions[i];
      final actualIndex = scrollOffset + i;
      final isSelected = actualIndex == selectedIndex;

      rows.add(
          MouseRegion(
            onEnter: (_) => onHover?.call(actualIndex),
            opaque: false,
            child: GestureDetector(
              onTap: () => onTap?.call(actualIndex),
              behavior: HitTestBehavior.opaque,
              child: _buildSuggestionRow(suggestion, isSelected),
            ),
          ),
        );
      }

      rows.insert(0, Divider(color: Color.fromRGB(80, 60, 120), height: 1));
      rows.add(Divider(color: Color.fromRGB(80, 60, 120), height: 1));

      return Container(
        decoration: BoxDecoration(
          color: Color.fromRGB(20, 15, 40),
        ),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Component _buildSuggestionRow(CommandSuggestion suggestion, bool isSelected) {
    return Container(
      decoration: isSelected
          ? BoxDecoration(color: Color.fromRGB(40, 30, 80))
          : null,
      padding: EdgeInsets.symmetric(horizontal: 1),
      child: Row(
        children: [
          Text(
            isSelected ? '> ' : '  ',
            style: TextStyle(
              color: isSelected ? Colors.brightYellow : Colors.gray,
            ),
          ),
          Text(
            suggestion.value,
            style: TextStyle(
              color: isSelected ? Colors.brightCyan : Colors.white,
              fontWeight: isSelected ? FontWeight.bold : null,
            ),
          ),
          SizedBox(width: 1),
          Expanded(
            child: Text(
              suggestion.description ?? '',
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.gray,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExtraInfoPanel extends StatelessComponent {
  final List<Message> messages;

  const _ExtraInfoPanel({required this.messages});

  @override
  Component build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Info',
            style: TextStyle(
              color: Colors.brightMagenta,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 1),
          _buildInfoRow('Messages', '${messages.length}'),
          _buildInfoRow('Model', 'crux-v1'),
          _buildInfoRow('Status', 'ready'),
        ],
      ),
    );
  }

  Component _buildInfoRow(String label, String value) {
    return Row(
      children: [
        Text(
          '$label ',
          style: TextStyle(color: Colors.gray),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessComponent {
  final Message message;

  const _MessageBubble({required this.message});

  @override
  Component build(BuildContext context) {
    final isUser = message.role == 'user';

    return Column(
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isUser ? ' You: ' : ' Crux: ',
                style: TextStyle(
                  color: isUser ? Colors.brightCyan : Colors.brightMagenta,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Expanded(
                child: Text(
                  message.content,
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        Divider(color: Color.fromRGB(40, 40, 60), height: 1),
      ],
    );
  }
}

/// Animated model button with flowing gradient gloss effect.
/// When animating, a bright band sweeps across the label background
/// from left to right continuously, creating a "gloss" effect.
/// When not animating, renders like a regular Button with hover support.
class _GlossyModelButton extends StatefulComponent {
  final String label;
  final bool isAnimating;
  final VoidCallback? onPressed;

  const _GlossyModelButton({
    required this.label,
    required this.isAnimating,
    this.onPressed,
  });

  @override
  State<_GlossyModelButton> createState() => _GlossyModelButtonState();
}

class _GlossyModelButtonState extends State<_GlossyModelButton> {
  Timer? _animTimer;
  double _phase = -_bandWidth;
  int _tickCount = 0;
  bool _hovered = false;
  bool _isFadingOut = false;
  double _fadeIntensity = 1.0;

  static const double _bandWidth = 8.0;
  static const int _fadeTicks = 20; // ~1.2s at 60ms per tick

  static const Color _baseBg = Color.fromRGB(25, 20, 45);
  static const Color _peakBg = Color.fromRGB(120, 80, 200);
  static const Color _baseFg = Color.fromRGB(120, 100, 160);
  static const Color _flashFg = Color.fromRGB(255, 255, 255);

  @override
  void initState() {
    super.initState();
    if (component.isAnimating) {
      _startAnimation();
    }
  }

  @override
  void didUpdateComponent(_GlossyModelButton old) {
    super.didUpdateComponent(old);
    if (component.isAnimating && !old.isAnimating) {
      _isFadingOut = false;
      _fadeIntensity = 1.0;
      _startAnimation();
    } else if (!component.isAnimating && old.isAnimating) {
      // Start fade-out instead of immediately stopping
      _isFadingOut = true;
      _fadeIntensity = 1.0;
      // Animation timer keeps running during fade
      if (_animTimer == null) {
        _startAnimation();
      }
    }
  }

  @override
  void dispose() {
    _animTimer?.cancel();
    _animTimer = null;
    super.dispose();
  }

  void _startAnimation() {
    _phase = -_bandWidth;
    _tickCount = 0;
    _animTimer?.cancel();
    _animTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      _phase += 1.5; // faster sweep
      final sweepEnd = component.label.length + _bandWidth;
      if (_phase > sweepEnd) {
        _phase = -_bandWidth;
      }
      _tickCount++;

      if (_isFadingOut) {
        _fadeIntensity -= 1.0 / _fadeTicks;
        if (_fadeIntensity <= 0) {
          _fadeIntensity = 0;
          _isFadingOut = false;
          _stopAnimation();
          setState(() {});
          return;
        }
      }

      setState(() {});
    });
  }

  void _stopAnimation() {
    _animTimer?.cancel();
    _animTimer = null;
  }

  @override
  Component build(BuildContext context) {
    final btn = component;

    if (!btn.isAnimating && !_isFadingOut) {
      // Static mode with hover support
      final bgColor = _hovered ? Color.fromRGB(40, 30, 80) : _baseBg;
      final fg = _hovered ? Colors.brightCyan : _baseFg;

      return MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        opaque: false,
        child: GestureDetector(
          onTap: btn.onPressed,
          behavior: HitTestBehavior.opaque,
          child: Container(
            color: bgColor,
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Text(
              btn.label,
              style: TextStyle(
                color: fg,
                fontWeight: _hovered ? FontWeight.bold : null,
              ),
            ),
          ),
        ),
      );
    }

    // Animated/fading mode: flowing gradient sweep + periodic text flash
    // Pulse: brief periodic flash using sin² — peaks every 0.33s (2π/5.5ticks ≈ 1.142)
    final pulseValue = pow(max(0.0, sin(_tickCount * 1.142)), 2.0).toDouble();

    final chars = <Component>[];
    for (int i = 0; i < btn.label.length; i++) {
      final distance = (i - _phase).abs();
      double sweepEase;
      if (distance < _bandWidth) {
        final t = 1.0 - distance / _bandWidth;
        sweepEase = t * t * (3 - 2 * t); // smoothstep
      } else {
        sweepEase = 0.0;
      }

      // Background: only sweep (localized flowing gradient)
      // Foreground: sweep + periodic pulse flash on top
      final bgBrightness = sweepEase * _fadeIntensity;
      final fgBrightness = max(sweepEase, pulseValue) * _fadeIntensity;

      final bg = Color.lerp(_baseBg, _peakBg, bgBrightness)!;
      final fg = Color.lerp(_baseFg, _flashFg, fgBrightness)!;

      chars.add(
        Text(
          btn.label[i],
          style: TextStyle(
            color: fg,
            backgroundColor: bg,
            fontWeight: fgBrightness > 0.3 ? FontWeight.bold : null,
          ),
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      opaque: false,
      child: GestureDetector(
        onTap: btn.onPressed,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: _baseBg,
          padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
          child: Row(children: chars),
        ),
      ),
    );
  }
}
