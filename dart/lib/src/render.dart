import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'board.dart';
import 'element.dart';

final _paths = Expando<Path>();
final _texts = Expando<TextPainter>();

/// Draws [e] in board coordinates.
void paintElement(Canvas canvas, BoardElement e, {double opacity = 1}) {
  final color = Color(e.color);
  final stroke = Paint()
    ..color = opacity == 1 ? color : color.withValues(alpha: color.a * opacity)
    ..style = PaintingStyle.stroke
    ..strokeWidth = e.strokeWidth
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  switch (e.kind) {
    case ElementKind.stroke || ElementKind.line || ElementKind.arrow:
      final p = e.points;
      if (p.length < 2) return;
      canvas.save();
      canvas.translate(e.x, e.y);
      if (p.length == 2) {
        canvas.drawCircle(
          Offset(p[0], p[1]),
          e.strokeWidth / 2,
          stroke..style = PaintingStyle.fill,
        );
      } else {
        canvas.drawPath(_paths[p] ??= _path(p), stroke);
        if (e.kind == ElementKind.arrow) _arrowHead(canvas, e, stroke);
      }
      canvas.restore();
    case ElementKind.rectangle || ElementKind.ellipse:
      final rect = Rect.fromLTWH(e.x, e.y, e.width, e.height);
      final draw = e.kind == ElementKind.rectangle ? canvas.drawRect : canvas.drawOval;
      if (e.filled) {
        draw(rect, Paint()..color = stroke.color.withValues(alpha: stroke.color.a * 0.25));
      }
      draw(rect, stroke);
    case ElementKind.text:
      final painter = _texts[e] ??= textPainter(e);
      if (opacity == 1) {
        painter.paint(canvas, Offset(e.x, e.y));
      } else {
        canvas.saveLayer(e.bounds, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
        painter.paint(canvas, Offset(e.x, e.y));
        canvas.restore();
      }
  }
}

TextPainter textPainter(BoardElement e) => TextPainter(
  text: TextSpan(text: e.text, style: textStyle(e.color, e.fontSize)),
  textDirection: TextDirection.ltr,
)..layout();

/// Not inherited from the theme, so that a text looks the same being edited
/// and drawn.
TextStyle textStyle(int color, double fontSize) => TextStyle(
  inherit: false,
  color: Color(color),
  fontSize: fontSize,
  height: 1.25,
  textBaseline: TextBaseline.alphabetic,
);

/// A smooth curve through the points: quadratic segments between their
/// midpoints.
Path _path(Float32List p) {
  final path = Path()..moveTo(p[0], p[1]);
  final last = p.length - 2;
  if (last == 2) return path..lineTo(p[2], p[3]);
  for (var i = 2; i < last; i += 2) {
    path.quadraticBezierTo(p[i], p[i + 1], (p[i] + p[i + 2]) / 2, (p[i + 1] + p[i + 3]) / 2);
  }
  return path..lineTo(p[last], p[last + 1]);
}

void _arrowHead(Canvas canvas, BoardElement e, Paint paint) {
  final p = e.points;
  final tip = Offset(p[p.length - 2], p[p.length - 1]);
  final from = Offset(p[p.length - 4], p[p.length - 3]);
  final angle = (tip - from).direction;
  final length = e.arrowHeadLength;
  for (final side in const [-1, 1]) {
    canvas.drawLine(tip, tip - Offset.fromDirection(angle + side * math.pi / 7, length), paint);
  }
}

/// The committed elements, recorded once and replayed at any zoom. Elements
/// added on top only record themselves; anything else records the board
/// again.
class Scene {
  static const _maxLayers = 64;

  ui.Picture? _base;
  final _layers = <ui.Picture>[];
  final _drawn = <String>{};
  int _topZ = 0;
  Set<String> _hidden = const {};

  /// Catches up with [board], leaving out the [hidden] elements.
  void sync(Board board, Set<String> hidden) {
    final changes = board.takeChanges();
    if (_base != null && changes != null && _sameSet(hidden, _hidden) && _onTop(board, changes)) {
      if (changes.isNotEmpty) _addLayer(board, changes);
      return;
    }
    _hidden = hidden;
    _rebuild(board);
  }

  void paint(Canvas canvas) {
    final base = _base;
    if (base != null) canvas.drawPicture(base);
    _layers.forEach(canvas.drawPicture);
  }

  void dispose() {
    _base?.dispose();
    for (final layer in _layers) {
      layer.dispose();
    }
    _layers.clear();
  }

  bool _onTop(Board board, Set<String> changes) {
    if (_layers.length >= _maxLayers) return false;
    for (final id in changes) {
      final e = board[id];
      if (e == null || _drawn.contains(id) || _hidden.contains(id) || e.z <= _topZ) return false;
    }
    return true;
  }

  void _addLayer(Board board, Set<String> ids) {
    final elements = [for (final id in ids) board[id]!]..sort(compareElements);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final e in elements) {
      paintElement(canvas, e);
      _drawn.add(e.id);
    }
    _layers.add(recorder.endRecording());
    _topZ = elements.last.z;
  }

  void _rebuild(Board board) {
    dispose();
    _drawn.clear();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final elements = board.elements;
    for (final e in elements) {
      if (_hidden.contains(e.id)) continue;
      paintElement(canvas, e);
      _drawn.add(e.id);
    }
    _base = recorder.endRecording();
    _topZ = elements.isEmpty ? 0 : elements.last.z;
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      identical(a, b) || a.length == b.length && a.containsAll(b);
}

/// The whole board as a PNG, [margin] around the drawing, or null when it is
/// empty. The image is at most [maxSide] pixels on its longest side.
Future<Uint8List?> exportPng(
  Board board, {
  double pixelRatio = 2,
  Color background = const Color(0xFFFFFFFF),
  double margin = 32,
  int maxSide = 8192,
}) async {
  final elements = board.elements;
  if (elements.isEmpty) return null;
  final bounds = elements
      .map((e) => e.bounds)
      .reduce((a, b) => a.expandToInclude(b))
      .inflate(margin);
  final scale = math.min(pixelRatio, maxSide / math.max(bounds.width, bounds.height));
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..scale(scale)
    ..translate(-bounds.left, -bounds.top)
    ..drawRect(bounds, Paint()..color = background);
  for (final e in elements) {
    paintElement(canvas, e);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    math.max(1, (bounds.width * scale).ceil()),
    math.max(1, (bounds.height * scale).ceil()),
  );
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}
