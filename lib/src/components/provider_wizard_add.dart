import 'dart:async';
import 'package:nocterm/nocterm.dart';
import 'ui/button.dart';
import 'ui/focus_grid.dart';
import 'ui/option_toggle.dart';
import 'ui/wizard_overlay.dart';
import '../models/provider_config.dart';
import '../services/provider_service.dart';

class _PendingModel {
  String id = '';
  String name = '';
  int contextSize = 131072;
  bool imageSupport = false;
  bool thinking = false;
  int? thinkingBudget;
  String? reasoningEffort;

  _PendingModel({
    this.id = '',
    this.name = '',
    this.contextSize = 131072,
    this.imageSupport = false,
    this.thinking = false,
    this.thinkingBudget,
    this.reasoningEffort,
  });

  bool isValid() => id.isNotEmpty && contextSize > 0;

  ModelConfig toModelConfig() {
    ReasoningEffort? effort;
    if (reasoningEffort != null) {
      switch (reasoningEffort!.toLowerCase()) {
        case 'low':
          effort = ReasoningEffort.low;
        case 'medium':
          effort = ReasoningEffort.medium;
        case 'high':
          effort = ReasoningEffort.high;
      }
    }
    return ModelConfig(
      id: id,
      name: name.isNotEmpty ? name : id,
      contextSize: contextSize,
      imageSupport: imageSupport,
      thinking: thinking,
      thinkingBudget: thinkingBudget,
      reasoningEffort: effort,
    );
  }
}

enum _DiscoverStatus { idle, discovering, discovered, failed }

/// Focus areas within a single merged grid row.
enum _MergedFocusArea {
  urlInput,
  resetDefaultBtn,
  apiKeyInput,
  showKeyBtn,
  nameInput,
  typeToggle,
}

/// Focus areas for footer buttons in the merged step.
enum _MergedFooter { nextBtn, cancelBtn }

/// Content focus areas for the model step grid (footer excluded).
enum _ModelContentFocus {
  discoverBtn,
  addModelBtn,
  removeModelBtn,
  modelId,
  modelName,
  modelContext,
  imageToggleBtn,
  thinkingToggleBtn,
}

/// Focus areas for footer buttons in the model step.
enum _ModelFooter { backBtn, nextBtn, cancelBtn }

/// Focus areas within the model editing step (content only — footer
/// uses [_ModelFooter]).
enum _ModelFocusArea {
  discoverBtn,
  addModelBtn,
  removeModelBtn,
  modelId,
  modelName,
  modelContext,
  imageToggleBtn,
  thinkingToggleBtn,
}

class ProviderWizardAdd extends StatefulComponent {
  final ProviderService service;
  final VoidCallback? onComplete;
  final VoidCallback? onDismiss;

  const ProviderWizardAdd({
    super.key,
    required this.service,
    this.onComplete,
    this.onDismiss,
  });

  @override
  State<ProviderWizardAdd> createState() => _ProviderWizardAddState();
}

class _ProviderWizardAddState extends State<ProviderWizardAdd> {
  // ── Merged step (endpoint, API key, name, type) ──
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  bool _apiKeyObscured = true;
  ProviderType _selectedType = ProviderType.openai;

  late FocusGrid<_MergedFocusArea> _mergedGrid;

  _MergedFooter _mergedFooter = _MergedFooter.nextBtn;
  bool _footerActive = false;

  // ── Models step ──
  final List<_PendingModel> _models = [_PendingModel()];
  int _editingModelIndex = 0;
  final TextEditingController _modelIdController = TextEditingController();
  final TextEditingController _modelNameController = TextEditingController();
  final TextEditingController _modelContextController =
      TextEditingController(text: '128');

  _ModelFocusArea _modelFocusedArea = _ModelFocusArea.modelId;
  late FocusGrid<_ModelContentFocus> _modelGrid;
  _ModelFooter _modelFooter = _ModelFooter.nextBtn;
  bool _modelFooterActive = false;

  _DiscoverStatus _discoverStatus = _DiscoverStatus.idle;
  List<DiscoveredModel> _discoveredModels = [];
  final Set<int> _selectedDiscoveredIndices = {};
  bool _showDiscoverPanel = false;
  bool _disposed = false;

  final WizardController wizardController = WizardController();

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  ProviderService get _service => component.service;

  String _defaultEndpoint(ProviderType type) {
    switch (type) {
      case ProviderType.openai:
        return 'https://api.openai.com/v1';
      case ProviderType.anthropic:
        return 'https://api.anthropic.com';
    }
  }

  String _providerTypeDisplayName(ProviderType type) {
    switch (type) {
      case ProviderType.openai:
        return 'OpenAI Compatible';
      case ProviderType.anthropic:
        return 'Anthropic Compatible';
    }
  }

  String _apiKeyHint(ProviderType type) {
    switch (type) {
      case ProviderType.openai:
        return 'Enter your API key';
      case ProviderType.anthropic:
        return 'Enter your Anthropic API key';
    }
  }

  bool _isValidEndpoint(String url) {
    if (url.isEmpty) return false;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return false;
    final hostPart = url.replaceFirst(RegExp(r'^https?://'), '');
    if (hostPart.isEmpty) return false;
    if (hostPart.contains(' ')) return false;
    final slashIndex = hostPart.indexOf('/');
    final host = slashIndex > 0 ? hostPart.substring(0, slashIndex) : hostPart;
    if (host.isEmpty) return false;
    final isLocalhost = host == 'localhost' || host.startsWith('localhost:');
    final isIp = RegExp(r'^[\d.]+(:\d+)?$').hasMatch(host);
    final hasDomainDot = host.contains('.');
    return isLocalhost || isIp || hasDomainDot;
  }

  bool _isValidProviderName(String name) {
    if (name.isEmpty) return false;
    return _service.providerByName(name) == null;
  }

  String _effectiveEndpoint() {
    final url = _endpointController.text;
    return url.isNotEmpty ? url : _defaultEndpoint(_selectedType);
  }

  bool _validateEndpointUrl() {
    final url = _endpointController.text;
    if (url.isEmpty) return true;
    return _isValidEndpoint(url);
  }

  bool _validateProviderName() =>
      _isValidProviderName(_nameController.text);

  String _extractNameFromUrl(String url) {
    if (!_isValidEndpoint(url)) return '';
    final hostPart = url.replaceFirst(RegExp(r'^https?://'), '');
    final slashIndex = hostPart.indexOf('/');
    final host = slashIndex > 0 ? hostPart.substring(0, slashIndex) : hostPart;
    final portIndex = host.lastIndexOf(':');
    final domain = portIndex > 0 ? host.substring(0, portIndex) : host;
    var name = domain;
    if (name.startsWith('api.')) name = name.substring(4);
    final dotIndex = name.indexOf('.');
    if (dotIndex > 0) name = name.substring(0, dotIndex);
    return name;
  }

