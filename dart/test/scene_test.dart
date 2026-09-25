import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/fresque.dart';
import 'package:fresque/src/render.dart';

import 'fakes.dart';

void main() {
  test('draws the board in order through any edits', () {
    final random = math.Random(7);
    final board = Board()..reset([for (var i = 0; i < 600; i++) rect('e$i', z: i)], 0);
    final scene = Scene();
    var hidden = <String>{};

    void check() {
      scene.sync(board, hidden);
      expect(
        scene.drawn.map((e) => e.id),
        [
          for (final e in board.elements)
            if (!hidden.contains(e.id)) e.id,
        ],
      );
    }

    check();
    for (var round = 0; round < 400; round++) {
      final ids = board.elements.map((e) => e.id).toList();
      final some = {
        for (var i = 0; i < 1 + random.nextInt(4); i++) ids[random.nextInt(ids.length)],
      };
      switch (random.nextInt(5)) {
        case 0:
          final top = board.topZ + 1;
          board.edit([
            for (var i = 0; i < 1 + random.nextInt(300); i++) rect('n$round-$i', z: top),
          ], []);
        case 1:
          board.edit([
            for (final id in some) board[id]!.copyWith(z: random.nextInt(board.topZ + 1)),
          ], []);
        case 2:
          board.edit([], some.toList());
        case 3:
          board.applyRemote([rect('r$round', z: random.nextInt(board.topZ + 1))], []);
        case 4:
          hidden = random.nextBool() ? some : {};
      }
      check();
    }
  });

  test('a new scene draws a board already drawn by another', () {
    final board = Board()..reset([rect('a'), rect('b', z: 2)], 0);
    Scene().sync(board, const {});
    final scene = Scene()..sync(board, const {});
    expect(scene.drawn.map((e) => e.id), ['a', 'b']);
  });
}
