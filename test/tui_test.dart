import 'package:test/test.dart';
import 'package:nocterm/nocterm.dart';
import 'package:nocterm/nocterm_test.dart';
import 'package:crux/src/models/slash_command.dart';
import 'package:crux/src/models/message.dart';
import 'package:crux/src/components/ui/button.dart';
import 'package:crux/src/components/ui/toast.dart';
import 'package:crux/src/components/command_overlay.dart';
import 'package:crux/src/components/message_bubble.dart';

import 'package:crux/src/components/ui/highlighted_markdown_text.dart';

void main() {
group('HighlightedMarkdownText', () {
    test('h1 heading renders without # markers', () async {
      await testNocterm('h1', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('# Hello'),
        ));
        expect(tester.terminalState, containsText('Hello'));
        expect(tester.terminalState.containsText('#'), isFalse);
      });
    });

    test('h2 heading renders without ## markers', () async {
      await testNocterm('h2', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('## Title'),
        ));
        expect(tester.terminalState, containsText('Title'));
        expect(tester.terminalState.containsText('##'), isFalse);
      });
    });

    test('paragraph renders text', () async {
      await testNocterm('paragraph', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('Some plain text'),
        ));
        expect(tester.terminalState, containsText('plain text'));
      });
    });

    test('bold renders without ** markers', () async {
      await testNocterm('bold', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('This is **bold** text'),
        ));
        expect(tester.terminalState, containsText('bold'));
        expect(tester.terminalState.containsText('**bold**'), isFalse);
        expect(tester.terminalState.containsText('**'), isFalse);
      });
    });

    test('italic renders without * markers', () async {
      await testNocterm('italic', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('This is *italic* text'),
        ));
        expect(tester.terminalState, containsText('italic'));
        expect(tester.terminalState.containsText('*italic*'), isFalse);
      });
    });

    test('strikethrough renders without ~~ markers', () async {
      await testNocterm('strikethrough', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('This is ~~deleted~~ text'),
        ));
        expect(tester.terminalState, containsText('deleted'));
        expect(tester.terminalState.containsText('~~deleted~~'), isFalse);
        expect(tester.terminalState.containsText('~~'), isFalse);
      });
    });

    test('inline code renders without backtick markers', () async {
      await testNocterm('inline code', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('Use the `foo` function'),
        ));
        expect(tester.terminalState, containsText('foo'));
        expect(tester.terminalState.containsText('`'), isFalse);
      });
    });

    test('code block renders with header and border', () async {
      await testNocterm('code block', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 24,
          child: HighlightedMarkdownText('```dart\nprint("hi");\n```'),
        ));
        expect(tester.terminalState, containsText('print'));
        expect(tester.terminalState, containsText('dart'));
        expect(tester.terminalState, containsText('│'));
        expect(tester.terminalState.containsText('```'), isFalse);
      });
    });

    test('blockquote renders with │ prefix', () async {
      await testNocterm('blockquote', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('> A quoted line'),
        ));
        expect(tester.terminalState, containsText('│'));
        expect(tester.terminalState, containsText('quoted'));
        expect(tester.terminalState.containsText('>'), isFalse);
      });
    });

    test('link renders text and href without brackets', () async {
      await testNocterm('link', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('Visit [Google](https://google.com)'),
        ));
        expect(tester.terminalState, containsText('Google'));
        expect(tester.terminalState, containsText('google.com'));
        expect(tester.terminalState.containsText('['), isFalse);
        expect(tester.terminalState.containsText(']('), isFalse);
      });
    });

    test('unordered list renders with bullet', () async {
      await testNocterm('ul', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('- Item one\n- Item two'),
        ));
        expect(tester.terminalState, containsText('Item one'));
        expect(tester.terminalState, containsText('Item two'));
        expect(tester.terminalState, containsText('•'));
      });
    });

    test('ordered list renders with numbers', () async {
      await testNocterm('ol', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('1. First\n2. Second'),
        ));
        expect(tester.terminalState, containsText('First'));
        expect(tester.terminalState, containsText('Second'));
      });
    });

    test('horizontal rule renders as dashes', () async {
      await testNocterm('hr', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('Above\n\n---\n\nBelow'),
        ));
        expect(tester.terminalState, containsText('─'));
      });
    });

    test('image renders alt text', () async {
      await testNocterm('img', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 10,
          child: HighlightedMarkdownText('![Alt text](url)'),
        ));
        expect(tester.terminalState, containsText('Alt text'));
      });
    });

    test('table renders with borders', () async {
      await testNocterm('table', (tester) async {
        await tester.pumpComponent(Container(
          width: 80, height: 24,
          child: HighlightedMarkdownText('| A | B |\n|---|---|\n| 1 | 2 |'),
        ));
        expect(tester.terminalState, containsText('A'));
        expect(tester.terminalState, containsText('B'));
        expect(tester.terminalState, containsText('1'));
        expect(tester.terminalState, containsText('2'));
      });
    });
  });

  group('Button', () {
    test('renders label text', () async {
      await testNocterm('button renders', (tester) async {
        await tester.pumpComponent(
          Button(
            label: 'ClickMe',
            onPressed: () {},
          ),
        );
        expect(tester.terminalState, containsText('ClickMe'));
      });
    });

    test('triggers onPressed on tap', () async {
      await testNocterm('button tap', (tester) async {
        var pressed = false;
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: Button(
              label: 'Submit',
              onPressed: () => pressed = true,
            ),
          ),
        );
        expect(tester.terminalState, containsText('Submit'));

        await tester.tap(4, 0);
        expect(pressed, isTrue);
      });
    });
  });

  group('Toast', () {
    test('renders message text', () async {
      await testNocterm('toast renders', (tester) async {
        var dismissed = false;
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: Toast(
              message: 'Model switched',
              onDismissed: () => dismissed = true,
              duration: const Duration(seconds: 5),
            ),
          ),
        );
        expect(tester.terminalState, containsText('Model switched'));
        expect(dismissed, isFalse);
      });
    });
  });

  group('CommandOverlay', () {
    test('renders command list with selected item', () async {
      await testNocterm('command overlay renders', (tester) async {
        final commands = <SlashCommand>[
          SlashCommand(name: '/model', description: 'Switch model', params: ['name']),
          SlashCommand(name: '/new', description: 'Create new session'),
          SlashCommand(name: '/think', description: 'Toggle thinking', params: ['level']),
        ];

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: CommandOverlay(
              commands: commands,
              selectedIndex: 0,
              scrollOffset: 0,
              maxVisible: 6,
            ),
          ),
        );

        expect(tester.terminalState, containsText('Commands'));
        expect(tester.terminalState, containsText('/model'));
        expect(tester.terminalState, containsText('/new'));
        expect(tester.terminalState, containsText('/think'));
      });
    });

    test('highlights selected command with > marker', () async {
      await testNocterm('command overlay selection', (tester) async {
        final commands = <SlashCommand>[
          SlashCommand(name: '/model', description: 'Switch model', params: ['name']),
          SlashCommand(name: '/new', description: 'Create new session'),
        ];

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: CommandOverlay(
              commands: commands,
              selectedIndex: 1,
              scrollOffset: 0,
              maxVisible: 6,
            ),
          ),
        );

        final output = tester.renderToString(showBorders: true);
        expect(output, contains('>'));
      });
    });

    test('tap on command triggers callback', () async {
      await testNocterm('command overlay tap', (tester) async {
        var tappedIndex = -1;
        final commands = <SlashCommand>[
          SlashCommand(name: '/model', description: 'Switch model', params: ['name']),
          SlashCommand(name: '/new', description: 'Create new session'),
        ];

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: CommandOverlay(
              commands: commands,
              selectedIndex: 0,
              scrollOffset: 0,
              maxVisible: 6,
              onTap: (index) => tappedIndex = index,
            ),
          ),
        );

        await tester.tap(3, 3);
        expect(tappedIndex, equals(0));
      });
    });
  });

  group('MessageBubble', () {
    test('renders message content', () async {
      await testNocterm('message bubble renders', (tester) async {
        final message = Message(
          id: 1,
          sessionId: 1,
          role: 'user',
          content: 'Hello world',
        );
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: MessageBubble(message: message),
          ),
        );
        expect(tester.terminalState, containsText('Hello world'));
      });
    });
  });

  group('AI Agent Debug Workflow', () {
    test('keyboard interaction: type, send keys, read screen', () async {
      await testNocterm('keyboard workflow', (tester) async {
        await tester.pumpComponent(const _InputDemo());

        expect(tester.terminalState, containsText('Input:'));
        expect(tester.terminalState, containsText('Enter: 0'));

        await tester.sendKeyEvent(KeyboardEvent(
          logicalKey: LogicalKey.keyA,
          character: 'a',
        ));
        expect(tester.terminalState, containsText('Input: a'));

        await tester.enterText('hello');
        expect(tester.terminalState, containsText('Input: ahello'));

        await tester.sendEnter();
        expect(tester.terminalState, containsText('Enter: 1'));
      });
    });

    test('mouse interaction: hover and tap at coordinates', () async {
      await testNocterm('mouse workflow', (tester) async {
        var tapX = -1;
        var tapY = -1;

        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: GestureDetector(
              onTapDown: (details) {
                tapX = details.localPosition.dx.round();
                tapY = details.localPosition.dy.round();
              },
              child: Container(
                width: 20,
                height: 5,
                decoration: BoxDecoration(border: BoxBorder.all()),
                child: const Text('Tap me'),
              ),
            ),
          ),
        );

        expect(tester.terminalState, containsText('Tap me'));
        expect(tapX, equals(-1));

        await tester.tap(10, 3);
        expect(tapX, equals(10));
        expect(tapY, equals(3));
      });
    });

    test('renderToString gives visual screen for AI debugging', () async {
      await testNocterm('visual screen dump', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: Column(
              children: [
                Text('Header', style: TextStyle(color: Colors.cyan)),
                Expanded(child: Text('Body content')),
                Text('Footer'),
              ],
            ),
          ),
        );

        final visual = tester.renderToString(showBorders: true);
        expect(visual, contains('Header'));
        expect(visual, contains('Body content'));
        expect(visual, contains('Footer'));
      });
    });

    test('findState inspects component internal state', () async {
      await testNocterm('find state', (tester) async {
        await tester.pumpComponent(const _Counter());

        final state = tester.findState<_CounterState>();
        expect(state.count, equals(0));

        await tester.sendKey(LogicalKey.add);
        expect(state.count, equals(1));

        await tester.sendKey(LogicalKey.add);
        expect(state.count, equals(2));

        await tester.sendKey(LogicalKey.minus);
        expect(state.count, equals(1));

        expect(tester.terminalState, containsText('Count: 1'));
      });
    });

    test('getCellAt reads individual cell char and style', () async {
      await testNocterm('cell inspection', (tester) async {
        await tester.pumpComponent(
          Container(
            width: 80,
            height: 24,
            child: Text('ABC', style: TextStyle(color: Colors.red)),
          ),
        );

        final cell = tester.terminalState.getCellAt(0, 0);
        expect(cell!.char, equals('A'));
      });
    });
  });
}

class _Counter extends StatefulComponent {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.add) {
          setState(() => count++);
          return true;
        }
        if (event.logicalKey == LogicalKey.minus) {
          setState(() => count--);
          return true;
        }
        return false;
      },
      child: Container(
        width: 80,
        height: 24,
        child: Center(child: Text('Count: $count')),
      ),
    );
  }
}

class _InputDemo extends StatefulComponent {
  const _InputDemo();

  @override
  State<_InputDemo> createState() => _InputDemoState();
}

class _InputDemoState extends State<_InputDemo> {
  String inputText = '';
  int enterCount = 0;

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: (event) {
        if (event.logicalKey == LogicalKey.enter) {
          setState(() => enterCount++);
          return true;
        }
        if (event.character != null) {
          setState(() => inputText += event.character!);
        }
        return false;
      },
      child: Container(
        width: 80,
        height: 24,
        child: Column(
          children: [
            Text('Input: $inputText'),
            Text('Enter: $enterCount'),
          ],
        ),
      ),
    );
  }
}