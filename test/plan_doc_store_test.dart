import 'dart:io';

import 'package:crux/src/models/plan_selection.dart';
import 'package:crux/src/services/plan_doc_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late PlanDocStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plan_store_test');
    store = PlanDocStore(
      projectPath: tmp.path,
      sessionId: 42,
      planName: 'PLAN.md',
    );
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('empty store has headVersion 0', () {
    expect(store.headVersion, 0);
    expect(store.readIndex(), isEmpty);
  });

  test('append creates v1 then increments', () {
    expect(store.append('# A\n'), 1);
    expect(store.append('# B\n'), 2);
    expect(store.headVersion, 2);
    expect(store.readVersion(1), '# A\n');
    expect(store.readVersion(2), '# B\n');
  });

  test('index records kind and revertedTo', () {
    store.append('# A\n', kind: PlanVersionKind.init);
    store.append('# B\n');
    store.append('# A\n', kind: PlanVersionKind.revert, revertedTo: 1);
    final index = store.readIndex();
    expect(index, hasLength(3));
    expect(index[0].kind, PlanVersionKind.init);
    expect(index[1].kind, PlanVersionKind.edit);
    expect(index[2].kind, PlanVersionKind.revert);
    expect(index[2].revertedTo, 1);
  });

  test('revert creates a NEW version, never rewinds', () {
    store.append('# A\n', kind: PlanVersionKind.init);
    store.append('# B\n');
    final head = store.append(
      '# A\n',
      kind: PlanVersionKind.revert,
      revertedTo: 1,
    );
    expect(head, 3);
    expect(store.readVersion(3), '# A\n');
    // v2 still exists — history is linear.
    expect(store.readVersion(2), '# B\n');
  });

  test('ensureInitialized only appends once', () {
    expect(store.ensureInitialized('# A\n'), 1);
    expect(store.ensureInitialized('# A\n'), 1);
    expect(store.readIndex(), hasLength(1));
  });

  test('readVersion returns null for a missing version', () {
    expect(store.readVersion(99), isNull);
  });

  test('corrupt index is treated as empty', () {
    final dir = Directory('${tmp.path}/.crux/plans/42/PLAN.md');
    dir.createSync(recursive: true);
    File('${dir.path}/index.json').writeAsStringSync('not json{');
    expect(store.readIndex(), isEmpty);
    expect(store.headVersion, 0);
  });
}
