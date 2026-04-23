import 'package:nocterm/nocterm.dart';
import '../models/message.dart';
import '../models/slash_command.dart';
import '../commands/registry.dart';

class ChatPanel extends StatefulComponent {
  const ChatPanel({super.key});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final List<Message> messages = [];
  final AutoScrollController scrollController = AutoScrollController();
  final TextEditingController textController = TextEditingController();

  // Command overlay state
  bool _commandOverlayVisible = false;
  int _selectedCommandIndex = 0;
  int _commandScrollOffset = 0;
  List<SlashCommand> _filteredCommands = [];

  static const int _infoPanelMinWidth = 100;
  static const double _infoPanelWidth = 28;
  static const int _maxVisibleCommands = 6;

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
    scrollController.dispose();
    textController.dispose();
    super.dispose();
  }

  /// Listen to text changes to detect slash command input.
  /// Shows the overlay when `/` is the first non-space character,
  /// and the command portion has no space (still typing the command name).
  void _onTextChanged() {
    final text = textController.text;
    final trimmedLeading = text.replaceFirst(RegExp(r'^\s+'), '');

    if (trimmedLeading.startsWith('/') &&
        !trimmedLeading.substring(1).contains(' ')) {
      final prefix = trimmedLeading;
      _filteredCommands = filterCommands(prefix);
      _commandOverlayVisible = _filteredCommands.isNotEmpty;
      // Reset selection and scroll when the filter changes
      _selectedCommandIndex = 0;
      _commandScrollOffset = 0;
    } else {
      _commandOverlayVisible = false;
      _filteredCommands = [];
      _selectedCommandIndex = 0;
      _commandScrollOffset = 0;
    }
    setState(() {});
  }

  /// Adjust scroll offset so the selected command is always visible.
  void _ensureSelectedVisible() {
    if (_selectedCommandIndex < _commandScrollOffset) {
      _commandScrollOffset = _selectedCommandIndex;
    } else if (_selectedCommandIndex >= _commandScrollOffset + _maxVisibleCommands) {
      _commandScrollOffset = _selectedCommandIndex - _maxVisibleCommands + 1;
    }
  }

  /// Intercept key events when the command overlay is visible.
  /// Handles arrow navigation, Enter to select, and Escape to dismiss.
  bool _handleInputKeyEvent(KeyboardEvent event) {
    if (!_commandOverlayVisible || _filteredCommands.isEmpty) return false;

    if (event.logicalKey == LogicalKey.arrowUp) {
      setState(() {
        if (_selectedCommandIndex > 0) {
          _selectedCommandIndex--;
        } else {
          _selectedCommandIndex = _filteredCommands.length - 1;
        }
        _ensureSelectedVisible();
      });
      return true;
    }

    if (event.logicalKey == LogicalKey.arrowDown) {
      setState(() {
        if (_selectedCommandIndex < _filteredCommands.length - 1) {
          _selectedCommandIndex++;
        } else {
          _selectedCommandIndex = 0;
        }
        _ensureSelectedVisible();
      });
      return true;
    }

    if (event.logicalKey == LogicalKey.enter) {
      final selected = _filteredCommands[_selectedCommandIndex];
      textController.text = selected.name + ' ';
      textController.selection =
          TextSelection.collapsed(offset: textController.text.length);
      // _onTextChanged fires and hides overlay since text now has a space
      return true;
    }

    if (event.logicalKey == LogicalKey.escape) {
      textController.clear();
      _commandOverlayVisible = false;
      _filteredCommands = [];
      _selectedCommandIndex = 0;
      _commandScrollOffset = 0;
      setState(() {});
      return true;
    }

    // Let character input, backspace, etc. pass through to TextField
    return false;
  }

  void _sendMessage() {
    final text = textController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      messages.add(Message(role: 'user', content: text));
    });
    textController.clear();
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

    if (_commandOverlayVisible && _filteredCommands.isNotEmpty) {
      children.add(
        _CommandOverlay(
          commands: _filteredCommands,
          selectedIndex: _selectedCommandIndex,
          scrollOffset: _commandScrollOffset,
          maxVisible: _maxVisibleCommands,
        ),
      );
    }

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

  Component _buildInputRow() {
    return Container(
      padding: EdgeInsets.all(1),
      decoration: BoxDecoration(
        border: BoxBorder(
          top: BorderSide(color: Color.fromRGB(50, 50, 70)),
        ),
      ),
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

  const _CommandOverlay({
    required this.commands,
    required this.selectedIndex,
    required this.scrollOffset,
    required this.maxVisible,
  });

  @override
  Component build(BuildContext context) {
    final visibleCommands =
        commands.skip(scrollOffset).take(maxVisible).toList();

    final rows = <Component>[];

    // Header row
    rows.add(
      Container(
        decoration: BoxDecoration(
          border: BoxBorder(
            bottom: BorderSide(color: Color.fromRGB(80, 60, 120)),
          ),
        ),
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

    // Command rows
    for (int i = 0; i < visibleCommands.length; i++) {
      final cmd = visibleCommands[i];
      final actualIndex = scrollOffset + i;
      final isSelected = actualIndex == selectedIndex;

      rows.add(_buildCommandRow(cmd, isSelected));
    }

    return Container(
      decoration: BoxDecoration(
        color: Color.fromRGB(20, 15, 40),
        border: BoxBorder(
          top: BorderSide(color: Color.fromRGB(80, 60, 120)),
          bottom: BorderSide(color: Color.fromRGB(80, 60, 120)),
        ),
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

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
      decoration: BoxDecoration(
        border: BoxBorder(
          bottom: BorderSide(color: Color.fromRGB(40, 40, 60)),
        ),
      ),
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
    );
  }
}
