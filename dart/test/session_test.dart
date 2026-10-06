import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/fresque.dart';

import 'fakes.dart';

void main() {
  late FakeServer server;
  late BoardSession session;

  /// Joins the way the hub is joined: it says who is there, the client asks
  /// for the document, and the hub sends it.
  Future<void> connect({
    Map<String, Object?>? greeting,
    Iterable<BoardElement> elements = const [],
  }) async {
    session.start();
    await pumpEventQueue();
    server.last.receive(greeting ?? hello());
    await pumpEventQueue();
    server.last.receive(doc(elements));
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
        peers: [
          {'sid': 2, 'id': '7', 'name': 'Alice'},
        ],
      ),
      elements: [rect('a')],
    );
    expect(server.clientIds, ['client']);
    expect(server.last.sentOfType('sync'), hasLength(1));
    expect(session.status, BoardStatus.online);
    expect(session.board['a'], isNotNull);
    expect(session.peers.single.name, 'Alice');
    expect(session.saved, isTrue);
  });

  test('sends edits and follows them until they are saved', () async {
    await connect();
    session.apply(put: [rect('a')]);
    final sent = server.last.sentOfType('op').single;
    expect(sent['n'], 1);
    expect(sent['d'], [created(rect('a'))]);
    expect(session.board['a'], isNotNull);
    expect(session.saved, isFalse);

    server.last.receive({'t': 'ack', 'n': 1, 'v': 4});
    await pumpEventQueue();
    expect(session.saved, isFalse);

    server.last.receive({'t': 'saved', 'v': 4});
    await pumpEventQueue();
    expect(session.saved, isTrue);
  });

  test('sends what changed of an element, and its place in the stack', () async {
    await connect(elements: [rect('a')]);
    session.apply(put: [rect('a', x: 5).copyWith(z: 9)]);
    session.apply(delete: ['a']);
    server.last.receive({'t': 'ack', 'n': 1, 'v': 1});
    await pumpEventQueue();
    expect(server.last.sentOfType('op').map((op) => op['d']), [
      [
        {
          'o': 'set',
          'id': 'a',
          'k': zKey(9),
          'a': {'x': 5},
        },
      ],
      [
        {'o': 'del', 'id': 'a'},
      ],
    ]);
  });

  test('sends nothing for an element as it already is', () async {
    await connect(elements: [rect('a')]);
    session.apply(put: [rect('a')]);
    expect(server.last.sentOfType('op'), isEmpty);
    expect(session.canUndo, isFalse);
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

    server.last.receive(op([created(rect('r'))], version: 1));
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
      server.last.receive(doc(const []));
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

  test('shows the pointer and the draft again once back online', () {
    fakeAsync((async) {
      session.start();
      async.flushMicrotasks();
      server.last.receive(hello());
      async.flushMicrotasks();
      server.last.receive(doc(const []));
      async.flushMicrotasks();

      session.moveCursor(const Offset(3, 4));
      async.elapse(const Duration(milliseconds: 50));
      unawaited(server.last.drop());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      server.last.receive(hello());
      async.flushMicrotasks();
      server.last.receive(doc(const [], ack: 0));
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 50));

      expect([for (final frame in server.last.sentOfType('eph')) (frame['d']! as Map)['c']], [
        [3, 4],
      ]);
    });
  });

  test('reconnects and sends again what the server did not apply', () {
    fakeAsync((async) {
      session.start();
      async.flushMicrotasks();
      server.last.receive(hello());
      async.flushMicrotasks();
      server.last.receive(doc(const []));
      async.flushMicrotasks();

      session.apply(put: [rect('a')]);
      session.apply(put: [rect('b')]);
      unawaited(server.last.drop());
      async.flushMicrotasks();
      expect(session.status, BoardStatus.offline);

      session.apply(put: [rect('c')]);
      async.elapse(const Duration(seconds: 1));
      expect(server.transports, hasLength(2));
      server.last.receive(hello());
      async.flushMicrotasks();
      // the first edit reached the hub, the others did not
      server.last.receive(doc([rect('a')], version: 1, ack: 1));
      async.flushMicrotasks();

      expect(session.status, BoardStatus.online);
      expect(session.board.elements.map((e) => e.id), ['a', 'b', 'c']);
      final sent = server.last.sentOfType('op');
      expect(sent.map((op) => op['n']), [2]);
      expect((sent.single['d']! as List).cast<Map<String, Object?>>().map((c) => c['id']), ['b', 'c']);
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
    await connect(elements: [rect('a'), rect('b')]);
    session.apply(put: [rect('a', x: 10), rect('b', x: 10)]);
    server.last.receive({'t': 'ack', 'n': 1, 'v': 1});
    server.last.receive(
      op([
        {
          'o': 'set',
          'id': 'b',
          'a': {'x': 99},
        },
      ], version: 2),
    );
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

  test('tells where each peer last edited, drawing included', () async {
    await connect(
      greeting: hello(
        peers: [
          {'sid': 2, 'id': '7', 'name': 'Alice'},
        ],
      ),
      elements: [rect('old', x: 500, y: 500)],
    );
    final edits = <BoardPeer>[];
    final subscription = session.edits.listen(edits.add);
    addTearDown(subscription.cancel);
    final alice = session.peers.single;

    server.last.receive({
      't': 'eph',
      'sid': 2,
      'd': {
        'd': {...rect('r', x: 100, y: 100).toJson(), 'o': 0},
      },
    });
    await pumpEventQueue();
    expect(alice.lastEdit, rect('r', x: 100, y: 100).bounds);

    server.last.receive(
      op([
        created(rect('r', x: 100, y: 100)),
        {'o': 'del', 'id': 'old'},
      ], version: 1),
    );
    await pumpEventQueue();
    expect(
      alice.lastEdit,
      rect('r', x: 100, y: 100).bounds.expandToInclude(rect('old', x: 500, y: 500).bounds),
    );
    expect(edits, [alice, alice]);

    server.last.receive({
      't': 'eph',
      'sid': 2,
      'd': {
        'c': [1, 2],
      },
    });
    await pumpEventQueue();
    expect(edits, hasLength(2));
  });
}
