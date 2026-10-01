import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/fresque.dart';

import 'fakes.dart';

/// Lets the last presence frame leave before the test ends.
void boardTest(String description, WidgetTesterCallback body) {
  testWidgets(description, (tester) async {
    await body(tester);
    await tester.pump(const Duration(milliseconds: 50));
  });
}

void main() {
  late FakeServer server;
  late BoardSession session;
  late BoardController controller;

  Future<void> mount(WidgetTester tester, {Map<String, Object?>? greeting}) async {
    server = FakeServer();
    session = BoardSession(server.connect)..start();
    controller = BoardController(session);
    addTearDown(() {
      controller.dispose();
      session.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BoardView(controller: controller)),
      ),
    );
    await tester.pump();
    server.last.receive(greeting ?? hello());
    await tester.pump();
  }

  boardTest('a pen stroke becomes one element', (tester) async {
    await mount(tester);
    await tester.dragFrom(const Offset(200, 200), const Offset(120, 60));
    await tester.pump();

    final ops = server.last.sentOfType('op');
    expect(ops, hasLength(1));
    final element = BoardElement.fromJson((ops.single['put']! as List).single)!;
    expect(element.kind, ElementKind.stroke);
    expect(element.points.length, greaterThanOrEqualTo(4));
    expect(session.board.elements.single.id, element.id);
  });

  boardTest('the eraser deletes what it crosses', (tester) async {
    await mount(tester);
    controller.tool = BoardTool.rectangle;
    controller.filled = true;
    await tester.dragFrom(const Offset(100, 100), const Offset(80, 80));
    await tester.pump();
    expect(session.board.elements, hasLength(1));

    controller.tool = BoardTool.eraser;
    await tester.dragFrom(const Offset(90, 140), const Offset(120, 0));
    await tester.pump();
    expect(session.board.elements, isEmpty);
  });

  boardTest('selecting and dragging moves the element', (tester) async {
    await mount(tester);
    controller.tool = BoardTool.rectangle;
    controller.filled = true;
    await tester.dragFrom(const Offset(100, 100), const Offset(80, 80));
    await tester.pump();
    final before = session.board.elements.single;

    controller.tool = BoardTool.select;
    await tester.dragFrom(const Offset(140, 140), const Offset(50, 0));
    await tester.pump();
    final after = session.board.elements.single;
    expect(after.id, before.id);
    expect(after.x - before.x, closeTo(50 / controller.scale, 1));
    expect(controller.selection, {before.id});
  });

  boardTest('a stroke drawn with Ctrl held becomes the shape it stands for', (tester) async {
    await mount(tester);
    controller.dash = BoardDash.dashed;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final gesture = await tester.startGesture(const Offset(100, 100));
    for (final corner in const [Offset(300, 100), Offset(300, 200), Offset(100, 200)]) {
      await gesture.moveTo(corner);
      await tester.pump();
    }
    await gesture.moveTo(const Offset(100, 102));
    await gesture.up();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final shape = session.board.elements.single;
    expect(shape.kind, ElementKind.rectangle);
    expect(shape.width, closeTo(200 / controller.scale, 4));
    expect(shape.height, closeTo(100 / controller.scale, 4));
    expect(shape.dash, BoardDash.dashed);
  });

  boardTest('dragging a corner of a selected image resizes it in proportion', (tester) async {
    await mount(tester);
    final image = BoardElement(
      id: 'i',
      kind: ElementKind.image,
      z: 1,
      x: 100,
      y: 100,
      width: 100,
      height: 50,
      color: 0xFF000000,
      src: 'data:image/png;base64,AAAA',
    );
    session.apply(put: [image]);
    controller
      ..tool = BoardTool.select
      ..select(['i']);
    await tester.pump();

    final corner = controller.toScreen(const Offset(200, 150)) + const Offset(4, 4);
    await tester.dragFrom(corner, const Offset(100, 0));
    await tester.pump();
    final resized = session.board['i']!;
    expect(resized.x, 100);
    expect(resized.y, 100);
    expect(resized.width, closeTo(200, 1));
    expect(resized.height, closeTo(100, 1));
    expect(controller.selection, {'i'});
  });

  boardTest('dragging a corner of a selected triangle stretches it', (tester) async {
    await mount(tester);
    final triangle = BoardElement(
      id: 't',
      kind: ElementKind.polygon,
      z: 1,
      x: 100,
      y: 100,
      points: Float32List.fromList([50, 0, 100, 100, 0, 100]),
      color: 0xFF000000,
    );
    session.apply(put: [triangle]);
    controller
      ..tool = BoardTool.select
      ..select(['t']);
    await tester.pump();

    final corner = controller.toScreen(const Offset(200, 200)) + const Offset(4, 4);
    await tester.dragFrom(corner, Offset(100 * controller.scale, 0));
    await tester.pump();
    final stretched = session.board['t']!;
    expect(stretched.box.left, closeTo(100, 1e-3));
    expect(stretched.box.top, closeTo(100, 1e-3));
    expect(stretched.box.width, closeTo(200, 1));
    expect(stretched.box.height, closeTo(100, 1));
    expect(stretched.points[0], closeTo(100, 1));
  });

  boardTest('Ctrl with C and V pastes a copy under the mouse, selected', (tester) async {
    await mount(tester);
    session.apply(put: [rect('a', z: 3)]);
    controller
      ..tool = BoardTool.select
      ..select(['a']);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(const Offset(300, 250));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(session.board.elements, hasLength(2));
    final copy = session.board.elements.last;
    expect(copy.id, isNot('a'));
    expect(copy.z, greaterThan(3));
    expect(copy.kind, ElementKind.rectangle);
    expect(copy.bounds.center, offsetMoreOrLessEquals(controller.toWorld(const Offset(300, 250))));
    expect(controller.selection, {copy.id});
    await mouse.removePointer();
  });

  boardTest('the text tool writes a text', (tester) async {
    await mount(tester);
    controller.tool = BoardTool.text;
    await tester.tapAt(const Offset(200, 200));
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);

    tester.testTextInput.enterText('Hello');
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.byType(EditableText)));
    await tester.pump();
    expect(find.byType(EditableText), findsOneWidget);

    await tester.tapAt(const Offset(500, 400));
    await tester.pump();
    expect(find.byType(EditableText), findsNothing);
    final text = session.board.elements.single;
    expect(text.kind, ElementKind.text);
    expect(text.text, 'Hello');
    expect(text.width, greaterThan(0));
  });

  boardTest('the text being edited follows the view', (tester) async {
    await mount(tester);
    controller.tool = BoardTool.text;
    await tester.tapAt(const Offset(200, 200));
    await tester.pump();
    final before = tester.getTopLeft(find.byType(EditableText));

    controller.panBy(const Offset(30, 10));
    await tester.pump();
    expect(tester.getTopLeft(find.byType(EditableText)) - before, const Offset(30, 10));
  });

  boardTest('a read-only board only pans', (tester) async {
    await mount(tester, greeting: hello(readOnly: true));
    final offset = controller.offset;
    await tester.dragFrom(const Offset(200, 200), const Offset(40, 0));
    await tester.pump();
    expect(server.last.sentOfType('op'), isEmpty);
    expect(controller.offset, isNot(offset));
  });

  boardTest('a board already received is framed on its first layout', (tester) async {
    server = FakeServer();
    session = BoardSession(server.connect)..start();
    controller = BoardController(session);
    addTearDown(() {
      controller.dispose();
      session.dispose();
    });
    await tester.pump();
    server.last.receive(hello(elements: [rect('a', x: 1000, y: 1000).toJson()]));
    await tester.pump();
    expect(session.status, BoardStatus.online);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BoardView(controller: controller)),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final center = controller.toScreen(session.board['a']!.bounds.center);
    final size = tester.getSize(find.byType(BoardView));
    expect(center.dx, closeTo(size.width / 2, 1));
    expect(center.dy, closeTo(size.height / 2, 1));
  });

  boardTest('Ctrl and the wheel zoom around the pointer on the web', (tester) async {
    await mount(tester);
    const pointer = Offset(200, 150);
    final under = controller.toWorld(pointer);
    tester.binding.handlePointerEvent(const PointerScaleEvent(position: pointer, scale: 2));
    await tester.pump();
    expect(controller.scale, 2);
    expect(controller.toWorld(pointer), under);
  });

  boardTest('Ctrl with + - and 0 zooms', (tester) async {
    await mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    expect(controller.scale, 1.25);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    expect(controller.scale, closeTo(0.8, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    expect(controller.scale, closeTo(1, 1e-9));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  boardTest('an image goes in the middle of the view, selected', (tester) async {
    await mount(tester);
    const viewport = Size(800, 600);
    await tester.runAsync(() async {
      await controller.insertImage(await noisePng(40, 20), viewport);
    });
    await tester.pump();

    final image = session.board.elements.single;
    expect(image.kind, ElementKind.image);
    expect(image.bounds.size, const Size(40, 20));
    expect(image.bounds.center, controller.visibleRect(viewport).center);
    expect(controller.selection, {image.id});
    expect(controller.tool, BoardTool.select);
    final sent = BoardElement.fromJson(
      (server.last.sentOfType('op').single['put']! as List).single,
    )!;
    expect(sent.src, image.src);
  });

  boardTest('following keeps the edits of a peer on screen until the view is panned', (tester) async {
    await mount(
      tester,
      greeting: hello(
        peers: [
          {'sid': 2, 'id': '7', 'name': 'Alice'},
        ],
      ),
    );
    final size = tester.getSize(find.byType(BoardView));
    bool onScreen(Rect area) => (Offset.zero & size).contains(controller.toScreen(area.center));

    final far = rect('far', x: 5000, y: -3000);
    server.last.receive({
      't': 'op',
      'sid': 2,
      'put': [far.toJson()],
    });
    await tester.pump();
    expect(onScreen(far.bounds), isFalse);
    controller.follow('7');
    expect(onScreen(far.bounds), isTrue);

    final wide = BoardElement(
      id: 'wide',
      kind: ElementKind.rectangle,
      z: 2,
      x: 0,
      y: 0,
      width: 4000,
      height: 10,
      color: 0xFF000000,
    );
    server.last.receive({
      't': 'eph',
      'sid': 2,
      'd': {
        'd': {...wide.toJson(), 'o': 0},
      },
    });
    await tester.pump();
    expect(controller.scale, lessThan(1));
    expect(controller.toScreen(wide.bounds.topLeft).dx, greaterThanOrEqualTo(0));
    expect(controller.toScreen(wide.bounds.bottomRight).dx, lessThanOrEqualTo(size.width));

    controller.tool = BoardTool.hand;
    await tester.dragFrom(const Offset(200, 200), const Offset(40, 0));
    await tester.pump();
    expect(controller.following, isNull);
    final offset = controller.offset;
    server.last.receive({
      't': 'op',
      'sid': 2,
      'put': [rect('elsewhere', x: -9000, y: 9000).toJson()],
    });
    await tester.pump();
    expect(controller.offset, offset);
  });

  boardTest('following stops when the peer leaves', (tester) async {
    await mount(
      tester,
      greeting: hello(
        peers: [
          {'sid': 2, 'id': '7', 'name': 'Alice'},
        ],
      ),
    );
    controller.follow('7');
    server.last.receive({'t': 'leave', 'sid': 2});
    await tester.pump();
    expect(controller.following, isNull);
  });
}
