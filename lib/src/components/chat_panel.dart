import 'dart:async';
import 'dart:math';
import 'package:nocterm/nocterm.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../models/slash_command.dart';
import '../commands/registry.dart';
import 'ui/button.dart';
import 'ui/toast.dart';
import 'ui/bg_progress_bar.dart';
import 'ui/glossy_model_button.dart';
import 'command_overlay.dart';
import 'suggestion_overlay.dart';
import 'extra_info_panel.dart';
import 'message_bubble.dart';

enum _OverlayMode { off, command, parameter }

class ChatPanel extends StatefulComponent {
  const ChatPanel({super.key});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  // Session management
  final List<Session> _sessions = [];
  int _currentSessionId = 1;
  int _nextSessionId = 1;

  final AutoScrollController scrollController = AutoScrollController();
  final TextEditingController textController = TextEditingController();



  // Auxiliary local model
  static const String _localModel = 'local/llama3';
  static const String _localModelShortName = 'llama3';

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

  // (Per-session response state now lives on the Session model)

  // Context window progress animation (global, operates on current session)
  static const int _contextMaxTokens = 262144;
  Timer? _contextAnimTimer;
  DateTime? _lastContextTick;
  static const double _contextLerpSpeed = 6.0;
  bool _contextBarHovered = false;

  static const Set<String> _imageModels = {
    'openai/gpt-4o',
    'openai/gpt-4',
    'anthropic/claude-3.5',
    'anthropic/claude-3',
    'google/gemini-pro',
    'google/gemini-flash',
  };

  static const List<String> _mockAiResponses = [
    "I've analyzed your request. Here's my approach...",
    "That's an interesting question. Let me break it down for you.",
    "I can help with that. Let me outline a solution.",
    "Good thinking! Here's what I'd suggest...",
    "Let me consider the options and recommend the best path forward.",
  ];

  static const List<String> _mockSessionTitles = [
    'Build a TUI chat app',
    'Debug rendering pipeline',
    'Add markdown support',
    'Refactor command registry',
    'Implement session switching',
  ];

  static const int _infoPanelMinWidth = 100;
  static const double _infoPanelWidth = 28;
  static const int _maxVisibleItems = 6;

  @override
  void initState() {
    super.initState();
    textController.addListener(_onTextChanged);
    _createMockSessions();
  }

  void _createMockSessions() {
    final now = DateTime.now();

    // Session 1 — idle, already completed conversation (most recent activity)
    final s1 = Session(
      id: 1,
      title: _mockSessionTitles[0],
      model: 'openai/gpt-4o',
      status: SessionStatus.idle,
      lastActivityAt: now.subtract(Duration(minutes: 2)),
      messages: [
        Message(role: 'ai', content: "Hello! I'm Crux, your coding assistant. What would you like to work on today?"),
        Message(role: 'user', content: 'Can you help me build a TUI application with a chat interface?'),
        Message(role: 'ai', content: 'Absolutely! I can help you build a TUI chat application using Nocterm. What specific features are you looking for?'),
      ],
    );
    _sessions.add(s1);

    // Session 3 — needUserAction (second most recent — needs user input)
    final s3 = Session(
      id: 3,
      title: _mockSessionTitles[2],
      model: 'google/gemini-pro',
      status: SessionStatus.needUserAction,
      lastActivityAt: now.subtract(Duration(minutes: 5)),
      messages: [
        Message(role: 'user', content: 'Add markdown support to the chat bubbles.'),
        Message(role: 'ai', content: "I can add markdown rendering. Should I use a lightweight inline parser or a full CommonMark implementation?"),
      ],
    );
    _sessions.add(s3);

    // Session 2 — done (response complete but unread)
    final s2 = Session(
      id: 2,
      title: _mockSessionTitles[1],
      model: 'anthropic/claude-3.5',
      status: SessionStatus.done,
      lastActivityAt: now.subtract(Duration(minutes: 15)),
      messages: [
        Message(role: 'user', content: 'The rendering pipeline has a flickering issue on resize.'),
        Message(role: 'ai', content: "I've identified the issue — the diff renderer isn't flushing stale cells on layout changes. Let me patch it."),
      ],
    );
    _sessions.add(s2);

    // Session 4 — idle (least recently active)
    final s4 = Session(
      id: 4,
      title: _mockSessionTitles[3],
      model: 'local/llama3',
      status: SessionStatus.idle,
      lastActivityAt: now.subtract(Duration(hours: 1)),
      messages: [
        Message(role: 'user', content: 'Refactor the command registry to support dynamic suggestions.'),
      ],
    );
    _sessions.add(s4);

    _nextSessionId = 5;
    _currentSessionId = 1;
  }

  @override
  void dispose() {
    textController.removeListener(_onTextChanged);
    for (final session in _sessions) {
      session.responseTimer?.cancel();
      session.metricsTimer?.cancel();
    }
    _contextAnimTimer?.cancel();
    scrollController.dispose();
    textController.dispose();
    super.dispose();
  }