  void _autoDetectName() {
    final url = _endpointController.text;
    final extracted = _extractNameFromUrl(url);
    if (extracted.isNotEmpty && _nameController.text.isEmpty) {
      _nameController.text = extracted;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Model field sync
  // ═══════════════════════════════════════════════════════════════════════════

  void _syncModelFieldsToPending() {
    if (_editingModelIndex >= 0 && _editingModelIndex < _models.length) {
      final m = _models[_editingModelIndex];
      m.id = _modelIdController.text;
      m.name = _modelNameController.text;
      m.contextSize =
          (int.tryParse(_modelContextController.text) ?? 128) * 1024;
    }
  }

  void _loadModelFieldsFromPending(int index) {
    if (index >= 0 && index < _models.length) {
      final m = _models[index];
      _modelIdController.text = m.id;
      _modelNameController.text = m.name;
      _modelContextController.text = (m.contextSize ~/ 1024).toString();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void initState() {
    super.initState();
    _mergedGrid = FocusGrid<_MergedFocusArea>(
      cells: const [
        FocusCell(_MergedFocusArea.urlInput, row: 0, col: 0),
        FocusCell(_MergedFocusArea.resetDefaultBtn, row: 0, col: 1),
        FocusCell(_MergedFocusArea.apiKeyInput, row: 1, col: 0),
        FocusCell(_MergedFocusArea.showKeyBtn, row: 1, col: 1),
        FocusCell(_MergedFocusArea.nameInput, row: 2, col: 0),
        FocusCell(_MergedFocusArea.typeToggle, row: 3, col: 0),
      ],
      initial: _MergedFocusArea.urlInput,
    );
    _modelGrid = FocusGrid<_ModelContentFocus>(
      cells: const [
        FocusCell(_ModelContentFocus.discoverBtn, row: 0, col: 0),
        FocusCell(_ModelContentFocus.addModelBtn, row: 0, col: 1),
        FocusCell(_ModelContentFocus.removeModelBtn, row: 1, col: 0),
        FocusCell(_ModelContentFocus.modelId, row: 2, col: 0),
        FocusCell(_ModelContentFocus.modelName, row: 3, col: 0),
        FocusCell(_ModelContentFocus.modelContext, row: 4, col: 0),
        FocusCell(_ModelContentFocus.imageToggleBtn, row: 5, col: 0),
        FocusCell(_ModelContentFocus.thinkingToggleBtn, row: 5, col: 1),
      ],
      initial: _ModelContentFocus.modelId,
    );

    _endpointController.addListener(() {
      if (_disposed) return;
      _autoDetectName();
      setState(() {});
    });
    _apiKeyController.addListener(() {
      if (!_disposed) setState(() {});
    });
    _nameController.addListener(() {
      if (!_disposed) setState(() {});
    });
    _modelIdController.addListener(() {
      if (!_disposed) setState(() {});
    });
    _modelNameController.addListener(() {
      if (!_disposed) setState(() {});
    });
    _modelContextController.addListener(() {
      if (!_disposed) setState(() {});
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _endpointController.dispose();
    _apiKeyController.dispose();
    _nameController.dispose();
    _modelIdController.dispose();
    _modelNameController.dispose();
    _modelContextController.dispose();
    super.dispose();
  }

  void _resetFocusForStep(int stepIndex) {
    switch (stepIndex) {
      case 0:
        _mergedGrid.moveTo(_MergedFocusArea.urlInput);
        _mergedFooter = _MergedFooter.nextBtn;
        _footerActive = false;
      case 1:
        _modelGrid.moveTo(_ModelContentFocus.discoverBtn);
        _syncModelFocusedFromGrid();
        _modelFooter = _ModelFooter.nextBtn;
        _modelFooterActive = false;
      case 2:
        break;
    }
  }

  int _modelFooterFocusIndex() {
    if (!_modelFooterActive) return FooterFocus.none;
    switch (_modelFooter) {
      case _ModelFooter.backBtn:
        return FooterFocus.back;
      case _ModelFooter.nextBtn:
        return FooterFocus.next;
      case _ModelFooter.cancelBtn:
        return FooterFocus.cancel;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Merged Step: Endpoint, API Key, Name, Type
  // ═══════════════════════════════════════════════════════════════════════════

  /// Whether the current grid focus is on a content button (not a TextField
  /// and not a type toggle — those are handled by [onKeyEvent]).
  bool get _isMergedOnContentBtn =>
      _mergedGrid.current == _MergedFocusArea.resetDefaultBtn ||
      _mergedGrid.current == _MergedFocusArea.showKeyBtn;

  /// Returns the footer button focus index for the merged step.
  int _mergedFooterFocusIndex() {
    if (!_footerActive) return FooterFocus.none;
    return _mergedFooter == _MergedFooter.nextBtn
        ? FooterFocus.next
        : FooterFocus.cancel;
  }

  bool _handleMergedTextFieldKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter) {
      wizardController.next();
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }
    if ((event.isControlPressed && event.logicalKey == LogicalKey.keyB) ||
        (event.isAltPressed && event.logicalKey == LogicalKey.arrowLeft)) {
      wizardController.back();
      return true;
    }

    // 2D arrow navigation
    if (event.logicalKey == LogicalKey.arrowUp) {
      _mergedGrid.moveUp();
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      final prev = _mergedGrid.current;
      _mergedGrid.moveDown();
      if (_mergedGrid.current == prev) {
        setState(() {
          _footerActive = true;
          _mergedFooter = _MergedFooter.nextBtn;
        });
      }
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowLeft) {
      _mergedGrid.moveLeft();
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowRight) {
      _mergedGrid.moveRight();
      wizardController.requestRebuild();
      return true;
    }

    // Tab: linear forward through all grid cells, then into footer
    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed) {
      final all = const [
        _MergedFocusArea.urlInput,
        _MergedFocusArea.resetDefaultBtn,
        _MergedFocusArea.apiKeyInput,
        _MergedFocusArea.showKeyBtn,
        _MergedFocusArea.nameInput,
        _MergedFocusArea.typeToggle,
      ];
      final idx = all.indexOf(_mergedGrid.current);
      if (idx == all.length - 1) {
        setState(() {
          _footerActive = true;
          _mergedFooter = _MergedFooter.nextBtn;
        });
      } else {
        _mergedGrid.moveTo(all[idx + 1]);
      }
      wizardController.requestRebuild();
      return true;
    }

    // Shift+Tab: linear backward
    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed) {
      final all = const [
        _MergedFocusArea.urlInput,
        _MergedFocusArea.resetDefaultBtn,
        _MergedFocusArea.apiKeyInput,
        _MergedFocusArea.showKeyBtn,
        _MergedFocusArea.nameInput,
        _MergedFocusArea.typeToggle,
      ];
      final idx = all.indexOf(_mergedGrid.current);
      if (idx == 0) {
        setState(() {
          _footerActive = true;
          _mergedFooter = _MergedFooter.cancelBtn;
        });
      } else {
        _mergedGrid.moveTo(all[idx - 1]);
      }
      wizardController.requestRebuild();
      return true;
    }

    return false;
  }

  bool _handleMergedContentBtnKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter ||
        event.logicalKey == LogicalKey.space) {
      if (_mergedGrid.current == _MergedFocusArea.resetDefaultBtn) {
        setState(() {
          _endpointController.text = _defaultEndpoint(_selectedType);
        });
      } else if (_mergedGrid.current == _MergedFocusArea.showKeyBtn) {
        setState(() {
          _apiKeyObscured = !_apiKeyObscured;
        });
      }
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }

    // 2D arrow navigation
    if (event.logicalKey == LogicalKey.arrowUp) {
      _mergedGrid.moveUp();
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      final prev = _mergedGrid.current;
      _mergedGrid.moveDown();
      if (_mergedGrid.current == prev) {
        setState(() {
          _footerActive = true;
          _mergedFooter = _MergedFooter.nextBtn;
        });
      }
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowLeft) {
      _mergedGrid.moveLeft();
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowRight) {
      _mergedGrid.moveRight();
      wizardController.requestRebuild();
      return true;
    }

    // Tab: linear forward
    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed) {
      final all = const [
        _MergedFocusArea.urlInput,
        _MergedFocusArea.resetDefaultBtn,
        _MergedFocusArea.apiKeyInput,
        _MergedFocusArea.showKeyBtn,
        _MergedFocusArea.nameInput,
        _MergedFocusArea.typeToggle,
      ];
      final idx = all.indexOf(_mergedGrid.current);
      if (idx == all.length - 1) {
        setState(() {
          _footerActive = true;
          _mergedFooter = _MergedFooter.nextBtn;
        });
      } else {
        _mergedGrid.moveTo(all[idx + 1]);
      }
      wizardController.requestRebuild();
      return true;
    }

    // Shift+Tab: linear backward
    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed) {
      final all = const [
        _MergedFocusArea.urlInput,
        _MergedFocusArea.resetDefaultBtn,
        _MergedFocusArea.apiKeyInput,
        _MergedFocusArea.showKeyBtn,
        _MergedFocusArea.nameInput,
        _MergedFocusArea.typeToggle,
      ];
      final idx = all.indexOf(_mergedGrid.current);
      if (idx == 0) {
        setState(() {
          _footerActive = true;
          _mergedFooter = _MergedFooter.cancelBtn;
        });
      } else {
        _mergedGrid.moveTo(all[idx - 1]);
      }
      wizardController.requestRebuild();
      return true;
    }

    return false;
  }

