// Regression net for the "attached image kills the turn" bug (session 6535).
//
// Zhipu's GLM-5.3 is text-only, and its coding-plan endpoint rejects a request
// that carries an image part with
//   `400 / 1210 messages.content.type 参数非法，取值范围 ['text']`
// — the whole turn died and the persisted user row (which keeps the pasted
// screenshot) then failed every later turn that replayed it.
//
// The capability flag already existed (`image_support` in the provider TOML)
// and the *drop* path honoured it, but nothing checked it on the send path:
// `InputPaste.tryClipboardImage` documents "model capability is validated when
// the attachment is sent", and that validation was missing. These tests pin the
// two halves of it now in place:
//
//   * wire_format.buildApiMessages gains `includeImages`, so the executor can
//     leave image parts out of the payload (covers history rows too);
//   * ChatTurnOrchestrator.sendTurn drops the images *before* persisting the
//     user row, so a text-only model never stores a screenshot it cannot read.

import 'dart:io';

import 'package:crux/src/components/chat_turn_orchestrator.dart';
import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/components/ui/toast.dart';
import 'package:crux/src/models/image_attachment.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/models/provider_config.dart';
import 'package:crux/src/models/session_runtime_state.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/chat_turn_executor.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/session_lease_manager.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';
import 'package:drift/native.dart';
import 'package:nocterm/nocterm.dart' hide isEmpty, isNotEmpty;
import 'package:test/test.dart';

const String kProvider = 'imageprov';

/// A text-only model and an image-capable one, side by side — the whole
/// distinction the gate keys on.
const String _providerToml = '''
type = "openai_compatible"
endpoint_url = "http://localhost:9/v1"

[[models]]
id = "text-only"
name = "Text Only"
context_size = 8192
image_support = false
thinking = false

[[models]]
id = "vision"
name = "Vision"
context_size = 8192
image_support = true
thinking = false
''';

const ImageAttachment _image = ImageAttachment(
  mediaType: 'image/png',
  base64Data: 'aGVsbG8=',
  label: 'clipboard (PNG)',
);

Message _userRowWithImage() => Message(
  id: 1,
  sessionId: 1,
  role: 'user',
  content: '[ image 1 ] why is this misaligned?',
  images: const [_image],
);

/// Records the payload of every request so a test can inspect the wire.
class _CapturingLlmClient extends LlmClient {
  final List<List<Map<String, dynamic>>> requests = [];

  @override
  Stream<LlmChunk> streamChat({
    required String endpointUrl,
    required dynamic config,
    required String apiKey,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    String thinkingMode = 'enabled',
    String? reasoningEffort,
    int? thinkingBudget,
    int? maxTokens,
    double temperature = 0,
    double topP = 1.0,
    List<Map<String, dynamic>>? tools,
    String? userId,
    LlmStreamCancelToken? cancelToken,
  }) {
    requests.add(messages);
    return Stream.fromIterable(const [
      LlmChunk(textDelta: 'ok'),
      LlmChunk(finishReason: 'stop'),
    ]);
  }

  @override
  void dispose() {}
}

/// Unit tests never write the real auth file, so the key comes from the stub.
class _StubProviderService extends ProviderService {
  _StubProviderService({required super.userProvidersDir});

  @override
  String? getApiKey(String providerName) => 'sk-test-not-used';
}

/// Every `content` part of every message in [messages], flattened.
List<Map<String, dynamic>> _contentParts(List<Map<String, dynamic>> messages) =>
    [
      for (final message in messages)
        if (message['content'] case final List<dynamic> parts)
          for (final part in parts)
            if (part is Map<String, dynamic>) part,
    ];

bool _hasImagePart(List<Map<String, dynamic>> messages) =>
    _contentParts(messages)
        .any((part) => part['type'] == 'image_url' || part['type'] == 'image');

