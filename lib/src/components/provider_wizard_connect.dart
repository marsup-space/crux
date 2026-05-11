import 'dart:async';
import 'package:nocterm/nocterm.dart';
import 'ui/button.dart';
import 'ui/wizard_overlay.dart';
import '../models/provider_config.dart';
import '../services/provider_service.dart';

/// Internal status for the connection verification step.
enum _ConnectionStatus { pending, testing, success, failure, skipped }

/// A step-by-step wizard overlay for connecting (storing an API key) to a
/// provider.
///
/// Steps:
/// 1. **Select Provider** — pick from loaded providers; shows 🔑 if key exists.
/// 2. **Enter API Key** — text input with obscure-text toggle and hints.
/// 3. **Verify Connection** — auto-tests the key against `/models`; offers
///    "Skip Verification" on failure.
/// 4. **Confirm Storage** — summary of where the key is stored.
///
/// Usage:
/// ```dart
/// ProviderWizardConnect(
///   service: providerService,
///   onComplete: () => dismissOverlay(),
///   onDismiss: () => dismissOverlay(),
/// )
/// ```
class ProviderWizardConnect extends StatefulComponent {
  final ProviderService service;
  final VoidCallback? onComplete;
  final VoidCallback? onDismiss;

  const ProviderWizardConnect({
    super.key,
    required this.service,
    this.onComplete,
    this.onDismiss,
  });

  @override
  State<ProviderWizardConnect> createState() => _ProviderWizardConnectState();
}

enum _ApiKeyFocusArea { apiKeyInput, backBtn, nextBtn, cancelBtn }

class _ProviderWizardConnectState extends State<ProviderWizardConnect> {
  // ── Step 1: Provider selection ──
  int _selectedProviderIndex = -1;
  String? _selectedProviderName;
  ProviderConfig? _selectedProvider;

  // ── Step 2: API key ──
  final TextEditingController _apiKeyController = TextEditingController();
  bool _apiKeyObscured = true;
  _ApiKeyFocusArea _apiKeyFocusedArea = _ApiKeyFocusArea.apiKeyInput;

  // ── Step 3: Connection verification ──
  _ConnectionStatus _connectionStatus = _ConnectionStatus.pending;
  String? _connectionMessage;
  int? _discoveredModelCount;
  bool _testScheduled = false;
  String? _lastTestedKey;

  // ── Wizard controller ──
  final WizardController wizardController = WizardController();

  // ── Lifecycle guard ──
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _apiKeyController.addListener(() {
      if (!_disposed) setState(() {});
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _apiKeyController.dispose();
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
      case 1: // Enter API Key
        _apiKeyFocusedArea = _ApiKeyFocusArea.apiKeyInput;
      case 2: // Verify Connection — no focus areas to reset
        break;
      case 3: // Confirm Storage — no focus areas to reset
        break;
    }
  }

