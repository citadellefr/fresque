import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/fresque.dart';

import 'fakes.dart';

void main() {
  late Board board;

  setUp(() {
    board = Board()..reset([rect('a'), rect('b', z: 2)], 0);
    board.takeChanges();
  });

  test('shows local edits before the server confirms them', () {
    final moved = rect('a', x: 50);
    final op = board.edit([moved], ['b']);
    expect(board['a'], same(moved));
    expect(board['b'], isNull);
    expect(board.elements.map((e) => e.id), ['a']);
    expect(board.takeChanges(), {'a', 'b'});

    board.acknowledge(op.n);
    expect(board.hasPending, isFalse);
    expect(board['a'], same(moved));
    expect(board['b'], isNull);
    expect(board.takeChanges(), isEmpty);
  });

  test('a rejected edit rolls back', () {
    final op = board.edit([rect('a', x: 50)], []);
    board.reject(op.n);
    expect(board['a']!.x, 0);
    expect(board.takeChanges(), {'a'});
  });

  test('remote edits stay under pending local ones, then give way to them', () {
    final mine = rect('a', x: 1);
    final op = board.edit([mine], []);
    board.takeChanges();

    board.applyRemote([rect('a', x: 2), rect('c', z: 3)], []);
    expect(board['a'], same(mine));
    expect(board.takeChanges(), {'c'});

    board.acknowledge(op.n);
    expect(board['a'], same(mine));
  });

  test('a remote edit after the acknowledgement wins', () {
    final op = board.edit([rect('a', x: 1)], []);
    board.acknowledge(op.n);
    board.applyRemote([rect('a', x: 2)], []);
    expect(board['a']!.x, 2);
  });

  test('reset keeps and returns what the server has not applied', () {
    final first = board.edit([rect('x')], []);
    final second = board.edit([rect('y')], []);
    final resend = board.reset([rect('a'), rect('x')], first.n);
    expect(resend.map((op) => op.n), [second.n]);
    expect(board['x'], isNotNull);
    expect(board['y'], isNotNull);
    expect(board['b'], isNull);
    expect(board.takeChanges(), isNull);
  });

  test('orders by z, then id', () {
    board.edit([rect('c', z: 1), rect('d', z: 0)], []);
    expect(board.elements.map((e) => e.id), ['d', 'a', 'c', 'b']);
    expect(board.topZ, 2);
    expect(board.bottomZ, 0);
  });
}
