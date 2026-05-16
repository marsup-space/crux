import 'package:nocterm/nocterm.dart';
import 'ui/button.dart';
import '../models/provider_config.dart';
import '../services/provider_service.dart';

enum _FocusArea { apiKeyInput, toggleBtn, submitBtn, removeBtn, cancelBtn }

class ProviderWizardBuiltin extends StatefulComponent {
  final ProviderService service;
  final String providerName;
  final VoidCallback? onComplete;
  final VoidCallback? onDismiss;

  const ProviderWizardBuiltin({
    super.key,
    required this.service,
    required this.providerName,
    this.onComplete,
    this.onDismiss,
  });

  @override
  State<ProviderWizardBuiltin> createState() => _ProviderWizardBuiltinState();
}

class _ProviderWizardBuiltinState extends State<ProviderWizardBuiltin> {
  final TextEditingController _apiKeyController = TextEditingController();
  bool _apiKeyObscured = true;
  _FocusArea _focused = _FocusArea.apiKeyInput;
  bool _disposed = false;

  ProviderService get _service => component.service;
  String get _providerName => component.providerName;

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

  bool get _hasExistingKey => _service.getApiKey(_providerName) != null;

  bool get _keyIsValid {
    final key = _apiKeyController.text;
    return key.isNotEmpty && key.length >= 20;
  }

  void _submit() {
    if (!_keyIsValid) return;
    _service.setApiKey(_providerName, _apiKeyController.text);
    component.onComplete?.call();
  }

  void _removeKey() {
    _service.removeApiKey(_providerName);
    _apiKeyController.clear();
    setState(() {});
  }

  List<_FocusArea> get _focusSequence {
    final seq = <_FocusArea>[
      _FocusArea.apiKeyInput,
      _FocusArea.toggleBtn,
      _FocusArea.submitBtn,
    ];
    if (_hasExistingKey) seq.add(_FocusArea.removeBtn);
    seq.add(_FocusArea.cancelBtn);
    return seq;
  }

  void _cycleFocus(bool forward) {
    final seq = _focusSequence;
    final idx = seq.indexOf(_focused);
    if (idx == -1) {
      _focused = _FocusArea.apiKeyInput;
    } else {
      final next = forward
          ? (idx + 1) % seq.length
          : (idx - 1 + seq.length) % seq.length;
      _focused = seq[next];
    }
  }

  bool _handleKeyEvent(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      component.onDismiss?.call();
      return true;
    }
    final inTextField = _focused == _FocusArea.apiKeyInput;

