// Tests for the markdown task-list parser backing the notes widget.

import 'package:test/test.dart';

import 'package:crux/src/utils/todo_parser.dart';

void main() {
  group('parseTodos', () {
    test('empty / no markers yields empty summary', () {
      expect(parseTodos('').isEmpty, isTrue);
      expect(parseTodos('just prose\nno lists here').isEmpty, isTrue);
      // A bullet without a checkbox, and a checkbox with no text after
      // it, are not todos.
      expect(parseTodos('- not a todo\n- [ ]').isEmpty, isTrue);
    });

    test('parses open and done items across marker styles', () {
      final s = parseTodos('''
# notes
- [ ] open one
- [x] done one
* [X] done two (star)
+ [ ] open two (plus)
1. [ ] ordered open
''');
      expect(s.totalCount, 5);
      expect(s.openCount, 3);
      expect(s.open.map((i) => i.text), [
        'open one',
        'open two (plus)',
        'ordered open',
      ]);
      expect(s.done.map((i) => i.text), ['done one', 'done two (star)']);
    });

    test('handles indented items; rejects malformed brackets', () {
      final s = parseTodos('''
    - [ ] nested open
\t- [ ] tab-indented open
- [  ] two-space bracket — not a todo
- [x]done — no space after bracket, not a todo
''');
      // The two indented items match; the malformed brackets do not.
      expect(s.openCount, 2);
      expect(s.open.map((i) => i.text), [
        'nested open',
        'tab-indented open',
      ]);
    });

    test('ignores todos inside fenced code blocks', () {
      final s = parseTodos('''
- [ ] real open
```dart
- [ ] inside backtick fence — not a todo
- [x] also inside
```
~~~
- [ ] inside tilde fence — not a todo
~~~
- [ ] another real open
''');
      expect(s.totalCount, 2);
      expect(s.openCount, 2);
      expect(s.open.map((i) => i.text), ['real open', 'another real open']);
    });

    test('a tilde line does not close a backtick fence', () {
      // CommonMark: a fence closes only on a matching marker. Here the
      // ``` fence never closes, so everything after it is code.
      final s = parseTodos('''
```
- [ ] in code
~~~
- [ ] still in code (the ~~~ opened a nested fence, didn't close)
''');
      expect(s.openCount, 0);
    });

    test('unclosed fence suppresses the rest of the document', () {
      final s = parseTodos('''
- [ ] before
```
- [ ] after, still in fence
''');
      expect(s.openCount, 1);
    });

    test('records line indices in document order', () {
      final s = parseTodos('- [ ] a\n- [x] b\n- [ ] c\n');
      expect(s.items.map((i) => i.lineIndex), [0, 1, 2]);
      expect(s.items.map((i) => i.done), [false, true, false]);
    });

    test('non-task list items are ignored', () {
      final s = parseTodos('''
- plain bullet
- [notab] not a checkbox
1. numbered, no box
- [ ] actual todo
''');
      expect(s.totalCount, 1);
      expect(s.open.single.text, 'actual todo');
    });
  });

  group('TodoSummary accessors', () {
    test('open/done partition items without reordering', () {
      final s = parseTodos('- [x] done\n- [ ] open\n- [x] done2\n');
      expect(s.open.map((i) => i.text), ['open']);
      expect(s.done.map((i) => i.text), ['done', 'done2']);
      expect(s.isEmpty, isFalse);
    });
  });
}
