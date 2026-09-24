import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/fresque.dart';

import 'fakes.dart';

void main() {
  late FakeServer server;
  late BoardSession session;

  Future<void> connect({Map<String, Object?>? greeting}) async {
    session.start();
    await pumpEventQueue();
    server.last.receive(greeting ?? hello());
    await pumpEventQueue();
  }

  setUp(() {
    server = FakeServer();
    session = BoardSession(server.connect, clientId: 'client');
  });

  tearDown(() => session.dispose());

  test('comes online with the board the server sends', () async {
    expect(session.status, BoardStatus.connecting);
    await connect(
      greeting: hello(
        elements: [rect('a').toJson()],
        peers: [
          {'sid': 2, 'id': '7', 'name': 'Alice'},
        ],
      ),
    );
    expect(server.clientIds, ['client']);
    expect(session.status, BoardStatus.online);
    expect(session.board['a'], isNotNull);
    expect(session.peers.single.name, 'Alice');
    expect(session.saved, isTrue);
  });

  test('sends edits and follows them until they are saved', () async {
    await connect();
    session.apply(put: [rect('a')]);
    final op = server.last.sentOfType('op').single;
    expect(op['n'], 1);
    expect((op['put']! as List).single, rect('a').toJson());
    expect(session.saved, isFalse);

    server.last.receive({'t': 'ack', 'n': 1, 'v': 4});
    await pumpEventQueue();
    expect(session.board.hasPending, isFalse);
    expect(session.saved, isFalse);

    server.last.receive({'t': 'saved', 'v': 4});
    await pumpEventQueue();
    expect(session.saved, isTrue);
  });

  test('a refused edit is rolled back and reported', () async {
    await connect();
    final reasons = <String>[];
    final subscription = session.rejections.listen(reasons.add);
    session.apply(put: [rect('a')]);
    server.last.receive({'t': 'nack', 'n': 1, 'error': 'board size limit reached'});
    await pumpEventQueue();
    expect(session.board['a'], isNull);
    expect(reasons, ['board size limit reached']);
    await subscription.cancel();
  });

  test('a failed save is shown until one succeeds', () async {
    await connect();
    server.last.receive({'t': 'error', 'error': 'quota exceeded'});
    await pumpEventQueue();
    expect(session.saveError, 'quota exceeded');
    expect(session.saved, isFalse);
    server.last.receive({'t': 'saved', 'v': 1});
    await pumpEventQueue();
    expect(session.saveError, isNull);
  });

  test('applies the edits of others and ends their draft', () async {
    await connect(
      greeting: hello(
        peers: [
          {'sid': 2, 'id': '7', 'name': 'Alice'},
        ],
      ),
    );
    server.last.receive({
      't': 'eph',
      'sid': 2,
      'd': {
        'c': [5, 6],
        'd': {...rect('r').toJson(), 'o': 0},
      },
    });
    await pumpEventQueue();
    final alice = session.peers.single;
    expect(alice.cursor, const Offset(5, 6));
    expect(alice.draft?.id, 'r');

    server.last.receive({
      't': 'op',
      'sid': 2,
      'put': [rect('r').toJson()],
    });
    await pumpEventQueue();
    expect(session.board['r'], isNotNull);
    expect(alice.draft, isNull);
  });

  test('stroke drafts travel as the points added since the last frame', () {
    fakeAsync((async) {
      session.start();
      async.flushMicrotasks();
      server.last.receive(hello());
      async.flushMicrotasks();

      BoardElement stroke(List<double> points) => BoardElement(
        id: 's',
        kind: ElementKind.stroke,
        z: 0,
        x: 0,
        y: 0,
        points: Float32List.fromList(points),
        color: 0,
      );
      session.showDraft(stroke([0, 0, 1, 1]));
      async.elapse(const Duration(milliseconds: 50));
      session.showDraft(stroke([0, 0, 1, 1, 2, 2]));
      async.elapse(const Duration(milliseconds: 50));
      session.showDraft(null);
      async.elapse(const Duration(milliseconds: 50));

      final drafts = [for (final frame in server.last.sentOfType('eph')) (frame['d']! as Map)['d']];
      expect(drafts, hasLength(3));
      expect((drafts[0]! as Map)['p'], [0, 0, 1, 1]);
      expect((drafts[0]! as Map)['o'], 0);
      expect((drafts[1]! as Map)['p'], [2, 2]);
      expect((drafts[1]! as Map)['o'], 4);
      expect(drafts[2], isNull);
    });
  });

  test('reconnects and sends again what the server did not apply', () {
    fakeAsync((async) {
      session.start();
      async.flushMicrotasks();
      server.last.receive(hello());
      async.flushMicrotasks();

      session.apply(put: [rect('a')]);
      session.apply(put: [rect('b')]);
      unawaited(server.last.drop());
      async.flushMicrotasks();
      expect(session.status, BoardStatus.offline);

      session.apply(put: [rect('c')]);
      async.elapse(const Duration(seconds: 1));
      expect(server.transports, hasLength(2));
      server.last.receive(hello(ack: 1, elements: [rect('a').toJson()]));
      async.flushMicrotasks();

      expect(session.status, BoardStatus.online);
      expect(server.last.sentOfType('op').map((op) => op['n']), [2, 3]);
      expect(session.board.elements.map((e) => e.id), ['a', 'b', 'c']);
    });
  });

  test('stops when the server withdraws access', () async {
    await connect();
    await server.last.drop(4001, 'access withdrawn');
    await pumpEventQueue();
    expect(session.status, BoardStatus.closed);
    expect(session.failure, isA<BoardClosed>());
    expect('${session.failure}', 'access withdrawn');

    session.retry();
    await pumpEventQueue();
    expect(server.transports, hasLength(2));
  });

  test('undo and redo leave the edits of others alone', () async {
    await connect(
      greeting: hello(elements: [rect('a'), rect('b')].map((e) => e.toJson()).toList()),
    );
    session.apply(put: [rect('a', x: 10), rect('b', x: 10)]);
    server.last.receive({'t': 'ack', 'n': 1, 'v': 1});
    server.last.receive({
      't': 'op',
      'sid': 2,
      'put': [rect('b', x: 99).toJson()],
    });
    await pumpEventQueue();

    session.undo();
    expect(session.board['a']!.x, 0);
    expect(session.board['b']!.x, 99);
    expect(session.canRedo, isTrue);

    session.redo();
    expect(session.board['a']!.x, 10);
    expect(session.board['b']!.x, 99);
  });

  test('a read-only session sends no edit', () async {
    await connect(greeting: hello(readOnly: true));
    session.apply(put: [rect('a')]);
    expect(server.last.sentOfType('op'), isEmpty);
    expect(session.board['a'], isNull);
  });
}
