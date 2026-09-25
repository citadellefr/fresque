import 'package:flutter/material.dart';
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
}