    if ((event.logicalKey == LogicalKey.tab && !event.isShiftPressed) ||
        (!inTextField && event.logicalKey == LogicalKey.arrowDown) ||
        (!inTextField && event.logicalKey == LogicalKey.arrowRight)) {
      setState(() => _cycleFocus(true));
      return true;
    }
    if ((event.logicalKey == LogicalKey.tab && event.isShiftPressed) ||
        (!inTextField && event.logicalKey == LogicalKey.arrowUp) ||
        (!inTextField && event.logicalKey == LogicalKey.arrowLeft)) {
      setState(() => _cycleFocus(false));
      return true;
    }
    if (event.logicalKey == LogicalKey.enter) {
      switch (_focused) {
        case _FocusArea.submitBtn:
          _submit();
        case _FocusArea.removeBtn:
          _removeKey();
        case _FocusArea.cancelBtn:
          component.onDismiss?.call();
        case _FocusArea.toggleBtn:
          setState(() => _apiKeyObscured = !_apiKeyObscured);
        case _FocusArea.apiKeyInput:
          if (_keyIsValid) _submit();
      }
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    final provider = _service.providerByName(_providerName);
    final keyText = _apiKeyController.text;

    final rows = <Component>[];

    rows.add(
      Text(
        _providerName,
        style: const TextStyle(
          color: Colors.brightMagenta,
          fontWeight: FontWeight.bold,
        ),
      ),
    );

    if (provider != null) {
      rows.add(
        Text(
          '  ${provider.type.toConfigString().toUpperCase()} · ${provider.endpointUrl}',
          style: const TextStyle(color: Colors.gray),
        ),
      );
      rows.add(
        Text(
          '  Models: ${provider.models.map((m) => m.name).join(', ')}',
          style: const TextStyle(color: Colors.gray),
        ),
      );
    }

    rows.add(const SizedBox(height: 1));

    if (_hasExistingKey) {
      rows.add(
        Row(
          children: [
            const Text(
              '  ✓ Connected',
              style: TextStyle(color: Color.fromRGB(100, 220, 100)),
            ),
            const SizedBox(width: 2),
            Text(
              '(CRUX_API_KEY_${_providerName.toUpperCase()})',
              style: const TextStyle(color: Colors.gray),
            ),
          ],
        ),
      );
    } else {
      rows.add(
        const Text(
          '  Not connected',
          style: TextStyle(color: Colors.gray),
        ),
      );
    }

    rows.add(const SizedBox(height: 1));

    rows.add(
      Row(
        children: [
          const Text('Key: ', style: TextStyle(color: Colors.brightCyan)),
          Expanded(
            child: TextField(
              controller: _apiKeyController,
              focused: _focused == _FocusArea.apiKeyInput,
              onKeyEvent: (event) {
                if (event.logicalKey == LogicalKey.enter && _keyIsValid) {
                  _submit();
                  return true;
                }
                return _handleKeyEvent(event);
              },
              obscureText: _apiKeyObscured,
              obscuringCharacter: '•',
              style: const TextStyle(color: Colors.white),
              placeholder: _hasExistingKey
                  ? 'Enter new key to replace...'
                  : 'Paste your API key...',
            ),
          ),
        ],
      ),
    );

    if (keyText.isNotEmpty && keyText.length < 20) {
      rows.add(const SizedBox(height: 1));
      rows.add(
        Text(
          '  ⚠ At least 20 characters (${keyText.length}/20)',
          style: const TextStyle(color: Colors.brightYellow),
        ),
      );
    }

    rows.add(const SizedBox(height: 1));

    final buttons = <Component>[];

    buttons.add(
      Button(
        label: _apiKeyObscured ? '👁 Show' : '🔒 Hide',
        onPressed: () => setState(() => _apiKeyObscured = !_apiKeyObscured),
        focused: _focused == _FocusArea.toggleBtn,
        color: Colors.gray,
        hoverColor: Colors.brightCyan,
        bgColor: const Color.fromRGB(25, 20, 45),
        hoverBgColor: const Color.fromRGB(40, 30, 80),
      ),
    );

    buttons.add(
      Button(
        label: ' Connect ',
        onPressed: _submit,
        focused: _focused == _FocusArea.submitBtn,
        color: _keyIsValid
            ? const Color.fromRGB(100, 220, 100)
            : Colors.gray,
        hoverColor: Colors.brightCyan,
        bgColor: _keyIsValid
            ? const Color.fromRGB(20, 60, 20)
            : const Color.fromRGB(25, 20, 45),
        hoverBgColor: const Color.fromRGB(40, 30, 80),
      ),
    );

    if (_hasExistingKey) {
      buttons.add(
        Button(
          label: ' Remove Key ',
          onPressed: _removeKey,
          focused: _focused == _FocusArea.removeBtn,
          color: const Color.fromRGB(255, 80, 80),
          hoverColor: Colors.brightYellow,
          bgColor: const Color.fromRGB(60, 20, 20),
          hoverBgColor: const Color.fromRGB(40, 30, 80),
        ),
      );
    }

    buttons.add(
      Button(
        label: ' Cancel ',
        onPressed: () => component.onDismiss?.call(),
        focused: _focused == _FocusArea.cancelBtn,
        color: Colors.gray,
        hoverColor: Colors.brightCyan,
        bgColor: const Color.fromRGB(25, 20, 45),
        hoverBgColor: const Color.fromRGB(40, 30, 80),
      ),
    );

    rows.add(Row(children: buttons));

    final border = BoxBorder.all(color: const Color.fromRGB(80, 60, 120));

    return Focusable(
      focused: true,
      onKeyEvent: _handleKeyEvent,
      child: Container(
        decoration: BoxDecoration(
          color: const Color.fromRGB(18, 14, 30),
          border: border,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
      ),
    );
  }
}
