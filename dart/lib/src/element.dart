import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

enum ElementKind {
  stroke('s'),
  line('l'),
  arrow('a'),
  rectangle('r'),
  ellipse('e'),
  text('t');

  const ElementKind(this.code);

  final String code;

  static ElementKind? fromCode(Object? code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

/// One thing drawn on a board. Immutable: an edit is a new element with the
/// same [id].
///
/// Strokes, lines and arrows hold their [points] as `x0, y0, x1, y1, …`
/// relative to ([x], [y]), so moving one only changes its origin. Shapes and
/// texts span [width] × [height] from their origin.
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
    this.text = '',
    this.fontSize = 20,
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
  final String text;
  final double fontSize;

  late final Rect bounds = _bounds();

  bool get isPath =>
      kind == ElementKind.stroke || kind == ElementKind.line || kind == ElementKind.arrow;

  BoardElement copyWith({
    int? z,
    double? x,
    double? y,
    double? width,
    double? height,
    Float32List? points,
    int? color,
    double? strokeWidth,
    bool? filled,
    String? text,
    double? fontSize,
  }) => BoardElement(
    id: id,
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
    text: text ?? this.text,
    fontSize: fontSize ?? this.fontSize,
  );

  BoardElement translated(Offset delta) => copyWith(x: x + delta.dx, y: y + delta.dy);

  Rect _bounds() {
    if (isPath) {
      if (points.isEmpty) return Rect.fromLTWH(x, y, 0, 0);
      var left = double.infinity, top = double.infinity;
      var right = double.negativeInfinity, bottom = double.negativeInfinity;
      for (var i = 0; i + 1 < points.length; i += 2) {
        left = math.min(left, points[i]);
        right = math.max(right, points[i]);
        top = math.min(top, points[i + 1]);
        bottom = math.max(bottom, points[i + 1]);
      }
      final pad = kind == ElementKind.arrow ? arrowHeadLength : strokeWidth / 2;
      return Rect.fromLTRB(x + left, y + top, x + right, y + bottom).inflate(pad);
    }
    final rect = Rect.fromLTWH(x, y, width, height);
    return kind == ElementKind.text ? rect : rect.inflate(strokeWidth / 2);
  }

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
    if (kind == ElementKind.text) ...{'tx': text, 'fs': _num(fontSize)},
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
      text: json['tx'] is String ? json['tx']! as String : '',
      fontSize: _double(json['fs'], 20),
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
