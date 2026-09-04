import 'dart:async';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/chat_turn_orchestrator.dart';
import 'package:crux/src/components/session_controller.dart';
import 'package:crux/src/components/streaming_controller.dart';
import 'package:crux/src/components/ui/toast.dart';
import 'package:crux/src/services/chat_service.dart';
import 'package:crux/src/services/git_status_service.dart';
import 'package:crux/src/services/llm_client.dart';
import 'package:crux/src/services/provider_service.dart';
import 'package:crux/src/services/tool_executor.dart';
import 'package:crux/src/services/web_provider_registry.dart';
import 'package:crux/src/storage/storage.dart';
import 'package:crux/src/tools/file_read_tracker.dart';
import 'package:crux/src/tools/registry.dart';

void main() {
  late Directory tempDir;
  late CruxDatabase db;
  late SessionStore store;
  late ProviderService providerService;
  late ChatService chatService;
  late SessionController sessionController;
  late StreamingController streamingController;
  late ToolRegistry toolRegistry;
  late FileReadTracker tracker;
  late GitStatusService gitStatusService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('crux_btw_cancel_');
    db = CruxDatabase.forTesting(NativeDatabase.memory());
    store = SessionStore(db, instanceId: 'local');
    providerService = ProviderService(
      userProvidersDir: '${tempDir.path}/providers',
      userDataDirOverride: tempDir.path,
    );
    tracker = FileReadTracker();
    toolRegistry = ToolRegistry()
      ..registerDefaults(
        tracker,
        sessionStore: store,
        webProviderRegistry: WebProviderRegistry(),
      );
    chatService = ChatService(
      store,
      providerService,
      LlmClient(),
      ToolExecutor(toolRegistry),
    );
    sessionController = SessionController(
      store: store,
      providerService: providerService,
      chatService: chatService,
      refresh: () {},
    );
    streamingController = StreamingController(
      sessionController: sessionController,
      refresh: () {},
    );
    gitStatusService = GitStatusService();
  });

  tearDown(() async {
    streamingController.dispose();
    sessionController.dispose();
    chatService.dispose();
    gitStatusService.dispose();
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('cancelling an active BTW stream closes its HTTP stream', () async {
    final requestReceived = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(': connected\n\n');
      await request.response.flush();
      requestReceived.complete();
      // Intentionally never emit an SSE event. Without a cancel token, the
      // handler would remain blocked in `await for` indefinitely.
      await Completer<void>().future;
    });

    final providersDir = Directory(providerService.providersDir);
    await providersDir.create(recursive: true);
    await File('${providersDir.path}/test.toml').writeAsString('''
type = "openai_compatible"
endpoint_url = "http://127.0.0.1:${server.port}/v1"

[[models]]
id = "m"
name = "m"
context_size = 1000
''');
    await providerService.initialize();
    await providerService.setApiKey('test', 'test-key');

    final session = await store.create(
      title: 'BTW cancellation',
      model: 'test/m',
      projectPath: tempDir.path,
    );
    sessionController
      ..sessions = [session]
      ..currentSessionId = session.id;
    final orchestrator = ChatTurnOrchestrator(
      store: store,
      chatService: chatService,
      providerService: providerService,
      sessionController: sessionController,
      streamingController: streamingController,
      toolRegistry: toolRegistry,
      showToast: (_, {mode = ToastMode.info}) {},
      refresh: () {},
      gitStatusService: gitStatusService,
      tracker: tracker,
    );

    final turn = orchestrator.sendBtwTurn('will this be cancelled?');
    await requestReceived.future.timeout(const Duration(seconds: 2));

    orchestrator.interruptResponse(textController: TextEditingController());

    await turn.timeout(const Duration(seconds: 2));
    expect(sessionController.runtime(session.id).isResponding, isFalse);
  });
}
