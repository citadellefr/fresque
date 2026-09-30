import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'element.dart';
import 'geometry.dart';

/// The clean shape a hand-drawn [stroke] stands for: a straight line, an
/// ellipse or a circle, a rectangle or a square, or a polygon of up to eight
/// sides. It keeps the id, place in the stack and style of [stroke]. Null
/// when the stroke looks like none of them.
BoardElement? recognizeShape(BoardElement stroke) {
  final points = _resample(stroke.points, 64);
  if (points == null) return null;
  final bounds = _boundsOf(points);
  if (bounds.longestSide < 4) return null;
  var length = 0.0;
  for (var i = 1; i < points.length; i++) {
    length += (points[i] - points[i - 1]).distance;
  }
  if ((points.last - points.first).distance > 0.15 * length) return _line(stroke, points);
  return _ellipse(stroke, points, bounds) ?? _polygon(stroke, points, bounds);
}

BoardElement? _line(BoardElement stroke, List<Offset> points) {
  final start = points.first;
  var delta = points.last - start;
  for (final p in points) {
    if (_distanceToLine(p, start, points.last) > 0.06 * delta.distance) return null;
  }
  const step = math.pi / 2, snap = math.pi / 30;
  final straight = (delta.direction / step).round() * step;
  if ((delta.direction - straight).abs() < snap) {
    delta = Offset.fromDirection(straight, delta.distance);
  }
  return _element(
    stroke,
    ElementKind.line,
    x: stroke.x + start.dx,
    y: stroke.y + start.dy,
    points: [0, 0, delta.dx, delta.dy],
  );
}

BoardElement? _ellipse(BoardElement stroke, List<Offset> points, Rect bounds) {
  var rx = bounds.width / 2, ry = bounds.height / 2;
  if (math.min(rx, ry) < 0.1 * math.max(rx, ry)) return null;
  final center = bounds.center;
  var error = 0.0;
  for (final p in points) {
    final d = p - center;
    error += (math.sqrt(d.dx * d.dx / (rx * rx) + d.dy * d.dy / (ry * ry)) - 1).abs();
  }
  if (error / points.length > 0.08) return null;
  if ((rx - ry).abs() < 0.12 * math.max(rx, ry)) rx = ry = (rx + ry) / 2;
  return _element(
    stroke,
    ElementKind.ellipse,
    x: stroke.x + center.dx - rx,
    y: stroke.y + center.dy - ry,
    width: 2 * rx,
    height: 2 * ry,
  );
}

BoardElement? _polygon(BoardElement stroke, List<Offset> points, Rect bounds) {
  final size = bounds.longestSide;
  final flat = Float32List(2 * points.length);
  for (var i = 0; i < points.length; i++) {
    flat[2 * i] = points[i].dx;
    flat[2 * i + 1] = points[i].dy;
  }
  final kept = simplify(flat, 0.06 * size);
  final corners = [
    for (var i = 0; i + 1 < kept.length - 2; i += 2) Offset(kept[i], kept[i + 1]),
  ];
  // the ends of the stroke and the wobbles of a corner leave points that are
  // not corners: too close to the next one, or on a straight side
  for (var changed = true; changed && corners.length >= 3;) {
    changed = false;
    for (var i = 0; i < corners.length && corners.length >= 3; i++) {
      final previous = corners[(i - 1) % corners.length];
      final corner = corners[i];
      final next = corners[(i + 1) % corners.length];
      final turn = _turn((corner - previous).direction, (next - corner).direction);
      if ((next - corner).distance < 0.12 * size || turn.abs() < math.pi / 8) {
        corners.removeAt(i);
        changed = true;
      }
    }
  }
  if (corners.length < 3 || corners.length > 8) return null;
  if (corners.length == 4 && _upright(corners)) return _rectangle(stroke, _boundsOf(corners));
  return _element(
    stroke,
    ElementKind.polygon,
    x: stroke.x,
    y: stroke.y,
    points: [for (final c in corners) ...[c.dx, c.dy]],
  );
}

/// Whether the four sides run close to horizontal and vertical.
bool _upright(List<Offset> corners) {
  for (var i = 0; i < corners.length; i++) {
    final side = corners[(i + 1) % corners.length] - corners[i];
    final off = side.direction % (math.pi / 2);
    if (math.min(off, math.pi / 2 - off) > math.pi / 12) return false;
  }
  return true;
}

BoardElement _rectangle(BoardElement stroke, Rect rect) {
  if ((rect.width - rect.height).abs() < 0.1 * rect.longestSide) {
    final side = (rect.width + rect.height) / 2;
    rect = Rect.fromCenter(center: rect.center, width: side, height: side);
  }
  return _element(
    stroke,
    ElementKind.rectangle,
    x: stroke.x + rect.left,
    y: stroke.y + rect.top,
    width: rect.width,
    height: rect.height,
  );
}

BoardElement _element(
  BoardElement stroke,
  ElementKind kind, {
  required double x,
  required double y,
  double width = 0,
  double height = 0,
  List<double>? points,
}) => BoardElement(
  id: stroke.id,
  kind: kind,
  z: stroke.z,
  x: x,
  y: y,
  width: width,
  height: height,
  points: points == null ? null : Float32List.fromList(points),
  color: stroke.color,
  strokeWidth: stroke.strokeWidth,
  filled: stroke.filled,
  dash: stroke.dash,
);

/// [count] points evenly spaced along [p], or null when it has no length.
List<Offset>? _resample(Float32List p, int count) {
  final input = [for (var i = 0; i + 1 < p.length; i += 2) Offset(p[i], p[i + 1])];
  var length = 0.0;
  for (var i = 1; i < input.length; i++) {
    length += (input[i] - input[i - 1]).distance;
  }
  if (length == 0) return null;
  final step = length / (count - 1);
  final out = [input.first];
  var carried = 0.0;
  for (var i = 1; i < input.length && out.length < count; i++) {
    final from = input[i - 1], to = input[i];
    final segment = (to - from).distance;
    var at = step - carried;
    while (at <= segment && out.length < count) {
      out.add(Offset.lerp(from, to, at / segment)!);
      at += step;
    }
    carried = segment - (at - step);
  }
  while (out.length < count) {
    out.add(input.last);
  }
  return out;
}

Rect _boundsOf(List<Offset> points) {
  var left = double.infinity, top = double.infinity;
  var right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final p in points) {
    left = math.min(left, p.dx);
    top = math.min(top, p.dy);
    right = math.max(right, p.dx);
    bottom = math.max(bottom, p.dy);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

double _distanceToLine(Offset p, Offset a, Offset b) {
  final ab = b - a;
  if (ab.distance == 0) return (p - a).distance;
  return ((p.dx - a.dx) * ab.dy - (p.dy - a.dy) * ab.dx).abs() / ab.distance;
}

/// The angle from direction [a] to direction [b], within ±π.
double _turn(double a, double b) {
  final turn = (b - a) % (2 * math.pi);
  return turn > math.pi ? turn - 2 * math.pi : turn;
}
