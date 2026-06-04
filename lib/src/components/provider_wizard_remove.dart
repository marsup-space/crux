import 'package:nocterm/nocterm.dart';
import '../theme/crux_theme.dart';
import 'ui/wizard_overlay.dart';
import '../models/provider_config.dart';
import '../services/provider_service.dart';

/// Confirmation choice for the removal step.
enum _RemoveChoice { keep, remove }

/// A 2-step wizard overlay for removing a provider configuration.
///
/// Step 1: **Select Provider** — pick from loaded providers; shows details
/// (type, endpoint, model count) below the selection.
/// Step 2: **Confirm Removal** — warning message with two selectable
/// options: "Yes, remove" and "No, keep it". The default selection is
/// "No, keep it" for safety. The user must explicitly choose removal.
///
/// Usage:
/// ```dart
/// ProviderWizardRemove(
///   service: providerService,
///   onComplete: () => dismissOverlay(),
///   onDismiss: () => dismissOverlay(),
/// )
/// ```
class ProviderWizardRemove extends StatefulComponent {
  final ProviderService service;
  final VoidCallback? onComplete;
  final VoidCallback? onDismiss;

  const ProviderWizardRemove({
    super.key,
    required this.service,
    this.onComplete,
    this.onDismiss,
  });

  @override
  State<ProviderWizardRemove> createState() => _ProviderWizardRemoveState();
}

class _ProviderWizardRemoveState extends State<ProviderWizardRemove> {
  // ── Step 1: Provider selection ──
  int _selectedProviderIndex = -1;
  String? _selectedProviderName;
  ProviderConfig? _selectedProvider;

  // ── Step 2: Confirmation ──
  _RemoveChoice _removeChoice = _RemoveChoice.keep; // default: safe