void main() {
  group('wire_format image capability gate', () {
    test('includeImages: false keeps the text and drops the image parts', () {
      for (final wire in [
        WireFamily.openaiCompatible,
        WireFamily.anthropicCompatible,
      ]) {
        final withImages = buildApiMessages([_userRowWithImage()], wire);
        expect(
          _hasImagePart(withImages),
          isTrue,
          reason: 'default keeps today\'s behavior on the $wire wire',
        );

        final textOnly = buildApiMessages(
          [_userRowWithImage()],
          wire,
          includeImages: false,
        );
        expect(_hasImagePart(textOnly), isFalse, reason: 'wire: $wire');
        // The user's own `[ image N ]` marker is part of their message.
        expect(
          textOnly.single['content'].toString(),
          contains('why is this misaligned?'),
        );
      }
    });

    test('a text-only request is still a plain string message', () {
      final messages = buildApiMessages(
        [_userRowWithImage()],
        WireFamily.openaiCompatible,
        includeImages: false,
      );
      expect(messages, hasLength(1));
      expect(messages.single['role'], 'user');
      expect(messages.single['content'], isA<String>());
    });
  });

  group('executor strips images the model cannot read', () {
    late Directory tempDir;
    late CruxDatabase db;
    late SessionStore store;
    late ProviderService providerService;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_image_gate');
      await File('${tempDir.path}/$kProvider.toml')
          .writeAsString(_providerToml);
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      providerService = _StubProviderService(userProvidersDir: tempDir.path);
      await providerService.initialize();
    });

    tearDown(() async {
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<List<Map<String, dynamic>>> runTurn(String modelId) async {
      final client = _CapturingLlmClient();
      final toolRegistry = ToolRegistry()
        ..registerDefaults(
          FileReadTracker(),
          sessionStore: store,
          webProviderRegistry: WebProviderRegistry(),
        );
      final executor = ChatTurnExecutor(
        store,
        providerService,
        client,
        ToolExecutor(toolRegistry),
        SessionLeaseManager(),
      );
      addTearDown(executor.dispose);

      final session = await store.create(
        title: 'image-gate',
        model: '$kProvider/$modelId',
        projectPath: tempDir.path,
      );
      final runtime = SessionRuntimeState(sessionId: session.id)
        ..responseStartTime = DateTime.now();
      await executor.sendMessage(
        sessionId: session.id,
        session: session,
        runtime: runtime,
        onDelta: (_) {},
        onReasoning: (_) {},
        onChunk: () {},
        onComplete: (_) {},
        onError: (error) => fail('turn failed: ${error.message}'),
        images: const [_image],
        userContent: '[ image 1 ] why is this misaligned?',
      );
      return client.requests.single;
    }

    test('a text-only model never receives the image part', () async {
      final request = await runTurn('text-only');
      expect(_hasImagePart(request), isFalse);
      expect(request.last['content'].toString(), contains('misaligned'));
    });

    test('an image-capable model still receives it', () async {
      final request = await runTurn('vision');
      expect(_hasImagePart(request), isTrue);
    });
  });

  group('orchestrator drops unsupported images before persisting', () {
    late Directory tempDir;
    late CruxDatabase db;
    late SessionStore store;
    late ProviderService providerService;
    late SessionController sessionController;
    late StreamingController streamingController;
    late GitStatusService gitStatusService;
    late ChatTurnOrchestrator orchestrator;
    late List<String> toasts;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('crux_image_toast');
      await File('${tempDir.path}/$kProvider.toml')
          .writeAsString(_providerToml);
      db = CruxDatabase.forTesting(NativeDatabase.memory());
      store = SessionStore(db);
      providerService = _StubProviderService(userProvidersDir: tempDir.path);
      await providerService.initialize();
      final toolRegistry = ToolRegistry()
        ..registerDefaults(
          FileReadTracker(),
          sessionStore: store,
          webProviderRegistry: WebProviderRegistry(),
        );
      final chatService = ChatService(
        store,
        providerService,
        _CapturingLlmClient(),
        ToolExecutor(toolRegistry),
      );
      sessionController = SessionController(
        store: store,
        providerService: providerService,
        chatService: chatService,
        refresh: () {},
        projectPath: () => tempDir.path,
      );
      streamingController = StreamingController(
        sessionController: sessionController,
        refresh: () {},
      );
      gitStatusService = GitStatusService();
      toasts = [];
      orchestrator = ChatTurnOrchestrator(
        store: store,
        chatService: chatService,
        providerService: providerService,
        sessionController: sessionController,
        streamingController: streamingController,
        toolRegistry: toolRegistry,
        showToast: (message, {mode = ToastMode.info}) => toasts.add(message),
        refresh: () {},
        gitStatusService: gitStatusService,
        tracker: FileReadTracker(),
      );
    });

    tearDown(() async {
      streamingController.dispose();
      sessionController.dispose();
      gitStatusService.dispose();
      await db.close();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<List<ImageAttachment>> sendWithImage(String modelId) async {
      final session = await store.create(
        title: 'image-toast',
        model: '$kProvider/$modelId',
        projectPath: tempDir.path,
      );
      sessionController
        ..sessions = [session]
        ..currentSessionId = session.id;
      toasts.clear();

      await orchestrator.sendMessage(
        text: '[ image 1 ] why is this misaligned?',
        textController: TextEditingController(),
        images: const [_image],
      );
      // `sendMessage` starts the turn without awaiting it; the user row lands
      // inside the executor a few microtasks later.
      await pumpEventQueue();
      final rows = await store.messageStore.getMessages(session.id);
      return rows.firstWhere((row) => row.role == 'user').images;
    }

    test(
      'the row is stored without the image and the user is told why',
      () async {
        final images = await sendWithImage('text-only');

        expect(images, isEmpty);
        expect(
          toasts.where(
            (toast) => toast.contains('does not accept image input'),
          ),
          isNotEmpty,
          reason: 'a silently dropped screenshot is as confusing as the 400',
        );
        expect(
          toasts.any((toast) => toast.contains('$kProvider/text-only')),
          isTrue,
          reason: 'the toast must name the model to switch away from',
        );
      },
    );

    test('an image-capable model keeps the attachment', () async {
      final images = await sendWithImage('vision');

      expect(images, hasLength(1));
      expect(toasts, isEmpty);
    });
  });
}