  // ── Convenience accessor ──
  ProviderService get _service => component.service;

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
      // Reset downstream state when provider changes
      _apiKeyController.clear();
      _apiKeyObscured = true;
      _connectionStatus = _ConnectionStatus.pending;
      _connectionMessage = null;
      _discoveredModelCount = null;
      _testScheduled = false;
      _lastTestedKey = null;
    });
  }

  bool _validateSelectProvider() => _selectedProviderName != null;

  Component _buildSelectProviderStep() {
    final providers = _service.providers();
    final rows = <Component>[];

    rows.add(
      const Text(
        'Select a provider to connect:',
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
        final keyStatus = _service.getApiKey(_selectedProvider!.name) != null;
        rows.add(
          Text(
            '  API Key: ${keyStatus ? "✓ Already set" : "Not set"}',
            style: TextStyle(
              color: keyStatus
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
  // Step 2: Enter API Key
  // ═══════════════════════════════════════════════════════════════════════════

  String _getApiKeyHint(ProviderType type) {
    switch (type) {
      case ProviderType.openai:
        return 'Enter your API key';
      case ProviderType.anthropic:
        return 'Enter your Anthropic API key';
    }
  }

  bool _validateEnterApiKey() {
    final key = _apiKeyController.text;
    return key.isNotEmpty && key.length >= 20;
  }

  /// Handles key events for the single API-key TextField.
  /// Extends the standard [WizardController.handleFieldKeyEvent] behavior
  /// by also treating Tab as "advance" (same as Enter), since there's
  /// only one input field on this step — Tab has no other field to move to.
  bool _handleApiKeyKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.enter) {
      wizardController.next();
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }
    // Ctrl+B or Alt+LeftArrow → go back to previous step
    if ((event.isControlPressed && event.logicalKey == LogicalKey.keyB) ||
        (event.isAltPressed && event.logicalKey == LogicalKey.arrowLeft)) {
      wizardController.back();
      return true;
    }
    // Tab/ArrowDown/ArrowRight → cycle focus forward: apiKeyInput → backBtn → nextBtn → cancelBtn → apiKeyInput
    if ((event.logicalKey == LogicalKey.tab && !event.isShiftPressed) ||
        event.logicalKey == LogicalKey.arrowDown ||
        event.logicalKey == LogicalKey.arrowRight) {
      setState(() {
        _apiKeyFocusedArea = switch (_apiKeyFocusedArea) {
          _ApiKeyFocusArea.apiKeyInput => _ApiKeyFocusArea.backBtn,
          _ApiKeyFocusArea.backBtn => _ApiKeyFocusArea.nextBtn,
          _ApiKeyFocusArea.nextBtn => _ApiKeyFocusArea.cancelBtn,
          _ApiKeyFocusArea.cancelBtn => _ApiKeyFocusArea.apiKeyInput,
        };
      });
      wizardController.requestRebuild();
      return true;
    }
    // Shift+Tab/ArrowUp/ArrowLeft → cycle focus backward: apiKeyInput → cancelBtn → nextBtn → backBtn → apiKeyInput
    if ((event.logicalKey == LogicalKey.tab && event.isShiftPressed) ||
        event.logicalKey == LogicalKey.arrowUp ||
        event.logicalKey == LogicalKey.arrowLeft) {
      setState(() {
        _apiKeyFocusedArea = switch (_apiKeyFocusedArea) {
          _ApiKeyFocusArea.apiKeyInput => _ApiKeyFocusArea.cancelBtn,
          _ApiKeyFocusArea.cancelBtn => _ApiKeyFocusArea.nextBtn,
          _ApiKeyFocusArea.nextBtn => _ApiKeyFocusArea.backBtn,
          _ApiKeyFocusArea.backBtn => _ApiKeyFocusArea.apiKeyInput,
        };
      });
      wizardController.requestRebuild();
      return true;
    }
    return false; // Let TextField handle typing, backspace, etc.
  }

  /// Handles key events when focus is on footer buttons (not the TextField).
  /// Called by the wizard overlay's onKeyEvent for step 2.
  bool _handleApiKeyStepKeyEvent(KeyboardEvent event) {
    // Enter → activate the focused footer button
    if (event.logicalKey == LogicalKey.enter) {
      switch (_apiKeyFocusedArea) {
        case _ApiKeyFocusArea.backBtn:
          wizardController.back();
        case _ApiKeyFocusArea.nextBtn:
          wizardController.next();
        case _ApiKeyFocusArea.cancelBtn:
          wizardController.cancel();
        case _ApiKeyFocusArea.apiKeyInput:
          // Should not happen in this handler, but just advance
          wizardController.next();
      }
      return true;
    }
    // Escape → cancel
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }
    // Tab/ArrowDown/ArrowRight → cycle forward through footer buttons
    if ((event.logicalKey == LogicalKey.tab && !event.isShiftPressed) ||
        event.logicalKey == LogicalKey.arrowDown ||
        event.logicalKey == LogicalKey.arrowRight) {
      setState(() {
        _apiKeyFocusedArea = switch (_apiKeyFocusedArea) {
          _ApiKeyFocusArea.backBtn => _ApiKeyFocusArea.nextBtn,
          _ApiKeyFocusArea.nextBtn => _ApiKeyFocusArea.cancelBtn,
          _ApiKeyFocusArea.cancelBtn => _ApiKeyFocusArea.apiKeyInput,
          _ApiKeyFocusArea.apiKeyInput => _ApiKeyFocusArea.backBtn,
        };
      });
      wizardController.requestRebuild();
      return true;
    }
    // Shift+Tab/ArrowUp/ArrowLeft → cycle backward through footer buttons
    if ((event.logicalKey == LogicalKey.tab && event.isShiftPressed) ||
        event.logicalKey == LogicalKey.arrowUp ||
        event.logicalKey == LogicalKey.arrowLeft) {
      setState(() {
        _apiKeyFocusedArea = switch (_apiKeyFocusedArea) {
          _ApiKeyFocusArea.cancelBtn => _ApiKeyFocusArea.nextBtn,
          _ApiKeyFocusArea.nextBtn => _ApiKeyFocusArea.backBtn,
          _ApiKeyFocusArea.backBtn => _ApiKeyFocusArea.apiKeyInput,
          _ApiKeyFocusArea.apiKeyInput => _ApiKeyFocusArea.cancelBtn,
        };
      });
      wizardController.requestRebuild();
      return true;
    }
    return false; // Let overlay defaults handle other keys
  }

  /// Handles key events for the footer [Focusable] on the API key step.
  ///
  /// Called when a footer button (Back / Next / Cancel) is focused.
  /// - Enter → activate the focused footer button.
  /// - Escape → cancel.
  /// - Tab / ArrowDown / ArrowRight → cycle forward through footer buttons,
  ///   shifting back to the apiKeyInput TextField after cancelBtn.
  /// - Shift+Tab / ArrowUp / ArrowLeft → cycle backward through footer buttons,
  ///   shifting back to the apiKeyInput TextField after backBtn.
  bool _handleApiKeyFooterKeyEvent(KeyboardEvent event) {
    // Enter → activate the focused footer button
    if (event.logicalKey == LogicalKey.enter) {
      switch (_apiKeyFocusedArea) {
        case _ApiKeyFocusArea.backBtn:
          wizardController.back();
        case _ApiKeyFocusArea.nextBtn:
          wizardController.next();
        case _ApiKeyFocusArea.cancelBtn:
          wizardController.cancel();
        case _ApiKeyFocusArea.apiKeyInput:
          wizardController.next();
      }
      return true;
    }
    // Escape → cancel
    if (event.logicalKey == LogicalKey.escape) {
      wizardController.cancel();
      return true;
    }
    // Tab/ArrowDown/ArrowRight → cycle: backBtn → nextBtn → cancelBtn → apiKeyInput
    if ((event.logicalKey == LogicalKey.tab && !event.isShiftPressed) ||
        event.logicalKey == LogicalKey.arrowDown ||
        event.logicalKey == LogicalKey.arrowRight) {
      setState(() {
        _apiKeyFocusedArea = switch (_apiKeyFocusedArea) {
          _ApiKeyFocusArea.backBtn => _ApiKeyFocusArea.nextBtn,
          _ApiKeyFocusArea.nextBtn => _ApiKeyFocusArea.cancelBtn,
          _ApiKeyFocusArea.cancelBtn => _ApiKeyFocusArea.apiKeyInput,
          _ApiKeyFocusArea.apiKeyInput => _ApiKeyFocusArea.backBtn,
        };
      });
      wizardController.requestRebuild();
      return true;
    }
    // Shift+Tab/ArrowUp/ArrowLeft → cycle: cancelBtn → nextBtn → backBtn → apiKeyInput
    if ((event.logicalKey == LogicalKey.tab && event.isShiftPressed) ||
        event.logicalKey == LogicalKey.arrowUp ||
        event.logicalKey == LogicalKey.arrowLeft) {
      setState(() {
        _apiKeyFocusedArea = switch (_apiKeyFocusedArea) {
          _ApiKeyFocusArea.cancelBtn => _ApiKeyFocusArea.nextBtn,
          _ApiKeyFocusArea.nextBtn => _ApiKeyFocusArea.backBtn,
          _ApiKeyFocusArea.backBtn => _ApiKeyFocusArea.apiKeyInput,
          _ApiKeyFocusArea.apiKeyInput => _ApiKeyFocusArea.cancelBtn,
        };
      });
      wizardController.requestRebuild();
      return true;
    }
    return false;
  }

  Component _buildEnterApiKeyStep() {
    final provider = _selectedProvider;
    if (provider == null) {
      return const Text(
        'No provider selected.',
        style: TextStyle(color: Colors.gray),
      );
    }

    final hintText = _getApiKeyHint(provider.type);
    final hasExistingKey = _service.getApiKey(provider.name) != null;
    final keyText = _apiKeyController.text;

    final rows = <Component>[];

    rows.add(
      Text(
        'Enter API key for ${provider.name}:',
        style: const TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    if (hasExistingKey) {
      rows.add(
        const Text(
          '⚠ An API key is already set. Entering a new key will replace it.',
          style: TextStyle(color: Colors.brightYellow),
        ),
      );
      rows.add(const SizedBox(height: 1));
    }

    rows.add(Text(hintText, style: const TextStyle(color: Colors.gray)));
    rows.add(
      const Text(
        '  Stored in environment variable for this session only.',
        style: TextStyle(color: Colors.gray),
      ),
    );
    rows.add(const SizedBox(height: 1));

    // Key input row
    rows.add(
      Row(
        children: [
          const Text('Key: ', style: TextStyle(color: Colors.brightCyan)),
          Expanded(
            child: TextField(
              controller: _apiKeyController,
              focused: _apiKeyFocusedArea == _ApiKeyFocusArea.apiKeyInput,
              onKeyEvent: _handleApiKeyKeyEvent,
              obscureText: _apiKeyObscured,
              obscuringCharacter: '•',
              style: const TextStyle(color: Colors.white),
              placeholder: 'Paste your API key...',
            ),
          ),
        ],
      ),
    );
    rows.add(const SizedBox(height: 1));

    // Toggle visibility button
    rows.add(
      Button(
        label: _apiKeyObscured ? '👁 Show Key' : '🔒 Hide Key',
        onPressed: () => setState(() => _apiKeyObscured = !_apiKeyObscured),
        color: Colors.gray,
        hoverColor: Colors.brightCyan,
        bgColor: const Color.fromRGB(25, 20, 45),
        hoverBgColor: const Color.fromRGB(40, 30, 80),
      ),
    );

    // Validation feedback
    if (keyText.isNotEmpty && keyText.length < 20) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        Text(
          '⚠ Key must be at least 20 characters (${keyText.length}/20)',
          style: const TextStyle(color: Colors.brightYellow),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Step 3: Verify Connection
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _testConnection() async {
    if (_disposed) return;
    final providerName = _selectedProviderName!;
    final key = _apiKeyController.text;

    setState(() {
      _connectionStatus = _ConnectionStatus.testing;
    });

    // Store the key in the in-memory environment so discoverModels can use it.
    _service.setApiKey(providerName, key);
    _lastTestedKey = key;

    try {
      final models = await _service.discoverModels(providerName);
      if (_disposed) return;
      setState(() {
        _connectionStatus = _ConnectionStatus.success;
        _discoveredModelCount = models.length;
        _connectionMessage = null;
      });
    } catch (e) {
      if (_disposed) return;
      setState(() {
        _connectionStatus = _ConnectionStatus.failure;
        _connectionMessage = e.toString();
        _discoveredModelCount = null;
      });
    }
  }

  void _resetVerification() {
    setState(() {
      _connectionStatus = _ConnectionStatus.pending;
      _testScheduled = false;
      _discoveredModelCount = null;
      _connectionMessage = null;
    });
  }

  bool _validateVerifyConnection() {
    if (_connectionStatus == _ConnectionStatus.success ||
        _connectionStatus == _ConnectionStatus.skipped) {
      // If the key has changed since the last successful test,
      // the verification is stale — block progression.
      if (_lastTestedKey != null && _apiKeyController.text != _lastTestedKey) {
        return false;
      }
      return true;
    }
    return false;
  }

  Component _buildVerifyConnectionStep() {
    final provider = _selectedProvider;
    if (provider == null) {
      return const Text(
        'No provider selected.',
        style: TextStyle(color: Colors.gray),
      );
    }

    // Auto-start the test when the step first becomes active
    if (_connectionStatus == _ConnectionStatus.pending && !_testScheduled) {
      _testScheduled = true;
      Timer(const Duration(milliseconds: 100), () => _testConnection());
    }

    // Detect if the key has changed since the last test
    final keyChanged =
        _lastTestedKey != null &&
        _apiKeyController.text != _lastTestedKey &&
        _connectionStatus != _ConnectionStatus.pending &&
        _connectionStatus != _ConnectionStatus.testing;

    final rows = <Component>[];

    rows.add(
      Text(
        'Verify connection to ${provider.name}:',
        style: const TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    switch (_connectionStatus) {
      case _ConnectionStatus.pending:
        rows.add(
          const Text(
            'Preparing to test connection...',
            style: TextStyle(color: Colors.gray),
          ),
        );
        break;

      case _ConnectionStatus.testing:
        rows.add(
          Text(
            '⏳ Testing connection to ${provider.endpointUrl}...',
            style: const TextStyle(color: Colors.brightCyan),
          ),
        );
        rows.add(const SizedBox(height: 1));
        rows.add(
          const Text(
            '  Sending request to /models endpoint...',
            style: TextStyle(color: Colors.gray),
          ),
        );
        break;

      case _ConnectionStatus.success:
        rows.add(
          const Text(
            '✓ Connection successful!',
            style: TextStyle(color: Color.fromRGB(100, 220, 100)),
          ),
        );
        rows.add(const SizedBox(height: 1));
        rows.add(
          Text(
            '  Found ${_discoveredModelCount ?? 0} available models',
            style: const TextStyle(color: Colors.white),
          ),
        );
        rows.add(const SizedBox(height: 1));
        rows.add(
          const Text(
            '  Your API key is valid and has been stored.',
            style: TextStyle(color: Color.fromRGB(100, 220, 100)),
          ),
        );
        break;

      case _ConnectionStatus.failure:
        rows.add(
          const Text(
            '✗ Connection failed',
            style: TextStyle(color: Color.fromRGB(255, 80, 80)),
          ),
        );
        rows.add(const SizedBox(height: 1));
        rows.add(
          Text(
            '  ${_connectionMessage ?? "Unknown error"}',
            style: const TextStyle(color: Colors.gray),
          ),
        );
        rows.add(const SizedBox(height: 1));
        rows.add(
          const Text(
            'Press Back to re-enter your API key, or skip verification:',
            style: TextStyle(color: Colors.gray),
          ),
        );
        rows.add(const SizedBox(height: 1));
        rows.add(
          Button(
            label: ' Skip Verification ',
            onPressed: () {
              // Store the key even though verification failed
              _service.setApiKey(
                _selectedProviderName!,
                _apiKeyController.text,
              );
              setState(() {
                _connectionStatus = _ConnectionStatus.skipped;
                _lastTestedKey = _apiKeyController.text;
              });
            },
            color: Colors.brightYellow,
            hoverColor: Colors.brightCyan,
            bgColor: const Color.fromRGB(25, 20, 45),
            hoverBgColor: const Color.fromRGB(40, 30, 80),
          ),
        );
        break;

      case _ConnectionStatus.skipped:
        rows.add(
          const Text(
            '⚠ Verification skipped',
            style: TextStyle(color: Colors.brightYellow),
          ),
        );
        rows.add(const SizedBox(height: 1));
        rows.add(
          const Text(
            '  The API key has been stored without verification.',
            style: TextStyle(color: Colors.gray),
          ),
        );
        rows.add(const SizedBox(height: 1));
        rows.add(
          const Text(
            '  You can verify it later with /provider connect.',
            style: TextStyle(color: Colors.gray),
          ),
        );
        break;
    }

    // Show "Re-test" button when the key has changed since last test
    if (keyChanged) {
      rows.add(const SizedBox(height: 1));
      rows.add(const Divider(color: Color.fromRGB(80, 60, 120), height: 1));
      rows.add(const SizedBox(height: 1));
      rows.add(
        const Text(
          '⚠ API key has changed since last verification.',
          style: TextStyle(color: Colors.brightYellow),
        ),
      );
      rows.add(const SizedBox(height: 1));
      rows.add(
        Button(
          label: ' Re-test Connection ',
          onPressed: _resetVerification,
          color: Colors.brightCyan,
          hoverColor: Colors.brightYellow,
          bgColor: const Color.fromRGB(25, 20, 45),
          hoverBgColor: const Color.fromRGB(40, 30, 80),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Step 4: Confirm Storage
  // ═══════════════════════════════════════════════════════════════════════════

  Component _buildConfirmStep() {
    final provider = _selectedProvider;
    if (provider == null) {
      return const Text(
        'No provider selected.',
        style: TextStyle(color: Colors.gray),
      );
    }

    final rows = <Component>[];

    rows.add(
      const Text(
        'API Key Storage Confirmation',
        style: TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    rows.add(
      Text(
        '✓ API key for ${provider.name} has been stored.',
        style: const TextStyle(color: Color.fromRGB(100, 220, 100)),
      ),
    );
    rows.add(const SizedBox(height: 1));

    rows.add(
      Text(
        '  Environment variable: CRUX_API_KEY_${provider.name.toUpperCase()}',
        style: const TextStyle(color: Colors.white),
      ),
    );
    rows.add(
      const Text(
        '  The key is stored in-memory for this session only.',
        style: TextStyle(color: Colors.white),
      ),
    );
    rows.add(
      const Text(
        '  It will NOT persist across restarts — set it again next session,',
        style: TextStyle(color: Colors.white),
      ),
    );
    rows.add(
      const Text(
        '  or set CRUX_API_KEY_<PROVIDER> in your shell environment.',
        style: TextStyle(color: Colors.gray),
      ),
    );
    rows.add(const SizedBox(height: 1));

    if (_connectionStatus == _ConnectionStatus.success) {
      rows.add(
        Text(
          '  Connection verified: ${_discoveredModelCount ?? 0} models available',
          style: const TextStyle(color: Color.fromRGB(100, 220, 100)),
        ),
      );
    } else if (_connectionStatus == _ConnectionStatus.skipped) {
      rows.add(
        const Text(
          '  Connection verification was skipped',
          style: TextStyle(color: Colors.brightYellow),
        ),
      );
    }

    rows.add(const SizedBox(height: 1));
    rows.add(
      const Text(
        'Press Confirm to finish, or Back to review.',
        style: TextStyle(color: Colors.gray),
      ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Wizard callbacks
  // ═══════════════════════════════════════════════════════════════════════════

  void _onWizardComplete() {
    // The key has already been stored during verification (step 3).
    // If verification was skipped, the key was stored by the
    // "Skip Verification" button handler. Nothing more to do.
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
        title: 'Select Provider',
        contentBuilder: _buildSelectProviderStep,
        validate: _validateSelectProvider,
        onKeyEvent: (event) {
          if (event.logicalKey == LogicalKey.arrowUp) {
            final providers = _service.providers();
            setState(() {
              _selectedProviderIndex = (_selectedProviderIndex > 0)
                  ? _selectedProviderIndex - 1
                  : providers.length - 1;
            });
            return true;
          }
          if (event.logicalKey == LogicalKey.arrowDown) {
            final providers = _service.providers();
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
        onFooterKeyEvent: null,
      ),
      WizardStep(
        title: 'Enter API Key',
        contentBuilder: _buildEnterApiKeyStep,
        validate: _validateEnterApiKey,
        onKeyEvent: _handleApiKeyStepKeyEvent,
        stepContentFocused: () => false,
        onFooterKeyEvent: _handleApiKeyFooterKeyEvent,
        footerFocusIndex: () {
          if (_apiKeyFocusedArea == _ApiKeyFocusArea.backBtn) {
            return FooterFocus.back;
          }
          if (_apiKeyFocusedArea == _ApiKeyFocusArea.nextBtn) {
            return FooterFocus.next;
          }
          if (_apiKeyFocusedArea == _ApiKeyFocusArea.cancelBtn) {
            return FooterFocus.cancel;
          }
          return FooterFocus.none;
        },
      ),
      WizardStep(
        title: 'Verify Connection',
        contentBuilder: _buildVerifyConnectionStep,
        validate: _validateVerifyConnection,
        stepContentFocused: () => true,
        onFooterKeyEvent: null,
      ),
      WizardStep(
        title: 'Confirm Storage',
        contentBuilder: _buildConfirmStep,
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