  // ── Wizard controller ──
  final WizardController wizardController = WizardController();

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
      // Reset confirmation choice when provider changes
      _removeChoice = _RemoveChoice.keep;
    });
  }

  bool _validateSelectProvider() => _selectedProviderName != null;

  Component _buildSelectProviderStep() {
    final providers = _service.providers();
    final rows = <Component>[];

    rows.add(
      const Text(
        'Select a provider to remove:',
        style: TextStyle(
          color: CruxTheme.wizardTitle,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    if (providers.isEmpty) {
      rows.add(
        const Text(
          'No providers configured. Nothing to remove.',
          style: TextStyle(color: CruxTheme.wizardTextDim),
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
                    ? const BoxDecoration(
                        color: CruxTheme.buttonBackgroundHover,
                      )
                    : null,
                padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
                child: Row(
                  children: [
                    Text(
                      isSelected ? '▶ ' : '  ',
                      style: TextStyle(
                        color: isSelected
                            ? CruxTheme.wizardTextSelected
                            : CruxTheme.wizardTextDim,
                      ),
                    ),
                    Text(
                      provider.name,
                      style: TextStyle(
                        color: isSelected
                            ? CruxTheme.wizardTextSelected
                            : CruxTheme.foreground,
                        fontWeight: isSelected ? FontWeight.bold : null,
                      ),
                    ),
                    if (hasKey)
                      const Text(
                        ' 🔑',
                        style: TextStyle(color: CruxTheme.warningColor),
                      ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        '${provider.type.toConfigString()} · ${provider.endpointUrl}',
                        style: TextStyle(
                          color: isSelected
                              ? CruxTheme.foreground
                              : CruxTheme.wizardTextDim,
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
        rows.add(const Divider(color: CruxTheme.outline, height: 1));
        rows.add(
          Text(
            '  Type: ${_selectedProvider!.type.toConfigString()}',
            style: const TextStyle(color: CruxTheme.foreground),
          ),
        );
        rows.add(
          Text(
            '  Endpoint: ${_selectedProvider!.endpointUrl}',
            style: const TextStyle(color: CruxTheme.foreground),
          ),
        );
        rows.add(
          Text(
            '  Models: ${_selectedProvider!.models.length}',
            style: const TextStyle(color: CruxTheme.foreground),
          ),
        );
        final keyStatus = _service.getApiKey(_selectedProvider!.name) != null;
        rows.add(
          Text(
            '  API Key: ${keyStatus ? "✓ Set (will also be removed)" : "Not set"}',
            style: TextStyle(
              color: keyStatus
                  ? CruxTheme.warningColor
                  : CruxTheme.wizardTextDim,
            ),
          ),
        );

        // Show model list
        if (_selectedProvider!.models.isNotEmpty) {
          rows.add(const SizedBox(height: 1));
          rows.add(
            const Text(
              '  Models that will be removed:',
              style: TextStyle(color: CruxTheme.warningColor),
            ),
          );
          for (final model in _selectedProvider!.models) {
            rows.add(
              Text(
                '    - ${model.compositeKey(_selectedProvider!.name)} '
                '(ctx: ${model.contextSize ~/ 1024}k, img: ${model.imageSupport})',
                style: const TextStyle(color: CruxTheme.wizardTextDim),
              ),
            );
          }
        }
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Step 2: Confirm Removal
  // ═══════════════════════════════════════════════════════════════════════════

  bool _validateConfirmRemoval() => _removeChoice == _RemoveChoice.remove;

  Component _buildConfirmRemovalStep() {
    final provider = _selectedProvider;
    if (provider == null) {
      return const Text(
        'No provider selected.',
        style: TextStyle(color: CruxTheme.wizardTextDim),
      );
    }

    final modelCount = provider.models.length;
    final hasKey = _service.getApiKey(provider.name) != null;

    final rows = <Component>[];

    // Warning header
    rows.add(
      const Text(
        '⚠ Confirm Provider Removal',
        style: TextStyle(
          color: CruxTheme.errorColor,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    rows.add(
      Text(
        'Are you sure you want to remove provider "${provider.name}"?',
        style: const TextStyle(color: CruxTheme.foreground),
      ),
    );
    rows.add(const SizedBox(height: 1));

    // Impact summary
    rows.add(
      Text(
        '  This will permanently delete:',
        style: const TextStyle(color: CruxTheme.warningColor),
      ),
    );
    rows.add(
      Text(
        '    - ${provider.name}.toml (configuration file)',
        style: const TextStyle(color: CruxTheme.foreground),
      ),
    );
    rows.add(
      Text(
        '    - $modelCount model(s) will be unregistered',
        style: const TextStyle(color: CruxTheme.foreground),
      ),
    );
    rows.add(
      Text(
        '    - Endpoint: ${provider.endpointUrl}',
        style: const TextStyle(color: CruxTheme.foreground),
      ),
    );
    if (hasKey) {
      rows.add(
        const Text(
          '    - API key (removed from auth.json)',
          style: TextStyle(color: CruxTheme.foreground),
        ),
      );
    }
    rows.add(const SizedBox(height: 1));

    rows.add(
      const Text(
        '  This action cannot be undone.',
        style: TextStyle(
          color: CruxTheme.errorColor,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    rows.add(const Divider(color: CruxTheme.outline, height: 1));
    rows.add(const SizedBox(height: 1));

    // Choice options
    rows.add(
      const Text(
        'Choose an option:',
        style: TextStyle(
          color: CruxTheme.wizardTitle,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
    rows.add(const SizedBox(height: 1));

    // "No, keep it" option — default, safe choice
    rows.add(
      MouseRegion(
        onEnter: (_) => setState(() => _removeChoice = _RemoveChoice.keep),
        opaque: false,
        child: GestureDetector(
          onTap: () => setState(() => _removeChoice = _RemoveChoice.keep),
          behavior: HitTestBehavior.opaque,
          child: Container(
            decoration: _removeChoice == _RemoveChoice.keep
                ? const BoxDecoration(color: CruxTheme.buttonBackgroundHover)
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              children: [
                Text(
                  _removeChoice == _RemoveChoice.keep ? '▶ ' : '  ',
                  style: TextStyle(
                    color: _removeChoice == _RemoveChoice.keep
                        ? CruxTheme.wizardTextSelected
                        : CruxTheme.wizardTextDim,
                  ),
                ),
                Text(
                  'No, keep it',
                  style: TextStyle(
                    color: _removeChoice == _RemoveChoice.keep
                        ? CruxTheme.wizardTextSelected
                        : CruxTheme.foreground,
                    fontWeight: _removeChoice == _RemoveChoice.keep
                        ? FontWeight.bold
                        : null,
                  ),
                ),
                const SizedBox(width: 2),
                const Text(
                  '(safe — cancel removal)',
                  style: TextStyle(color: CruxTheme.wizardTextDim),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // "Yes, remove" option — dangerous, requires explicit selection
    rows.add(
      MouseRegion(
        onEnter: (_) => setState(() => _removeChoice = _RemoveChoice.remove),
        opaque: false,
        child: GestureDetector(
          onTap: () => setState(() => _removeChoice = _RemoveChoice.remove),
          behavior: HitTestBehavior.opaque,
          child: Container(
            decoration: _removeChoice == _RemoveChoice.remove
                ? const BoxDecoration(color: CruxTheme.errorColor)
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 0),
            child: Row(
              children: [
                Text(
                  _removeChoice == _RemoveChoice.remove ? '▶ ' : '  ',
                  style: TextStyle(
                    color: _removeChoice == _RemoveChoice.remove
                        ? CruxTheme.errorColor
                        : CruxTheme.wizardTextDim,
                  ),
                ),
                Text(
                  'Yes, remove',
                  style: TextStyle(
                    color: _removeChoice == _RemoveChoice.remove
                        ? CruxTheme.errorColor
                        : CruxTheme.foreground,
                    fontWeight: _removeChoice == _RemoveChoice.remove
                        ? FontWeight.bold
                        : null,
                  ),
                ),
                const SizedBox(width: 2),
                const Text(
                  '(destructive — permanent deletion)',
                  style: TextStyle(color: CruxTheme.wizardTextDim),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    rows.add(const SizedBox(height: 1));

    // Current selection indicator
    if (_removeChoice == _RemoveChoice.remove) {
      rows.add(
        const Text(
          '⚠ You have selected permanent removal. Press Confirm to proceed.',
          style: TextStyle(color: CruxTheme.errorColor),
        ),
      );
    } else {
      rows.add(
        const Text(
          '✓ Removal canceled. Press Back to choose a different provider, '
          'or Cancel to exit.',
          style: TextStyle(color: CruxTheme.successColor),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Wizard callbacks
  // ═══════════════════════════════════════════════════════════════════════════

  void _onWizardComplete() async {
    if (_selectedProviderName != null &&
        _removeChoice == _RemoveChoice.remove) {
      await _service.removeProvider(_selectedProviderName!);
      // Also remove the API key if it exists
      if (_service.getApiKey(_selectedProviderName!) != null) {
        await _service.removeApiKey(_selectedProviderName!);
      }
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
        title: 'Select Provider to Remove',
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
      ),
      WizardStep(
        title: 'Confirm Removal',
        contentBuilder: _buildConfirmRemovalStep,
        validate: _validateConfirmRemoval,
        isComplete: true,
        onKeyEvent: (event) {
          if (event.logicalKey == LogicalKey.arrowUp ||
              event.logicalKey == LogicalKey.arrowDown) {
            setState(() {
              _removeChoice = _removeChoice == _RemoveChoice.keep
                  ? _RemoveChoice.remove
                  : _RemoveChoice.keep;
            });
            return true;
          }
          return false;
        },
      ),
    ];

    return WizardOverlay(
      controller: wizardController,
      steps: steps,
      onComplete: _onWizardComplete,
      onCancel: _onWizardCancel,
    );
  }
}
