import 'dart:async';
import 'dart:io';
import 'package:nocterm/nocterm.dart';
import '../models/message.dart';
import '../models/session.dart';
import '../models/session_runtime_state.dart';
import '../models/slash_command.dart';
import '../commands/registry.dart';
import '../services/chat_service.dart';
import '../services/llm_client.dart';
import '../services/provider_service.dart';
import '../storage/database.dart' hide Session, Message, Part;
import '../storage/session_lock.dart';
import '../storage/session_store.dart';
import 'ui/button.dart';
import 'ui/toast.dart';
import 'ui/bg_progress_bar.dart';
import 'ui/glossy_model_button.dart';
import 'provider_wizard_builtin.dart';
import 'provider_wizard_custom.dart';
import 'command_overlay.dart';
import 'suggestion_overlay.dart';
import 'extra_info_panel.dart';
import 'message_bubble.dart';

enum _OverlayMode { off, command, parameter, wizard }

enum _ProviderWizardSubcommand { builtin, custom }

class ChatPanel extends StatefulComponent {
  final String providersDir;
  const ChatPanel({super.key, required this.providersDir});

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  late final SessionStore _store;
  late final SessionLock _lock;
  late final ChatService _chatService;

  List<Session> _sessions = [];
  int? _currentSessionId;
  final Map<int, SessionRuntimeState> _runtimeStates = {};
  final Map<int, List<Message>> _messageCache = {};
  String _streamingContent = '';
  String _streamingReasoning = '';
  bool _thinkingCollapsed = false;

  String get _projectPath => Directory.current.path;

  final AutoScrollController scrollController = AutoScrollController();
  final TextEditingController textController = TextEditingController();

  String _localModel = 'local/llama3';
  String _localModelShortName = 'llama3';

  _OverlayMode _overlayMode = _OverlayMode.off;

  List<SlashCommand> _filteredCommands = [];
  int _selectedCommandIndex = 0;
  int _commandScrollOffset = 0;

  SlashCommand? _activeCommand;
  int _currentParamIndex = 0;
  List<CommandSuggestion> _filteredSuggestions = [];
  int _selectedSuggestionIndex = 0;
  int _suggestionScrollOffset = 0;

  bool _toastVisible = false;
  String _toastMessage = '';

  late final ProviderService _providerService;
  bool _providerServiceReady = false;
  _ProviderWizardSubcommand? _activeWizardSubcommand;
  String? _builtinProviderName;

  int get _contextMaxTokens {
    if (!_providerServiceReady) return 131072;
    final model = _providerService.modelByCompositeKey(_currentSession.model);
    return model?.contextSize ?? 131072;
  }

  Timer? _contextAnimTimer;
  DateTime? _lastContextTick;
  static const double _contextLerpSpeed = 6.0;
  bool _contextBarHovered = false;

  bool _modelSupportsImages(String compositeKey) {
    if (!_providerServiceReady) return false;
    return _providerService.imageModelKeys().contains(compositeKey);
  }

  bool _modelSupportsThinking(String compositeKey) {
    if (!_providerServiceReady) return false;
    final mc = _providerService.modelByCompositeKey(compositeKey);
    return mc?.thinking == true || mc?.reasoningEffort != null;
  }

  static const int _infoPanelMinWidth = 100;
  static const double _infoPanelWidth = 28;
  static const int _maxVisibleItems = 6;

  SessionRuntimeState _runtime(int sessionId) {
    return _runtimeStates.putIfAbsent(
      sessionId,
      () {
        final initial = _computeBaseContext(sessionId);
        final session = _findSession(sessionId);
        return SessionRuntimeState(
          sessionId: sessionId,
          contextTargetTokens: initial,
          contextDisplayTokens: initial.toDouble(),
          thinkingMode: session?.thinkingMode ?? 'enabled',
          reasoningEffort: session?.reasoningEffort,
        );
      },
    );
  }

  Session get _currentSession {
    if (_currentSessionId == null) {
      return Session(id: 0, title: 'New Session');
    }
    return _sessions.firstWhere(
      (s) => s.id == _currentSessionId,
      orElse: () => Session(id: 0, title: 'New Session'),
    );
  }

  List<Message> get _currentMessages =>
      _messageCache[_currentSessionId] ?? [];