  /// The currently active session.
  Session get _currentSession =>
      _sessions.firstWhere((s) => s.id == _currentSessionId);

  /// Find a session by its id, or null if not found.
  Session? _findSession(int id) {
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Switch to a different session by id.
  void _switchSession(int id) {
    final session = _findSession(id);
    if (session == null) {
      setState(() {
        _toastVisible = true;
        _toastMessage = 'Session #$id not found';
      });
      return;
    }

    // Mark "done" session as "idle" when user views it
    if (session.status == SessionStatus.done) {
      session.status = SessionStatus.idle;
    }

    _currentSessionId = id;
    setState(() {});
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

    // Dynamic suggestions for /session command: list all existing sessions
    final List<CommandSuggestion> suggestions;
    if (commandName == '/session' && paramIndex == 0) {
      suggestions = _sessions
          .map((s) => CommandSuggestion(
                value: s.displayId,
                description: s.title,
              ))
          .toList();
    } else {
      suggestions = command.suggestionsPerParam[paramIndex];
    }
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

    final session = _currentSession;

    // Initialize per-session mock metrics
    session.responseStartTime = DateTime.now();
    session.mockTtftTargetMs = (Random().nextInt(2800) + 200).toDouble(); // 200–3000ms
    session.mockTokRate = Random().nextInt(40) + 30.0; // 30–70 tok/s
    session.tokPerSec = 0.0;
    session.ttftMs = 0.0;
    session.tokCount = 0.0;

    setState(() {
      session.messages.add(Message(role: 'user', content: text));
      session.isResponding = true;
      session.status = SessionStatus.running;
      session.lastActivityAt = DateTime.now();
      session.contextTargetTokens += Random().nextInt(12000) + 3000;
      _startContextAnimation();
    });

    // Start per-session metrics timer to simulate tok/s ramping
    session.metricsTimer?.cancel();
    session.metricsTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _updateMetrics(session);
    });

