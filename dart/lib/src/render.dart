import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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

/// The committed elements, recorded once and replayed at any zoom. They are
/// recorded in chunks of neighbours in stacking order, so that an edit only
/// records its chunk again.
class Scene {
  static const _chunkSize = 256;

  final _chunks = <_Chunk>[];
  final _chunkOf = <String, _Chunk>{};
  Set<String> _hidden = const {};
  var _built = false;

  /// What is drawn, bottom to top.
  @visibleForTesting
  Iterable<BoardElement> get drawn => _chunks.expand((chunk) => chunk.elements);

  /// Catches up with [board], leaving out the [hidden] elements.
  void sync(Board board, Set<String> hidden) {
    final changes = board.takeChanges();
    if (changes == null || !_built) {
      _hidden = hidden;
      _rebuild(board);
      return;
    }
    if (!_sameSet(hidden, _hidden)) {
      changes
        ..addAll(hidden.difference(_hidden))
        ..addAll(_hidden.difference(hidden));
      _hidden = hidden;
    }
    for (final id in changes) {
      final chunk = _chunkOf.remove(id);
      if (chunk != null) {
        chunk.remove(id);
        if (chunk.elements.isEmpty) _chunks.remove(chunk);
      }
      final e = board[id];
      if (e != null && !hidden.contains(id)) _insert(e);
    }
  }

  void paint(Canvas canvas) {
    for (final chunk in _chunks) {
      canvas.drawPicture(chunk.picture);
    }
  }

  void dispose() {
    for (final chunk in _chunks) {
      chunk.clear();
    }
    _chunks.clear();
    _chunkOf.clear();
    _built = false;
  }

  void _rebuild(Board board) {
    dispose();
    _built = true;
    for (final e in board.elements) {
      if (_hidden.contains(e.id)) continue;
      if (_chunks.isEmpty || _chunks.last.elements.length >= _chunkSize) _chunks.add(_Chunk());
      _chunks.last.elements.add(e);
      _chunkOf[e.id] = _chunks.last;
    }
  }

  /// Into the highest chunk that starts below [e]: new elements usually go
  /// on top, in the last chunk, or in a new one once it is full.
  void _insert(BoardElement e) {
    var i = _chunks.length - 1;
    while (i > 0 && compareElements(_chunks[i].elements.first, e) > 0) {
      i--;
    }
    if (i < 0 ||
        i == _chunks.length - 1 &&
            _chunks[i].elements.length >= _chunkSize &&
            compareElements(_chunks[i].elements.last, e) < 0) {
      _chunks.add(_Chunk());
      i++;
    }
    final chunk = _chunks[i]..insert(e);
    _chunkOf[e.id] = chunk;
    if (chunk.elements.length > 2 * _chunkSize) _split(i);
  }

  void _split(int i) {
    final lower = _chunks[i];
    final upper = _Chunk()..elements.addAll(lower.elements.skip(_chunkSize));
    lower.elements.length = _chunkSize;
    _chunks.insert(i + 1, upper);
    for (final e in upper.elements) {
      _chunkOf[e.id] = upper;
    }
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      identical(a, b) || a.length == b.length && a.containsAll(b);
}

class _Chunk {
  final elements = <BoardElement>[];
  ui.Picture? _picture;

  ui.Picture get picture => _picture ??= _record();

  void insert(BoardElement e) {
    var low = 0, high = elements.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (compareElements(elements[middle], e) < 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    elements.insert(low, e);
    clear();
  }

  void remove(String id) {
    elements.removeWhere((e) => e.id == id);
    clear();
  }

  /// Drops the recording, to be made again on the next paint.
  void clear() {
    _picture?.dispose();
    _picture = null;
  }

  ui.Picture _record() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final e in elements) {
      paintElement(canvas, e);
    }
    return recorder.endRecording();
  }
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
