import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';

import '../i18n/locale_controller.dart';
import '../services/codex_oauth.dart';
import '../services/llm_client.dart';
import '../services/maple_font_installer.dart';
import '../services/terminal_font_service.dart';
import '../services/provider_service.dart';
import '../services/runtime_setup_service.dart';
import '../services/web_provider_registry.dart';
import '../theme/crux_theme.dart';
import '../theme/theme_controller.dart';
import '../utils/terminal_symbols.dart';
import '../utils/url_launcher.dart';
import 'ui/button.dart';
import 'ui/hoverable.dart';
import 'ui/option_toggle.dart';

const tinyFishApiKeysUrl = 'https://agent.tinyfish.ai/api-keys';

typedef ProviderConnectionTest = Future<String?> Function(
  String providerName,
  String modelKey,
);
typedef WebConnectionTest = Future<String?> Function();
typedef PrerequisiteCheck = Future<void> Function(
  RuntimeProgressCallback onProgress,
);
typedef CodexDeviceLogin = ({
  String verificationUrl,
  String userCode,
  String deviceId,
  Duration interval,
});
typedef CodexLoginStarter = Future<CodexDeviceLogin> Function();
typedef CodexLoginWaiter = Future<String> Function({
  required String deviceId,
  required String userCode,
  required Duration interval,
});
typedef ClipboardWriter = bool Function(String text);

Future<CodexDeviceLogin> _beginCodexLogin() => CodexOAuth.beginDeviceLogin();

Future<String> _waitForCodexLogin({
  required String deviceId,
  required String userCode,
  required Duration interval,
}) => CodexOAuth.waitForDeviceLogin(
  deviceId: deviceId,
  userCode: userCode,
  interval: interval,
);

bool _copyToClipboard(String text) => ClipboardManager.copy(text);

/// First-run, single-page setup experience. It deliberately owns a full
/// screen instead of living in Home: a model-less Crux cannot do useful work,
/// so setup is the application until the minimum configuration is complete.
class SetupGuide extends StatefulComponent {
  final ProviderService providerService;
  final WebProviderRegistry webProviderRegistry;
  final ThemeController themeController;
  final LocaleController localeController;
  final Future<void> Function(String defaultModel) onFinish;
  final VoidCallback? onQuit;
  final ProviderConnectionTest? testProvider;
  final WebConnectionTest? testWeb;
  final UrlLaunchResult Function(String url) launchUrl;
  final String projectPath;
  final PrerequisiteCheck? ensureSemble;
  final PrerequisiteCheck? ensureRipgrep;
  final CodexLoginStarter beginCodexLogin;
  final CodexLoginWaiter waitForCodexLogin;
  final ClipboardWriter copyToClipboard;
  final Map<String, String> Function()? environment;
  final TerminalFontService? terminalFont;
  final Future<void> Function(RuntimeProgressCallback)? installMapleFont;

  const SetupGuide({
    super.key,
    required this.providerService,
    required this.webProviderRegistry,
    required this.themeController,
    required this.localeController,
    required this.onFinish,
    this.onQuit,
    this.testProvider,
    this.testWeb,
    this.launchUrl = openUrl,
    this.projectPath = '',
    this.ensureSemble,
    this.ensureRipgrep,
    this.beginCodexLogin = _beginCodexLogin,
    this.waitForCodexLogin = _waitForCodexLogin,
    this.copyToClipboard = _copyToClipboard,
    this.environment,
    this.terminalFont,
    this.installMapleFont,
  });

  @override
  State<SetupGuide> createState() => _SetupGuideState();
}

class _SetupGuideState extends State<SetupGuide> {
  static const _providerKeyFocus = 16;
  static const _webKeyFocus = 23;
  static const _focusCount = 33;

  final _scroll = ScrollController();
  final _providerKey = TextEditingController();
  final _webKey = TextEditingController();
  int _focus = 0;
  int _providerIndex = 0;
  int _auxIndex = 0;
  bool _busy = false;
  final Set<String> _verifiedProviders = {};
  bool _auxVerified = false;
  bool _webVerified = false;
  bool _runtimeChecking = false;
  bool _sembleReady = false;
  bool _ripgrepReady = false;
  double _sembleProgress = 0;
  double _ripgrepProgress = 0;
  String _sembleStage = 'waiting';
  String _ripgrepStage = 'waiting';
  String _sembleTransfer = '';
  String _ripgrepTransfer = '';
  String _runtimeStatus = '';
  bool _fontCardVisible = false;
  TerminalFontStatus? _fontStatus;
  bool _fontInstalled = false;
  bool _fontBusy = false;
  bool _fontInstalling = false;
  double _fontProgress = 0;
  String _fontStage = 'waiting';
  String _fontStatusText = '';
  CellWidthPreset? _fontCellWidthPreset;
  String _languageError = '';
  String _providerStatus = '';
  String? _codexUserCode;
  String _auxStatus = '';
  String _webStatus = '';
  String _finishStatus = '';

  bool get _zh => component.localeController.activeCode == 'zh';
  String _t(String en, String zh) => _zh ? zh : en;
  List<String> get _providers => component.providerService.providerNames();

  List<String> get _configuredModels {
    final service = component.providerService;
    return service
        .allModelKeys()
        .where((key) {
          final provider = key.split('/').first;
          final apiKey = service.getApiKey(provider);
          return apiKey != null && apiKey.isNotEmpty;
        })
        .toList(growable: false);
  }

  String get _selectedProvider =>
      _providers.isEmpty ? '' : _providers[_providerIndex % _providers.length];

  String get _selectedAux {
    final models = _configuredModels;
    if (models.isEmpty) return '';
    _auxIndex %= models.length;
    return models[_auxIndex];
  }