    // Mock AI response after random 10-30 seconds (cranked up for multi-session testing)
    session.responseTimer?.cancel();
    final delaySeconds = Random().nextInt(21) + 10;
    session.responseTimer = Timer(Duration(seconds: delaySeconds), () {
      session.metricsTimer?.cancel();
      setState(() {
        session.isResponding = false;
        session.tokPerSec = session.mockTokRate;
        session.messages.add(Message(
          role: 'ai',
          content: _mockAiResponses[session.mockResponseIndex % _mockAiResponses.length],
        ));
        session.mockResponseIndex++;
        session.status = SessionStatus.done;
        session.lastActivityAt = DateTime.now();
        session.contextTargetTokens += Random().nextInt(12000) + 3000;
        _startContextAnimation();
      });
    });
  }

  void _updateMetrics(Session session) {
    if (session.responseStartTime == null) return;
    final elapsed = DateTime.now().difference(session.responseStartTime!).inMicroseconds / 1000.0;

    if (elapsed < session.mockTtftTargetMs) {
      // TTFT phase: live counter ticking up at 60fps
      session.ttftMs = elapsed;
      setState(() {});
      return;
    }

    // First token arrived: freeze TTFT at target value
    session.ttftMs = session.mockTtftTargetMs;

    // Simulate token generation at mock rate (~16ms interval)
    final elapsedAfterTtft = elapsed - session.ttftMs;
    session.tokCount += session.mockTokRate * 0.016;

    // Compute live tok/s from actual elapsed time after TTFT
    final elapsedSec = elapsedAfterTtft / 1000.0;
    if (elapsedSec > 0) {
      session.tokPerSec = session.tokCount / elapsedSec;
    }

    setState(() {});
  }

  String _formatTtft(double ms) {
    if (ms >= 1000) {
      final sec = ms / 1000.0;
      return '${sec.toStringAsFixed(2)}s';
    }
    return '${ms.round()}ms';
  }

  void _executeCommand(String text) {
    final parts = text.split(' ');
    final commandName = parts[0];
    final command = findCommand(commandName);

    if (commandName == '/model') {
      if (parts.length > 1 && parts[1].isNotEmpty) {
        setState(() {
          _currentSession.model = parts[1];
          _toastVisible = true;
          _toastMessage = 'Model switched to ${parts[1]}';
        });
      } else {
        setState(() {
          _toastVisible = true;
          _toastMessage = 'Usage: /model <name>';
        });
      }
    } else if (commandName == '/session') {
      if (parts.length > 1 && parts[1].isNotEmpty) {
        final idStr = parts[1].replaceFirst('#', '');
        final id = int.tryParse(idStr);
        if (id != null) {
          _switchSession(id);
        } else {
          setState(() {
            _toastVisible = true;
            _toastMessage = 'Usage: /session #<id>';
          });
        }
      } else {
        setState(() {
          _toastVisible = true;
          _toastMessage = 'Usage: /session #<id>';
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

  void _startContextAnimation() {
    if (_contextAnimTimer != null) return; // already running
    _lastContextTick = DateTime.now();
    _contextAnimTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = DateTime.now();
      final deltaTime = now.difference(_lastContextTick!).inMilliseconds / 1000.0;
      _lastContextTick = now;

      final session = _currentSession;
      final diff = session.contextTargetTokens - session.contextDisplayTokens;
      if (diff.abs() < 0.5) {
        session.contextDisplayTokens = session.contextTargetTokens.toDouble();
        _stopContextAnimation();
        setState(() {});
        return;
      }

      session.contextDisplayTokens += diff * (deltaTime * _contextLerpSpeed);
      setState(() {});
    });
  }

  void _stopContextAnimation() {
    _contextAnimTimer?.cancel();
    _contextAnimTimer = null;
    _lastContextTick = null;
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
                  child: ExtraInfoPanel(sessions: _sessions, currentSessionId: _currentSessionId, onSwitchSession: _switchSession),
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
          child: CommandOverlay(
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
          child: SuggestionOverlay(
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
    if (_currentSession.messages.isEmpty) {
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
        itemCount: _currentSession.messages.length,
        itemBuilder: (context, index) {
          return MessageBubble(message: _currentSession.messages[index]);
        },
      ),
    );
  }

  Component _buildToolbar() {
    final session = _currentSession;
    final modelButton = session.isResponding
        ? GlossyModelButton(
            label: _currentSession.model,
            isAnimating: true,
            onPressed: _onModelButtonPressed,
          )
        : Button(
            label: _currentSession.model,
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
          if (_imageModels.contains(_currentSession.model))
            Text('\u{F06E}', style: TextStyle(color: Color.fromRGB(120, 100, 160))),
          Text('  ', style: TextStyle(color: Color.fromRGB(50, 50, 70))),
          _buildContextBar(),
          Text('  ', style: TextStyle(color: Color.fromRGB(50, 50, 70))),
          Text(
            session.isResponding
                ? '${session.tokPerSec.toStringAsFixed(1)} tok/s'
                : session.tokPerSec > 0
                    ? '${session.tokPerSec.toStringAsFixed(1)} tok/s'
                    : '— tok/s',
            style: TextStyle(
              color: session.isResponding
                  ? Color.fromRGB(180, 220, 255)
                  : Color.fromRGB(80, 80, 100),
            ),
          ),
          Text(' ', style: TextStyle(color: Color.fromRGB(50, 50, 70))),
          Text(
            session.isResponding
                ? _formatTtft(session.ttftMs)
                : session.ttftMs > 0
                    ? _formatTtft(session.ttftMs)
                    : '—',
            style: TextStyle(
              color: session.isResponding
                  ? Color.fromRGB(180, 220, 255)
                  : Color.fromRGB(80, 80, 100),
            ),
          ),
          Expanded(child: SizedBox()),
          _buildLocalModelButton(),
        ],
      ),
    );
  }

  Component _buildLocalModelButton() {
    return Button(
      label: '\u{F233} $_localModelShortName',
      onPressed: _onLocalModelButtonPressed,
      color: Color.fromRGB(120, 100, 160),
      hoverColor: Colors.brightCyan,
      bgColor: Color.fromRGB(25, 20, 45),
      hoverBgColor: Color.fromRGB(40, 30, 80),
      padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
    );
  }

  void _onLocalModelButtonPressed() {
    setState(() {
      _currentSession.model = _localModel;
      _toastVisible = true;
      _toastMessage = 'Model switched to $_localModel';
    });
  }

  Component _buildContextBar() {
    final session = _currentSession;
    final fillRatio = (session.contextDisplayTokens / _contextMaxTokens).clamp(0.0, 1.0);
    final displayInt = session.contextDisplayTokens.round();
    final labelText = _contextBarHovered ? 'Compact' : '$displayInt / $_contextMaxTokens';

    final bar = BgProgressBar(
      value: fillRatio,
      width: 20,
      label: labelText,
      fillColor: _contextBarHovered
          ? Color.fromRGB(100, 180, 255)
          : Color.fromRGB(120, 80, 200),
      emptyColor: Color.fromRGB(30, 25, 50),
      labelFillFg: _contextBarHovered
          ? Color.fromRGB(20, 15, 40)
          : Color.fromRGB(25, 20, 45),
      labelEmptyFg: _contextBarHovered
          ? Color.fromRGB(220, 240, 255)
          : Color.fromRGB(200, 180, 255),
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _contextBarHovered = true),
      onExit: (_) => setState(() => _contextBarHovered = false),
      opaque: false,
      child: GestureDetector(
        onTap: _onCompactButtonPressed,
        behavior: HitTestBehavior.opaque,
        child: bar,
      ),
    );
  }

  void _onCompactButtonPressed() {
    final newText = '/compact ';
    textController.text = newText;
    textController.selection =
        TextSelection.collapsed(offset: newText.length);
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
