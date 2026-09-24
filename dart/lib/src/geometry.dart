import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'element.dart';

/// Ramer–Douglas–Peucker on `x0, y0, x1, y1, …`: drops the points that stray
/// less than [epsilon] from the line their neighbours draw.
Float32List simplify(Float32List points, double epsilon) {
  final count = points.length ~/ 2;
  if (count < 3) return Float32List.fromList(points);
  final keep = Uint8List(count)
    ..[0] = 1
    ..[count - 1] = 1;
  final stack = <int>[0, count - 1];
  while (stack.isNotEmpty) {
    final last = stack.removeLast();
    final first = stack.removeLast();
    var farthest = -1;
    var distance = epsilon;
    for (var i = first + 1; i < last; i++) {
      final d = _segmentDistance(
        points[2 * i],
        points[2 * i + 1],
        points[2 * first],
        points[2 * first + 1],
        points[2 * last],
        points[2 * last + 1],
      );
      if (d > distance) {
        distance = d;
        farthest = i;
      }
    }
    if (farthest >= 0) {
      keep[farthest] = 1;
      stack.addAll([first, farthest, farthest, last]);
    }
  }
  final out = Float32List(2 * keep.where((k) => k == 1).length);
  var j = 0;
  for (var i = 0; i < count; i++) {
    if (keep[i] == 1) {
      out[j++] = points[2 * i];
      out[j++] = points[2 * i + 1];
    }
  }
  return out;
}

/// Whether [p] touches the ink of [e], within [tolerance].
bool hits(BoardElement e, Offset p, double tolerance) {
  if (!e.bounds.inflate(tolerance).contains(p)) return false;
  final reach = tolerance + e.strokeWidth / 2;
  switch (e.kind) {
    case ElementKind.text:
      return true;
    case ElementKind.stroke || ElementKind.line || ElementKind.arrow:
      final pts = e.points;
      final x = p.dx - e.x, y = p.dy - e.y;
      if (pts.length == 2) return math.sqrt(_sq(x - pts[0]) + _sq(y - pts[1])) <= reach;
      for (var i = 0; i + 3 < pts.length; i += 2) {
        if (_segmentDistance(x, y, pts[i], pts[i + 1], pts[i + 2], pts[i + 3]) <= reach) {
          return true;
        }
      }
      return false;
    case ElementKind.rectangle:
      final rect = Rect.fromLTWH(e.x, e.y, e.width, e.height);
      if (e.filled && rect.contains(p)) return true;
      return rect.inflate(reach).contains(p) && !rect.deflate(reach).contains(p);
    case ElementKind.ellipse:
      final rx = e.width / 2, ry = e.height / 2;
      if (rx <= 0 || ry <= 0) return false;
      final dx = p.dx - (e.x + rx), dy = p.dy - (e.y + ry);
      final r = math.sqrt(_sq(dx / rx) + _sq(dy / ry));
      if (e.filled && r <= 1) return true;
      return (r - 1).abs() * math.min(rx, ry) <= reach;
  }
}

/// The topmost element under [p], if any.
BoardElement? hitTop(List<BoardElement> bottomToTop, Offset p, double tolerance) {
  for (var i = bottomToTop.length - 1; i >= 0; i--) {
    if (hits(bottomToTop[i], p, tolerance)) return bottomToTop[i];
  }
  return null;
}

double _sq(double v) => v * v;

double _segmentDistance(double px, double py, double ax, double ay, double bx, double by) {
  final dx = bx - ax, dy = by - ay;
  final length = dx * dx + dy * dy;
  var t = length == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / length;
  t = t.clamp(0.0, 1.0);
  return math.sqrt(_sq(px - (ax + t * dx)) + _sq(py - (ay + t * dy)));
}
