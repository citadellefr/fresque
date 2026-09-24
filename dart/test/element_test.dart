import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/fresque.dart';

void main() {
  test('round-trips through JSON, tenths of a unit kept', () {
    final stroke = BoardElement(
      id: 'a',
      kind: ElementKind.stroke,
      z: 3,
      x: 10.04,
      y: -2.5,
      points: Float32List.fromList([0, 0, 1.26, 3]),
      color: 0xFF112233,
      strokeWidth: 4,
    );
    final json = stroke.toJson();
    expect(json, {
      'id': 'a',
      'k': 's',
      'z': 3,
      'x': 10,
      'y': -2.5,
      'p': [0, 0, 1.3, 3],
      'c': 0xFF112233,
      'sw': 4,
    });
    final back = BoardElement.fromJson(json)!;
    expect(back.kind, ElementKind.stroke);
    expect(back.points, [0, 0, closeTo(1.3, 1e-6), 3]);
    expect(back.color, 0xFF112233);
  });

  test('texts carry their text and size', () {
    final text = BoardElement(
      id: 't',
      kind: ElementKind.text,
      z: 0,
      x: 0,
      y: 0,
      width: 40,
      height: 25,
      color: 0xFF000000,
      text: 'Bonjour',
      fontSize: 24,
    );
    final back = BoardElement.fromJson(text.toJson())!;
    expect(back.text, 'Bonjour');
    expect(back.fontSize, 24);
    expect(back.bounds, const Rect.fromLTWH(0, 0, 40, 25));
  });

  test('ignores what it cannot draw', () {
    expect(BoardElement.fromJson({'id': 'x', 'k': 'image'}), isNull);
    expect(BoardElement.fromJson({'k': 'r'}), isNull);
    expect(BoardElement.fromJson([1, 2]), isNull);
  });

  test('bounds include the stroke and the arrow head', () {
    final line = BoardElement(
      id: 'l',
      kind: ElementKind.line,
      z: 0,
      x: 10,
      y: 10,
      points: Float32List.fromList([0, 0, 100, 0]),
      color: 0,
      strokeWidth: 4,
    );
    expect(line.bounds, const Rect.fromLTRB(8, 8, 112, 12));
    final arrow = BoardElement(
      id: 'a',
      kind: ElementKind.arrow,
      z: 0,
      x: 0,
      y: 0,
      points: Float32List.fromList([0, 0, 100, 0]),
      color: 0,
    );
    expect(arrow.bounds.left, -arrow.arrowHeadLength);
  });
}
