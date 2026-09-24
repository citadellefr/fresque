import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/src/element.dart';
import 'package:fresque/src/geometry.dart';

void main() {
  test('simplify drops points on a straight line and keeps corners', () {
    final points = Float32List.fromList([0, 0, 1, 0.01, 2, 0, 3, 0, 3, 1, 3, 2]);
    expect(simplify(points, 0.1), [0, 0, 3, 0, 3, 2]);
  });

  test('hits follows the ink', () {
    final stroke = BoardElement(
      id: 's',
      kind: ElementKind.stroke,
      z: 0,
      x: 100,
      y: 100,
      points: Float32List.fromList([0, 0, 100, 0]),
      color: 0,
      strokeWidth: 4,
    );
    expect(hits(stroke, const Offset(150, 103), 2), isTrue);
    expect(hits(stroke, const Offset(150, 110), 2), isFalse);

    final hollow = BoardElement(
      id: 'r',
      kind: ElementKind.rectangle,
      z: 0,
      x: 0,
      y: 0,
      width: 100,
      height: 100,
      color: 0,
    );
    expect(hits(hollow, const Offset(50, 50), 4), isFalse);
    expect(hits(hollow, const Offset(0, 50), 4), isTrue);
    expect(hits(hollow.copyWith(filled: true), const Offset(50, 50), 4), isTrue);

    final ellipse = BoardElement(
      id: 'e',
      kind: ElementKind.ellipse,
      z: 0,
      x: 0,
      y: 0,
      width: 100,
      height: 50,
      color: 0,
    );
    expect(hits(ellipse, const Offset(100, 25), 3), isTrue);
    expect(hits(ellipse, const Offset(50, 25), 3), isFalse);
  });

  test('hitTop finds the highest element', () {
    final low = BoardElement(
      id: 'low',
      kind: ElementKind.rectangle,
      z: 0,
      x: 0,
      y: 0,
      width: 10,
      height: 10,
      color: 0,
      filled: true,
    );
    final high = low.copyWith(z: 1);
    expect(
      hitTop(
        [
          low,
          BoardElement.fromJson({...high.toJson(), 'id': 'high'})!,
        ],
        const Offset(5, 5),
        1,
      )!.id,
      'high',
    );
    expect(hitTop([low], const Offset(50, 50), 1), isNull);
  });
}
