
import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/fresque.dart';
import 'package:trame/trame.dart';

import 'fakes.dart';

void main() {
  late TestBoard board;

  setUp(() {
    board = TestBoard([rect('a'), rect('b', z: 2)]);
    board.takeChanges();
  });

  test('says which elements an edit changed', () {
    final moved = rect('a', x: 50);
    board.edit([moved, rect('c', z: 3)], ['b']);
    expect(board['a']!.x, 50);
    expect(board['b'], isNull);
    expect(board.elements.map((e) => e.id), ['a', 'c']);
    expect(board.takeChanges(), {'a', 'b', 'c'});
    expect(board.takeChanges(), isEmpty);
  });

  test('says when the whole board came at once', () {
    expect(TestBoard([rect('a')]).takeChanges(), isNull);
  });

  test('orders by z, then id', () {
    board.edit([rect('c', z: 1), rect('d', z: 0)], []);
    expect(board.elements.map((e) => e.id), ['d', 'a', 'c', 'b']);
    expect(board.topZ, 2);
    expect(board.bottomZ, 0);
  });

  test('tells what the last edit touched, before and after', () {
    board.edit([rect('a', x: 100)], []);
    expect(board.lastArea, rect('a').bounds.expandToInclude(rect('a', x: 100).bounds));
    board.edit([], ['b']);
    expect(board.lastArea, rect('b').bounds);
  });

  test('leaves alone what this version cannot draw', () {
    final tree = Tree();
    final board = Board(() => tree);
    final edit = Edit([
      Change.create(const Node(id: 'x', type: 'slide', key: 'V')),
      Change.create(const Node(id: 'y', type: elementType, key: 'V', attributes: {'k': 'unknown'})),
      Change.create(Node(id: 'z', type: elementType, key: zKey(1), attributes: rect('z').attributes)),
    ]);
    tree.apply(edit);
    board.follow(edit);
    expect(board.elements.map((e) => e.id), ['z']);
  });

  test('keys sort as the stack does', () {
    final zs = [-1099511627776, -1000, -1, 0, 1, 7, 255, 256, 1 << 30, 1099511627775];
    for (var i = 0; i < zs.length; i++) {
      expect(zOf(zKey(zs[i])), zs[i]);
      if (i > 0) expect(zKey(zs[i - 1]).compareTo(zKey(zs[i])), lessThan(0));
    }
    expect(zKey(0), '10000000000');
    expect(zKey(-1), 'ffffffffff'.padLeft(11, '0'));
    expect(zOf('nonsense'), 0);
  });
}