  String? get _verifiedDefaultModel {
    final current = component.providerService.resolveDefaultModel();
    if (current != null &&
        _verifiedProviders.contains(current.split('/').first)) {
      return current;
    }
    for (final model in component.providerService.allModelKeys()) {
      if (_verifiedProviders.contains(model.split('/').first)) return model;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // ProviderService is initialized during app boot. A persisted credential
    // is already a connected provider when /setup is opened again; requiring
    // a fresh test in this particular SetupGuide instance made the status row
    // say "Connected" while the card incorrectly kept its incomplete border.
    _verifiedProviders.addAll(
      _providers.where(
        (name) =>
            component.providerService.getApiKey(name)?.isNotEmpty ?? false,
      ),
    );
    _restoreAuxiliaryModel();
    unawaited(_initializeWebProvider());

    unawaited(_checkRuntime());
    unawaited(_initializeTerminalFont());
  }

  /// The terminal font card only exists for Windows Terminal hosts with a
  /// settings file. Detection and the status read touch nothing on disk
  /// besides reading — nothing is written until the user presses a button.
  ///
  /// [SetupGuide.environment] is the only environment source here on
  /// purpose: a plain `dart test` on a developer machine otherwise
  /// inherits `WT_SESSION` from the hosting terminal and the card would
  /// flap in unrelated layout assertions.
  Future<void> _initializeTerminalFont() async {
    final env = component.environment?.call();
    if (env == null) return;
    if (detectTerminalHost(env) != TerminalHost.windowsTerminal) return;
    final service = component.terminalFont ?? TerminalFontService();
    if (service.findSettingsFile() == null) return;
    final status = await service.loadStatus();
    if (!mounted) return;
    setState(() {
      _fontCardVisible = true;
      _fontStatus = status;
      // Normalize to a real preset so Apply always sends an explicit
      // choice; defaultWidth on a file without cellWidth is a no-op.
      _fontCellWidthPreset = status?.cellWidthPreset ?? CellWidthPreset.defaultWidth;
      _fontInstalled = isMapleMonoInstalled(service.localAppData);
    });
  }

  /// Restores the persisted auxiliary-model choice when setup is reopened.
  /// It is considered configured but not freshly connection-tested in this
  /// guide, so users may still explicitly run the verification action.
  void _restoreAuxiliaryModel() {
    final saved = component.providerService.auxiliaryModel;
    if (saved == null || saved == 'none') return;
    final index = _configuredModels.indexOf(saved);
    if (index < 0) return;
    _auxIndex = index;
    _auxVerified = true;
    _auxStatus = _t('Saved auxiliary model loaded', '已加载保存的辅助模型');
  }

  Future<void> _initializeWebProvider() async {
    await component.webProviderRegistry.initialize();
    if (!mounted) return;
    final savedKey = component.webProviderRegistry.getApiKey('tinyfish');
    if (savedKey == null || savedKey.isEmpty) return;
    _webKey.text = savedKey;
    setState(() {
      _webVerified = true;
      _webStatus = _t('Saved TinyFish key loaded', '已加载保存的 TinyFish key');
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _providerKey.dispose();
    _webKey.dispose();
    super.dispose();
  }

  void _moveFocus(int delta) {
    setState(() {
      do {
        _focus = (_focus + delta) % _focusCount;
        if (_focus < 0) _focus += _focusCount;
      } while (!_isFocusable(_focus));
    });
    // Keep keyboard navigation useful in short terminals. The scroll view
    // clamps automatically, and users can still wheel/PageUp/PageDown.
    if (delta > 0) _scroll.scrollBy(2);
    if (delta < 0) _scroll.scrollBy(-2);
  }

  bool _isFocusable(int index) {
    final codex = _selectedProvider == 'codex';
    if (codex && index == _providerKeyFocus) return false;
    if (codex && index == 17 && _codexUserCode == null) return false;
    if (!codex && index == 18) return false;
    return true;
  }

  bool _fieldKey(KeyboardEvent event) {
    if (_quitIfRequested(event)) return true;
    if (_exitSetupIfReady(event)) return true;
    if (event.logicalKey == LogicalKey.tab) {
      _moveFocus(event.isShiftPressed ? -1 : 1);
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      _moveFocus(-1);
      return true;
    }
    return false;
  }

  bool _handleKey(KeyboardEvent event) {
    if (_quitIfRequested(event)) return true;
    if (_exitSetupIfReady(event)) return true;
    if (event.logicalKey == LogicalKey.tab) {
      _moveFocus(event.isShiftPressed ? -1 : 1);
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowDown) {
      _moveFocus(1);
      return true;
    }
    if (event.logicalKey == LogicalKey.arrowUp) {
      _moveFocus(-1);
      return true;
    }
    if (event.logicalKey == LogicalKey.pageDown) {
      _scroll.pageDown();
      return true;
    }
    if (event.logicalKey == LogicalKey.pageUp) {
      _scroll.pageUp();
      return true;
    }
    if (event.logicalKey == LogicalKey.enter && !_busy) {
      _activate(_focus);
      return true;
    }
    return false;
  }

  bool _quitIfRequested(KeyboardEvent event) {
    if (!event.matches(LogicalKey.keyC, ctrl: true)) return false;
    component.onQuit?.call();
    return true;
  }

  /// Esc leaves setup as soon as the minimum useful configuration exists:
  /// one resolvable LLM. Auxiliary/web/runtime cards remain optional for this
  /// exit path, including when a secret input currently owns focus.
  bool _exitSetupIfReady(KeyboardEvent event) {
    if (event.logicalKey != LogicalKey.escape) return false;
    final defaultModel = component.providerService.resolveDefaultModel();
    if (defaultModel == null) return false;
    unawaited(component.onFinish(defaultModel));
    return true;
  }

  void _activate(int index) {
    if (index == 0) unawaited(_chooseUiLanguage('en'));
    if (index == 1) unawaited(_chooseUiLanguage('zh'));
    if (index == 2) unawaited(_chooseReplyLanguage('follow'));
    if (index == 3) unawaited(_chooseReplyLanguage('auto'));
    if (index >= 4 && index < 14) {
      final themes = component.themeController.availableIds;
      final themeIndex = index - 4;
      if (themeIndex < themes.length) {
        unawaited(_chooseTheme(themes[themeIndex]));
      }
    }
    if (index == 14) _cycleProvider(-1);
    if (index == 15) _cycleProvider(1);
    if (index == 17) {
      if (_selectedProvider == 'codex') {
        _copyCodexCode();
      } else {
        unawaited(_saveAndTestProvider());
      }
    }
    if (index == 18) unawaited(_connectCodex());
    if (index == 19) _cycleAux(-1);
    if (index == 20) _cycleAux(1);
    if (index == 21) unawaited(_verifyAux());
    if (index == 22) _openTinyFish();
    if (index == 24) unawaited(_saveAndTestWeb());
    if (index == 25) unawaited(_finish());
    if (index == 26) unawaited(_checkRuntime());
    if (index == 27 && !_fontInstalled && !_fontBusy) {
      unawaited(_installTerminalFont());
    }
    if (index >= 28 && index < 32) {
      setState(() => _fontCellWidthPreset = CellWidthPreset.values[index - 28]);
    }
    if (index == 32 && !_fontBusy) unawaited(_applyTerminalFont());
  }

  void _updateFontProgress(
    double progress,
    String stage, [
    RuntimeTransferStats? stats,
  ]) {
    if (!mounted) return;
    setState(() {
      _fontProgress = progress;
      _fontStage = stage;
      _fontStatusText = _formatTransfer(stats);
    });
  }

  Future<void> _installTerminalFont() async {
    setState(() {
      _fontBusy = true;
      _fontInstalling = true;
      _fontProgress = 0;
      _fontStage = 'checking';
      _fontStatusText = '';
    });
    try {
      final injected = component.installMapleFont;
      final fontService = component.terminalFont ?? TerminalFontService();
      if (injected != null) {
        await injected(_updateFontProgress);
      } else {
        await installMapleMonoNfCn(
          onProgress: _updateFontProgress,
          localAppData: fontService.localAppData,
        );
      }
      final status = await fontService.loadStatus();
      if (!mounted) return;
      setState(() {
        _fontInstalled = true;
        _fontStatus = status;
        _fontCellWidthPreset =
            status?.cellWidthPreset ?? CellWidthPreset.defaultWidth;
        _fontStatusText = _t('Maple Mono NF CN installed', 'Maple Mono NF CN 已安装');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _fontStatusText = _runtimeFailure('Maple Mono', error));
    } finally {
      if (mounted) {
        setState(() {
          _fontBusy = false;
          _fontInstalling = false;
        });
      }
    }
  }

  Future<void> _applyTerminalFont() async {
    final service = component.terminalFont ?? TerminalFontService();
    final preset = _fontCellWidthPreset;
    setState(() {
      _fontBusy = true;
      _fontStatusText = _t('Saving font settings…', '正在保存字体设置…');
    });
    try {
      await service.applyFontSettings(
        FontSettingsEdit(
          face: _fontInstalled ? mapleFontFaceName : null,
          cellWidthPreset: preset,
        ),
      );
      final status = await service.loadStatus();
      if (!mounted) return;
      setState(() {
        _fontStatus = status;
        _fontCellWidthPreset =
            status?.cellWidthPreset ?? CellWidthPreset.defaultWidth;
        _fontStatusText = _t('Font settings saved', '字体设置已保存');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _fontStatusText = _runtimeFailure('font', error));
    } finally {
      if (mounted) setState(() => _fontBusy = false);
    }
  }

  Future<void> _checkRuntime() async {
    if (_runtimeChecking) return;
    setState(() {
      _runtimeChecking = true;
      _sembleProgress = 0;
      _ripgrepProgress = 0;
      _sembleStage = 'checking';
      _ripgrepStage = 'checking';
      _sembleTransfer = '';
      _ripgrepTransfer = '';
      _runtimeStatus = _t(
        'Preparing Semble model and ripgrep…',
        '正在准备 Semble 模型和 ripgrep…',
      );
    });
    final service = RuntimeSetupService();
    Object? sembleError;
    Object? ripgrepError;
    await Future.wait([
      () async {
        try {
          final injected = component.ensureSemble;
          if (injected != null) {
            await injected(_updateSembleProgress);
          } else {
            await service.ensureSemble(
              component.projectPath.isEmpty
                  ? Directory.current.path
                  : component.projectPath,
              onProgress: _updateSembleProgress,
            );
          }
          _sembleReady = true;
          _sembleProgress = 1;
          _sembleStage = 'ready';
        } catch (error) {
          sembleError = error;
          _sembleReady = false;
          _sembleStage = 'failed';
        }
      }(),
      () async {
        try {
          final injected = component.ensureRipgrep;
          if (injected != null) {
            await injected(_updateRipgrepProgress);
          } else {
            await service.ensureRipgrep(onProgress: _updateRipgrepProgress);
          }
          _ripgrepReady = true;
          _ripgrepProgress = 1;
          _ripgrepStage = 'ready';
        } catch (error) {
          ripgrepError = error;
          _ripgrepReady = false;
          _ripgrepStage = 'failed';
        }
      }(),
    ]);
    if (!mounted) return;
    setState(() {
      _runtimeChecking = false;
      if (_sembleReady && _ripgrepReady) {
        _runtimeStatus = _t(
          'Semble model and ripgrep are ready',
          'Semble 模型和 ripgrep 已就绪',
        );
      } else {
        final failures = <String>[
          if (sembleError != null) _runtimeFailure('Semble', sembleError!),
          if (ripgrepError != null) _runtimeFailure('ripgrep', ripgrepError!),
        ];
        _runtimeStatus = failures.join(' · ');
      }
    });
  }

  void _updateSembleProgress(
    double progress,
    String stage, [
    RuntimeTransferStats? stats,
  ]) {
    if (!mounted) return;
    setState(() {
      _sembleProgress = progress;
      _sembleStage = stage;
      _sembleTransfer = _formatTransfer(stats);
    });
  }

  void _updateRipgrepProgress(
    double progress,
    String stage, [
    RuntimeTransferStats? stats,
  ]) {
    if (!mounted) return;
    setState(() {
      _ripgrepProgress = progress;
      _ripgrepStage = stage;
      _ripgrepTransfer = _formatTransfer(stats);
    });
  }

  String _runtimeFailure(String name, Object error) {
    final raw = switch (error) {
      HttpException(:final message) => message,
      SocketException(:final message) => message,
      _ => '$error',
    };
    final compact = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final message = compact.length > 140
        ? '${compact.substring(0, 139)}…'
        : compact;
    return '$name: $message';
  }

  String _formatTransfer(RuntimeTransferStats? stats) {
    if (stats == null) return '';
    if (stats.sourceCount case final count?) {
      return _t('Testing $count download sources…', '正在测试 $count 个下载源…');
    }
    final parts = <String>[];
    if (stats.receivedBytes case final received?) {
      final downloaded = _formatBytes(received);
      parts.add(
        stats.totalBytes == null
            ? downloaded
            : '$downloaded / ${_formatBytes(stats.totalBytes!)}',
      );
    }
    if (stats.bytesPerSecond case final speed?) {
      parts.add('${_formatBytes(speed.round())}/s');
    }
    if (stats.source case final source?) parts.add(source);
    return parts.join('  ·  ');
  }

  String _formatBytes(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = value >= 100 || unit == 0 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  Future<void> _chooseUiLanguage(String code) async {
    final result = await component.localeController.switchLocale(code);
    if (!mounted) return;
    setState(() {
      _languageError = result.persisted
          ? ''
          : _t('Could not save interface language', '无法保存界面语言');
    });
  }

  Future<void> _chooseReplyLanguage(String code) async {
    final result = await component.localeController.switchReplyLanguage(code);
    if (!mounted) return;
    setState(() {
      _languageError = result.persisted
          ? ''
          : _t('Could not save reply language', '无法保存回复语言');
    });
  }

  Future<void> _chooseTheme(String id) async {
    final result = await component.themeController.switchTheme(id);
    setState(() {
      _finishStatus = result.persisted
          ? ''
          : _t('Theme could not be saved', '主题无法保存');
    });
  }

  void _cycleProvider(int delta) {
    if (_providers.isEmpty) return;
    setState(() {
      _providerIndex = (_providerIndex + delta) % _providers.length;
      if (_providerIndex < 0) _providerIndex += _providers.length;
      _providerKey.clear();
      _providerStatus = '';
    });
  }

  Future<String?> _runProviderTest(String provider, String model) async {
    final injected = component.testProvider;
    if (injected != null) return injected(provider, model);
    final config = component.providerService.providerByName(provider);
    final key = component.providerService.getApiKey(provider);
    if (config == null || key == null || key.isEmpty) {
      return _t('API key is missing', '缺少 API key');
    }
    final modelConfig = component.providerService.modelByCompositeKey(model);
    if (modelConfig == null) return _t('No model is available', '没有可用模型');
    final cancel = LlmStreamCancelToken();
    try {
      await for (final chunk
          in LlmClient()
              .streamChat(
                endpointUrl: config.endpointUrl,
                config: config,
                apiKey: key,
                modelId: modelConfig.id,
                messages: const [
                  {'role': 'user', 'content': 'Reply with OK.'},
                ],
                thinkingMode: 'disabled',
                reasoningEffort: 'off',
                maxTokens: 4,
                temperature: 0,
                cancelToken: cancel,
              )
              .timeout(const Duration(seconds: 30))) {
        if (chunk.error != null) return chunk.error!.toUserMessage();
        if (chunk.textDelta != null || chunk.finishReason != null) return null;
      }
      return _t('Provider returned no response', 'Provider 没有返回响应');
    } catch (error) {
      await cancel.cancelActiveStream(reason: 'setup validation ended');
      return '$error';
    }
  }

  Future<void> _saveAndTestProvider() async {
    final provider = _selectedProvider;
    final key = _providerKey.text.trim();
    if (provider.isEmpty || key.isEmpty) {
      setState(
        () => _providerStatus = _t(
          'Choose a provider and enter its API key',
          '请选择 provider 并输入 API key',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _providerStatus = _t('Testing connection…', '正在测试连接…');
    });
    await component.providerService.setApiKey(provider, key);
    final config = component.providerService.providerByName(provider);
    final model = config == null || config.models.isEmpty
        ? ''
        : config.models.first.compositeKey(provider);
    final error = model.isEmpty
        ? _t('Provider has no models', 'Provider 没有模型')
        : await _runProviderTest(provider, model);
    setState(() {
      _busy = false;
      _providerStatus = error == null
          ? _t(
              'Connected. You can add another provider.',
              '连接成功；你还可以继续添加其他 provider。',
            )
          : _t('Saved, but test failed: $error', '已保存，但测试失败：$error');
      if (error == null) {
        _verifiedProviders.add(provider);
      } else {
        _verifiedProviders.remove(provider);
      }
    });
  }

  Future<void> _connectCodex() async {
    if (_selectedProvider != 'codex') {
      setState(
        () => _providerStatus = _t(
          'Select codex first to use ChatGPT sign-in',
          '请先选择 codex，再使用 ChatGPT 登录',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _providerStatus = _t('Starting ChatGPT sign-in…', '正在启动 ChatGPT 登录…');
    });
    try {
      final login = await component.beginCodexLogin();
      component.launchUrl(login.verificationUrl);
      setState(() {
        _codexUserCode = login.userCode;
        _providerStatus = _t(
          'Browser opened. Enter the code below.',
          '浏览器已打开，请输入下方代码。',
        );
      });
      final credential = await component
          .waitForCodexLogin(
            deviceId: login.deviceId,
            userCode: login.userCode,
            interval: login.interval,
          )
          .timeout(const Duration(minutes: 5));
      await component.providerService.setApiKey('codex', credential);
      final model = component.providerService
          .providerByName('codex')!
          .models
          .first
          .compositeKey('codex');
      final error = await _runProviderTest('codex', model);
      setState(
        () => _providerStatus = error == null
            ? _t('ChatGPT Codex connected', 'ChatGPT Codex 已连接')
            : _t('Signed in, but test failed: $error', '已登录，但测试失败：$error'),
      );
      if (error == null) _verifiedProviders.add('codex');
    } catch (error) {
      setState(
        () => _providerStatus = _t(
          'ChatGPT sign-in failed: $error',
          'ChatGPT 登录失败：$error',
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _codexUserCode = null;
        });
      }
    }
  }

  void _copyCodexCode() {
    final code = _codexUserCode;
    if (code == null) return;
    final copied = component.copyToClipboard(code);
    setState(() {
      _providerStatus = copied
          ? _t('Device code copied', '验证码已复制')
          : _t('Could not copy the device code', '无法复制验证码');
    });
  }

  void _cycleAux(int delta) {
    final models = _configuredModels;
    if (models.isEmpty) return;
    setState(() {
      _auxIndex = (_auxIndex + delta) % models.length;
      if (_auxIndex < 0) _auxIndex += models.length;
      _auxStatus = '';
      _auxVerified = false;
    });
  }

  Future<void> _verifyAux() async {
    final model = _selectedAux;
    if (model.isEmpty) {
      setState(
        () => _auxStatus = _t('Connect a provider first', '请先连接 provider'),
      );
      return;
    }
    setState(() {
      _busy = true;
      _auxStatus = _t('Testing auxiliary model…', '正在测试辅助模型…');
    });
    await component.providerService.setAuxiliaryModel(model);
    final error = await _runProviderTest(model.split('/').first, model);
    setState(() {
      _busy = false;
      _auxStatus = error == null
          ? _t('Auxiliary model verified', '辅助模型验证成功')
          : _t('Test failed: $error', '测试失败：$error');
      _auxVerified = error == null;
    });
  }

  void _openTinyFish() {
    final result = component.launchUrl(tinyFishApiKeysUrl);
    setState(
      () => _webStatus = result == UrlLaunchResult.launched
          ? _t(
              'Browser opened. Create a key, then paste it below.',
              '浏览器已打开。创建 key 后粘贴到下方。',
            )
          : _t(
              'Open $tinyFishApiKeysUrl in your browser',
              '请在浏览器打开 $tinyFishApiKeysUrl',
            ),
    );
  }

  Future<void> _saveAndTestWeb() async {
    final enteredKey = _webKey.text.trim();
    final key = enteredKey.isNotEmpty
        ? enteredKey
        : component.webProviderRegistry.getApiKey('tinyfish');
    if (key == null || key.isEmpty) {
      setState(
        () => _webStatus = _t(
          'Enter your TinyFish API key',
          '请输入 TinyFish API key',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _webStatus = _t('Testing TinyFish search…', '正在测试 TinyFish 搜索…');
    });
    if (enteredKey.isNotEmpty) {
      await component.webProviderRegistry.setApiKey('tinyfish', enteredKey);
    }
    String? error;
    try {
      final injected = component.testWeb;
      if (injected != null) {
        error = await injected();
      } else {
        final provider = component.webProviderRegistry.getProvider('tinyfish');
        if (provider == null) {
          error = 'TinyFish is unavailable';
        } else {
          await provider.search(query: 'Crux setup connection test');
        }
      }
    } catch (e) {
      error = '$e';
    }
    setState(() {
      _busy = false;
      _webStatus = error == null
          ? _t('TinyFish verified', 'TinyFish 验证成功')
          : _t('Saved, but test failed: $error', '已保存，但测试失败：$error');
      _webVerified = error == null;
    });
  }

  Future<void> _finish() async {
    final defaultModel = _verifiedDefaultModel;
    final aux = component.providerService.auxiliaryModel;
    final webReady =
        component.webProviderRegistry.isAnySearchProviderConfigured;
    if (defaultModel == null ||
        aux == null ||
        aux == 'none' ||
        !_auxVerified ||
        !webReady ||
        !_webVerified ||
        !_sembleReady ||
        !_ripgrepReady) {
      setState(
        () => _finishStatus = _t(
          'Verify every card and wait for runtime tools before finishing.',
          '请验证所有卡片，并等待运行时工具准备完成。',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _finishStatus = _t('Saving setup…', '正在保存设置…');
    });
    await component.providerService.setLastUsedModel(defaultModel);
    await component.onFinish(defaultModel);
  }

  Component _button(
    int index,
    String label,
    VoidCallback? onPressed, {
    bool allowWhileBusy = false,
  }) => Button(
    label: label,
    onPressed: (_busy && !allowWhileBusy) || onPressed == null
        ? null
        : () {
            if (_focus != index) setState(() => _focus = index);
            onPressed();
          },
    focused: _focus == index,
  );

  Component _status(String value) => value.isEmpty
      ? const SizedBox()
      : Text(
          value,
          style: TextStyle(color: CruxTheme.of(context).onSurfaceVariant),
        );

  Component _secretInput({
    required TextEditingController controller,
    required int focusIndex,
    required String placeholder,
    required VoidCallback onSubmitted,
  }) {
    final theme = CruxTheme.of(context);
    final focused = _focus == focusIndex;
    final borderColor = focused ? theme.buttonTextFocused : theme.outline;
    return Hoverable(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (_focus != focusIndex) setState(() => _focus = focusIndex);
      },
      builder: (context, hovered) {
        final effectiveBorderColor = focused || hovered
            ? theme.buttonTextFocused
            : borderColor;
        return TextField(
          controller: controller,
          focused: focused,
          onFocusChange: (hasFocus) {
            if (hasFocus && _focus != focusIndex) {
              setState(() => _focus = focusIndex);
            }
          },
          obscureText: true,
          maxLines: 1,
          placeholder: placeholder,
          placeholderStyle: TextStyle(color: theme.onSurfaceDim),
          style: TextStyle(color: theme.foreground),
          decoration: InputDecoration(
            border: BoxBorder.all(
              color: effectiveBorderColor,
              style: BoxBorderStyle.rounded,
            ),
            focusedBorder: BoxBorder.all(
              color: effectiveBorderColor,
              style: BoxBorderStyle.rounded,
            ),
            contentPadding: EdgeInsets.zero,
          ),
          onKeyEvent: _fieldKey,
          onSubmitted: (_) => onSubmitted(),
        );
      },
    );
  }

  Component _section(
    BuildContext context,
    String number,
    String title,
    List<Component> children, {
    bool completed = false,
  }) => _SetupCard(
    number: number,
    title: title,
    completed: completed,
    children: children,
  );

  Component _languageCard(BuildContext context) =>
      _section(context, '1', _t('Language', '语言'), [
        Text(
          _t('Interface language', '界面语言'),
          style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
        ),
        OptionToggle(
          options: const ['English', '中文'],
          selectedIndex: component.localeController.activeCode == 'zh' ? 1 : 0,
          selectedBgColor: CruxTheme.of(context).buttonBackgroundHover,
          unselectedBgColor: CruxTheme.of(context).buttonBackground,
          hoverBgColor: CruxTheme.of(context).buttonBackgroundHover,
          onFocusRequest: (index) => setState(() => _focus = index),
          onChanged: (index) =>
              unawaited(_chooseUiLanguage(index == 0 ? 'en' : 'zh')),
          focused: _focus == 0 || _focus == 1,
        ),
        const SizedBox(height: 1),
        Text(
          _t('Reply language', '回复语言'),
          style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
        ),
        OptionToggle(
          options: [_t('Follow interface', '跟随界面'), _t('Auto-detect', '自动识别')],
          selectedIndex: component.localeController.replyLanguageCode == 'auto'
              ? 1
              : 0,
          selectedBgColor: CruxTheme.of(context).buttonBackgroundHover,
          unselectedBgColor: CruxTheme.of(context).buttonBackground,
          hoverBgColor: CruxTheme.of(context).buttonBackgroundHover,
          onFocusRequest: (index) => setState(() => _focus = index + 2),
          onChanged: (index) =>
              unawaited(_chooseReplyLanguage(index == 0 ? 'follow' : 'auto')),
          focused: _focus == 2 || _focus == 3,
        ),
        _status(_languageError),
      ], completed: _languageError.isEmpty);

  Component _themeCard(BuildContext context) {
    final themes = component.themeController.availableIds.take(10).toList();
    final dark = themes
        .where(
          (id) =>
              component.themeController.registry[id]?.brightness ==
              Brightness.dark,
        )
        .toList();
    final light = themes
        .where(
          (id) =>
              component.themeController.registry[id]?.brightness ==
              Brightness.light,
        )
        .toList();
    Component themeButton(String id) => _button(
      4 + themes.indexOf(id),
      '${component.themeController.activeId == id ? terminalSymbol('●', '*') : terminalSymbol('○', 'o')} $id',
      () => unawaited(_chooseTheme(id)),
    );
    Component themeColumn(String title, List<String> ids) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$title  ${ids.length}',
          style: TextStyle(
            color: CruxTheme.of(context).onSurfaceVariant,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 1),
        for (final id in ids) themeButton(id),
      ],
    );
    return _section(context, '2', _t('Theme', '主题'), [
      Text(
        _t('Preview instantly · 10 curated themes', '即时预览 · 10 个精选主题'),
        style: TextStyle(color: CruxTheme.of(context).onSurfaceDim),
      ),
      const SizedBox(height: 1),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: themeColumn(_t('Dark', '深色'), dark)),
          const SizedBox(width: 2),
          Expanded(child: themeColumn(_t('Light', '浅色'), light)),
        ],
      ),
    ], completed: true);
  }

  Component _providerCard(
    BuildContext context,
    String provider,
    List<String> configured,
  ) {
    final theme = CruxTheme.of(context);
    return _section(context, '3', _t('LLM providers', 'LLM providers'), [
      Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              _t('At least one · add as many as you use', '至少一个 · 可继续添加多个'),
              style: TextStyle(color: theme.onSurfaceDim),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Align(
              alignment: Alignment.topRight,
              child: Text(
                _t(
                  'Connected  ${configured.isEmpty ? '—' : configured.join('  ·  ')}',
                  '已连接  ${configured.isEmpty ? '—' : configured.join('  ·  ')}',
                ),
                style: TextStyle(
                  color: configured.isEmpty ? theme.warning : theme.success,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 1),
      Row(
        children: [
          _button(14, ' ‹ ', () => _cycleProvider(-1)),
          Expanded(
            child: Container(
              color: theme.buttonBackground,
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Text(
                provider.isEmpty
                    ? _t('No providers found', '未找到 provider')
                    : provider,
                style: TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          _button(15, ' › ', () => _cycleProvider(1)),
        ],
      ),
      if (provider == 'codex') ...[
        Text(
          _t(
            'Authenticate through your ChatGPT account.',
            '通过 ChatGPT 账号完成授权。',
          ),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
        _button(
          18,
          _t(' Sign in with ChatGPT ', ' 使用 ChatGPT 登录 '),
          () => unawaited(_connectCodex()),
        ),
        if (_codexUserCode case final code?) ...[
          const SizedBox(height: 1),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                color: theme.buttonBackgroundHover,
                child: Text(
                  code,
                  style: TextStyle(
                    color: theme.success,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 1),
              _button(
                17,
                _t(' Copy code ', ' 复制代码 '),
                _copyCodexCode,
                allowWhileBusy: true,
              ),
            ],
          ),
        ],
      ] else ...[
        Text(
          _t('API key', 'API key'),
          style: TextStyle(color: theme.onSurfaceVariant),
        ),
        _secretInput(
          controller: _providerKey,
          focusIndex: _providerKeyFocus,
          placeholder: _t('Paste API key', '粘贴 API key'),
          onSubmitted: () => unawaited(_saveAndTestProvider()),
        ),
        const SizedBox(height: 1),
        _button(
          17,
          _t('Save + test', '保存 + 测试'),
          () => unawaited(_saveAndTestProvider()),
        ),
      ],
      _status(_providerStatus),
    ], completed: _verifiedProviders.isNotEmpty);
  }

  Component _auxCard(BuildContext context) {
    final theme = CruxTheme.of(context);
    final selected = _selectedAux;
    return _section(context, '4', _t('Auxiliary model', '辅助模型'), [
      Text(
        _t('Required for titles, summaries, and safety checks', '用于标题、摘要与安全检查'),
        style: TextStyle(color: theme.onSurfaceDim),
      ),
      const SizedBox(height: 1),
      Row(
        children: [
          _button(19, ' ‹ ', () => _cycleAux(-1)),
          Expanded(
            child: Container(
              color: theme.buttonBackground,
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Text(
                selected.isEmpty
                    ? _t('Connect a provider first', '请先连接 provider')
                    : component.providerService.displayLabelFor(selected),
                style: TextStyle(fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          _button(20, ' › ', () => _cycleAux(1)),
        ],
      ),
      _button(
        21,
        _t(' Use this model + test ', ' 使用此模型 + 测试 '),
        () => unawaited(_verifyAux()),
      ),
      _status(_auxStatus),
    ], completed: _auxVerified);
  }

  Component _webCard(BuildContext context) {
    final theme = CruxTheme.of(context);
    final savedKey = component.webProviderRegistry.getApiKey('tinyfish');
    final configured = savedKey != null && savedKey.isNotEmpty;
    return _section(context, '5', _t('Web · TinyFish', 'Web · TinyFish'), [
      Text(
        configured
            ? _t(
                'Configured · Edit the key or test it again',
                '已配置 · 可以修改 key 或重新测试',
              )
            : _t(
                'Recommended · Search and Fetch are free',
                '推荐使用 · Search 和 Fetch 免费',
              ),
        style: TextStyle(color: theme.onSurfaceDim),
      ),
      const SizedBox(height: 1),
      _button(
        22,
        configured
            ? _t('Manage TinyFish API keys ↗', '管理 TinyFish API keys ↗')
            : _t('1  Create account + API key ↗', '1  注册并创建 API key ↗'),
        _openTinyFish,
      ),
      Padding(
        padding: const EdgeInsets.only(left: 1),
        child: Text(
          configured ? 'API key' : '2  API key',
          style: TextStyle(color: theme.onSurfaceVariant),
        ),
      ),
      _secretInput(
        controller: _webKey,
        focusIndex: _webKeyFocus,
        placeholder: _t('Paste TinyFish API key', '粘贴 TinyFish API key'),
        onSubmitted: () => unawaited(_saveAndTestWeb()),
      ),
      _button(
        24,
        configured
            ? _t('Save changes + test', '保存修改 + 测试')
            : _t('3  Save + test search', '3  保存 + 测试搜索'),
        () => unawaited(_saveAndTestWeb()),
      ),
      _status(_webStatus),
    ], completed: _webVerified);
  }

  String _runtimeStage(String stage) => switch (stage) {
    'checking' => _t('checking', '检查中'),
    'testing_sources' => _t('testing sources', '测试下载源'),
    'downloading_model' => _t('downloading model', '下载模型'),
    'downloading_tokenizer' => _t('downloading tokenizer', '下载 tokenizer'),
    'downloading' => _t('downloading', '下载中'),
    'verifying' => _t('verifying', '校验中'),
    'extracting' => _t('extracting', '解压中'),
    'registering' => _t('registering', '注册中'),
    'warming_up' => _t('warming up', '预热中'),
    'ready' => _t('ready', '已就绪'),
    'failed' => _t('failed', '失败'),
    _ => _t('waiting', '等待中'),
  };

  Component _progressRow(
    String label,
    double progress,
    String stage,
    String transfer,
  ) {
    final theme = CruxTheme.of(context);
    final value = progress.clamp(0.0, 1.0).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
            Text(
              '${(value * 100).round().toString().padLeft(3)}%',
              style: TextStyle(color: theme.onSurfaceVariant),
            ),
          ],
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.clamp(10, 36).floor();
            final filled = (width * value).round().clamp(0, width).toInt();
            return Row(
              children: [
                Text(
                  terminalSymbol('█', '#') * filled,
                  style: TextStyle(color: theme.accent),
                ),
                Text(
                  terminalSymbol('░', '-') * (width - filled),
                  style: TextStyle(color: theme.outline),
                ),
                const SizedBox(width: 1),
                Expanded(
                  child: Text(
                    _runtimeStage(stage),
                    style: TextStyle(
                      color: stage == 'failed'
                          ? theme.error
                          : stage == 'ready'
                          ? theme.success
                          : theme.onSurfaceDim,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            );
          },
        ),
        if (transfer.isNotEmpty)
          Text(
            transfer,
            style: TextStyle(color: theme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  Component _fontCard(BuildContext context) {
    final theme = CruxTheme.of(context);
    final status = _fontStatus;
    final face = status?.fontFace;
    final cellWidth = status?.cellWidth;
    const presetLabels = ['default', '0.95ch', '0.9ch', '0.85ch'];
    final selectedPreset = _fontCellWidthPreset ?? CellWidthPreset.defaultWidth;
    return _section(
      context,
      '6',
      _t('Terminal font', '终端字体'),
      [
        Text(
          _t('Optional · opt-in', '可选 · 手动启用'),
          style: TextStyle(color: theme.onSurfaceDim),
        ),
        const SizedBox(height: 1),
        Text(
          cellWidth == null
              ? _t(
                  'Font  ${face ?? '—'}  ·  cell width  default',
                  '字体  ${face ?? '—'}  ·  字宽  默认',
                )
              : _t(
                  'Font  ${face ?? '—'}  ·  cell width  $cellWidth',
                  '字体  ${face ?? '—'}  ·  字宽  $cellWidth',
                ),
          style: TextStyle(color: theme.onSurfaceVariant),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 1),
        OptionToggle(
          options: presetLabels,
          selectedIndex: CellWidthPreset.values.indexOf(selectedPreset),
          selectedBgColor: theme.buttonBackgroundHover,
          unselectedBgColor: theme.buttonBackground,
          hoverBgColor: theme.buttonBackgroundHover,
          onFocusRequest: (index) => setState(() => _focus = 28 + index),
          onChanged: (index) => setState(
            () => _fontCellWidthPreset = CellWidthPreset.values[index],
          ),
          focused: _focus >= 28 && _focus < 32,
        ),
        const SizedBox(height: 1),
        Row(
          children: [
            _button(
              27,
              _fontInstalled
                  ? _t(' Installed ', ' 已安装 ')
                  : _fontBusy && _fontInstalling
                  ? _t(' Installing… ', ' 安装中… ')
                  : _t(' Install Maple Mono ', ' 安装 Maple Mono '),
              _fontInstalled || _fontBusy ? null : () => unawaited(_installTerminalFont()),
            ),
            const SizedBox(width: 1),
            _button(
              32,
              _fontBusy
                  ? _t(' Apply… ', ' 应用… ')
                  : _t(' Apply ', ' 应用 '),
              _fontBusy ? null : () => unawaited(_applyTerminalFont()),
            ),
          ],
        ),
        if (_fontInstalling)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              '${( _fontProgress.clamp(0.0, 1.0) * 100).round()}%  ${_runtimeStage(_fontStage)}${_fontStatusText.isEmpty ? '' : '  ·  $_fontStatusText'}',
              style: TextStyle(color: theme.onSurfaceDim),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        _status(_fontStatusText.isNotEmpty && !_fontInstalling ? _fontStatusText : ''),
      ],
      completed: false,
    );
  }

  Component _runtimeCard(BuildContext context) {
    final theme = CruxTheme.of(context);
    return _section(context, '7', _t('Runtime readiness', '运行环境'), [
      Text(
        _t('Checked and installed automatically', '自动检查并安装'),
        style: TextStyle(color: theme.onSurfaceDim),
      ),
      const SizedBox(height: 1),
      _progressRow(
        _t('Semble embedding model', 'Semble 嵌入模型'),
        _sembleProgress,
        _sembleStage,
        _sembleTransfer,
      ),
      const SizedBox(height: 1),
      _progressRow(
        'ripgrep',
        _ripgrepProgress,
        _ripgrepStage,
        _ripgrepTransfer,
      ),
      _status(_runtimeStatus),
      if (!_runtimeChecking)
        _button(
          26,
          _sembleReady && _ripgrepReady
              ? _t(' Check again ', ' 重新检查 ')
              : _t(' Retry install ', ' 重试安装 '),
          () => unawaited(_checkRuntime()),
        ),
    ], completed: _sembleReady && _ripgrepReady);
  }

  Component _finishCard(BuildContext context) {
    final theme = CruxTheme.of(context);
    final ready =
        _verifiedProviders.isNotEmpty &&
        _auxVerified &&
        _webVerified &&
        _sembleReady &&
        _ripgrepReady;
    return _section(context, '', _t('Ready to launch', '准备启动'), [
      Text(
        ready
            ? _t('Everything is connected.', '所有项目均已连接。')
            : _t('Complete and verify each card.', '请完成并验证每张卡片。'),
        style: TextStyle(color: ready ? theme.success : theme.onSurfaceDim),
      ),
      const SizedBox(height: 1),
      _button(
        25,
        _busy
            ? _t(' Working… ', ' 处理中… ')
            : _t(' Finish setup  → ', ' 完成设置  → '),
        _finish,
      ),
      _status(_finishStatus),
    ], completed: ready);
  }

  Component _header(BuildContext context) {
    final theme = CruxTheme.of(context);
    final canExit = component.providerService.resolveDefaultModel() != null;
    final strings = component.localeController.strings;
    return Container(
      decoration: BoxDecoration(
        color: theme.surface,
        border: BoxBorder.all(
          color: theme.accent,
          style: BoxBorderStyle.rounded,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
      child: Row(
        children: [
          Text(
            _t('CRUX  SETUP', 'CRUX  设置'),
            style: TextStyle(color: theme.accent, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 3),
          Expanded(
            child: Text(
              _t('First-run · Tab/↑↓ · Enter', '初始配置 · Tab/↑↓ · Enter'),
              style: TextStyle(color: theme.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 2),
          Text(
            canExit
                ? strings.t('setup.header.exitHint')
                : _t('Ctrl+C quit', 'Ctrl+C 退出'),
            style: TextStyle(color: theme.onSurfaceDim),
          ),
        ],
      ),
    );
  }

  Component _gapColumn(List<Component> cards) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < cards.length; i++) ...[
        if (i > 0) const SizedBox(height: 1),
        cards[i],
      ],
    ],
  );

  Component _responsiveCards(
    BuildContext context,
    double width,
    String provider,
    List<String> configured,
  ) {
    final language = _languageCard(context);
    final theme = _themeCard(context);
    final providers = _providerCard(context, provider, configured);
    final aux = _auxCard(context);
    final web = _webCard(context);
    final font = _fontCardVisible ? _fontCard(context) : null;
    final runtime = _runtimeCard(context);
    final finish = _finishCard(context);
    if (width < 96) {
      return _gapColumn([
        language,
        theme,
        providers,
        aux,
        web,
        ?font,
        runtime,
        finish,
      ]);
    }
    final columnWidth = ((width - 2) / 2).floorToDouble();
    // Two equal-width independent columns keep every setup card aligned. The
    // final launch action spans both columns so it has the same visual weight
    // and width as the setup header.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: columnWidth,
              child: _gapColumn([language, providers, runtime]),
            ),
            const SizedBox(width: 2),
            SizedBox(
              width: columnWidth,
              child: _gapColumn([
                theme,
                aux,
                web,
                ?font,
              ]),
            ),
          ],
        ),
        const SizedBox(height: 1),
        finish,
      ],
    );
  }

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    final provider = _selectedProvider;
    final configured = _providers
        .where(
          (name) =>
              component.providerService.getApiKey(name)?.isNotEmpty ?? false,
        )
        .toList();
    return Focusable(
      focused: _focus != _providerKeyFocus && _focus != _webKeyFocus,
      onKeyEvent: _handleKey,
      child: Container(
        color: theme.background,
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) => Align(
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: constraints.maxWidth.clamp(0, 160),
                  child: _header(context),
                ),
              ),
            ),
            const SizedBox(height: 1),
            Expanded(
              child: Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: LayoutBuilder(
                    builder: (context, constraints) => Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        width: constraints.maxWidth.clamp(0, 160),
                        child: _responsiveCards(
                          context,
                          constraints.maxWidth.clamp(0, 160),
                          provider,
                          configured,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupCard extends StatelessComponent {
  final String number;
  final String title;
  final bool completed;
  final List<Component> children;

  const _SetupCard({
    required this.number,
    required this.title,
    required this.completed,
    required this.children,
  });

  @override
  Component build(BuildContext context) {
    final theme = CruxTheme.of(context);
    return Hoverable(
      builder: (context, hovered) => Container(
        decoration: BoxDecoration(
          color: theme.surface,
          border: BoxBorder.all(
            color: hovered
                ? theme.outlineBright
                : completed
                ? theme.accent
                : theme.outline,
            style: BoxBorderStyle.rounded,
          ),
          title: BorderTitle(
            text: number.isEmpty ? title : '$number  $title',
            style: TextStyle(color: theme.accent, fontWeight: FontWeight.bold),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}
