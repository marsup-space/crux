import 'package:nocterm/nocterm.dart';
import 'ui/button.dart';
import '../models/provider_config.dart';
import '../services/provider_service.dart';

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
    _service.setApiKey(_providerName, _apiKeyController.text).then((_) {
      component.onComplete?.call();
    });
  }

  void _removeKey() {
    _service.removeApiKey(_providerName).then((_) {
      _apiKeyController.clear();
      setState(() {});
    });
  }

  bool _handleGlobalKey(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.escape) {
      component.onDismiss?.call();
      return true;
    }
    return false;
  }

  bool _handleButtonKey(KeyboardEvent event, VoidCallback action) {
    if (event.logicalKey == LogicalKey.enter) {
      action();
      return true;
    }
    return _handleGlobalKey(event);
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
              focused: true,
              onKeyEvent: (event) {
                if (event.logicalKey == LogicalKey.escape) {
                  component.onDismiss?.call();
                  return true;
                }
                if (event.logicalKey == LogicalKey.enter && _keyIsValid) {
                  _submit();
                  return true;
                }
                return false;
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
      Focusable(
        onKeyEvent: (event) => _handleButtonKey(
          event,
          () => setState(() => _apiKeyObscured = !_apiKeyObscured),
        ),
        child: Builder(builder: (context) {
          final focused = Focus.of(context);
          return Button(
            label: _apiKeyObscured ? '👁 Show' : '🔒 Hide',
            onPressed: () => setState(() => _apiKeyObscured = !_apiKeyObscured),
            focused: focused,
            color: Colors.gray,
            hoverColor: Colors.brightCyan,
            bgColor: const Color.fromRGB(25, 20, 45),
            hoverBgColor: const Color.fromRGB(40, 30, 80),
          );
        }),
      ),
    );

    buttons.add(
      Focusable(
        onKeyEvent: (event) => _handleButtonKey(event, _submit),
        child: Builder(builder: (context) {
          final focused = Focus.of(context);
          return Button(
            label: ' Connect ',
            onPressed: _submit,
            focused: focused,
            color: _keyIsValid
                ? const Color.fromRGB(100, 220, 100)
                : Colors.gray,
            hoverColor: Colors.brightCyan,
            bgColor: _keyIsValid
                ? const Color.fromRGB(20, 60, 20)
                : const Color.fromRGB(25, 20, 45),
            hoverBgColor: const Color.fromRGB(40, 30, 80),
          );
        }),
      ),
    );

    if (_hasExistingKey) {
      buttons.add(
        Focusable(
          onKeyEvent: (event) => _handleButtonKey(event, _removeKey),
          child: Builder(builder: (context) {
            final focused = Focus.of(context);
            return Button(
              label: ' Remove Key ',
              onPressed: _removeKey,
              focused: focused,
              color: const Color.fromRGB(255, 80, 80),
              hoverColor: Colors.brightYellow,
              bgColor: const Color.fromRGB(60, 20, 20),
              hoverBgColor: const Color.fromRGB(40, 30, 80),
            );
          }),
        ),
      );
    }

    buttons.add(
      Focusable(
        onKeyEvent: (event) =>
            _handleButtonKey(event, () => component.onDismiss?.call()),
        child: Builder(builder: (context) {
          final focused = Focus.of(context);
          return Button(
            label: ' Cancel ',
            onPressed: () => component.onDismiss?.call(),
            focused: focused,
            color: Colors.gray,
            hoverColor: Colors.brightCyan,
            bgColor: const Color.fromRGB(25, 20, 45),
            hoverBgColor: const Color.fromRGB(40, 30, 80),
          );
        }),
      ),
    );

    rows.add(Row(children: buttons));

    final border = BoxBorder.all(color: const Color.fromRGB(80, 60, 120));

    return FocusScope(
      trapping: true,
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