  @override
  void initState() {
    super.initState();
    _providerService = ProviderService(providersDir: component.providersDir);
    _lock = SessionLock();
    final db = CruxDatabase();
    _store = SessionStore(db, _lock);
    _chatService = ChatService(_store, _providerService, LlmClient());
    textController.addListener(_onTextChanged);
    _initSessions();
    _providerService.initialize().then((_) {
      setState(() {
        _providerServiceReady = true;
        _resolveLocalModel();
      });
    });
  }

  void _resolveLocalModel() {
    final localProvider = _providerService.providerByName('local');
    if (localProvider != null && localProvider.models.isNotEmpty) {
      final firstModel = localProvider.models.first;
      _localModel = firstModel.compositeKey(localProvider.name);
      _localModelShortName = firstModel.name;
    }
  }

  Future<void> _initSessions() async {
    _sessions = await _store.list(projectPath: _projectPath);
    if (_sessions.isEmpty) {
      await _providerService.initialize();
      _providerServiceReady = true;
      final model = _providerService.resolveDefaultModel() ?? '';
      final session = await _store.create(title: 'New Session', model: model, projectPath: _projectPath);
      _sessions = [session];
      _resolveLocalModel();
    }
    _currentSessionId = _sessions.first.id;
    await _loadMessages(_currentSessionId!);
    setState(() {});
  }

  Future<void> _loadMessages(int sessionId) async {
    _messageCache[sessionId] = await _store.getMessages(sessionId);
  }

  @override
  void dispose() {
    textController.removeListener(_onTextChanged);
    _chatService.dispose();
    for (final rt in _runtimeStates.values) {
      rt.cancelTimers();
    }
    for (final timer in _metricsTimers.values) {
      timer.cancel();
    }
    _metricsTimers.clear();
    _contextAnimTimer?.cancel();
    scrollController.dispose();
    textController.dispose();
    super.dispose();
  }