  bool _handleMergedTypeToggleKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter) {
      wizardController.next();
      return true;
    }

    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }

    // Left/Right toggles between OpenAI / Anthropic
    if (event.logicalKey == LogicalKey.arrowLeft) {
      setState(() => _selectedType = ProviderType.openai);
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowRight) {
      setState(() => _selectedType = ProviderType.anthropic);
      return true;
    }

    // Up/Down moves to grid cells above/below
    if (event.logicalKey == LogicalKey.arrowUp) {
      _mergedGrid.moveUp();
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      setState(() {
        _footerActive = true;
        _mergedFooter = _MergedFooter.nextBtn;
      });
      wizardController.requestRebuild();
      return true;
    }

    // Tab: linear forward into footer
    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed) {
      setState(() {
        _footerActive = true;
        _mergedFooter = _MergedFooter.nextBtn;
      });
      wizardController.requestRebuild();
      return true;
    }

    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed) {
      final all = const [
        _MergedFocusArea.urlInput,
        _MergedFocusArea.resetDefaultBtn,
        _MergedFocusArea.apiKeyInput,
        _MergedFocusArea.showKeyBtn,
        _MergedFocusArea.nameInput,
        _MergedFocusArea.typeToggle,
      ];
      final idx = all.indexOf(_mergedGrid.current);
      if (idx == 0) {
        setState(() {
          _footerActive = true;
          _mergedFooter = _MergedFooter.cancelBtn;
        });
      } else {
        _mergedGrid.moveTo(all[idx - 1]);
      }
      wizardController.requestRebuild();
      return true;
    }

    return false;
  }

  bool _handleMergedFooterKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter) {
      if (_mergedFooter == _MergedFooter.nextBtn) {
        wizardController.next();
      } else {
        wizardController.cancel();
      }
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }

    if (event.logicalKey == LogicalKey.arrowUp) {
      _mergedGrid.moveTo(_MergedFocusArea.typeToggle);
      setState(() => _footerActive = false);
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowLeft) {
      if (_mergedFooter == _MergedFooter.nextBtn) {
        _mergedGrid.moveTo(_MergedFocusArea.typeToggle);
        setState(() => _footerActive = false);
      } else {
        setState(() => _mergedFooter = _MergedFooter.nextBtn);
      }
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowRight) {
      if (_mergedFooter == _MergedFooter.nextBtn) {
        setState(() => _mergedFooter = _MergedFooter.cancelBtn);
      } else {
        _mergedGrid.moveTo(_MergedFocusArea.urlInput);
        setState(() => _footerActive = false);
      }
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed) {
      if (_mergedFooter == _MergedFooter.nextBtn) {
        setState(() => _mergedFooter = _MergedFooter.cancelBtn);
      } else {
        _mergedGrid.moveTo(_MergedFocusArea.urlInput);
        setState(() => _footerActive = false);
      }
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed) {
      if (_mergedFooter == _MergedFooter.nextBtn) {
        _mergedGrid.moveTo(_MergedFocusArea.typeToggle);
        setState(() => _footerActive = false);
      } else {
        setState(() => _mergedFooter = _MergedFooter.nextBtn);
      }
      wizardController.requestRebuild();
      return true;
    }

    return false;
  }

  Component _buildMergedStep() {
    final rows = <Component>[];

    rows.add(
      const Text(
        'Configure your provider:',
        style: TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    // ── Row 0: URL input + Reset Default button ──
    rows.add(
      Row(
        children: [
          GestureDetector(
            onTap: () => setState(
              () => _mergedGrid.moveTo(_MergedFocusArea.urlInput),
            ),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                const Text(
                  'URL: ',
                  style: TextStyle(color: Colors.brightCyan),
                ),
                SizedBox(
                  width: 38,
                  child: TextField(
                    controller: _endpointController,
                    focused:
                        !_footerActive &&
                        _mergedGrid.current == _MergedFocusArea.urlInput,
                    onKeyEvent: _handleMergedTextFieldKeyEvent,
                    style: const TextStyle(color: Colors.white),
                    placeholder: _defaultEndpoint(_selectedType),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 1),
          Button(
            label: ' ↺ Reset ',
            onPressed: () {
              setState(() {
                _mergedGrid.moveTo(_MergedFocusArea.resetDefaultBtn);
                _endpointController.text = _defaultEndpoint(_selectedType);
              });
              wizardController.requestRebuild();
            },
            color:
                _mergedGrid.current == _MergedFocusArea.resetDefaultBtn
                    ? Colors.brightCyan
                    : Colors.gray,
            hoverColor: Colors.brightCyan,
            bgColor:
                _mergedGrid.current == _MergedFocusArea.resetDefaultBtn
                    ? const Color.fromRGB(40, 30, 80)
                    : const Color.fromRGB(25, 20, 45),
            hoverBgColor: const Color.fromRGB(40, 30, 80),
          ),
        ],
      ),
    );

    // URL validation feedback
    final url = _endpointController.text;
    if (url.isNotEmpty && !_isValidEndpoint(url)) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        const Text(
          '⚠ Invalid URL. Must start with http:// or https:// and have a valid host.',
          style: TextStyle(color: Colors.brightYellow),
        ),
      );
    }
    rows.add(const SizedBox(height: 1));

    // ── Row 1: API Key input + Show/Hide button ──
    rows.add(
      Row(
        children: [
          GestureDetector(
            onTap: () => setState(
              () => _mergedGrid.moveTo(_MergedFocusArea.apiKeyInput),
            ),
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                const Text(
                  'Key: ',
                  style: TextStyle(color: Colors.brightCyan),
                ),
                SizedBox(
                  width: 38,
                  child: TextField(
                    controller: _apiKeyController,
                    focused:
                        !_footerActive &&
                        _mergedGrid.current == _MergedFocusArea.apiKeyInput,
                    onKeyEvent: _handleMergedTextFieldKeyEvent,
                    obscureText: _apiKeyObscured,
                    obscuringCharacter: '•',
                    style: const TextStyle(color: Colors.white),
                    placeholder: _apiKeyHint(_selectedType),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 1),
          Button(
            label: _apiKeyObscured ? ' 👁 Show ' : ' 🔒 Hide ',
            onPressed: () {
              setState(() {
                _mergedGrid.moveTo(_MergedFocusArea.showKeyBtn);
                _apiKeyObscured = !_apiKeyObscured;
              });
              wizardController.requestRebuild();
            },
            color:
                _mergedGrid.current == _MergedFocusArea.showKeyBtn
                    ? Colors.brightCyan
                    : Colors.gray,
            hoverColor: Colors.brightCyan,
            bgColor:
                _mergedGrid.current == _MergedFocusArea.showKeyBtn
                    ? const Color.fromRGB(40, 30, 80)
                    : const Color.fromRGB(25, 20, 45),
            hoverBgColor: const Color.fromRGB(40, 30, 80),
          ),
        ],
      ),
    );

    // API key validation
    final key = _apiKeyController.text;
    if (key.isNotEmpty && key.length < 20) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        Text(
          '⚠ Key must be at least 20 characters (${key.length}/20)',
          style: const TextStyle(color: Colors.brightYellow),
        ),
      );
    }
    rows.add(const SizedBox(height: 1));

    // ── Row 2: Provider Name ──
    rows.add(
      GestureDetector(
        onTap: () => setState(
          () => _mergedGrid.moveTo(_MergedFocusArea.nameInput),
        ),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            const Text(
              'Name: ',
              style: TextStyle(color: Colors.brightCyan),
            ),
            Expanded(
              child: TextField(
                controller: _nameController,
                focused:
                    !_footerActive &&
                    _mergedGrid.current == _MergedFocusArea.nameInput,
                onKeyEvent: _handleMergedTextFieldKeyEvent,
                style: const TextStyle(color: Colors.white),
                placeholder: 'auto-detected from URL',
              ),
            ),
          ],
        ),
      ),
    );

    // Name validation
    final name = _nameController.text;
    if (name.isNotEmpty) {
      rows.add(const SizedBox(height: 1));
      if (_service.providerByName(name) != null) {
        rows.add(
          const Text(
            '⚠ A provider with this name already exists.',
            style: TextStyle(color: Colors.brightYellow),
          ),
        );
      } else {
        rows.add(
          const Text(
            '✓ Name is available.',
            style: TextStyle(color: Color.fromRGB(100, 220, 100)),
          ),
        );
      }
    }
    rows.add(const SizedBox(height: 1));

    // ── Row 3: Type switch ──
    rows.add(
      const Text(
        'Type:',
        style: TextStyle(color: Colors.brightCyan),
      ),
    );
    rows.add(const SizedBox(height: 1));
    rows.add(
      OptionToggle(
        options: const ['OpenAI Compatible', 'Anthropic Compatible'],
        selectedIndex: _selectedType == ProviderType.openai ? 0 : 1,
        onChanged: (i) {
          setState(() {
            _selectedType =
                i == 0 ? ProviderType.openai : ProviderType.anthropic;
            _mergedGrid.moveTo(_MergedFocusArea.typeToggle);
          });
          wizardController.requestRebuild();
        },
        focused: !_footerActive && _mergedGrid.current == _MergedFocusArea.typeToggle,
      ),
    );

    rows.add(const SizedBox(height: 1));
    rows.add(
      const Text(
        'API key is optional — you can set it later via /provider connect.',
        style: TextStyle(color: Colors.gray),
      ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Model step: key handlers
  // ═══════════════════════════════════════════════════════════════════════════

  bool _handleModelFieldKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter) {
      wizardController.next();
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }
    if ((event.isControlPressed && event.logicalKey == LogicalKey.keyB) ||
        (event.isAltPressed && event.logicalKey == LogicalKey.arrowLeft)) {
      wizardController.back();
      return true;
    }

    // Up/Down from model card fields → navigate within grid, switch card at boundary
    if (event.logicalKey == LogicalKey.arrowUp) {
      final isModelField = _modelFocusedArea == _ModelFocusArea.modelId ||
          _modelFocusedArea == _ModelFocusArea.modelName ||
          _modelFocusedArea == _ModelFocusArea.modelContext;
      if (isModelField) {
        final prev = _modelGrid.current;
        _modelGrid.moveUp();
        if (_modelGrid.current != prev) {
          _syncModelFocusedFromGrid();
        } else {
          _syncModelFieldsToPending();
          if (_editingModelIndex > 0) {
            setState(() {
              _editingModelIndex--;
              _loadModelFieldsFromPending(_editingModelIndex);
            });
          }
        }
      } else {
        final prev = _modelGrid.current;
        _modelGrid.moveUp();
        if (_modelGrid.current != prev) {
          _syncModelFocusedFromGrid();
        }
      }
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      final isModelField = _modelFocusedArea == _ModelFocusArea.modelId ||
          _modelFocusedArea == _ModelFocusArea.modelName ||
          _modelFocusedArea == _ModelFocusArea.modelContext;
      if (isModelField) {
        _syncModelFieldsToPending();
        if (_editingModelIndex < _models.length - 1) {
          setState(() {
            _editingModelIndex++;
            _loadModelFieldsFromPending(_editingModelIndex);
          });
        } else {
          setState(() {
            _modelFooterActive = true;
            _modelFooter = _ModelFooter.backBtn;
          });
        }
      } else {
        final prev = _modelGrid.current;
        _modelGrid.moveDown();
        if (_modelGrid.current == prev) {
          setState(() {
            _modelFooterActive = true;
            _modelFooter = _ModelFooter.backBtn;
          });
        } else {
          _syncModelFocusedFromGrid();
        }
      }
      wizardController.requestRebuild();
      return true;
    }
    // Left/Right: toggle fields within a model card
    if (event.logicalKey == LogicalKey.arrowLeft) {
      switch (_modelFocusedArea) {
        case _ModelFocusArea.modelName:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.modelId;
            _modelGrid.moveTo(_ModelContentFocus.modelId);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.modelContext:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.modelName;
            _modelGrid.moveTo(_ModelContentFocus.modelName);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.imageToggleBtn:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.modelContext;
            _modelGrid.moveTo(_ModelContentFocus.modelContext);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.thinkingToggleBtn:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.imageToggleBtn;
            _modelGrid.moveTo(_ModelContentFocus.imageToggleBtn);
          });
          wizardController.requestRebuild();
          return true;
        default:
          _modelGrid.moveLeft();
          _syncModelFocusedFromGrid();
          wizardController.requestRebuild();
          return true;
      }
    }
    if (event.logicalKey == LogicalKey.arrowRight) {
      switch (_modelFocusedArea) {
        case _ModelFocusArea.modelId:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.modelName;
            _modelGrid.moveTo(_ModelContentFocus.modelName);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.modelName:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.modelContext;
            _modelGrid.moveTo(_ModelContentFocus.modelContext);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.modelContext:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.imageToggleBtn;
            _modelGrid.moveTo(_ModelContentFocus.imageToggleBtn);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.imageToggleBtn:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.thinkingToggleBtn;
            _modelGrid.moveTo(_ModelContentFocus.thinkingToggleBtn);
          });
          wizardController.requestRebuild();
          return true;
        default:
          _modelGrid.moveRight();
          _syncModelFocusedFromGrid();
          wizardController.requestRebuild();
          return true;
      }
    }

    // Tab: linear forward through all content cells, then into footer
    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed) {
      final all = const [
        _ModelContentFocus.discoverBtn,
        _ModelContentFocus.addModelBtn,
        _ModelContentFocus.removeModelBtn,
        _ModelContentFocus.modelId,
        _ModelContentFocus.modelName,
        _ModelContentFocus.modelContext,
        _ModelContentFocus.imageToggleBtn,
        _ModelContentFocus.thinkingToggleBtn,
      ];
      final idx = all.indexOf(_modelGrid.current);
      if (idx == all.length - 1) {
        setState(() {
          _modelFooterActive = true;
          _modelFooter = _ModelFooter.backBtn;
        });
      } else {
        _modelGrid.moveTo(all[idx + 1]);
        _syncModelFocusedFromGrid();
      }
      wizardController.requestRebuild();
      return true;
    }

    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed) {
      final all = const [
        _ModelContentFocus.discoverBtn,
        _ModelContentFocus.addModelBtn,
        _ModelContentFocus.removeModelBtn,
        _ModelContentFocus.modelId,
        _ModelContentFocus.modelName,
        _ModelContentFocus.modelContext,
        _ModelContentFocus.imageToggleBtn,
        _ModelContentFocus.thinkingToggleBtn,
      ];
      final idx = all.indexOf(_modelGrid.current);
      if (idx == 0) {
        setState(() {
          _modelFooterActive = true;
          _modelFooter = _ModelFooter.cancelBtn;
        });
      } else {
        _modelGrid.moveTo(all[idx - 1]);
        _syncModelFocusedFromGrid();
      }
      wizardController.requestRebuild();
      return true;
    }

    return false;
  }

  void _syncModelFocusedFromGrid() {
    switch (_modelGrid.current) {
      case _ModelContentFocus.discoverBtn:
        _modelFocusedArea = _ModelFocusArea.discoverBtn;
      case _ModelContentFocus.addModelBtn:
        _modelFocusedArea = _ModelFocusArea.addModelBtn;
      case _ModelContentFocus.removeModelBtn:
        _modelFocusedArea = _ModelFocusArea.removeModelBtn;
      case _ModelContentFocus.modelId:
        _modelFocusedArea = _ModelFocusArea.modelId;
      case _ModelContentFocus.modelName:
        _modelFocusedArea = _ModelFocusArea.modelName;
      case _ModelContentFocus.modelContext:
        _modelFocusedArea = _ModelFocusArea.modelContext;
      case _ModelContentFocus.imageToggleBtn:
        _modelFocusedArea = _ModelFocusArea.imageToggleBtn;
      case _ModelContentFocus.thinkingToggleBtn:
        _modelFocusedArea = _ModelFocusArea.thinkingToggleBtn;
    }
  }

  bool _handleModelStepKeyEvent(KeyboardEvent event) {
    if (_modelFocusedArea != _ModelFocusArea.discoverBtn &&
        _modelFocusedArea != _ModelFocusArea.addModelBtn &&
        _modelFocusedArea != _ModelFocusArea.removeModelBtn &&
        _modelFocusedArea != _ModelFocusArea.imageToggleBtn &&
        _modelFocusedArea != _ModelFocusArea.thinkingToggleBtn) {
      return false;
    }

    if (event.logicalKey == LogicalKey.enter) {
      if (_modelFocusedArea == _ModelFocusArea.discoverBtn) {
        setState(() {
          _showDiscoverPanel = !_showDiscoverPanel;
          if (_showDiscoverPanel && _discoverStatus == _DiscoverStatus.idle) {
            _discoverModels();
          }
        });
        return true;
      }
      if (_modelFocusedArea == _ModelFocusArea.addModelBtn) {
        _syncModelFieldsToPending();
        setState(() {
          _models.add(_PendingModel());
          _editingModelIndex = _models.length - 1;
          _modelGrid.moveTo(_ModelContentFocus.modelId);
          _modelFocusedArea = _ModelFocusArea.modelId;
          _loadModelFieldsFromPending(_editingModelIndex);
        });
        wizardController.requestRebuild();
        return true;
      }
      if (_modelFocusedArea == _ModelFocusArea.removeModelBtn) {
        if (_models.length > 1) {
          _removeCurrentModel();
        }
        return true;
      }
      return false;
    }

    if (event.logicalKey == LogicalKey.space) {
      if (_modelFocusedArea == _ModelFocusArea.discoverBtn) {
        setState(() {
          _showDiscoverPanel = !_showDiscoverPanel;
          if (_showDiscoverPanel && _discoverStatus == _DiscoverStatus.idle) {
            _discoverModels();
          }
        });
        return true;
      }
      if (_modelFocusedArea == _ModelFocusArea.addModelBtn) {
        _syncModelFieldsToPending();
        setState(() {
          _models.add(_PendingModel());
          _editingModelIndex = _models.length - 1;
          _modelGrid.moveTo(_ModelContentFocus.modelId);
          _modelFocusedArea = _ModelFocusArea.modelId;
          _loadModelFieldsFromPending(_editingModelIndex);
        });
        wizardController.requestRebuild();
        return true;
      }
      if (_modelFocusedArea == _ModelFocusArea.removeModelBtn) {
        if (_models.length > 1) {
          _removeCurrentModel();
        }
        return true;
      }
      if (_editingModelIndex >= 0 && _editingModelIndex < _models.length) {
        final m = _models[_editingModelIndex];
        _syncModelFieldsToPending();
        setState(() {
          if (_modelFocusedArea == _ModelFocusArea.imageToggleBtn) {
            m.imageSupport = !m.imageSupport;
          } else if (_modelFocusedArea == _ModelFocusArea.thinkingToggleBtn) {
            m.thinking = !m.thinking;
          }
        });
        return true;
      }
      return false;
    }

    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }

    if (event.logicalKey == LogicalKey.arrowUp) {
      final prev = _modelGrid.current;
      _modelGrid.moveUp();
      if (_modelGrid.current != prev) {
        _syncModelFocusedFromGrid();
      }
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      final prev = _modelGrid.current;
      _modelGrid.moveDown();
      if (_modelGrid.current == prev) {
        setState(() {
          _modelFooterActive = true;
          _modelFooter = _ModelFooter.backBtn;
        });
      } else {
        _syncModelFocusedFromGrid();
      }
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowLeft) {
      switch (_modelFocusedArea) {
        case _ModelFocusArea.modelName:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.modelId;
            _modelGrid.moveTo(_ModelContentFocus.modelId);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.modelContext:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.modelName;
            _modelGrid.moveTo(_ModelContentFocus.modelName);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.imageToggleBtn:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.modelContext;
            _modelGrid.moveTo(_ModelContentFocus.modelContext);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.thinkingToggleBtn:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.imageToggleBtn;
            _modelGrid.moveTo(_ModelContentFocus.imageToggleBtn);
          });
          wizardController.requestRebuild();
          return true;
        default:
          _modelGrid.moveLeft();
          _syncModelFocusedFromGrid();
          wizardController.requestRebuild();
          return true;
      }
    }
    if (event.logicalKey == LogicalKey.arrowRight) {
      switch (_modelFocusedArea) {
        case _ModelFocusArea.modelId:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.modelName;
            _modelGrid.moveTo(_ModelContentFocus.modelName);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.modelName:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.modelContext;
            _modelGrid.moveTo(_ModelContentFocus.modelContext);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.modelContext:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.imageToggleBtn;
            _modelGrid.moveTo(_ModelContentFocus.imageToggleBtn);
          });
          wizardController.requestRebuild();
          return true;
        case _ModelFocusArea.imageToggleBtn:
          setState(() {
            _modelFocusedArea = _ModelFocusArea.thinkingToggleBtn;
            _modelGrid.moveTo(_ModelContentFocus.thinkingToggleBtn);
          });
          wizardController.requestRebuild();
          return true;
        default:
          _modelGrid.moveRight();
          _syncModelFocusedFromGrid();
          wizardController.requestRebuild();
          return true;
      }
    }

    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed) {
      final all = const [
        _ModelContentFocus.discoverBtn,
        _ModelContentFocus.addModelBtn,
        _ModelContentFocus.removeModelBtn,
        _ModelContentFocus.modelId,
        _ModelContentFocus.modelName,
        _ModelContentFocus.modelContext,
        _ModelContentFocus.imageToggleBtn,
        _ModelContentFocus.thinkingToggleBtn,
      ];
      final idx = all.indexOf(_modelGrid.current);
      if (idx == all.length - 1) {
        setState(() {
          _modelFooterActive = true;
          _modelFooter = _ModelFooter.backBtn;
        });
      } else {
        _modelGrid.moveTo(all[idx + 1]);
        _syncModelFocusedFromGrid();
      }
      wizardController.requestRebuild();
      return true;
    }

    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed) {
      final all = const [
        _ModelContentFocus.discoverBtn,
        _ModelContentFocus.addModelBtn,
        _ModelContentFocus.removeModelBtn,
        _ModelContentFocus.modelId,
        _ModelContentFocus.modelName,
        _ModelContentFocus.modelContext,
        _ModelContentFocus.imageToggleBtn,
        _ModelContentFocus.thinkingToggleBtn,
      ];
      final idx = all.indexOf(_modelGrid.current);
      if (idx == 0) {
        setState(() {
          _modelFooterActive = true;
          _modelFooter = _ModelFooter.cancelBtn;
        });
      } else {
        _modelGrid.moveTo(all[idx - 1]);
        _syncModelFocusedFromGrid();
      }
      wizardController.requestRebuild();
      return true;
    }

    return false;
  }

  void _removeCurrentModel() {
    _syncModelFieldsToPending();
    final idx = _editingModelIndex;
    setState(() {
      _models.removeAt(idx);
      if (_models.isEmpty) {
        _models.add(_PendingModel());
      }
      if (_editingModelIndex >= _models.length) {
        _editingModelIndex = _models.length - 1;
      }
      if (_editingModelIndex >= 0) {
        _modelGrid.moveTo(_ModelContentFocus.modelId);
        _modelFocusedArea = _ModelFocusArea.modelId;
        _loadModelFieldsFromPending(_editingModelIndex);
      }
    });
    wizardController.requestRebuild();
  }

  bool _handleModelFooterKeyEvent(KeyboardEvent event) {
    if (!_modelFooterActive) return false;

    if (event.logicalKey == LogicalKey.enter) {
      if (_modelFooter == _ModelFooter.backBtn) {
        wizardController.back();
        return true;
      } else if (_modelFooter == _ModelFooter.nextBtn) {
        wizardController.next();
        return true;
      } else if (_modelFooter == _ModelFooter.cancelBtn) {
        wizardController.cancel();
        return true;
      }
      return false;
    }

    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }

    if (event.logicalKey == LogicalKey.arrowUp) {
      _modelGrid.moveTo(_ModelContentFocus.modelId);
      _syncModelFocusedFromGrid();
      setState(() => _modelFooterActive = false);
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowLeft) {
      if (_modelFooter == _ModelFooter.cancelBtn) {
        setState(() => _modelFooter = _ModelFooter.nextBtn);
      } else if (_modelFooter == _ModelFooter.nextBtn) {
        setState(() => _modelFooter = _ModelFooter.backBtn);
      } else {
        _modelGrid.moveTo(_ModelContentFocus.thinkingToggleBtn);
        _syncModelFocusedFromGrid();
        setState(() => _modelFooterActive = false);
      }
      wizardController.requestRebuild();
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowRight) {
      if (_modelFooter == _ModelFooter.backBtn) {
        setState(() => _modelFooter = _ModelFooter.nextBtn);
      } else if (_modelFooter == _ModelFooter.nextBtn) {
        setState(() => _modelFooter = _ModelFooter.cancelBtn);
      } else {
        _modelGrid.moveTo(_ModelContentFocus.discoverBtn);
        _syncModelFocusedFromGrid();
        setState(() => _modelFooterActive = false);
      }
      wizardController.requestRebuild();
      return true;
    }

    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed) {
      if (_modelFooter == _ModelFooter.backBtn) {
        setState(() => _modelFooter = _ModelFooter.nextBtn);
      } else if (_modelFooter == _ModelFooter.nextBtn) {
        setState(() => _modelFooter = _ModelFooter.cancelBtn);
      } else {
        _modelGrid.moveTo(_ModelContentFocus.discoverBtn);
        _syncModelFocusedFromGrid();
        setState(() => _modelFooterActive = false);
      }
      wizardController.requestRebuild();
      return true;
    }

    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed) {
      if (_modelFooter == _ModelFooter.cancelBtn) {
        setState(() => _modelFooter = _ModelFooter.nextBtn);
      } else if (_modelFooter == _ModelFooter.nextBtn) {
        setState(() => _modelFooter = _ModelFooter.backBtn);
      } else {
        _modelGrid.moveTo(_ModelContentFocus.thinkingToggleBtn);
        _syncModelFocusedFromGrid();
        setState(() => _modelFooterActive = false);
      }
      wizardController.requestRebuild();
      return true;
    }

    return false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Model step: validation & discovery
  // ═══════════════════════════════════════════════════════════════════════════

  bool _validateModels() {
    if (_models.isEmpty) return false;
    if (_showDiscoverPanel && _discoverStatus == _DiscoverStatus.discovered) {
      return _selectedDiscoveredIndices.isNotEmpty ||
          _models.any((m) => m.isValid());
    }
    return _models.any((m) => m.isValid());
  }

  Future<void> _discoverModels() async {
    setState(() {
      _discoverStatus = _DiscoverStatus.discovering;
    });

    try {
      final tempName = _nameController.text.isNotEmpty
          ? _nameController.text
          : 'temp_discover';
      final models = await _service.discoverModels(tempName);
      if (_disposed) return;
      setState(() {
        _discoveredModels = models;
        _discoverStatus = models.isNotEmpty
            ? _DiscoverStatus.discovered
            : _DiscoverStatus.failed;
        _selectedDiscoveredIndices.clear();
      });
    } catch (e) {
      if (_disposed) return;
      setState(() {
        _discoverStatus = _DiscoverStatus.failed;
        _discoveredModels = [];
      });
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Model step: build
  // ═══════════════════════════════════════════════════════════════════════════

  Component _buildModelConfigStep() {
    final rows = <Component>[];

    rows.add(
      const Text(
        'Configure models for this provider:',
        style: TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    rows.add(
      Row(
        children: [
          Button(
            label: _showDiscoverPanel
                ? ' ✕ Close Discover '
                : ' 🔍 Auto-discover Models ',
            onPressed: () {
              setState(() {
                _modelFocusedArea = _ModelFocusArea.discoverBtn;
                _showDiscoverPanel = !_showDiscoverPanel;
                if (_showDiscoverPanel &&
                    _discoverStatus == _DiscoverStatus.idle) {
                  _discoverModels();
                }
              });
              wizardController.requestRebuild();
            },
            color: _modelFocusedArea == _ModelFocusArea.discoverBtn
                ? Colors.brightCyan
                : (_showDiscoverPanel
                      ? Colors.brightYellow
                      : Colors.brightCyan),
            hoverColor: Colors.brightCyan,
            bgColor: _modelFocusedArea == _ModelFocusArea.discoverBtn
                ? const Color.fromRGB(40, 30, 80)
                : const Color.fromRGB(25, 20, 45),
            hoverBgColor: const Color.fromRGB(40, 30, 80),
          ),
          const SizedBox(width: 2),
          Button(
            label: ' ➕ Add Model ',
            onPressed: () {
              _syncModelFieldsToPending();
              setState(() {
                _models.add(_PendingModel());
                _editingModelIndex = _models.length - 1;
                _modelFocusedArea = _ModelFocusArea.modelId;
                _loadModelFieldsFromPending(_editingModelIndex);
              });
              wizardController.requestRebuild();
            },
            color: _modelFocusedArea == _ModelFocusArea.addModelBtn
                ? Colors.brightCyan
                : Colors.brightCyan,
            hoverColor: Colors.brightYellow,
            bgColor: _modelFocusedArea == _ModelFocusArea.addModelBtn
                ? const Color.fromRGB(40, 30, 80)
                : const Color.fromRGB(25, 20, 45),
            hoverBgColor: const Color.fromRGB(40, 30, 80),
          ),
        ],
      ),
    );

    if (_showDiscoverPanel) {
      rows.add(const SizedBox(height: 1));
      rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));
      rows.add(const SizedBox(height: 1));

      switch (_discoverStatus) {
        case _DiscoverStatus.idle:
          rows.add(
            const Text(
              '  Ready to discover models from the endpoint...',
              style: TextStyle(color: Colors.gray),
            ),
          );
        case _DiscoverStatus.discovering:
          rows.add(
            const Text(
              '  ⏳ Querying /models endpoint...',
              style: TextStyle(color: Colors.brightCyan),
            ),
          );
        case _DiscoverStatus.discovered:
          rows.add(
            Text(
              '  ✓ Found ${_discoveredModels.length} models. '
              'Select which ones to include:',
              style: const TextStyle(color: Color.fromRGB(100, 220, 100)),
            ),
          );
          rows.add(const SizedBox(height: 1));

          for (int i = 0; i < _discoveredModels.length; i++) {
            final dm = _discoveredModels[i];
            final isSelected = _selectedDiscoveredIndices.contains(i);

            rows.add(
              MouseRegion(
                onEnter: (_) => setState(() {}),
                opaque: false,
                child: GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _selectedDiscoveredIndices.remove(i);
                      } else {
                        _selectedDiscoveredIndices.add(i);
                      }
                    });
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    decoration: isSelected
                        ? const BoxDecoration(color: Color.fromRGB(40, 30, 80))
                        : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 1,
                      vertical: 0,
                    ),
                    child: Row(
                      children: [
                        Text(
                          isSelected ? '☑ ' : '☐ ',
                          style: TextStyle(
                            color: isSelected ? Colors.brightCyan : Colors.gray,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            dm.id +
                                (dm.name != null ? ' (${dm.name})' : ''),
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.brightCyan
                                  : Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }

          if (_selectedDiscoveredIndices.isNotEmpty) {
            rows.add(const SizedBox(height: 1));
            rows.add(
              Button(
                label:
                    ' Add ${_selectedDiscoveredIndices.length} Selected Models ',
                onPressed: () {
                  setState(() {
                    for (final idx in _selectedDiscoveredIndices) {
                      final dm = _discoveredModels[idx];
                      _models.add(
                        _PendingModel(
                          id: dm.id,
                          name: dm.name ?? dm.id,
                          contextSize: dm.contextSize ?? 131072,
                          imageSupport: dm.imageSupport ?? false,
                        ),
                      );
                    }
                    _selectedDiscoveredIndices.clear();
                    _editingModelIndex = _models.length - 1;
                    _modelFocusedArea = _ModelFocusArea.modelId;
                    _loadModelFieldsFromPending(_editingModelIndex);
                  });
                },
                color: const Color.fromRGB(100, 220, 100),
                hoverColor: Colors.brightCyan,
                bgColor: const Color.fromRGB(25, 20, 45),
                hoverBgColor: const Color.fromRGB(40, 30, 80),
              ),
            );
          }
        case _DiscoverStatus.failed:
          rows.add(
            const Text(
              '  ✗ Could not discover models from this endpoint.',
              style: TextStyle(color: Color.fromRGB(255, 80, 80)),
            ),
          );
          rows.add(
            const Text(
              '  This may be because no API key is set, or the endpoint is unreachable.',
              style: TextStyle(color: Colors.gray),
            ),
          );
          rows.add(const SizedBox(height: 1));
          rows.add(
            Button(
              label: ' Retry Discovery ',
              onPressed: _discoverModels,
              color: Colors.brightYellow,
              hoverColor: Colors.brightCyan,
              bgColor: const Color.fromRGB(25, 20, 45),
              hoverBgColor: const Color.fromRGB(40, 30, 80),
            ),
          );
      }

      rows.add(const SizedBox(height: 1));
      rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));
    }

    rows.add(const SizedBox(height: 1));

    _syncModelFieldsToPending();

    if (_models.isEmpty) {
      rows.add(
        const Text(
          '  No models configured. Add one manually or discover from API.',
          style: TextStyle(color: Colors.gray),
        ),
      );
    } else {
      for (int i = 0; i < _models.length; i++) {
        final m = _models[i];
        final isEditing = i == _editingModelIndex;
        final cardBg = isEditing
            ? const Color.fromRGB(35, 28, 55)
            : const Color.fromRGB(28, 23, 45);
        final cardBorder = BorderSide(
          color: isEditing
              ? Colors.brightCyan
              : const Color.fromRGB(80, 60, 120),
        );

        rows.add(
          Container(
            decoration: BoxDecoration(
              color: cardBg,
              border: BoxBorder(
                left: cardBorder,
                top: const BorderSide(color: Color.fromRGB(80, 60, 120)),
                bottom: const BorderSide(color: Color.fromRGB(80, 60, 120)),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    GestureDetector(
                      onTap: isEditing
                          ? null
                          : () {
                              _syncModelFieldsToPending();
                              setState(() {
                                _editingModelIndex = i;
                                _modelGrid.moveTo(_ModelContentFocus.modelId);
                                _modelFocusedArea = _ModelFocusArea.modelId;
                                _loadModelFieldsFromPending(i);
                              });
                              wizardController.requestRebuild();
                            },
                      behavior: HitTestBehavior.opaque,
                      child: Text(
                        '▸ Model ${i + 1}',
                        style: TextStyle(
                          color: isEditing ? Colors.brightCyan : Colors.gray,
                          fontWeight: isEditing ? FontWeight.bold : null,
                        ),
                      ),
                    ),
                    if (_models.length > 1)
                      GestureDetector(
                        onTap: isEditing
                            ? () => setState(() {
                                  _modelGrid.moveTo(
                                      _ModelContentFocus.removeModelBtn);
                                  _syncModelFocusedFromGrid();
                                })
                            : null,
                        behavior: HitTestBehavior.opaque,
                        child: Button(
                          label: ' ✕ Remove ',
                          onPressed: () {
                            setState(() {
                              _models.removeAt(i);
                              if (_editingModelIndex >= _models.length) {
                                _editingModelIndex = _models.length - 1;
                              }
                              if (_editingModelIndex >= 0) {
                                _loadModelFieldsFromPending(
                                    _editingModelIndex);
                              }
                            });
                          },
                          color: isEditing &&
                                  _modelFocusedArea ==
                                      _ModelFocusArea.removeModelBtn
                              ? Colors.brightCyan
                              : const Color.fromRGB(255, 80, 80),
                          hoverColor: Colors.brightYellow,
                          bgColor: cardBg,
                          hoverBgColor: const Color.fromRGB(50, 40, 70),
                          padding: const EdgeInsets.symmetric(horizontal: 0),
                        ),
                      ),
                  ],
                ),
                // Body: two-column layout
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left column — Model ID
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color: isEditing
                            ? const Color.fromRGB(40, 30, 80)
                            : const Color.fromRGB(25, 20, 45),
                        border: BoxBorder(
                          left: BorderSide(
                            color: isEditing
                                ? Colors.brightCyan
                                : const Color.fromRGB(80, 60, 120),
                          ),
                          top: const BorderSide(
                              color: Color.fromRGB(80, 60, 120)),
                          bottom: const BorderSide(
                              color: Color.fromRGB(80, 60, 120)),
                          right: const BorderSide(
                              color: Color.fromRGB(80, 60, 120)),
                        ),
                        borderRadius:
                            const BorderRadius.all(Radius.circular(1)),
                      ),
                      width: 24,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ID:',
                            style: TextStyle(color: Colors.brightCyan),
                          ),
                          if (isEditing)
                            TextField(
                              controller: _modelIdController,
                              focused: !_modelFooterActive &&
                                  _modelFocusedArea ==
                                      _ModelFocusArea.modelId,
                              onKeyEvent: _handleModelFieldKeyEvent,
                              style: const TextStyle(color: Colors.white),
                              placeholder:
                                  'e.g. gpt-4o',
                            )
                          else
                            Text(
                              m.id.isNotEmpty ? m.id : '(empty)',
                              style: TextStyle(
                                color: m.id.isNotEmpty
                                    ? Colors.white
                                    : Colors.gray,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 1),
                    // Right column — Name, Context, Toggles
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Name row
                          Row(
                            children: [
                              const Text(
                                'Name: ',
                                style: TextStyle(color: Colors.brightCyan),
                              ),
                              Expanded(
                                child: isEditing
                                    ? TextField(
                                        controller: _modelNameController,
                                        focused: !_modelFooterActive &&
                                            _modelFocusedArea ==
                                                _ModelFocusArea.modelName,
                                        onKeyEvent:
                                            _handleModelFieldKeyEvent,
                                        style: const TextStyle(
                                            color: Colors.white),
                                        placeholder:
                                            _modelIdController.text.isEmpty
                                                ? 'defaults to ID'
                                                : _modelIdController.text,
                                      )
                                    : Text(
                                        m.name.isNotEmpty
                                            ? m.name
                                            : (m.id.isNotEmpty ? m.id : ''),
                                        style: TextStyle(
                                          color: (m.name.isNotEmpty ||
                                                  m.id.isNotEmpty)
                                              ? Colors.white
                                              : Colors.gray,
                                        ),
                                      ),
                              ),
                              const Text(
                                ' (opt)',
                                style: TextStyle(color: Colors.gray),
                              ),
                            ],
                          ),
                          // Context + toggles row
                          Row(
                            children: [
                              const Text(
                                'Ctx: ',
                                style: TextStyle(color: Colors.brightCyan),
                              ),
                              SizedBox(
                                width: 6,
                                child: isEditing
                                    ? TextField(
                                        controller:
                                            _modelContextController,
                                        focused: !_modelFooterActive &&
                                            _modelFocusedArea ==
                                                _ModelFocusArea
                                                    .modelContext,
                                        onKeyEvent:
                                            _handleModelFieldKeyEvent,
                                        style: const TextStyle(
                                            color: Colors.white),
                                        placeholder: '128',
                                      )
                                    : Text(
                                        '${m.contextSize ~/ 1024}',
                                        style: const TextStyle(
                                            color: Colors.white),
                                      ),
                              ),
                              const Text('k', style: TextStyle(color: Colors.gray)),
                              const SizedBox(width: 2),
                              if (isEditing)
                                Button(
                                  label: m.imageSupport
                                      ? ' \u{F03E} ON '
                                      : ' \u{F03E} OFF ',
                                  onPressed: () {
                                    _syncModelFieldsToPending();
                                    setState(() {
                                      _modelFocusedArea = _ModelFocusArea
                                          .imageToggleBtn;
                                      m.imageSupport = !m.imageSupport;
                                    });
                                    wizardController.requestRebuild();
                                  },
                                  color: _modelFocusedArea ==
                                          _ModelFocusArea.imageToggleBtn
                                      ? Colors.brightCyan
                                      : m.imageSupport
                                          ? const Color.fromRGB(100, 220, 100)
                                          : Colors.gray,
                                  hoverColor: Colors.brightCyan,
                                  bgColor: _modelFocusedArea ==
                                          _ModelFocusArea.imageToggleBtn
                                      ? const Color.fromRGB(40, 30, 80)
                                      : cardBg,
                                  hoverBgColor: const Color.fromRGB(40, 30, 80),
                                  padding: const EdgeInsets.symmetric(horizontal: 0),
                                )
                              else
                                Text(
                                  m.imageSupport
                                      ? ' \u{F03E} ON '
                                      : ' \u{F03E} OFF ',
                                  style: TextStyle(
                                    color: m.imageSupport
                                        ? const Color.fromRGB(100, 220, 100)
                                        : Colors.gray,
                                  ),
                                ),
                              const SizedBox(width: 1),
                              if (isEditing)
                                Button(
                                  label: m.thinking
                                      ? ' \u{F085} ON '
                                      : ' \u{F085} OFF ',
                                  onPressed: () {
                                    _syncModelFieldsToPending();
                                    setState(() {
                                      _modelFocusedArea = _ModelFocusArea
                                          .thinkingToggleBtn;
                                      m.thinking = !m.thinking;
                                    });
                                    wizardController.requestRebuild();
                                  },
                                  color: _modelFocusedArea ==
                                          _ModelFocusArea.thinkingToggleBtn
                                      ? Colors.brightCyan
                                      : m.thinking
                                          ? Colors.brightYellow
                                          : Colors.gray,
                                  hoverColor: Colors.brightCyan,
                                  bgColor: _modelFocusedArea ==
                                          _ModelFocusArea.thinkingToggleBtn
                                      ? const Color.fromRGB(40, 30, 80)
                                      : cardBg,
                                  hoverBgColor: const Color.fromRGB(40, 30, 80),
                                  padding: const EdgeInsets.symmetric(horizontal: 0),
                                )
                              else
                                Text(
                                  m.thinking
                                      ? ' \u{F085} ON '
                                      : ' \u{F085} OFF ',
                                  style: TextStyle(
                                    color: m.thinking
                                        ? Colors.brightYellow
                                        : Colors.gray,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (!m.isValid() && m.id.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  const Text(
                    '⚠ Model needs a valid ID and context size.',
                    style: TextStyle(color: Colors.brightYellow),
                  ),
                ],
              ],
            ),
          ),
        );

        if (i < _models.length - 1) {
          rows.add(const SizedBox(height: 1));
        }
      }
    }

    return SingleChildScrollView(
      keyboardScrollable: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Review step
  // ═══════════════════════════════════════════════════════════════════════════

  Component _buildReviewStep() {
    final name = _nameController.text;
    final endpointUrl = _effectiveEndpoint();

    final rows = <Component>[];

    rows.add(
      const Text(
        'Review your provider configuration:',
        style: TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));
    rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));

    rows.add(
      Row(
        children: [
          const Text('  Name: ', style: TextStyle(color: Colors.brightCyan)),
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
    rows.add(
      Row(
        children: [
          const Text('  Type: ', style: TextStyle(color: Colors.brightCyan)),
          Text(
            _providerTypeDisplayName(_selectedType),
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
    );
    rows.add(
      Row(
        children: [
          const Text(
            '  Endpoint: ',
            style: TextStyle(color: Colors.brightCyan),
          ),
          Expanded(
            child: Text(
              endpointUrl,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
    rows.add(
      Row(
        children: [
          const Text('  Models: ', style: TextStyle(color: Colors.brightCyan)),
          const Text(
            'Add later via /provider modify',
            style: TextStyle(color: Colors.gray),
          ),
        ],
      ),
    );
    rows.add(
      Row(
        children: [
          const Text('  API Key: ', style: TextStyle(color: Colors.brightCyan)),
          Text(
            _apiKeyController.text.isNotEmpty
                ? '✓ Will be stored in auth.json (persists across restarts)'
                : 'Not provided (set later via /provider connect)',
            style: TextStyle(
              color: _apiKeyController.text.isNotEmpty
                  ? const Color.fromRGB(100, 220, 100)
                  : Colors.gray,
            ),
          ),
        ],
      ),
    );

    rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));

    rows.add(const SizedBox(height: 1));
    rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));
    rows.add(const SizedBox(height: 1));

    rows.add(
      const Text(
        'Press Confirm to create the provider, or Back to edit.',
        style: TextStyle(color: Colors.gray),
      ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Wizard callbacks
  // ═══════════════════════════════════════════════════════════════════════════

  void _onWizardComplete() async {
    final name = _nameController.text;
    final endpointUrl = _effectiveEndpoint();

    _syncModelFieldsToPending();
    final validModels = _models
        .where((m) => m.isValid())
        .map((m) => m.toModelConfig())
        .toList();

    final config = ProviderConfig(
      name: name,
      type: _selectedType,
      endpointUrl: endpointUrl,
      models: List.unmodifiable(validModels),
    );

    await _service.addProvider(config);

    final apiKey = _apiKeyController.text;
    if (apiKey.isNotEmpty) {
      await _service.setApiKey(name, apiKey);
    }

    component.onComplete?.call();
  }

  void _onWizardCancel() {
    component.onDismiss?.call();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Component build(BuildContext context) {
    final mergedStepValid = _validateEndpointUrl() && _validateProviderName();

    final steps = [
      WizardStep(
        title: 'Configure Provider',
        contentBuilder: _buildMergedStep,
        validate: () => mergedStepValid,
        onKeyEvent: (event) {
          if (!_isMergedOnContentBtn &&
              _mergedGrid.current != _MergedFocusArea.typeToggle) {
            return false;
          }
          if (_isMergedOnContentBtn) {
            return _handleMergedContentBtnKeyEvent(event);
          }
          return _handleMergedTypeToggleKeyEvent(event);
        },
        stepContentFocused: () =>
            !_footerActive &&
            (_isMergedOnContentBtn ||
             _mergedGrid.current == _MergedFocusArea.typeToggle),
        footerFocusIndex: _mergedFooterFocusIndex,
        onFooterKeyEvent: _handleMergedFooterKeyEvent,
      ),
      WizardStep(
        title: 'Configure Models',
        contentBuilder: _buildModelConfigStep,
        validate: _validateModels,
        onKeyEvent: _handleModelStepKeyEvent,
        stepContentFocused: () =>
            !_modelFooterActive &&
            (_modelFocusedArea == _ModelFocusArea.discoverBtn ||
             _modelFocusedArea == _ModelFocusArea.addModelBtn ||
             _modelFocusedArea == _ModelFocusArea.removeModelBtn ||
             _modelFocusedArea == _ModelFocusArea.imageToggleBtn ||
             _modelFocusedArea == _ModelFocusArea.thinkingToggleBtn),
        footerFocusIndex: _modelFooterFocusIndex,
        onFooterKeyEvent: _handleModelFooterKeyEvent,
      ),
      WizardStep(
        title: 'Review & Confirm',
        contentBuilder: _buildReviewStep,
        validate: () => true,
        isComplete: true,
        stepContentFocused: () => true,
        onFooterKeyEvent: null,
      ),
    ];

    return WizardOverlay(
      controller: wizardController,
      steps: steps,
      onComplete: _onWizardComplete,
      onCancel: _onWizardCancel,
      onStepChanged: _resetFocusForStep,
    );
  }
}
