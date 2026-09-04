import 'package:nocterm/nocterm.dart';
import 'package:test/test.dart';

import 'package:crux/src/components/ui/layout_metrics.dart';

void main() {
  test(
    'chat-sized input viewport keeps three rows and scrolls overflow',
    () async {
      await testNocterm('chat input viewport scrolls', (tester) async {
        final controller = TextEditingController(
          text: 'one\ntwo\nthree\nfour\nfive',
        );
        final scrollController = ScrollController();

        await tester.pumpComponent(
          Align(
            alignment: Alignment.topLeft,
            child: Container(
              width: 40,
              height: kChatInputMinVisibleLines.toDouble(),
              child: Scrollbar(
                controller: scrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: scrollController,
                  child: TextField(
                    controller: controller,
                    focused: true,
                    maxLines: null,
                  ),
                ),
              ),
            ),
          ),
        );

        expect(
          scrollController.viewportDimension,
          kChatInputMinVisibleLines.toDouble(),
        );
        expect(scrollController.maxScrollExtent, greaterThan(0));

        scrollController.scrollToEnd();
        await tester.pump();
        expect(tester.terminalState, containsText('five'));
      }, size: const Size(80, 12));
    },
  );
}
