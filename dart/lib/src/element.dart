import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

enum ElementKind {
  stroke('s'),
  line('l'),
  arrow('a'),
  rectangle('r'),
  ellipse('e'),
  polygon('g'),
  text('t'),
  image('i');

  const ElementKind(this.code);

  final String code;

  static ElementKind? fromCode(Object? code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

/// How the outline of a path or a shape is drawn.
enum BoardDash {
  solid,
  dashed,
  dotted;

  static BoardDash fromCode(Object? code) => switch (code) {
    1 => dashed,
    2 => dotted,
    _ => solid,
  };
}

/// One thing drawn on a board. Immutable: an edit is a new element with the
/// same [id].
///
/// Strokes, lines, arrows and polygons hold their [points] as
/// `x0, y0, x1, y1, …` relative to ([x], [y]), so moving one only changes its
/// origin; a polygon joins its last point back to its first. Shapes,
/// texts and images span [width] × [height] from their origin. An image
/// carries its picture in [src], a data URL.
@immutable
class BoardElement {
  BoardElement({
    required this.id,
    required this.kind,
    required this.z,
    required this.x,
    required this.y,
    required this.color,
    this.width = 0,
    this.height = 0,
    Float32List? points,
    this.strokeWidth = 2,
    this.filled = false,
    this.dash = BoardDash.solid,
    this.text = '',
    this.fontSize = 20,
    this.src = '',
  }) : points = points ?? _noPoints;

  static final _noPoints = Float32List(0);

  final String id;
  final ElementKind kind;
  final int z;
  final double x;
  final double y;
  final double width;
  final double height;
  final Float32List points;
  final int color;
  final double strokeWidth;
  final bool filled;
  final BoardDash dash;
  final String text;
  final double fontSize;
  final String src;

  /// What its points or its size span, the width of the stroke left out.
  late final Rect box = _box();

  /// What it covers once drawn.
  late final Rect bounds = _bounds();

  bool get isPath =>
      kind == ElementKind.stroke ||
      kind == ElementKind.line ||
      kind == ElementKind.arrow ||
      kind == ElementKind.polygon;

  /// Whether it can be stretched by its corners: anything but a text or a
  /// dot.
  bool get canResize => kind != ElementKind.text && box.longestSide > 0;

  bool get canFill =>
      kind == ElementKind.rectangle || kind == ElementKind.ellipse || kind == ElementKind.polygon;

  BoardElement copyWith({
    String? id,
    int? z,
    double? x,
    double? y,
    double? width,
    double? height,
    Float32List? points,
    int? color,
    double? strokeWidth,
    bool? filled,
    BoardDash? dash,
    String? text,
    double? fontSize,
  }) => BoardElement(
    id: id ?? this.id,
    kind: kind,
    z: z ?? this.z,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
    points: points ?? this.points,
    color: color ?? this.color,
    strokeWidth: strokeWidth ?? this.strokeWidth,
    filled: filled ?? this.filled,
    dash: dash ?? this.dash,
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
    src: src,
  );

  BoardElement translated(Offset delta) => copyWith(x: x + delta.dx, y: y + delta.dy);

  /// Stretched so that its [box] becomes [to]. A side of no length, that of a
  /// level line, keeps none.
  BoardElement fitted(Rect to) {
    if (!isPath) return copyWith(x: to.left, y: to.top, width: to.width, height: to.height);
    final from = box;
    final kx = from.width == 0 ? 0.0 : to.width / from.width;
    final ky = from.height == 0 ? 0.0 : to.height / from.height;
    final scaled = Float32List(points.length);
    for (var i = 0; i + 1 < points.length; i += 2) {
      scaled[i] = (x + points[i] - from.left) * kx;
      scaled[i + 1] = (y + points[i + 1] - from.top) * ky;
    }
    return copyWith(x: to.left, y: to.top, points: scaled);
  }

  Rect _box() {
    if (!isPath) return Rect.fromLTWH(x, y, width, height);
    if (points.isEmpty) return Rect.fromLTWH(x, y, 0, 0);
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    for (var i = 0; i + 1 < points.length; i += 2) {
      left = math.min(left, points[i]);
      right = math.max(right, points[i]);
      top = math.min(top, points[i + 1]);
      bottom = math.max(bottom, points[i + 1]);
    }
    return Rect.fromLTRB(x + left, y + top, x + right, y + bottom);
  }

  Rect _bounds() => switch (kind) {
    ElementKind.text || ElementKind.image => box,
    ElementKind.arrow => box.inflate(arrowHeadLength),
    _ => box.inflate(strokeWidth / 2),
  };

  double get arrowHeadLength => math.max(12, strokeWidth * 4);

  Map<String, Object?> toJson() => {
    'id': id,
    'k': kind.code,
    'z': z,
    'x': _num(x),
    'y': _num(y),
    if (width != 0) 'w': _num(width),
    if (height != 0) 'h': _num(height),
    if (points.isNotEmpty) 'p': [for (final v in points) _num(v)],
    'c': color,
    'sw': _num(strokeWidth),
    if (filled) 'f': 1,
    if (dash != BoardDash.solid) 'd': dash.index,
    if (kind == ElementKind.text) ...{'tx': text, 'fs': _num(fontSize)},
    if (kind == ElementKind.image) 'src': src,
  };

  /// Null for anything this version cannot draw, which is then left alone.
  static BoardElement? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['id'];
    final kind = ElementKind.fromCode(json['k']);
    if (id is! String || kind == null) return null;
    final p = json['p'];
    return BoardElement(
      id: id,
      kind: kind,
      z: _int(json['z']),
      x: _double(json['x']),
      y: _double(json['y']),
      width: _double(json['w']),
      height: _double(json['h']),
      points: p is List<Object?> ? _points(p) : null,
      color: _int(json['c'], 0xFF000000),
      strokeWidth: _double(json['sw'], 2),
      filled: json['f'] == 1 || json['f'] == true,
      dash: BoardDash.fromCode(json['d']),
      text: json['tx'] is String ? json['tx']! as String : '',
      fontSize: _double(json['fs'], 20),
      src: json['src'] is String ? json['src']! as String : '',
    );
  }

  static Float32List _points(List<Object?> json) {
    final points = Float32List(json.length);
    for (var i = 0; i < json.length; i++) {
      points[i] = _double(json[i]);
    }
    return points;
  }

  /// Tenths of a unit are finer than anyone draws; whole numbers are written
  /// without a decimal point.
  static num _num(double v) {
    final tenths = (v * 10).round();
    return tenths % 10 == 0 ? tenths ~/ 10 : tenths / 10;
  }

  static double _double(Object? v, [double fallback = 0]) =>
      v is num && v.isFinite ? v.toDouble() : fallback;

  static int _int(Object? v, [int fallback = 0]) => v is num && v.isFinite ? v.toInt() : fallback;
}
