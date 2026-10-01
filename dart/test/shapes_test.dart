import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/src/element.dart';
import 'package:fresque/src/shapes.dart';

/// A hand-drawn stroke through [corners], each side cut in steps and shaken
/// by up to [wobble].
BoardElement drawn(List<(double, double)> corners, {double wobble = 2, int seed = 1}) {
  final random = math.Random(seed);
  final points = <double>[];
  for (var i = 0; i + 1 < corners.length; i++) {
    final (x0, y0) = corners[i];
    final (x1, y1) = corners[i + 1];
    for (var t = 0.0; t < 1; t += 0.1) {
      points
        ..add(x0 + (x1 - x0) * t + (random.nextDouble() - 0.5) * wobble)
        ..add(y0 + (y1 - y0) * t + (random.nextDouble() - 0.5) * wobble);
    }
  }
  final (x, y) = corners.last;
  points.addAll([x, y]);
  return stroke(points);
}

BoardElement stroke(List<double> points) => BoardElement(
  id: 's',
  kind: ElementKind.stroke,
  z: 4,
  x: 10,
  y: 20,
  points: Float32List.fromList(points),
  color: 0xFF1976D2,
  strokeWidth: 3,
  dash: BoardDash.dashed,
);

BoardElement circle(double rx, double ry, {double turns = 1, double wobble = 0.03}) {
  final random = math.Random(3);
  return stroke([
    for (var a = 0.0; a <= 2 * math.pi * turns; a += 0.1) ...[
      100 + rx * math.cos(a) * (1 + (random.nextDouble() - 0.5) * wobble),
      100 + ry * math.sin(a) * (1 + (random.nextDouble() - 0.5) * wobble),
    ],
  ]);
}

void main() {
  test('a closed round stroke becomes an ellipse', () {
    final shape = recognizeShape(circle(80, 40))!;
    expect(shape.kind, ElementKind.ellipse);
    expect(shape.x, closeTo(10 + 20, 3));
    expect(shape.y, closeTo(20 + 60, 3));
    expect(shape.width, closeTo(160, 5));
    expect(shape.height, closeTo(80, 5));
  });

  test('a nearly round one becomes a circle', () {
    final shape = recognizeShape(circle(50, 46))!;
    expect(shape.kind, ElementKind.ellipse);
    expect(shape.width, shape.height);
  });

  test('a four-cornered stroke becomes a rectangle, or a square', () {
    final rectangle = recognizeShape(
      drawn([(40, 0), (200, 2), (198, 100), (0, 98), (2, 0), (40, 0)]),
    )!;
    expect(rectangle.kind, ElementKind.rectangle);
    expect(rectangle.x, closeTo(10, 4));
    expect(rectangle.width, closeTo(200, 6));
    expect(rectangle.height, closeTo(100, 6));

    final square = recognizeShape(drawn([(0, 0), (100, 0), (100, 96), (0, 96), (0, 0)]))!;
    expect(square.kind, ElementKind.rectangle);
    expect(square.width, square.height);
  });

  test('a triangle becomes a polygon of three corners', () {
    final shape = recognizeShape(drawn([(0, 100), (60, 0), (120, 100), (0, 100)]))!;
    expect(shape.kind, ElementKind.polygon);
    expect(shape.points, hasLength(6));
    expect(shape.x, 10);
  });

  test('a tilted square becomes a diamond, its corners on the middles of its box', () {
    final shape = recognizeShape(drawn([(50, 0), (104, 48), (52, 100), (0, 52), (50, 0)]))!;
    expect(shape.kind, ElementKind.polygon);
    final box = shape.box;
    expect(shape.points, hasLength(8));
    for (var i = 0; i < 8; i += 2) {
      final x = shape.x + shape.points[i], y = shape.y + shape.points[i + 1];
      bool near(double a, double b) => (a - b).abs() < 1e-3;
      final onMiddle =
          near(x, box.center.dx) && (near(y, box.top) || near(y, box.bottom)) ||
          near(y, box.center.dy) && (near(x, box.left) || near(x, box.right));
      expect(onMiddle, isTrue);
    }
  });

  test('only simple shapes: no pentagon, no slanted quadrilateral', () {
    expect(
      recognizeShape(drawn([(50, 0), (100, 38), (80, 100), (20, 100), (0, 38), (50, 0)])),
      isNull,
    );
    expect(recognizeShape(drawn([(0, 0), (160, 30), (200, 120), (30, 100), (0, 0)])), isNull);
  });

  test('a straight stroke becomes a line, level when it nearly is', () {
    final shape = recognizeShape(drawn([(0, 0), (200, 8)]))!;
    expect(shape.kind, ElementKind.line);
    expect(shape.points, hasLength(4));
    expect(shape.points[3], closeTo(0, 1e-6));
    expect(shape.points[2], closeTo(200, 3));

    final slanted = recognizeShape(drawn([(0, 0), (100, 60)]))!;
    expect(slanted.points[3], closeTo(60, 3));
  });

  test('keeps the id, the place in the stack and the style', () {
    final shape = recognizeShape(circle(50, 50))!;
    expect(shape.id, 's');
    expect(shape.z, 4);
    expect(shape.color, 0xFF1976D2);
    expect(shape.strokeWidth, 3);
    expect(shape.dash, BoardDash.dashed);
  });

  test('leaves alone what is no shape', () {
    expect(recognizeShape(drawn([(0, 0), (50, 80), (100, 0), (150, 80)])), isNull);
    expect(recognizeShape(circle(60, 60, turns: 0.5)), isNull);
    expect(recognizeShape(stroke([5, 5])), isNull);
  });
}