  Session? _findSession(int id) {
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> _switchSession(int id) async {
    final session = _findSession(id);
    if (session == null) {
      setState(() {
        _toastVisible = true;
        _toastMessage = 'Session #$id not found';
      });
      return;
    }

    if (session.status == SessionStatus.done) {
      await _store.update(id, status: SessionStatus.idle);
      session.status = SessionStatus.idle;
    }

    _currentSessionId = id;
    await _loadMessages(id);
    final rt = _runtime(id);
    final base = _computeBaseContext(id);
    rt.contextTargetTokens = base;
    rt.contextDisplayTokens = base.toDouble();
    rt.ttftMs = 0;
    rt.ttftReceived = false;
    rt.tokPerSec = 0;
    rt.isResponding = false;
    _stopContextAnimation();
    scrollController.scrollToBottom();
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
    _activeWizardSubcommand = null;
  }

  void _onTextChanged() {
    if (_overlayMode == _OverlayMode.wizard) return;

    final text = textController.text;
    final trimmed = text.replaceFirst(RegExp(r'^\s+'), '');

    if (!trimmed.startsWith('/')) {
      _setOverlayOff();
      setState(() {});
      return;
    }

    final spaceIndex = trimmed.indexOf(' ');

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

    final commandName = trimmed.substring(0, spaceIndex);
    final command = findCommand(commandName);

    if (command == null ||
        (!command.hasSuggestionsForParam(0) &&
            commandName != '/model')) {
      _setOverlayOff();
      setState(() {});
      return;
    }

    final afterCommand = trimmed.substring(spaceIndex + 1);
    int paramIndex;
    String currentInput;

    if (afterCommand.isEmpty) {
      paramIndex = 0;
      currentInput = '';
    } else if (afterCommand.endsWith(' ')) {
      final completedParts = afterCommand
          .trimRight()
          .split(' ')
          .where((s) => s.isNotEmpty)
          .toList();
      paramIndex = completedParts.length;
      currentInput = '';
    } else {
      final parts = afterCommand.split(' ');
      currentInput = parts.last;
      paramIndex = parts.length - 1;
    }

    if (!command.hasSuggestionsForParam(paramIndex) &&
        !(commandName == '/model' && paramIndex == 0)) {
      _setOverlayOff();
      setState(() {});
      return;
    }

    final List<CommandSuggestion> suggestions;
    if (commandName == '/session' && paramIndex == 0) {
      suggestions = _sessions
          .map(
            (s) => CommandSuggestion(value: s.displayId, description: s.title),
          )
          .toList();
    } else if (commandName == '/model' && paramIndex == 0) {
      if (_providerServiceReady) {
        suggestions = _providerService.allModelEntries()
            .where((e) => _providerService.getApiKey(e.providerName) != null)
            .map((e) {
          final ctx = e.model.contextSize >= 1000000
              ? '${(e.model.contextSize / 1048576).toStringAsFixed(0)}M'
              : '${(e.model.contextSize / 1000).toStringAsFixed(0)}K';
          final img = e.model.imageSupport ? ', img' : '';
          final think = e.model.thinking ? ', think' : '';
          return CommandSuggestion(
            value: e.compositeKey,
            description: '${e.model.name} (${ctx} ctx$img$think)',
          );
        }).toList();
      } else {
        suggestions = [];
      }
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

  int _computeScrollOffset(
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

  bool _handleInputKeyEvent(KeyboardEvent event) {
    if (_overlayMode == _OverlayMode.off) return false;

    if (_overlayMode == _OverlayMode.wizard) {
      return true;
    }

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
        if (selected.params.isEmpty) {
          _setOverlayOff();
          textController.clear();
          _executeCommand(selected.name);
        } else {
          textController.text = selected.name + ' ';
          textController.selection = TextSelection.collapsed(
            offset: textController.text.length,
          );
        }
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
        final trimmed = textController.text.replaceFirst(RegExp(r'^\s+'), '');
        final commandAndSpace = _activeCommand!.name + ' ';
        final restOfText = trimmed.substring(_activeCommand!.name.length + 1);

        String prefix;
        if (restOfText.isEmpty || restOfText.endsWith(' ')) {
          prefix = trimmed;
        } else {
          final lastSpace = restOfText.lastIndexOf(' ');
          prefix = lastSpace >= 0
              ? commandAndSpace + restOfText.substring(0, lastSpace + 1)
              : commandAndSpace;
        }

        final nextParamIndex = _currentParamIndex + 1;
        final isLastParam =
            nextParamIndex >= _activeCommand!.params.length;

        if (isLastParam) {
          final commandText = prefix + selected.value;
          _setOverlayOff();
          textController.clear();
          _executeCommand(commandText);
        } else {
          final newText = prefix + selected.value + ' ';
          textController.text = newText;
          textController.selection = TextSelection.collapsed(
            offset: newText.length,
          );
        }
        return true;
      }

      if (event.logicalKey == LogicalKey.escape) {
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
    if (selected.params.isEmpty) {
      _setOverlayOff();
      textController.clear();
      _executeCommand(selected.name);
    } else {
      textController.text = selected.name + ' ';
      textController.selection = TextSelection.collapsed(
        offset: textController.text.length,
      );
    }
  }

  void _onScrollCommand(MouseEvent event) {
    final maxOffset = _filteredCommands.length > _maxVisibleItems
        ? _filteredCommands.length - _maxVisibleItems
        : 0;
    if (event.button == MouseButton.wheelUp && _commandScrollOffset > 0) {
      setState(() {
        _commandScrollOffset = (_commandScrollOffset - _maxVisibleItems).clamp(
          0,
          maxOffset,
        );
      });
    } else if (event.button == MouseButton.wheelDown &&
        _commandScrollOffset < maxOffset) {
      setState(() {
        _commandScrollOffset = (_commandScrollOffset + _maxVisibleItems).clamp(
          0,
          maxOffset,
        );
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
    final trimmed = textController.text.replaceFirst(RegExp(r'^\s+'), '');
    final commandAndSpace = _activeCommand!.name + ' ';
    final restOfText = trimmed.substring(_activeCommand!.name.length + 1);

    String prefix;
    if (restOfText.isEmpty || restOfText.endsWith(' ')) {
      prefix = trimmed;
    } else {
      final lastSpace = restOfText.lastIndexOf(' ');
      prefix = lastSpace >= 0
          ? commandAndSpace + restOfText.substring(0, lastSpace + 1)
          : commandAndSpace;
    }

    final nextParamIndex = _currentParamIndex + 1;
    final isLastParam =
        nextParamIndex >= _activeCommand!.params.length;

    if (isLastParam) {
      final commandText = prefix + selected.value;
      _setOverlayOff();
      textController.clear();
      _executeCommand(commandText);
    } else {
      final newText = prefix + selected.value + ' ';
      textController.text = newText;
      textController.selection = TextSelection.collapsed(offset: newText.length);
    }
  }

  void _onScrollSuggestion(MouseEvent event) {
    final maxOffset = _filteredSuggestions.length > _maxVisibleItems
        ? _filteredSuggestions.length - _maxVisibleItems
        : 0;
    if (event.button == MouseButton.wheelUp && _suggestionScrollOffset > 0) {
      setState(() {
        _suggestionScrollOffset = (_suggestionScrollOffset - _maxVisibleItems)
            .clamp(0, maxOffset);
      });
    } else if (event.button == MouseButton.wheelDown &&
        _suggestionScrollOffset < maxOffset) {
      setState(() {
        _suggestionScrollOffset = (_suggestionScrollOffset + _maxVisibleItems)
            .clamp(0, maxOffset);
      });
    }
  }

  Future<void> _sendMessage() async {
    if (_overlayMode == _OverlayMode.wizard) return;

    final text = textController.text.trim();
    if (text.isEmpty) return;

    textController.clear();

    if (text.startsWith('/')) {
      _executeCommand(text);
      return;
    }

    final sessionId = _currentSessionId;
    if (sessionId == null) return;

    final rt = _runtime(sessionId);
    _streamingContent = '';
    _streamingReasoning = '';
    _thinkingCollapsed = false;

    rt.isResponding = true;
    rt.responseStartTime = DateTime.now();
    rt.ttftMs = 0.0;
    rt.ttftReceived = false;
    rt.tokPerSec = 0.0;
    rt.tokCount = 0.0;

    _startMetricsTimer(sessionId);
    final userMsg = Message(
      id: -1,
      sessionId: sessionId,
      role: 'user',
      content: text,
    );
    _messageCache[sessionId] = [...?_messageCache[sessionId], userMsg];
    setState(() {});

    _chatService.sendMessage(
      sessionId: sessionId,
      userContent: text,
      session: _currentSession,
      runtime: rt,
      onDelta: (delta) {
        if (_streamingReasoning.isNotEmpty && !_thinkingCollapsed) {
          _thinkingCollapsed = true;
        }
        if (_streamingContent.isEmpty) {
          rt.contentStartTime = DateTime.now();
        }
        _streamingContent += delta;
      },
      onReasoning: (reasoning) {
        _streamingReasoning += reasoning;
      },
      onChunk: () {
        final charCount = _streamingContent.length;
        final estimatedTokens = (charCount / 3.5).ceil();
        rt.contextTargetTokens = _computeBaseContext(sessionId) + estimatedTokens;
        if (!_contextAnimTimerIsActive()) {
          _startContextAnimation();
        }
        setState(() {});
      },
      onComplete: (response) async {
        _streamingContent = '';
        _streamingReasoning = '';
        _thinkingCollapsed = false;
        _stopMetricsTimer(sessionId);
        final msgs = await _store.getMessages(sessionId);
        _messageCache[sessionId] = msgs;
        if (response.promptTokens + response.completionTokens > 0) {
          final finalTokens = _computeBaseContext(sessionId);
          rt.contextTargetTokens = finalTokens;
          rt.contextDisplayTokens = finalTokens.toDouble();
          _stopContextAnimation();
        }
        final hit = response.promptCacheHitTokens;
        final miss = response.promptCacheMissTokens;
        if (hit + miss > 0) {
          final pct = ((hit / (hit + miss)) * 100).round();
          setState(() {
            _toastVisible = true;
            _toastMessage = 'cache hit ${hit} miss ${miss} ($pct%)';
          });
        } else {
          setState(() {});
        }
      },
      onError: (error) {
        _stopMetricsTimer(sessionId);
        setState(() {
          _toastVisible = true;
          _toastMessage = error;
        });
      },
    );
  }

  String _formatTtft(double ms) {
    if (ms >= 1000) {
      final sec = ms / 1000.0;
      return '${sec.toStringAsFixed(2)}s';
    }
    return '${ms.round()}ms';
  }

  Future<void> _executeCommand(String text) async {
    final parts = text.split(' ');
    final commandName = parts[0];
    final command = findCommand(commandName);

    if (commandName == '/model') {
      if (parts.length > 1 && parts[1].isNotEmpty) {
        final modelKey = parts[1];
        if (_providerServiceReady &&
            _providerService.modelByCompositeKey(modelKey) == null) {
          setState(() {
            _toastVisible = true;
            _toastMessage = 'Unknown model: $modelKey';
          });
        } else {
          if (_currentSessionId != null) {
            await _store.update(_currentSessionId!, model: modelKey);
            _currentSession.model = modelKey;
          }
          setState(() {
            _toastVisible = true;
            _toastMessage = 'Model switched to $modelKey';
          });
          _providerService.setLastUsedModel(modelKey);
        }
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
          await _switchSession(id);
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
    } else if (commandName == '/new') {
      final model = _providerService.resolveDefaultModel() ?? '';
      final session = await _store.create(title: 'New Session', model: model, projectPath: _projectPath);
      _sessions = await _store.list(projectPath: _projectPath);
      await _switchSession(session.id);
    } else if (commandName == '/provider') {
      final subcommand = parts.length > 1 ? parts[1] : '';
      const builtInProviders = {'deepseek', 'infinigence', 'volcengine'};

      if (builtInProviders.contains(subcommand)) {
        _providerService.initialize().then((_) {
          final provider = _providerService.providerByName(subcommand);
          if (provider == null) {
            setState(() {
              _toastVisible = true;
              _toastMessage = 'Provider "$subcommand" not found in config';
            });
            return;
          }
          setState(() {
            _overlayMode = _OverlayMode.wizard;
            _activeWizardSubcommand = _ProviderWizardSubcommand.builtin;
            _builtinProviderName = subcommand;
            _setOverlayOffExceptWizard();
          });
        });
      } else if (subcommand == 'custom') {
        _providerService.initialize().then((_) {
          setState(() {
            _overlayMode = _OverlayMode.wizard;
            _activeWizardSubcommand = _ProviderWizardSubcommand.custom;
            _builtinProviderName = null;
            _setOverlayOffExceptWizard();
          });
        });
      } else {
        setState(() {
          _toastVisible = true;
          _toastMessage =
              'Usage: /provider <deepseek|infinigence|volcengine|custom>';
        });
      }
    } else if (commandName == '/think') {
      if (_currentSessionId == null) return;
      final rt = _runtime(_currentSessionId!);
      final effort = parts.length > 1 ? parts[1] : '';
      switch (effort) {
        case 'off':
          rt.thinkingMode = 'disabled';
          rt.reasoningEffort = null;
          _persistThinkingLevel(rt);
          setState(() {
            _toastVisible = true;
            _toastMessage = 'Thinking mode: off';
          });
          break;
        case 'normal':
          rt.thinkingMode = 'enabled';
          rt.reasoningEffort = 'normal';
          _persistThinkingLevel(rt);
          setState(() {
            _toastVisible = true;
            _toastMessage = 'Thinking mode: normal';
          });
          break;
        case 'high':
          rt.thinkingMode = 'enabled';
          rt.reasoningEffort = 'high';
          _persistThinkingLevel(rt);
          setState(() {
            _toastVisible = true;
            _toastMessage = 'Thinking mode: high';
          });
          break;
        case 'max':
          rt.thinkingMode = 'enabled';
          rt.reasoningEffort = 'max';
          _persistThinkingLevel(rt);
          setState(() {
            _toastVisible = true;
            _toastMessage = 'Thinking mode: max';
          });
          break;
        default:
          final current = rt.thinkingMode == 'disabled'
              ? 'off'
              : rt.reasoningEffort ?? 'normal';
          setState(() {
            _toastVisible = true;
            _toastMessage = 'Usage: /think <off|normal|high|max> (current: $current)';
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

  void _setOverlayOffExceptWizard() {
    _filteredCommands = [];
    _selectedCommandIndex = 0;
    _commandScrollOffset = 0;
    _filteredSuggestions = [];
    _activeCommand = null;
    _currentParamIndex = 0;
    _selectedSuggestionIndex = 0;
    _suggestionScrollOffset = 0;
  }

  void _dismissWizard({String? message}) {
    setState(() {
      _overlayMode = _OverlayMode.off;
    _activeWizardSubcommand = null;
    _builtinProviderName = null;
      if (message != null) {
        _toastVisible = true;
        _toastMessage = message;
      }
    });
  }

  Component _buildWizardOverlay() {
    final sub = _activeWizardSubcommand;
    if (sub == null) return const SizedBox();

    final VoidCallback onComplete = () {
      switch (sub) {
        case _ProviderWizardSubcommand.builtin:
          _dismissWizard(message: '✓ ${_builtinProviderName ?? "Provider"} connected successfully');
        case _ProviderWizardSubcommand.custom:
          _dismissWizard(message: '✓ Custom provider updated successfully');
      }
    };

    final VoidCallback onDismiss = () => _dismissWizard();

    switch (sub) {
      case _ProviderWizardSubcommand.builtin:
        return ProviderWizardBuiltin(
          service: _providerService,
          providerName: _builtinProviderName!,
          onComplete: onComplete,
          onDismiss: onDismiss,
        );
      case _ProviderWizardSubcommand.custom:
        return ProviderWizardCustom(
          service: _providerService,
          onComplete: onComplete,
          onDismiss: onDismiss,
        );
    }
  }

  void _startContextAnimation() {
    if (_contextAnimTimer != null) return;
    _lastContextTick = DateTime.now();
    _contextAnimTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = DateTime.now();
      final deltaTime =
          now.difference(_lastContextTick!).inMilliseconds / 1000.0;
      _lastContextTick = now;

      if (_currentSessionId == null) return;
      final rt = _runtime(_currentSessionId!);
      final diff = rt.contextTargetTokens - rt.contextDisplayTokens;
      if (diff.abs() < 0.5) {
        rt.contextDisplayTokens = rt.contextTargetTokens.toDouble();
        _stopContextAnimation();
        setState(() {});
        return;
      }

      rt.contextDisplayTokens += diff * (deltaTime * _contextLerpSpeed);
      setState(() {});
    });
  }

  void _stopContextAnimation() {
    _contextAnimTimer?.cancel();
    _contextAnimTimer = null;
    _lastContextTick = null;
  }

  final Map<int, Timer> _metricsTimers = {};

  void _startMetricsTimer(int sessionId) {
    _stopMetricsTimer(sessionId);
    _metricsTimers[sessionId] =
        Timer.periodic(const Duration(milliseconds: 50), (_) {
      _updateLiveMetrics(sessionId);
      setState(() {});
    });
  }

  void _stopMetricsTimer(int sessionId) {
    _metricsTimers[sessionId]?.cancel();
    _metricsTimers.remove(sessionId);
  }

  void _updateLiveMetrics(int sessionId) {
    final rt = _runtime(sessionId);
    if (!rt.isResponding || rt.responseStartTime == null) return;

    final elapsedMs = DateTime.now()
            .difference(rt.responseStartTime!)
            .inMicroseconds /
        1000.0;

    if (!rt.ttftReceived) {
      rt.ttftMs = elapsedMs;
    }

    final contentChars = _streamingContent.length;
    final reasoningChars = _streamingReasoning.length;
    final totalChars = contentChars + reasoningChars;
    if (totalChars > 0 && rt.ttftReceived) {
      final estimatedTokens = (totalChars / 3.5).ceil();
      final elapsedSec =
          (elapsedMs - rt.ttftMs) / 1000.0;
      if (elapsedSec > 0) {
        rt.tokPerSec = estimatedTokens / elapsedSec;
      }
    }
  }

  bool _contextAnimTimerIsActive() => _contextAnimTimer != null;

  void _dismissToast() {
    setState(() {
      _toastVisible = false;
      _toastMessage = '';
    });
  }

  @override
  Component build(BuildContext context) {
    return LayoutBuilder(
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
                child: ExtraInfoPanel(
                  sessions: _sessions,
                  currentSessionId: _currentSessionId ?? 0,
                  onSwitchSession: _switchSession,
                ),
              ),
            ],
          );
        }

        return _buildMainInterface();
      },
    );
  }

  Component _buildMainInterface() {
    final children = <Component>[];

    if (_overlayMode == _OverlayMode.wizard) {
      children.add(Expanded(child: _buildWizardOverlay()));
      return Column(children: children);
    }

    children.add(Expanded(child: _buildMessageList()));

    if (_overlayMode == _OverlayMode.command && _filteredCommands.isNotEmpty) {
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
      children.add(Toast(message: _toastMessage, onDismissed: _dismissToast));
    }

    children.add(_buildToolbar());
    children.add(Divider(color: Color.fromRGB(50, 50, 70), height: 1));
    children.add(_buildInputRow());

    return Column(children: children);
  }

  Component _buildMessageList() {
    final messages = _currentMessages;
    final sessionId = _currentSessionId;
    final rt = sessionId != null ? _runtime(sessionId) : null;
    final isStreaming = rt?.isResponding ?? false;

    if (messages.isEmpty && !isStreaming) {
      return Center(
        child: Text('No messages yet.', style: TextStyle(color: Colors.gray)),
      );
    }

    final itemCount = messages.length + (isStreaming ? 1 : 0);

    return SelectionArea(
      onSelectionCompleted: (text) {
        if (text.isNotEmpty) {
          ClipboardManager.copy(text);
        }
      },
      child: Scrollbar(
      controller: scrollController,
      thumbVisibility: true,
      child: ListView.builder(
        controller: scrollController,
        padding: EdgeInsets.all(1),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index < messages.length) {
            return MessageBubble(message: messages[index]);
          }
          final hasReasoning = _streamingReasoning.isNotEmpty;
          final collapsed = _thinkingCollapsed && _streamingContent.isNotEmpty;
          final rt = sessionId != null ? _runtime(sessionId!) : null;

          String thinkingLine = '';
          if (hasReasoning && collapsed) {
            final thinkingMs = rt?.thinkingDurationMs ?? 0;
            final secs = thinkingMs > 0
                ? (thinkingMs / 1000.0).toStringAsFixed(1)
                : '?';
            final tokens = '~${(_streamingReasoning.length / 3.5).ceil()}';
            final effort = rt?.reasoningEffort ?? 'normal';
            thinkingLine = 'thought for ${secs}s, $tokens tokens [$effort]';
          }

          return Column(
            children: [
              Container(
                padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ' Crux: ',
                      style: TextStyle(
                        color: Colors.brightMagenta,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        hasReasoning && collapsed
                            ? thinkingLine
                            : hasReasoning && !collapsed
                                ? _streamingReasoning
                                : _streamingContent.isEmpty
                                    ? '...'
                                    : _streamingContent,
                        style: TextStyle(
                          color: hasReasoning && collapsed
                              ? Color.fromRGB(100, 85, 140)
                              : hasReasoning && !collapsed
                                  ? Color.fromRGB(80, 70, 110)
                                  : Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (hasReasoning && collapsed && _streamingContent.isNotEmpty)
                Container(
                  padding: EdgeInsets.only(left: 7, right: 1, top: 0, bottom: 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          _streamingContent,
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              Divider(color: Color.fromRGB(40, 40, 60), height: 1),
            ],
          );
        },
      ),
    ),
    );
  }

  Component _buildToolbar() {
    final sessionId = _currentSessionId;
    final rt = sessionId != null ? _runtime(sessionId) : null;
    final modelLabel = _currentSession.model.isEmpty
        ? 'select model'
        : _currentSession.model;
    final modelButton = (rt?.isResponding ?? false)
        ? GlossyModelButton(
            label: modelLabel,
            isAnimating: true,
            onPressed: _onModelButtonPressed,
          )
        : Button(
            label: modelLabel,
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
          if (_modelSupportsImages(_currentSession.model))
            Text(
              '\u{F06E}',
              style: TextStyle(color: Color.fromRGB(120, 100, 160)),
            ),
          if (rt != null && _modelSupportsThinking(_currentSession.model))
            Button(
              label: _thinkingLabel(rt),
              onPressed: () => _cycleThinkingLevel(rt),
              color: rt.thinkingMode == 'disabled'
                  ? Color.fromRGB(60, 50, 80)
                  : Color.fromRGB(120, 100, 160),
              hoverColor: Colors.brightCyan,
              bgColor: Color.fromRGB(25, 20, 45),
              hoverBgColor: Color.fromRGB(40, 30, 80),
              padding: EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            ),
          Text('  ', style: TextStyle(color: Color.fromRGB(50, 50, 70))),
          _buildContextBar(),
          Text('  ', style: TextStyle(color: Color.fromRGB(50, 50, 70))),
          Text(
            rt?.isResponding ?? false
                ? '${rt!.tokPerSec.toStringAsFixed(1)} tok/s'
                : rt != null && rt.tokPerSec > 0
                ? '${rt.tokPerSec.toStringAsFixed(1)} tok/s'
                : '— tok/s',
            style: TextStyle(
              color: rt?.isResponding ?? false
                  ? Color.fromRGB(180, 220, 255)
                  : Color.fromRGB(80, 80, 100),
            ),
          ),
          Text(' ', style: TextStyle(color: Color.fromRGB(50, 50, 70))),
          Text(
            rt?.isResponding ?? false
                ? _formatTtft(rt!.ttftMs)
                : rt != null && rt.ttftMs > 0
                ? _formatTtft(rt.ttftMs)
                : '—',
            style: TextStyle(
              color: rt?.isResponding ?? false
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
    if (_currentSessionId == null) return;
    _store.update(_currentSessionId!, model: _localModel);
    _currentSession.model = _localModel;
    setState(() {
      _toastVisible = true;
      _toastMessage = 'Model switched to $_localModel';
    });
    _providerService.setLastUsedModel(_localModel);
  }

  int _computeBaseContext(int sessionId) {
    final session = _findSession(sessionId);
    if (session != null && session.contextTokens > 0) {
      return session.contextTokens;
    }
    final msgs = _messageCache[sessionId];
    if (msgs == null || msgs.isEmpty) return 0;
    var total = 0;
    for (final m in msgs) {
      if (m.tokensIn + m.tokensOut > 0) {
        total = m.tokensIn + m.tokensOut - m.reasoningTokens;
      } else if (m.content.isNotEmpty) {
        final est = (m.content.length / 3.5).ceil();
        total += est;
      }
    }
    return total;
  }

  Component _buildContextBar() {
    if (_currentSessionId == null) return const SizedBox();
    final rt = _runtime(_currentSessionId!);
    final displayTokens = rt.contextDisplayTokens.round();
    final fillRatio = (displayTokens / _contextMaxTokens).clamp(0.0, 1.0);
    final fmtCtx = (int n) {
      final k = n ~/ 1024;
      final kStr = k.toString().replaceAllMapped(
          RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
      return '${kStr}k';
    };
    final fmtNum = (int n) => n.toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
    final labelText = _contextBarHovered
        ? 'Compact'
        : '${fmtNum(displayTokens)} / ${fmtCtx(_contextMaxTokens)}';

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
    textController.selection = TextSelection.collapsed(offset: newText.length);
  }

  void _onModelButtonPressed() {
    final newText = '/model ';
    textController.text = newText;
    textController.selection = TextSelection.collapsed(offset: newText.length);
  }

  String _thinkingLabel(SessionRuntimeState rt) {
    final effort = rt.thinkingMode == 'disabled'
        ? 'off'
        : rt.reasoningEffort ?? 'normal';
    return '\u{F0EB} ${effort.padRight(4)}';
  }

  void _cycleThinkingLevel(SessionRuntimeState rt) {
    final levels = ['off', 'normal', 'high', 'max'];
    final current = rt.thinkingMode == 'disabled'
        ? 'off'
        : rt.reasoningEffort ?? 'normal';
    final idx = levels.indexOf(current);
    final next = levels[(idx + 1) % levels.length];
    switch (next) {
      case 'off':
        rt.thinkingMode = 'disabled';
        rt.reasoningEffort = null;
        break;
      case 'normal':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'normal';
        break;
      case 'high':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'high';
        break;
      case 'max':
        rt.thinkingMode = 'enabled';
        rt.reasoningEffort = 'max';
        break;
    }
    _persistThinkingLevel(rt);
    setState(() {});
  }

  void _persistThinkingLevel(SessionRuntimeState rt) {
    final sid = _currentSessionId;
    if (sid == null) return;
    final session = _findSession(sid);
    if (session != null) {
      session.thinkingMode = rt.thinkingMode;
      session.reasoningEffort = rt.reasoningEffort;
    }
    _store.update(
      sid,
      thinkingMode: rt.thinkingMode,
      reasoningEffort: rt.reasoningEffort,
    );
  }

  Component _buildInputRow() {
    return Container(
      padding: EdgeInsets.all(1),
      child: Row(
        children: [
          Text('> ', style: TextStyle(color: Colors.gray)),
          Expanded(
            child: TextField(
              controller: textController,
              focused: true,
              maxLines: null,
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
