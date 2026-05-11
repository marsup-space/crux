import 'dart:async';
import 'package:nocterm/nocterm.dart';
import 'ui/button.dart';
import 'ui/wizard_overlay.dart';
import '../models/provider_config.dart';
import '../services/provider_service.dart';

/// A temporary model entry being edited in the modify wizard.
class _EditableModel {
  String id;
  String name;
  int contextSize;
  bool imageSupport;
  bool thinking;
  int? thinkingBudget;
  String? reasoningEffortStr;
  bool removed;

  _EditableModel({
    required this.id,
    required this.name,
    required this.contextSize,
    this.imageSupport = false,
    this.thinking = false,
    this.thinkingBudget,
    this.reasoningEffortStr,
    this.removed = false,
  });

  _EditableModel.fromModelConfig(ModelConfig m)
    : id = m.id,
      name = m.name,
      contextSize = m.contextSize,
      imageSupport = m.imageSupport,
      thinking = m.thinking,
      thinkingBudget = m.thinkingBudget,
      reasoningEffortStr = m.reasoningEffort?.toConfigString(),
      removed = false;

  /// Whether this model has enough info to be included in the provider.
  ///
  /// Name is optional — if left blank, it defaults to the model ID
  /// in [toModelConfig]. Only requires a non-empty ID, valid context size,
  /// and not marked as removed.
  bool isValid() => id.isNotEmpty && contextSize > 0 && !removed;

  ModelConfig toModelConfig() {
    ReasoningEffort? effort;
    if (reasoningEffortStr != null) {
      switch (reasoningEffortStr!.toLowerCase()) {
        case 'low':
          effort = ReasoningEffort.low;
          break;
        case 'medium':
          effort = ReasoningEffort.medium;
          break;
        case 'high':
          effort = ReasoningEffort.high;
          break;
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

/// A 4-step wizard overlay for modifying an existing provider configuration.
///
/// Steps:
/// 1. **Select Provider** — pick from loaded providers; shows details.
/// 2. **Edit Endpoint & Type** — edit endpoint URL (text field) and
///    provider type (selectable list). Both pre-filled with current values.
/// 3. **Edit Models** — view current models, add new ones, or mark
///    existing ones for removal. Each model's properties can be toggled.
/// 4. **Review & Confirm** — human-readable summary of all changes
///    before committing.
///
/// Usage:
/// ```dart
/// ProviderWizardModify(
///   service: providerService,
///   onComplete: () => dismissOverlay(),
///   onDismiss: () => dismissOverlay(),
/// )
/// ```
class ProviderWizardModify extends StatefulComponent {
  final ProviderService service;
  final VoidCallback? onComplete;
  final VoidCallback? onDismiss;

  const ProviderWizardModify({
    super.key,
    required this.service,
    this.onComplete,
    this.onDismiss,
  });

  @override
  State<ProviderWizardModify> createState() => _ProviderWizardModifyState();
}

enum _DiscoverStatus { idle, discovering, discovered, failed }

enum _FocusArea {
  urlInput,
  resetDefaultBtn,
  apiKeyInput,
  showKeyBtn,
  typeList,
  backBtn,
  nextBtn,
  cancelBtn,
}

enum _ModelFocusArea {
  discoverBtn,
  addModelBtn,
  modelId,
  modelName,
  modelContext,
  imageToggleBtn,
  thinkingToggleBtn,
  backBtn,
  nextBtn,
  cancelBtn,
}

class _ProviderWizardModifyState extends State<ProviderWizardModify> {
  // ── Step 1: Provider selection ──
  int _selectedProviderIndex = -1;
  String? _selectedProviderName;
  ProviderConfig? _selectedProvider;

  // ── Step 2: Endpoint, type & API key ──
  final TextEditingController _endpointController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  bool _apiKeyObscured = true;

  /// Which input area currently has focus on the endpoint+apikey+type step.
  _FocusArea _focusedArea = _FocusArea.urlInput;

  int _selectedTypeIndex = 0;
  ProviderType _selectedType = ProviderType.openai;

  // ── Step 3: Models ──
  final List<_EditableModel> _editableModels = [];
  int _editingModelIndex = 0;

  /// Which model field currently has focus on the edit-models step.
  _ModelFocusArea _modelFocusedArea = _ModelFocusArea.modelId;

  final TextEditingController _modelIdController = TextEditingController();
  final TextEditingController _modelNameController = TextEditingController();
  final TextEditingController _modelContextController = TextEditingController(
    text: '128',
  );

  // ── Wizard controller ──
  final WizardController wizardController = WizardController();

  // ── Lifecycle guard ──
  bool _disposed = false;

  // ── Auto-discover ──
  _DiscoverStatus _discoverStatus = _DiscoverStatus.idle;
  List<DiscoveredModel> _discoveredModels = [];
  final Set<int> _selectedDiscoveredIndices = {};
  bool _showDiscoverPanel = false;

  // ── Convenience accessor ──
  ProviderService get _service => component.service;

  static const List<ProviderType> _typeOptions = [
    ProviderType.openai,
    ProviderType.anthropic,
  ];

  String _providerTypeDisplayName(ProviderType type) {
    switch (type) {
      case ProviderType.openai:
        return 'OpenAI Compatible';
      case ProviderType.anthropic:
        return 'Anthropic Compatible';
    }
  }

  String _defaultEndpoint(ProviderType type) {
    switch (type) {
      case ProviderType.openai:
        return 'https://api.openai.com/v1';
      case ProviderType.anthropic:
        return 'https://api.anthropic.com/v1';
    }
  }

  @override
  void initState() {
    super.initState();
    _endpointController.addListener(() {
      if (!_disposed) setState(() {});
    });
    _apiKeyController.addListener(() {
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
    _modelIdController.dispose();
    _modelNameController.dispose();
    _modelContextController.dispose();
    super.dispose();
  }

  /// Resets focus area variables to sensible defaults for the given step.
  ///
  /// Called by [WizardOverlay.onStepChanged] when the wizard transitions
  /// to a different step (forward or back). This ensures that when the
  /// user returns to a step they previously visited, focus lands on the
  /// first interactive element rather than wherever they left off.
  void _resetFocusForStep(int stepIndex) {
    switch (stepIndex) {
      case 0: // Select Provider — no focus areas, mouse-driven selection
        break;
      case 1: // Edit Endpoint, Type & API Key
        _focusedArea = _FocusArea.urlInput;
      case 2: // Edit Models
        _modelFocusedArea = _ModelFocusArea.modelId;
      case 3: // Review & Confirm — no focus areas to reset
        break;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  void _initFromProvider(ProviderConfig provider) {
    _endpointController.text = provider.endpointUrl;
    _selectedType = provider.type;
    _selectedTypeIndex = _typeOptions.indexOf(provider.type);
    if (_selectedTypeIndex < 0) _selectedTypeIndex = 0;

    _editableModels.clear();
    for (final m in provider.models) {
      _editableModels.add(_EditableModel.fromModelConfig(m));
    }
    if (_editableModels.isEmpty) {
      _editableModels.add(
        _EditableModel(id: '', name: '', contextSize: 131072),
      );
    }
    _editingModelIndex = 0;
    _loadModelFieldsFromPending(0);
  }

  void _syncModelFieldsToPending() {
    if (_editingModelIndex >= 0 &&
        _editingModelIndex < _editableModels.length) {
      final m = _editableModels[_editingModelIndex];
      m.id = _modelIdController.text;
      m.name = _modelNameController.text;
      m.contextSize =
          (int.tryParse(_modelContextController.text) ?? 128) * 1024;
    }
  }

  void _loadModelFieldsFromPending(int index) {
    if (index >= 0 && index < _editableModels.length) {
      final m = _editableModels[index];
      _modelIdController.text = m.id;
      _modelNameController.text = m.name;
      _modelContextController.text = (m.contextSize ~/ 1024).toString();
    }
  }

  bool _hasChanges() {
    final provider = _selectedProvider;
    if (provider == null) return false;

    // Endpoint changed?
    if (_effectiveEndpoint() != provider.endpointUrl) return true;

    // Type changed?
    if (_selectedType != provider.type) return true;

    // Models changed?
    final currentValidModels = _editableModels
        .where((m) => m.isValid())
        .toList();
    if (currentValidModels.length != provider.models.length) return true;

    for (int i = 0; i < currentValidModels.length; i++) {
      final em = currentValidModels[i];
      final pm = provider.models[i];
      if (em.id != pm.id ||
          em.name != pm.name ||
          em.contextSize != pm.contextSize ||
          em.imageSupport != pm.imageSupport ||
          em.thinking != pm.thinking) {
        return true;
      }
    }

    // Check for removed models
    if (_editableModels.any((m) => m.removed)) return true;

    return false;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Step 1: Select Provider
  // ═══════════════════════════════════════════════════════════════════════════

  void _selectProvider(int index) {
    final providers = _service.providers();
    if (index < 0 || index >= providers.length) return;
    setState(() {
      _selectedProviderIndex = index;
      _selectedProviderName = providers[index].name;
      _selectedProvider = providers[index];
      _initFromProvider(providers[index]);
    });
  }

  bool _validateSelectProvider() => _selectedProviderName != null;

  Component _buildSelectProviderStep() {
    final providers = _service.providers();
    final rows = <Component>[];

    rows.add(
      const Text(
        'Select a provider to modify:',
        style: TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    if (providers.isEmpty) {
      rows.add(
        const Text(
          'No providers configured. Use /provider add first.',
          style: TextStyle(color: Colors.gray),
        ),
      );
    } else {
      for (int i = 0; i < providers.length; i++) {
        final provider = providers[i];
        final hasKey = _service.getApiKey(provider.name) != null;
        final isSelected = i == _selectedProviderIndex;

        rows.add(
          MouseRegion(
            onEnter: (_) => setState(() => _selectedProviderIndex = i),
            opaque: false,
            child: GestureDetector(
              onTap: () => _selectProvider(i),
              behavior: HitTestBehavior.opaque,
              child: Container(
                decoration: isSelected
                    ? const BoxDecoration(color: Color.fromRGB(40, 30, 80))
                    : null,
                padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                child: Row(
                  children: [
                    Text(
                      isSelected ? '▶ ' : '  ',
                      style: TextStyle(
                        color: isSelected ? Colors.brightCyan : Colors.gray,
                      ),
                    ),
                    Text(
                      provider.name,
                      style: TextStyle(
                        color: isSelected ? Colors.brightCyan : Colors.white,
                        fontWeight: isSelected ? FontWeight.bold : null,
                      ),
                    ),
                    if (hasKey)
                      const Text(
                        ' 🔑',
                        style: TextStyle(color: Colors.brightYellow),
                      ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        '${provider.type.toConfigString()} · ${provider.endpointUrl}',
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.gray,
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

      // Details panel for the selected provider
      if (_selectedProvider != null) {
        rows.add(const SizedBox(height: 1));
        rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));
        rows.add(
          Text(
            '  Type: ${_selectedProvider!.type.toConfigString()}',
            style: const TextStyle(color: Colors.white),
          ),
        );
        rows.add(
          Text(
            '  Endpoint: ${_selectedProvider!.endpointUrl}',
            style: const TextStyle(color: Colors.white),
          ),
        );
        rows.add(
          Text(
            '  Models: ${_selectedProvider!.models.length}',
            style: const TextStyle(color: Colors.white),
          ),
        );
        rows.add(
          Text(
            '  API Key: ${_service.getApiKey(_selectedProvider!.name) != null ? "✓ Set" : "Not set"}',
            style: TextStyle(
              color: _service.getApiKey(_selectedProvider!.name) != null
                  ? const Color.fromRGB(100, 220, 100)
                  : Colors.gray,
            ),
          ),
        );
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Step 2: Edit Endpoint & Type
  // ═══════════════════════════════════════════════════════════════════════════

  bool _isValidEndpoint(String url) {
    if (url.isEmpty) return true; // empty means keep current value
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

  bool _validateEndpointAndType() {
    final url = _endpointController.text;
    return _isValidEndpoint(url);
  }

  /// Handles key events for focus traversal between URL, API Key, and type list.
  bool _handleEndpointFocusKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter) {
      wizardController.next();
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }
    // Tab or ArrowDown/Right → move focus forward (urlInput → resetDefaultBtn → apiKeyInput → showKeyBtn → typeList → backBtn → nextBtn → cancelBtn → urlInput)
    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed ||
        event.logicalKey == LogicalKey.arrowDown ||
        event.logicalKey == LogicalKey.arrowRight) {
      setState(() {
        switch (_focusedArea) {
          case _FocusArea.urlInput:
            _focusedArea = _FocusArea.resetDefaultBtn;
          case _FocusArea.resetDefaultBtn:
            _focusedArea = _FocusArea.apiKeyInput;
          case _FocusArea.apiKeyInput:
            _focusedArea = _FocusArea.showKeyBtn;
          case _FocusArea.showKeyBtn:
            _focusedArea = _FocusArea.typeList;
          case _FocusArea.typeList:
            _focusedArea = _FocusArea.backBtn;
          case _FocusArea.backBtn:
            _focusedArea = _FocusArea.nextBtn;
          case _FocusArea.nextBtn:
            _focusedArea = _FocusArea.cancelBtn;
          case _FocusArea.cancelBtn:
            _focusedArea = _FocusArea.urlInput;
        }
      });
      wizardController.requestRebuild();
      return true;
    }
    // Shift+Tab or ArrowUp/Left → move focus backward (cancelBtn → nextBtn → backBtn → typeList → showKeyBtn → apiKeyInput → resetDefaultBtn → urlInput → cancelBtn)
    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed ||
        event.logicalKey == LogicalKey.arrowUp ||
        event.logicalKey == LogicalKey.arrowLeft) {
      setState(() {
        switch (_focusedArea) {
          case _FocusArea.urlInput:
            _focusedArea = _FocusArea.cancelBtn;
          case _FocusArea.resetDefaultBtn:
            _focusedArea = _FocusArea.urlInput;
          case _FocusArea.apiKeyInput:
            _focusedArea = _FocusArea.resetDefaultBtn;
          case _FocusArea.showKeyBtn:
            _focusedArea = _FocusArea.apiKeyInput;
          case _FocusArea.typeList:
            _focusedArea = _FocusArea.showKeyBtn;
          case _FocusArea.backBtn:
            _focusedArea = _FocusArea.typeList;
          case _FocusArea.nextBtn:
            _focusedArea = _FocusArea.backBtn;
          case _FocusArea.cancelBtn:
            _focusedArea = _FocusArea.nextBtn;
        }
      });
      wizardController.requestRebuild();
      return true;
    }
    // Ctrl+B or Alt+LeftArrow → go back to previous step
    if ((event.isControlPressed && event.logicalKey == LogicalKey.keyB) ||
        (event.isAltPressed && event.logicalKey == LogicalKey.arrowLeft)) {
      wizardController.back();
      return true;
    }
    // All other keys (typing, backspace, etc.) pass through to TextField
    return false;
  }

  /// Handles key events for the step content Focusable on the endpoint step.
  ///
  /// Called when focus is on a non-TextField area within the step:
  /// - **resetDefaultBtn**: Enter/Space resets the URL to the default.
  /// - **showKeyBtn**: Enter/Space toggles key visibility.
  /// - **typeList**: arrow keys navigate the provider type list.
  /// For all other areas, returns false so overlay defaults (Enter→next,
  /// Escape→cancel) apply.
  bool _handleEndpointContentKeyEvent(KeyboardEvent event) {
    // Enter or Space → activate the focused action button
    if (event.logicalKey == LogicalKey.enter ||
        event.logicalKey == LogicalKey.space) {
      if (_focusedArea == _FocusArea.resetDefaultBtn) {
        setState(() {
          _focusedArea = _FocusArea.resetDefaultBtn;
          _endpointController.text = _defaultEndpoint(_selectedType);
        });
        wizardController.requestRebuild();
        return true;
      }
      if (_focusedArea == _FocusArea.showKeyBtn) {
        setState(() {
          _focusedArea = _FocusArea.showKeyBtn;
          _apiKeyObscured = !_apiKeyObscured;
        });
        wizardController.requestRebuild();
        return true;
      }
      // For typeList, let overlay defaults handle Enter (advance)
      return false;
    }

    // Arrow keys navigate the type list when focus is on typeList
    if (_focusedArea == _FocusArea.typeList) {
      if (event.logicalKey == LogicalKey.arrowUp) {
        setState(() {
          _selectedTypeIndex = (_selectedTypeIndex > 0)
              ? _selectedTypeIndex - 1
              : _typeOptions.length - 1;
        });
        return true;
      }
      if (event.logicalKey == LogicalKey.arrowDown) {
        setState(() {
          _selectedTypeIndex = (_selectedTypeIndex < _typeOptions.length - 1)
              ? _selectedTypeIndex + 1
              : 0;
        });
        return true;
      }
    }

    return false;
  }

  /// Handles key events for the footer Focusable on the endpoint step.
  ///
  /// Called when the footer Focusable has `focused: true` (i.e., when
  /// `_focusedArea` is backBtn, nextBtn, or cancelBtn).
  bool _handleEndpointFooterKeyEvent(KeyboardEvent event) {
    // Enter → activate focused footer button
    if (event.logicalKey == LogicalKey.enter) {
      switch (_focusedArea) {
        case _FocusArea.backBtn:
          wizardController.back();
        case _FocusArea.nextBtn:
          wizardController.next();
        case _FocusArea.cancelBtn:
          wizardController.cancel();
        default:
          break;
      }
      return true;
    }
    // Escape → cancel
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }
    // Tab or ArrowDown/Right → cycle forward: backBtn → nextBtn → cancelBtn → urlInput
    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed ||
        event.logicalKey == LogicalKey.arrowDown ||
        event.logicalKey == LogicalKey.arrowRight) {
      setState(() {
        switch (_focusedArea) {
          case _FocusArea.backBtn:
            _focusedArea = _FocusArea.nextBtn;
          case _FocusArea.nextBtn:
            _focusedArea = _FocusArea.cancelBtn;
          case _FocusArea.cancelBtn:
            _focusedArea = _FocusArea.urlInput;
          default:
            break;
        }
      });
      wizardController.requestRebuild();
      return true;
    }
    // Shift+Tab or ArrowUp/Left → cycle backward: cancelBtn → nextBtn → backBtn → apiKeyInput
    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed ||
        event.logicalKey == LogicalKey.arrowUp ||
        event.logicalKey == LogicalKey.arrowLeft) {
      setState(() {
        switch (_focusedArea) {
          case _FocusArea.cancelBtn:
            _focusedArea = _FocusArea.nextBtn;
          case _FocusArea.nextBtn:
            _focusedArea = _FocusArea.backBtn;
          case _FocusArea.backBtn:
            _focusedArea = _FocusArea.typeList;
          default:
            break;
        }
      });
      wizardController.requestRebuild();
      return true;
    }
    return false;
  }

  /// Returns the effective endpoint URL: user-provided or the current provider value.
  String _effectiveEndpoint() {
    final url = _endpointController.text;
    final provider = _selectedProvider;
    return url.isNotEmpty
        ? url
        : (provider?.endpointUrl ?? _defaultEndpoint(_selectedType));
  }

  Component _buildEndpointAndTypeStep() {
    final provider = _selectedProvider;
    if (provider == null) {
      return const Text(
        'No provider selected.',
        style: TextStyle(color: Colors.gray),
      );
    }

    final url = _endpointController.text;
    final rows = <Component>[];

    rows.add(
      const Text(
        'Edit provider settings:',
        style: TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    // ── Endpoint URL ──
    rows.add(
      const Text(
        'Endpoint URL:',
        style: TextStyle(color: Colors.brightCyan, fontWeight: FontWeight.bold),
      ),
    );
    rows.add(
      GestureDetector(
        onTap: () => setState(() => _focusedArea = _FocusArea.urlInput),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            const Text('URL: ', style: TextStyle(color: Colors.brightCyan)),
            Expanded(
              child: TextField(
                controller: _endpointController,
                focused: _focusedArea == _FocusArea.urlInput,
                onKeyEvent: _handleEndpointFocusKeyEvent,
                style: const TextStyle(color: Colors.white),
                placeholder: _defaultEndpoint(_selectedType),
              ),
            ),
          ],
        ),
      ),
    );

    // Validation feedback
    if (url.isNotEmpty) {
      rows.add(const SizedBox(height: 1));
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        rows.add(
          const Text(
            '⚠ URL must start with http:// or https://',
            style: TextStyle(color: Color.fromRGB(255, 80, 80)),
          ),
        );
      } else if (!_isValidEndpoint(url)) {
        rows.add(
          const Text(
            '⚠ URL host must be a valid domain, IP, or localhost',
            style: TextStyle(color: Color.fromRGB(255, 80, 80)),
          ),
        );
      } else if (url != provider.endpointUrl) {
        rows.add(
          const Text(
            '✓ Endpoint URL changed',
            style: TextStyle(color: Color.fromRGB(100, 220, 100)),
          ),
        );
      } else {
        rows.add(
          const Text('  (unchanged)', style: TextStyle(color: Colors.gray)),
        );
      }
    } else {
      rows.add(const SizedBox(height: 1));
      rows.add(
        Text(
          '✓ Will keep current: ${provider.endpointUrl}',
          style: const TextStyle(color: Colors.gray),
        ),
      );
    }

    rows.add(const SizedBox(height: 1));
    rows.add(
      Button(
        label: ' Reset to Default ',
        onPressed: () {
          setState(() {
            _focusedArea = _FocusArea.resetDefaultBtn;
            _endpointController.text = _defaultEndpoint(_selectedType);
          });
        },
        color: _focusedArea == _FocusArea.resetDefaultBtn
            ? Colors.brightCyan
            : Colors.gray,
        hoverColor: Colors.brightCyan,
        bgColor: _focusedArea == _FocusArea.resetDefaultBtn
            ? const Color.fromRGB(40, 30, 80)
            : const Color.fromRGB(25, 20, 45),
        hoverBgColor: const Color.fromRGB(40, 30, 80),
      ),
    );

    rows.add(const SizedBox(height: 1));
    rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));
    rows.add(const SizedBox(height: 1));

    // ── API Key ──
    rows.add(
      const Text(
        'API Key (optional — leave empty to keep current):',
        style: TextStyle(color: Colors.brightCyan, fontWeight: FontWeight.bold),
      ),
    );
    rows.add(const SizedBox(height: 1));
    rows.add(
      const Text(
        '  Stored in environment variable for this session only.',
        style: TextStyle(color: Colors.gray),
      ),
    );
    rows.add(const SizedBox(height: 1));

    rows.add(
      GestureDetector(
        onTap: () => setState(() => _focusedArea = _FocusArea.apiKeyInput),
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            const Text('Key: ', style: TextStyle(color: Colors.brightCyan)),
            Expanded(
              child: TextField(
                controller: _apiKeyController,
                focused: _focusedArea == _FocusArea.apiKeyInput,
                onKeyEvent: _handleEndpointFocusKeyEvent,
                obscureText: _apiKeyObscured,
                obscuringCharacter: '•',
                style: const TextStyle(color: Colors.white),
                placeholder: 'Paste your API key...',
              ),
            ),
          ],
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    rows.add(
      Button(
        label: _apiKeyObscured ? '👁 Show Key' : '🔒 Hide Key',
        onPressed: () => setState(() {
          _focusedArea = _FocusArea.showKeyBtn;
          _apiKeyObscured = !_apiKeyObscured;
        }),
        color: _focusedArea == _FocusArea.showKeyBtn
            ? Colors.brightCyan
            : Colors.gray,
        hoverColor: Colors.brightCyan,
        bgColor: _focusedArea == _FocusArea.showKeyBtn
            ? const Color.fromRGB(40, 30, 80)
            : const Color.fromRGB(25, 20, 45),
        hoverBgColor: const Color.fromRGB(40, 30, 80),
      ),
    );

    // Key status feedback
    final apiKey = _apiKeyController.text;
    if (apiKey.isNotEmpty) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        const Text(
          '✓ API key will be stored in CRUX_API_KEY_<PROVIDER> env var',
          style: TextStyle(color: Color.fromRGB(100, 220, 100)),
        ),
      );
    } else {
      final existingKey = _service.getApiKey(provider.name);
      rows.add(const SizedBox(height: 1));
      rows.add(
        Text(
          existingKey != null
              ? '  Current key: ✓ set (leave empty to keep)'
              : '  No key set — can add later with /provider connect',
          style: TextStyle(color: Colors.gray),
        ),
      );
    }

    rows.add(const SizedBox(height: 1));
    rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));
    rows.add(const SizedBox(height: 1));

    // ── Provider Type ──
    rows.add(
      const Text(
        'Provider Type:',
        style: TextStyle(color: Colors.brightCyan, fontWeight: FontWeight.bold),
      ),
    );

    final descriptions = {
      ProviderType.openai: 'Chat completions API (OpenAI, Ollama, vLLM, etc.)',
      ProviderType.anthropic: 'Messages API (Claude, etc.)',
    };

    for (int i = 0; i < _typeOptions.length; i++) {
      final type = _typeOptions[i];
      final isSelected = i == _selectedTypeIndex;

      rows.add(
        MouseRegion(
          onEnter: (_) => setState(() => _selectedTypeIndex = i),
          opaque: false,
          child: GestureDetector(
            onTap: () {
              setState(() {
                _selectedTypeIndex = i;
                _selectedType = _typeOptions[i];
              });
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              decoration: isSelected
                  ? const BoxDecoration(color: Color.fromRGB(40, 30, 80))
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
              child: Row(
                children: [
                  Text(
                    isSelected ? '▶ ' : '  ',
                    style: TextStyle(
                      color: isSelected ? Colors.brightCyan : Colors.gray,
                    ),
                  ),
                  Text(
                    _providerTypeDisplayName(type),
                    style: TextStyle(
                      color: isSelected ? Colors.brightCyan : Colors.white,
                      fontWeight: isSelected ? FontWeight.bold : null,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      descriptions[type] ?? '',
                      style: TextStyle(
                        color: isSelected ? Colors.white : Colors.gray,
                      ),
                    ),
                  ),
                  if (type == provider.type && type == _selectedType)
                    const Text(
                      '(current)',
                      style: TextStyle(color: Colors.gray),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // Change indicator
    rows.add(const SizedBox(height: 1));
    if (_selectedType != provider.type) {
      rows.add(
        Text(
          '⚠ Type will change from ${_providerTypeDisplayName(provider.type)} '
          'to ${_providerTypeDisplayName(_selectedType)}',
          style: const TextStyle(color: Colors.brightYellow),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Step 3: Edit Models
  // ═══════════════════════════════════════════════════════════════════════════

  /// Handles key events for focus traversal between model ID, name, and context fields.
  bool _handleModelFieldKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter) {
      wizardController.next();
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }
    // Tab or ArrowDown/Right → move focus forward (discoverBtn → addModelBtn → modelId → modelName → modelContext → imageToggleBtn → thinkingToggleBtn → backBtn → nextBtn → cancelBtn → discoverBtn)
    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed ||
        event.logicalKey == LogicalKey.arrowDown ||
        event.logicalKey == LogicalKey.arrowRight) {
      setState(() {
        switch (_modelFocusedArea) {
          case _ModelFocusArea.discoverBtn:
            _modelFocusedArea = _ModelFocusArea.addModelBtn;
          case _ModelFocusArea.addModelBtn:
            _modelFocusedArea = _ModelFocusArea.modelId;
          case _ModelFocusArea.modelId:
            _modelFocusedArea = _ModelFocusArea.modelName;
          case _ModelFocusArea.modelName:
            _modelFocusedArea = _ModelFocusArea.modelContext;
          case _ModelFocusArea.modelContext:
            _modelFocusedArea = _ModelFocusArea.imageToggleBtn;
          case _ModelFocusArea.imageToggleBtn:
            _modelFocusedArea = _ModelFocusArea.thinkingToggleBtn;
          case _ModelFocusArea.thinkingToggleBtn:
            _modelFocusedArea = _ModelFocusArea.backBtn;
          case _ModelFocusArea.backBtn:
            _modelFocusedArea = _ModelFocusArea.nextBtn;
          case _ModelFocusArea.nextBtn:
            _modelFocusedArea = _ModelFocusArea.cancelBtn;
          case _ModelFocusArea.cancelBtn:
            _modelFocusedArea = _ModelFocusArea.discoverBtn;
        }
      });
      wizardController.requestRebuild();
      return true;
    }
    // Shift+Tab or ArrowUp/Left → move focus backward (cancelBtn → nextBtn → backBtn → thinkingToggleBtn → imageToggleBtn → modelContext → modelName → modelId → addModelBtn → discoverBtn → cancelBtn)
    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed ||
        event.logicalKey == LogicalKey.arrowUp ||
        event.logicalKey == LogicalKey.arrowLeft) {
      setState(() {
        switch (_modelFocusedArea) {
          case _ModelFocusArea.cancelBtn:
            _modelFocusedArea = _ModelFocusArea.nextBtn;
          case _ModelFocusArea.nextBtn:
            _modelFocusedArea = _ModelFocusArea.backBtn;
          case _ModelFocusArea.backBtn:
            _modelFocusedArea = _ModelFocusArea.thinkingToggleBtn;
          case _ModelFocusArea.thinkingToggleBtn:
            _modelFocusedArea = _ModelFocusArea.imageToggleBtn;
          case _ModelFocusArea.imageToggleBtn:
            _modelFocusedArea = _ModelFocusArea.modelContext;
          case _ModelFocusArea.modelContext:
            _modelFocusedArea = _ModelFocusArea.modelName;
          case _ModelFocusArea.modelName:
            _modelFocusedArea = _ModelFocusArea.modelId;
          case _ModelFocusArea.modelId:
            _modelFocusedArea = _ModelFocusArea.addModelBtn;
          case _ModelFocusArea.addModelBtn:
            _modelFocusedArea = _ModelFocusArea.discoverBtn;
          case _ModelFocusArea.discoverBtn:
            _modelFocusedArea = _ModelFocusArea.cancelBtn;
        }
      });
      wizardController.requestRebuild();
      return true;
    }
    // Ctrl+B or Alt+LeftArrow → go back to previous step
    if ((event.isControlPressed && event.logicalKey == LogicalKey.keyB) ||
        (event.isAltPressed && event.logicalKey == LogicalKey.arrowLeft)) {
      wizardController.back();
      return true;
    }
    // All other keys (typing, backspace, etc.) pass through to TextField
    return false;
  }

  /// Key event handler for the model step when focus is on a button or footer area.
  ///
  /// Called by the wizard overlay's Focusable. The overlay delegates ALL
  /// key events to the step's onKeyEvent first; if it returns true,
  /// the overlay does nothing further.
  ///
  /// When focus is on a toggle or footer button:
  /// - **Enter**: activates the focused button (toggle image/thinking,
  ///   or navigate back/next/cancel).
  /// - **Tab / ArrowDown**: cycles focus forward through areas.
  /// - **Shift+Tab / ArrowUp**: cycles focus backward through areas.
  /// - **Space**: activates toggle buttons (toggles image/thinking).
  bool _handleModelStepKeyEvent(KeyboardEvent event) {
    // Only handle keys when focus is on a button or footer area
    final isOnButtonArea =
        _modelFocusedArea == _ModelFocusArea.discoverBtn ||
        _modelFocusedArea == _ModelFocusArea.addModelBtn ||
        _modelFocusedArea == _ModelFocusArea.imageToggleBtn ||
        _modelFocusedArea == _ModelFocusArea.thinkingToggleBtn ||
        _modelFocusedArea == _ModelFocusArea.backBtn ||
        _modelFocusedArea == _ModelFocusArea.nextBtn ||
        _modelFocusedArea == _ModelFocusArea.cancelBtn;
    if (!isOnButtonArea) {
      return false;
    }

    // Enter → activate focused button
    if (event.logicalKey == LogicalKey.enter) {
      switch (_modelFocusedArea) {
        case _ModelFocusArea.discoverBtn:
          setState(() {
            _showDiscoverPanel = !_showDiscoverPanel;
            if (_showDiscoverPanel && _discoverStatus == _DiscoverStatus.idle) {
              _discoverModels();
            }
          });
        case _ModelFocusArea.addModelBtn:
          _syncModelFieldsToPending();
          setState(() {
            _editableModels.add(
              _EditableModel(id: '', name: '', contextSize: 131072),
            );
            _editingModelIndex = _editableModels.length - 1;
            _modelFocusedArea = _ModelFocusArea.modelId;
            _loadModelFieldsFromPending(_editingModelIndex);
          });
        case _ModelFocusArea.backBtn:
          wizardController.back();
        case _ModelFocusArea.nextBtn:
          wizardController.next();
        case _ModelFocusArea.cancelBtn:
          wizardController.cancel();
        case _ModelFocusArea.imageToggleBtn:
          if (_editingModelIndex >= 0 &&
              _editingModelIndex < _editableModels.length) {
            final m = _editableModels[_editingModelIndex];
            _syncModelFieldsToPending();
            setState(() {
              m.imageSupport = !m.imageSupport;
            });
          }
        case _ModelFocusArea.thinkingToggleBtn:
          if (_editingModelIndex >= 0 &&
              _editingModelIndex < _editableModels.length) {
            final m = _editableModels[_editingModelIndex];
            _syncModelFieldsToPending();
            setState(() {
              m.thinking = !m.thinking;
            });
          }
        default:
          break;
      }
      return true;
    }

    // Tab or ArrowDown/Right → cycle forward
    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed ||
        event.logicalKey == LogicalKey.arrowDown ||
        event.logicalKey == LogicalKey.arrowRight) {
      setState(() {
        switch (_modelFocusedArea) {
          case _ModelFocusArea.discoverBtn:
            _modelFocusedArea = _ModelFocusArea.addModelBtn;
          case _ModelFocusArea.addModelBtn:
            _modelFocusedArea = _ModelFocusArea.modelId;
          case _ModelFocusArea.imageToggleBtn:
            _modelFocusedArea = _ModelFocusArea.thinkingToggleBtn;
          case _ModelFocusArea.thinkingToggleBtn:
            _modelFocusedArea = _ModelFocusArea.backBtn;
          case _ModelFocusArea.backBtn:
            _modelFocusedArea = _ModelFocusArea.nextBtn;
          case _ModelFocusArea.nextBtn:
            _modelFocusedArea = _ModelFocusArea.cancelBtn;
          case _ModelFocusArea.cancelBtn:
            _modelFocusedArea = _ModelFocusArea.discoverBtn;
          default:
            break;
        }
      });
      wizardController.requestRebuild();
      return true;
    }

    // Shift+Tab or ArrowUp/Left → cycle backward
    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed ||
        event.logicalKey == LogicalKey.arrowUp ||
        event.logicalKey == LogicalKey.arrowLeft) {
      setState(() {
        switch (_modelFocusedArea) {
          case _ModelFocusArea.cancelBtn:
            _modelFocusedArea = _ModelFocusArea.nextBtn;
          case _ModelFocusArea.nextBtn:
            _modelFocusedArea = _ModelFocusArea.backBtn;
          case _ModelFocusArea.backBtn:
            _modelFocusedArea = _ModelFocusArea.thinkingToggleBtn;
          case _ModelFocusArea.thinkingToggleBtn:
            _modelFocusedArea = _ModelFocusArea.imageToggleBtn;
          case _ModelFocusArea.imageToggleBtn:
            _modelFocusedArea = _ModelFocusArea.modelContext;
          case _ModelFocusArea.modelContext:
            _modelFocusedArea = _ModelFocusArea.modelName;
          case _ModelFocusArea.modelName:
            _modelFocusedArea = _ModelFocusArea.modelId;
          case _ModelFocusArea.modelId:
            _modelFocusedArea = _ModelFocusArea.addModelBtn;
          case _ModelFocusArea.addModelBtn:
            _modelFocusedArea = _ModelFocusArea.discoverBtn;
          case _ModelFocusArea.discoverBtn:
            _modelFocusedArea = _ModelFocusArea.cancelBtn;
        }
      });
      wizardController.requestRebuild();
      return true;
    }

    // Space → activate action and toggle buttons (not footer buttons)
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
          _editableModels.add(
            _EditableModel(id: '', name: '', contextSize: 131072),
          );
          _editingModelIndex = _editableModels.length - 1;
          _modelFocusedArea = _ModelFocusArea.modelId;
          _loadModelFieldsFromPending(_editingModelIndex);
        });
        return true;
      }
      if (_modelFocusedArea == _ModelFocusArea.imageToggleBtn ||
          _modelFocusedArea == _ModelFocusArea.thinkingToggleBtn) {
        if (_editingModelIndex >= 0 &&
            _editingModelIndex < _editableModels.length) {
          final m = _editableModels[_editingModelIndex];
          _syncModelFieldsToPending();
          setState(() {
            if (_modelFocusedArea == _ModelFocusArea.imageToggleBtn) {
              m.imageSupport = !m.imageSupport;
            } else if (_modelFocusedArea == _ModelFocusArea.thinkingToggleBtn) {
              m.thinking = !m.thinking;
            }
          });
        }
        return true;
      }
      return false;
    }

    return false;
  }

  /// Handles key events for the footer Focusable on the models step.
  ///
  /// Called when the footer Focusable has `focused: true` (i.e., when
  /// `_modelFocusedArea` is backBtn, nextBtn, or cancelBtn).
  bool _handleModelFooterKeyEvent(KeyboardEvent event) {
    // Enter → activate focused footer button
    if (event.logicalKey == LogicalKey.enter) {
      switch (_modelFocusedArea) {
        case _ModelFocusArea.backBtn:
          wizardController.back();
        case _ModelFocusArea.nextBtn:
          wizardController.next();
        case _ModelFocusArea.cancelBtn:
          wizardController.cancel();
        default:
          break;
      }
      return true;
    }
    // Escape → cancel
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }
    // Tab or ArrowDown/Right → cycle forward: backBtn → nextBtn → cancelBtn → discoverBtn
    if (event.logicalKey == LogicalKey.tab && !event.isShiftPressed ||
        event.logicalKey == LogicalKey.arrowDown ||
        event.logicalKey == LogicalKey.arrowRight) {
      setState(() {
        switch (_modelFocusedArea) {
          case _ModelFocusArea.backBtn:
            _modelFocusedArea = _ModelFocusArea.nextBtn;
          case _ModelFocusArea.nextBtn:
            _modelFocusedArea = _ModelFocusArea.cancelBtn;
          case _ModelFocusArea.cancelBtn:
            _modelFocusedArea = _ModelFocusArea.discoverBtn;
          default:
            break;
        }
      });
      wizardController.requestRebuild();
      return true;
    }
    // Shift+Tab or ArrowUp/Left → cycle backward: cancelBtn → nextBtn → backBtn → thinkingToggleBtn
    if (event.logicalKey == LogicalKey.tab && event.isShiftPressed ||
        event.logicalKey == LogicalKey.arrowUp ||
        event.logicalKey == LogicalKey.arrowLeft) {
      setState(() {
        switch (_modelFocusedArea) {
          case _ModelFocusArea.cancelBtn:
            _modelFocusedArea = _ModelFocusArea.nextBtn;
          case _ModelFocusArea.nextBtn:
            _modelFocusedArea = _ModelFocusArea.backBtn;
          case _ModelFocusArea.backBtn:
            _modelFocusedArea = _ModelFocusArea.thinkingToggleBtn;
          default:
            break;
        }
      });
      wizardController.requestRebuild();
      return true;
    }
    return false;
  }

  bool _validateModels() {
    final validModels = _editableModels.where((m) => m.isValid()).toList();
    // If auto-discover is showing, check if we have selections or valid manual models
    if (_showDiscoverPanel && _discoverStatus == _DiscoverStatus.discovered) {
      return _selectedDiscoveredIndices.isNotEmpty || validModels.isNotEmpty;
    }
    return validModels.isNotEmpty;
  }

  /// Auto-discover models from the provider endpoint.
  Future<void> _discoverModels() async {
    setState(() {
      _discoverStatus = _DiscoverStatus.discovering;
    });

    try {
      final provider = _selectedProvider;
      if (provider == null) {
        setState(() {
          _discoverStatus = _DiscoverStatus.failed;
          _discoveredModels = [];
        });
        return;
      }

      final models = await _service.discoverModels(provider.name);
      if (_disposed) return;
      setState(() {
        _discoveredModels = models;
        _discoverStatus = models.isNotEmpty
            ? _DiscoverStatus.discovered
            : _DiscoverStatus.failed;
      });
    } catch (e) {
      if (_disposed) return;
      setState(() {
        _discoverStatus = _DiscoverStatus.failed;
        _discoveredModels = [];
      });
    }
  }

  Component _buildEditModelsStep() {
    final provider = _selectedProvider;
    if (provider == null) {
      return const Text(
        'No provider selected.',
        style: TextStyle(color: Colors.gray),
      );
    }

    _syncModelFieldsToPending();
    final rows = <Component>[];

    rows.add(
      const Text(
        'Edit models:',
        style: TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    // ── Action buttons ──
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
            },
            color: _modelFocusedArea == _ModelFocusArea.discoverBtn
                ? Colors.brightCyan
                : _showDiscoverPanel
                ? Colors.brightYellow
                : Colors.brightCyan,
            hoverColor: Colors.brightCyan,
            bgColor: _modelFocusedArea == _ModelFocusArea.discoverBtn
                ? const Color.fromRGB(40, 30, 80)
                : const Color.fromRGB(25, 20, 45),
            hoverBgColor: const Color.fromRGB(40, 30, 80),
          ),
          const SizedBox(width: 2),
          Button(
            label: ' ➕ Add New Model ',
            onPressed: () {
              _syncModelFieldsToPending();
              setState(() {
                _modelFocusedArea = _ModelFocusArea.addModelBtn;
                _editableModels.add(
                  _EditableModel(id: '', name: '', contextSize: 131072),
                );
                _editingModelIndex = _editableModels.length - 1;
                _loadModelFieldsFromPending(_editingModelIndex);
              });
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
    rows.add(const SizedBox(height: 1));

    // ── Auto-discover panel ──
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
          break;

        case _DiscoverStatus.discovering:
          rows.add(
            const Text(
              '  Discovering models...',
              style: TextStyle(color: Colors.brightYellow),
            ),
          );
          break;

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
                          isSelected ? '✓ ' : '  ',
                          style: TextStyle(
                            color: isSelected ? Colors.brightCyan : Colors.gray,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            dm.id,
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.brightCyan
                                  : Colors.white,
                            ),
                          ),
                        ),
                        if (dm.contextSize != null)
                          Text(
                            'ctx:${dm.contextSize! ~/ 1024}k',
                            style: const TextStyle(color: Colors.gray),
                          ),
                        if (dm.imageSupport ?? false)
                          const Text(
                            ' 🖼',
                            style: TextStyle(color: Colors.brightCyan),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }

          // Apply discovered models button
          if (_selectedDiscoveredIndices.isNotEmpty) {
            rows.add(const SizedBox(height: 1));
            rows.add(
              Button(
                label: ' ✓ Apply Selected Models ',
                onPressed: () {
                  setState(() {
                    for (final idx in _selectedDiscoveredIndices) {
                      final dm = _discoveredModels[idx];
                      _editableModels.add(
                        _EditableModel(
                          id: dm.id,
                          name: dm.name ?? dm.id,
                          contextSize: dm.contextSize ?? 131072,
                          imageSupport: dm.imageSupport ?? false,
                        ),
                      );
                    }
                    _selectedDiscoveredIndices.clear();
                    _showDiscoverPanel = false;
                    _editingModelIndex = _editableModels.length - 1;
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
          break;

        case _DiscoverStatus.failed:
          rows.add(
            const Text(
              '  ✕ Discovery failed. Check your endpoint and API key.',
              style: TextStyle(color: Color.fromRGB(255, 80, 80)),
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
          break;
      }

      rows.add(const SizedBox(height: 1));
      rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));
      rows.add(const SizedBox(height: 1));
    }

    rows.add(const SizedBox(height: 1));

    // ── Model cards ──

    final activeModels = _editableModels.where((m) => !m.removed).toList();
    final removedModels = _editableModels.where((m) => m.removed).toList();

    if (activeModels.isEmpty && removedModels.isEmpty) {
      rows.add(
        const Text(
          '  No models. Add one above.',
          style: TextStyle(color: Colors.gray),
        ),
      );
    } else {
      int renderedCount = 0;
      for (int i = 0; i < _editableModels.length; i++) {
        final m = _editableModels[i];
        if (m.removed) continue;

        final isEditing = i == _editingModelIndex;
        final isNew = !provider.models.any((pm) => pm.id == m.id);
        final displayName = m.name.isNotEmpty ? m.name : m.id;

        if (isEditing) {
          // ── Expanded card: full form fields ──
          rows.add(
            Container(
              decoration: const BoxDecoration(
                color: Color.fromRGB(35, 28, 55),
                border: BoxBorder(
                  left: BorderSide(color: Colors.brightCyan),
                  top: BorderSide(color: Color.fromRGB(80, 60, 120)),
                  bottom: BorderSide(color: Color.fromRGB(80, 60, 120)),
                ),
              ),
              padding: const EdgeInsets.all(1),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row: model number + ✨ if new + remove button
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Text(
                            '▸ Model ${i + 1}',
                            style: const TextStyle(
                              color: Colors.brightCyan,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (isNew)
                            const Text(
                              ' ✨',
                              style: TextStyle(
                                color: Color.fromRGB(100, 220, 100),
                              ),
                            ),
                        ],
                      ),
                      Button(
                        label: ' ✕ Remove ',
                        onPressed: () {
                          setState(() {
                            m.removed = true;
                            // Move editing index to next valid model
                            final nextValid = _editableModels
                                .asMap()
                                .entries
                                .where((e) => !e.value.removed)
                                .map((e) => e.key)
                                .toList();
                            if (nextValid.isNotEmpty) {
                              _editingModelIndex = nextValid.first;
                              _loadModelFieldsFromPending(_editingModelIndex);
                            }
                          });
                        },
                        color: const Color.fromRGB(255, 80, 80),
                        hoverColor: Colors.brightYellow,
                        bgColor: const Color.fromRGB(35, 28, 55),
                        hoverBgColor: const Color.fromRGB(50, 40, 70),
                        padding: const EdgeInsets.symmetric(horizontal: 0),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),

                  // ID field
                  GestureDetector(
                    onTap: () => setState(
                      () => _modelFocusedArea = _ModelFocusArea.modelId,
                    ),
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        const Text(
                          'ID: ',
                          style: TextStyle(color: Colors.brightCyan),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _modelIdController,
                            focused:
                                _modelFocusedArea == _ModelFocusArea.modelId,
                            onKeyEvent: _handleModelFieldKeyEvent,
                            style: const TextStyle(color: Colors.white),
                            placeholder: 'e.g. gpt-4o, claude-3-5-sonnet',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 1),

                  // Name field (optional — placeholder shows model ID)
                  GestureDetector(
                    onTap: () => setState(
                      () => _modelFocusedArea = _ModelFocusArea.modelName,
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
                            controller: _modelNameController,
                            focused:
                                _modelFocusedArea == _ModelFocusArea.modelName,
                            onKeyEvent: _handleModelFieldKeyEvent,
                            style: const TextStyle(color: Colors.white),
                            placeholder: _modelIdController.text.isEmpty
                                ? 'defaults to ID'
                                : _modelIdController.text,
                          ),
                        ),
                        const Text(
                          ' (optional)',
                          style: TextStyle(color: Colors.gray),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 1),

                  // Context Size field (in k)
                  GestureDetector(
                    onTap: () => setState(
                      () => _modelFocusedArea = _ModelFocusArea.modelContext,
                    ),
                    behavior: HitTestBehavior.opaque,
                    child: Row(
                      children: [
                        const Text(
                          'Context (k): ',
                          style: TextStyle(color: Colors.brightCyan),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _modelContextController,
                            focused:
                                _modelFocusedArea ==
                                _ModelFocusArea.modelContext,
                            onKeyEvent: _handleModelFieldKeyEvent,
                            style: const TextStyle(color: Colors.white),
                            placeholder: '128',
                          ),
                        ),
                        const Text(
                          'k tokens',
                          style: TextStyle(color: Colors.gray),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 1),

                  // Toggle buttons row
                  Row(
                    children: [
                      Button(
                        label: m.imageSupport
                            ? ' 🖼 Images: ON '
                            : ' 🖼 Images: OFF ',
                        onPressed: () {
                          _syncModelFieldsToPending();
                          setState(() {
                            _modelFocusedArea = _ModelFocusArea.imageToggleBtn;
                            m.imageSupport = !m.imageSupport;
                          });
                          wizardController.requestRebuild();
                        },
                        color:
                            _modelFocusedArea == _ModelFocusArea.imageToggleBtn
                            ? Colors.brightCyan
                            : m.imageSupport
                            ? const Color.fromRGB(100, 220, 100)
                            : Colors.gray,
                        hoverColor: Colors.brightCyan,
                        bgColor:
                            _modelFocusedArea == _ModelFocusArea.imageToggleBtn
                            ? const Color.fromRGB(40, 30, 80)
                            : const Color.fromRGB(35, 28, 55),
                        hoverBgColor: const Color.fromRGB(40, 30, 80),
                        padding: const EdgeInsets.symmetric(horizontal: 0),
                      ),
                      const SizedBox(width: 1),
                      Button(
                        label: m.thinking
                            ? ' 💭 Thinking: ON '
                            : ' 💭 Thinking: OFF ',
                        onPressed: () {
                          _syncModelFieldsToPending();
                          setState(() {
                            _modelFocusedArea =
                                _ModelFocusArea.thinkingToggleBtn;
                            m.thinking = !m.thinking;
                          });
                          wizardController.requestRebuild();
                        },
                        color:
                            _modelFocusedArea ==
                                _ModelFocusArea.thinkingToggleBtn
                            ? Colors.brightCyan
                            : m.thinking
                            ? Colors.brightYellow
                            : Colors.gray,
                        hoverColor: Colors.brightCyan,
                        bgColor:
                            _modelFocusedArea ==
                                _ModelFocusArea.thinkingToggleBtn
                            ? const Color.fromRGB(40, 30, 80)
                            : const Color.fromRGB(35, 28, 55),
                        hoverBgColor: const Color.fromRGB(40, 30, 80),
                        padding: const EdgeInsets.symmetric(horizontal: 0),
                      ),
                    ],
                  ),

                  // Validation feedback for incomplete model
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
        } else {
          // ── Collapsed card: summary row ──
          rows.add(
            MouseRegion(
              onEnter: (_) => setState(() {}),
              opaque: false,
              child: GestureDetector(
                onTap: () {
                  _syncModelFieldsToPending();
                  setState(() {
                    _editingModelIndex = i;
                    _modelFocusedArea = _ModelFocusArea.modelId;
                    _loadModelFieldsFromPending(i);
                  });
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  decoration: const BoxDecoration(
                    color: Color.fromRGB(30, 25, 50),
                    border: BoxBorder(
                      left: BorderSide(color: Color.fromRGB(80, 60, 120)),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 1,
                    vertical: 0,
                  ),
                  child: Row(
                    children: [
                      Text('  ', style: const TextStyle(color: Colors.gray)),
                      if (isNew)
                        const Text(
                          '✨ ',
                          style: TextStyle(color: Color.fromRGB(100, 220, 100)),
                        ),
                      Expanded(
                        child: Text(
                          m.isValid()
                              ? '${m.id} · ${displayName} · ctx:${m.contextSize ~/ 1024}k'
                              : '${m.id.isNotEmpty ? m.id : "(empty)"} · incomplete',
                          style: TextStyle(
                            color: m.isValid() ? Colors.white : Colors.gray,
                          ),
                        ),
                      ),
                      if (m.imageSupport)
                        const Text(
                          ' 🖼',
                          style: TextStyle(color: Colors.brightCyan),
                        ),
                      if (m.thinking)
                        const Text(
                          ' 💭',
                          style: TextStyle(color: Colors.brightYellow),
                        ),
                      Button(
                        label: ' ✕ ',
                        onPressed: () {
                          setState(() {
                            m.removed = true;
                            // Move editing index to next valid model
                            final nextValid = _editableModels
                                .asMap()
                                .entries
                                .where((e) => !e.value.removed)
                                .map((e) => e.key)
                                .toList();
                            if (nextValid.isNotEmpty) {
                              _editingModelIndex = nextValid.first;
                              _loadModelFieldsFromPending(_editingModelIndex);
                            }
                          });
                        },
                        color: const Color.fromRGB(255, 80, 80),
                        hoverColor: Colors.brightYellow,
                        bgColor: const Color.fromRGB(30, 25, 50),
                        hoverBgColor: const Color.fromRGB(40, 30, 80),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 0,
                          vertical: 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        // Spacing between cards
        renderedCount++;
        if (renderedCount < activeModels.length) {
          rows.add(const SizedBox(height: 1));
        }
      }

      // Removed models (with undo option)
      if (removedModels.isNotEmpty) {
        rows.add(const SizedBox(height: 1));
        rows.add(
          const Text(
            'Removed models:',
            style: TextStyle(
              color: Color.fromRGB(255, 80, 80),
              fontWeight: FontWeight.bold,
            ),
          ),
        );

        for (int i = 0; i < _editableModels.length; i++) {
          final m = _editableModels[i];
          if (!m.removed) continue;

          rows.add(
            Row(
              children: [
                const Text(
                  '  ✗ ',
                  style: TextStyle(color: Color.fromRGB(255, 80, 80)),
                ),
                Expanded(
                  child: Text(
                    '${m.id} (${m.name.isNotEmpty ? m.name : m.id})',
                    style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
                  ),
                ),
                Button(
                  label: ' ↩ Undo ',
                  onPressed: () {
                    setState(() {
                      m.removed = false;
                      _editingModelIndex = i;
                      _loadModelFieldsFromPending(i);
                    });
                  },
                  color: const Color.fromRGB(100, 220, 100),
                  hoverColor: Colors.brightCyan,
                  bgColor: const Color.fromRGB(25, 20, 45),
                  hoverBgColor: const Color.fromRGB(40, 30, 80),
                  padding: const EdgeInsets.symmetric(horizontal: 0),
                ),
              ],
            ),
          );
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
  // Step 4: Review & Confirm
  // ═══════════════════════════════════════════════════════════════════════════

  Component _buildReviewStep() {
    final provider = _selectedProvider;
    if (provider == null) {
      return const Text(
        'No provider selected.',
        style: TextStyle(color: Colors.gray),
      );
    }

    _syncModelFieldsToPending();
    final endpointUrl = _effectiveEndpoint();
    final validModels = _editableModels.where((m) => m.isValid()).toList();
    final removedModels = _editableModels.where((m) => m.removed).toList();

    final rows = <Component>[];

    rows.add(
      const Text(
        'Review your changes:',
        style: TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));

    // ── Provider settings ──
    rows.add(
      Row(
        children: [
          const Text('  Name: ', style: TextStyle(color: Colors.brightCyan)),
          Text(
            provider.name,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );

    // Type change
    rows.add(
      Row(
        children: [
          const Text('  Type: ', style: TextStyle(color: Colors.brightCyan)),
          Text(
            _providerTypeDisplayName(_selectedType),
            style: const TextStyle(color: Colors.white),
          ),
          if (_selectedType != provider.type)
            Text(
              ' (was ${_providerTypeDisplayName(provider.type)})',
              style: const TextStyle(color: Colors.brightYellow),
            ),
        ],
      ),
    );

    // Endpoint change
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
          if (endpointUrl != provider.endpointUrl)
            const Text(
              ' (changed)',
              style: TextStyle(color: Colors.brightYellow),
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
                ? '✓ Will be stored in CRUX_API_KEY_<PROVIDER> env var'
                : _service.getApiKey(provider.name) != null
                ? '✓ Current key kept'
                : 'Not set',
            style: TextStyle(
              color:
                  _apiKeyController.text.isNotEmpty ||
                      _service.getApiKey(provider.name) != null
                  ? const Color.fromRGB(100, 220, 100)
                  : Colors.gray,
            ),
          ),
        ],
      ),
    );

    rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));

    // ── Model changes ──
    rows.add(const SizedBox(height: 1));
    rows.add(
      Text(
        '  Models: ${validModels.length} active, ${removedModels.length} removed',
        style: const TextStyle(color: Colors.brightCyan),
      ),
    );

    // New models
    final newModels = validModels
        .where((m) => !provider.models.any((pm) => pm.id == m.id))
        .toList();
    if (newModels.isNotEmpty) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        const Text(
          '  ✨ New models:',
          style: TextStyle(
            color: Color.fromRGB(100, 220, 100),
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      for (final m in newModels) {
        rows.add(
          Text(
            '    + ${m.id} (${m.name.isNotEmpty ? m.name : m.id}) ctx:${m.contextSize ~/ 1024}k'
            '${m.imageSupport ? " 🖼" : ""}'
            '${m.thinking ? " 💭" : ""}',
            style: const TextStyle(color: Color.fromRGB(100, 220, 100)),
          ),
        );
      }
    }

    // Removed models
    if (removedModels.isNotEmpty) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        const Text(
          '  ✗ Removed models:',
          style: TextStyle(
            color: Color.fromRGB(255, 80, 80),
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      for (final m in removedModels) {
        rows.add(
          Text(
            '    - ${m.id} (${m.name.isNotEmpty ? m.name : m.id})',
            style: const TextStyle(color: Color.fromRGB(255, 80, 80)),
          ),
        );
      }
    }

    // Modified existing models
    final modifiedModels = validModels
        .where(
          (m) =>
              !m.removed &&
              provider.models.any((pm) => pm.id == m.id) &&
              _isModelModified(m, provider),
        )
        .toList();
    if (modifiedModels.isNotEmpty) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        const Text(
          '  ✎ Modified models:',
          style: TextStyle(
            color: Colors.brightYellow,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      for (final m in modifiedModels) {
        final pm = provider.models.firstWhere((pm) => pm.id == m.id);
        rows.add(
          Text(
            '    ~ ${m.id} (${m.name.isNotEmpty ? m.name : m.id}) ctx:${m.contextSize ~/ 1024}k'
            '${m.imageSupport ? " 🖼" : ""}'
            '${m.thinking ? " 💭" : ""}',
            style: const TextStyle(color: Colors.brightYellow),
          ),
        );
        // Show specific changes
        final changes = <String>[];
        if ((m.name.isNotEmpty ? m.name : m.id) != pm.name)
          changes.add(
            'name: ${pm.name} → ${m.name.isNotEmpty ? m.name : m.id}',
          );
        if (m.contextSize != pm.contextSize)
          changes.add(
            'ctx: ${pm.contextSize ~/ 1024}k → ${m.contextSize ~/ 1024}k',
          );
        if (m.imageSupport != pm.imageSupport)
          changes.add('img: ${pm.imageSupport} → ${m.imageSupport}');
        if (m.thinking != pm.thinking)
          changes.add('think: ${pm.thinking} → ${m.thinking}');
        if (changes.isNotEmpty) {
          rows.add(
            Text(
              '      Changes: ${changes.join(", ")}',
              style: const TextStyle(color: Colors.gray),
            ),
          );
        }
      }
    }

    // Unchanged models
    final unchangedModels = validModels
        .where(
          (m) =>
              !m.removed &&
              provider.models.any((pm) => pm.id == m.id) &&
              !_isModelModified(m, provider),
        )
        .toList();
    if (unchangedModels.isNotEmpty) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        const Text('  Unchanged models:', style: TextStyle(color: Colors.gray)),
      );
      for (final m in unchangedModels) {
        rows.add(
          Text('    = ${m.id}', style: const TextStyle(color: Colors.gray)),
        );
      }
    }

    rows.add(const SizedBox(height: 1));
    rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));
    rows.add(const SizedBox(height: 1));

    if (_hasChanges()) {
      rows.add(
        const Text(
          'Press Confirm to save changes, or Back to continue editing.',
          style: TextStyle(color: Colors.gray),
        ),
      );
    } else {
      rows.add(
        const Text(
          'No changes detected. Press Back to make changes, or Cancel to exit.',
          style: TextStyle(color: Colors.brightYellow),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  bool _isModelModified(_EditableModel em, ProviderConfig provider) {
    final pm = provider.models.where((m) => m.id == em.id).firstOrNull;
    if (pm == null) return true; // New model
    return (em.name.isNotEmpty ? em.name : em.id) != pm.name ||
        em.contextSize != pm.contextSize ||
        em.imageSupport != pm.imageSupport ||
        em.thinking != pm.thinking;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Wizard callbacks
  // ═══════════════════════════════════════════════════════════════════════════

  void _onWizardComplete() async {
    final provider = _selectedProvider;
    if (provider == null) {
      component.onComplete?.call();
      return;
    }

    _syncModelFieldsToPending();
    final endpointUrl = _effectiveEndpoint();
    final validModels = _editableModels
        .where((m) => m.isValid())
        .map((m) => m.toModelConfig())
        .toList();

    await _service.modifyProvider(
      provider.name,
      endpointUrl: endpointUrl,
      type: _selectedType,
      models: List.unmodifiable(validModels),
    );

    // Store the API key in the in-memory environment if one was provided
    final apiKey = _apiKeyController.text;
    if (apiKey.isNotEmpty) {
      _service.setApiKey(provider.name, apiKey);
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
    final steps = [
      WizardStep(
        title: 'Select Provider to Modify',
        contentBuilder: _buildSelectProviderStep,
        validate: _validateSelectProvider,
        onKeyEvent: (event) {
          final providers = _service.providers();
          if (providers.isEmpty) return false;
          if (event.logicalKey == LogicalKey.arrowUp) {
            setState(() {
              _selectedProviderIndex = (_selectedProviderIndex > 0)
                  ? _selectedProviderIndex - 1
                  : providers.length - 1;
            });
            return true;
          }
          if (event.logicalKey == LogicalKey.arrowDown) {
            setState(() {
              _selectedProviderIndex =
                  (_selectedProviderIndex < providers.length - 1)
                  ? _selectedProviderIndex + 1
                  : 0;
            });
            return true;
          }
          return false;
        },
        stepContentFocused: () => true,
      ),
      WizardStep(
        title: 'Edit Endpoint, Type & API Key',
        contentBuilder: _buildEndpointAndTypeStep,
        validate: _validateEndpointAndType,
        onKeyEvent: _handleEndpointContentKeyEvent,
        footerFocusIndex: () {
          if (_focusedArea == _FocusArea.backBtn) {
            return FooterFocus.back;
          }
          if (_focusedArea == _FocusArea.nextBtn) {
            return FooterFocus.next;
          }
          if (_focusedArea == _FocusArea.cancelBtn) {
            return FooterFocus.cancel;
          }
          return FooterFocus.none;
        },
        stepContentFocused: () =>
            _focusedArea == _FocusArea.resetDefaultBtn ||
            _focusedArea == _FocusArea.showKeyBtn ||
            _focusedArea == _FocusArea.typeList,
        onFooterKeyEvent: _handleEndpointFooterKeyEvent,
      ),
      WizardStep(
        title: 'Edit Models',
        contentBuilder: _buildEditModelsStep,
        validate: _validateModels,
        onKeyEvent: _handleModelStepKeyEvent,
        footerFocusIndex: () {
          if (_modelFocusedArea == _ModelFocusArea.backBtn) {
            return FooterFocus.back;
          }
          if (_modelFocusedArea == _ModelFocusArea.nextBtn) {
            return FooterFocus.next;
          }
          if (_modelFocusedArea == _ModelFocusArea.cancelBtn) {
            return FooterFocus.cancel;
          }
          return FooterFocus.none;
        },
        stepContentFocused: () =>
            _modelFocusedArea == _ModelFocusArea.discoverBtn ||
            _modelFocusedArea == _ModelFocusArea.addModelBtn ||
            _modelFocusedArea == _ModelFocusArea.imageToggleBtn ||
            _modelFocusedArea == _ModelFocusArea.thinkingToggleBtn,
        onFooterKeyEvent: _handleModelFooterKeyEvent,
      ),
      WizardStep(
        title: 'Review & Confirm',
        contentBuilder: _buildReviewStep,
        validate: () => true,
        isComplete: true,
        stepContentFocused: () => true,
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
