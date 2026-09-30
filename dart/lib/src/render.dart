import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'board.dart';
import 'element.dart';
import 'images.dart';
import 'pdf.dart';

final _paths = Expando<Path>();
final _texts = Expando<TextPainter>();

/// Draws [e] in board coordinates. An image not decoded in [images] yet is
/// drawn as a grey box.
void paintElement(Canvas canvas, BoardElement e, {double opacity = 1, DecodedImages? images}) {
  final color = Color(e.color);
  final stroke = Paint()
    ..color = opacity == 1 ? color : color.withValues(alpha: color.a * opacity)
    ..style = PaintingStyle.stroke
    ..strokeWidth = e.strokeWidth
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  switch (e.kind) {
    case ElementKind.stroke || ElementKind.line || ElementKind.arrow || ElementKind.polygon:
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
        final polygon = e.kind == ElementKind.polygon;
        final path = _paths[p] ??= polygon ? (Path()..addPolygon(_offsets(p), true)) : _path(p);
        if (polygon && e.filled) canvas.drawPath(path, _fill(stroke.color));
        canvas.drawPath(_dashed(path, e), stroke);
        if (e.kind == ElementKind.arrow) _arrowHead(canvas, e, stroke);
      }
      canvas.restore();
    case ElementKind.rectangle || ElementKind.ellipse:
      final rect = Rect.fromLTWH(e.x, e.y, e.width, e.height);
      final outline = e.kind == ElementKind.rectangle
          ? (Path()..addRect(rect))
          : (Path()..addOval(rect));
      if (e.filled) canvas.drawPath(outline, _fill(stroke.color));
      canvas.drawPath(_dashed(outline, e), stroke);
    case ElementKind.text:
      final painter = _texts[e] ??= textPainter(e);
      if (opacity == 1) {
        painter.paint(canvas, Offset(e.x, e.y));
      } else {
        canvas.saveLayer(e.bounds, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
        painter.paint(canvas, Offset(e.x, e.y));
        canvas.restore();
      }
    case ElementKind.image:
      final rect = Rect.fromLTWH(e.x, e.y, e.width, e.height);
      final image = images?[e];
      if (image == null) {
        canvas.drawRect(rect, Paint()..color = Color.fromRGBO(0, 0, 0, 0.06 * opacity));
      } else {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          rect,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..color = Color.fromRGBO(0, 0, 0, opacity),
        );
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

Paint _fill(Color color) => Paint()..color = color.withValues(alpha: color.a * 0.25);

List<Offset> _offsets(Float32List p) => [
  for (var i = 0; i + 1 < p.length; i += 2) Offset(p[i], p[i + 1]),
];

/// [path] cut into dashes or dots for [e], or as it is when it is solid. The
/// round caps lengthen each dash by the width of the stroke, and shorten each
/// gap as much.
Path _dashed(Path path, BoardElement e) {
  if (e.dash == BoardDash.solid) return path;
  final width = e.strokeWidth;
  final (on, off) = e.dash == BoardDash.dashed
      ? (3 * width + 4, 3 * width + 4)
      : (0.01, 2 * width + 3);
  final out = Path();
  for (final metric in path.computeMetrics()) {
    for (var at = 0.0; at < metric.length; at += on + off) {
      out.addPath(metric.extractPath(at, math.min(at + on, metric.length)), Offset.zero);
    }
  }
  return out;
}

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
/// records its chunk again. Listeners are told when a picture was decoded.
class Scene extends ChangeNotifier {
  static const _chunkSize = 256;

  late final images = DecodedImages(onDecoded: _decoded);

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
      if (e?.kind != ElementKind.image) images.forget(id);
      if (e != null && !hidden.contains(id)) _insert(e);
    }
  }

  void paint(Canvas canvas) {
    for (final chunk in _chunks) {
      canvas.drawPicture(chunk.picture(images));
    }
  }

  @override
  void dispose() {
    _clear();
    images.dispose();
    super.dispose();
  }

  void _decoded(String id) {
    _chunkOf[id]?.clear();
    notifyListeners();
  }

  void _clear() {
    for (final chunk in _chunks) {
      chunk.clear();
    }
    _chunks.clear();
    _chunkOf.clear();
    _built = false;
  }

  void _rebuild(Board board) {
    _clear();
    images.retainWhere((id) => board[id]?.kind == ElementKind.image);
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

  ui.Picture picture(DecodedImages images) => _picture ??= _record(images);

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

  ui.Picture _record(DecodedImages images) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    for (final e in elements) {
      paintElement(canvas, e, images: images);
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
  final bounds = _bounds(elements, margin);
  final scale = math.min(pixelRatio, maxSide / math.max(bounds.width, bounds.height));
  final images = DecodedImages();
  try {
    await images.decodeAll(elements);
    final image = await _render(elements, images, bounds, scale, background);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    images.dispose();
  }
}

/// A4 in board units, at 96 per inch.
const _a4 = Size(794, 1123);

/// The whole board as a PDF, or null when it is empty. Elements closer than
/// [margin] form groups that a page never cuts: each page gathers the groups
/// that fit together on A4 at their real size, turned like them, with [margin]
/// around. A group too large for A4 gets a page of its own, scaled down to it.
/// Pages are rendered at [pixelRatio], lowered only past [maxSide] pixels, on
/// an opaque [background].
Future<Uint8List?> exportPdf(
  Board board, {
  double pixelRatio = 2,
  Color background = const Color(0xFFFFFFFF),
  double margin = 32,
  int maxSide = 8192,
}) async {
  final elements = board.elements;
  if (elements.isEmpty) return null;
  final groups = [
    for (final group in _groups(elements, margin))
      (elements: group, bounds: _bounds(group, margin)),
  ];
  final pdf = PdfPictures();
  final images = DecodedImages();
  try {
    await images.decodeAll(elements);
    while (groups.isNotEmpty) {
      final first = groups.reduce((a, b) => _readFirst(a.bounds, b.bounds) ? a : b);
      groups.remove(first);
      var area = first.bounds;
      final drawn = {...first.elements};
      final center = first.bounds.center;
      double distance(Rect r) => (r.center - center).distance;
      final nearest = [...groups]
        ..sort((a, b) => distance(a.bounds).compareTo(distance(b.bounds)));
      for (final group in nearest) {
        final both = area.expandToInclude(group.bounds);
        if (both.size.shortestSide > _a4.width || both.size.longestSide > _a4.height) continue;
        area = both;
        drawn.addAll(group.elements);
        groups.remove(group);
      }
      final paper = area.width > area.height ? _a4.flipped : _a4;
      final grow = math.max(1.0, math.max(area.width / paper.width, area.height / paper.height));
      final rect = Rect.fromCenter(
        center: area.center,
        width: paper.width * grow,
        height: paper.height * grow,
      );
      final scale = math.min(pixelRatio, maxSide / rect.longestSide);
      final image = await _render(elements.where(drawn.contains), images, rect, scale, background);
      try {
        final rgb = await _rgb(image, background);
        if (rgb == null) continue;
        pdf.addPage(paper.width * 0.75, paper.height * 0.75, image.width, image.height, rgb);
      } finally {
        image.dispose();
      }
    }
  } finally {
    images.dispose();
  }
  return pdf.close();
}

/// [elements] in groups linked by bounds less than [gap] apart.
List<List<BoardElement>> _groups(List<BoardElement> elements, double gap) {
  final sorted = [...elements]..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
  final parent = List.generate(sorted.length, (i) => i);
  int root(int i) {
    while (parent[i] != i) {
      i = parent[i] = parent[parent[i]];
    }
    return i;
  }

  for (var i = 0; i < sorted.length; i++) {
    final near = sorted[i].bounds.inflate(gap);
    for (var j = i + 1; j < sorted.length && sorted[j].bounds.left < near.right; j++) {
      if (sorted[j].bounds.overlaps(near)) parent[root(j)] = root(i);
    }
  }
  final groups = <int, List<BoardElement>>{};
  for (var i = 0; i < sorted.length; i++) {
    (groups[root(i)] ??= []).add(sorted[i]);
  }
  return groups.values.toList();
}

bool _readFirst(Rect a, Rect b) => a.top < b.top || a.top == b.top && a.left <= b.left;

Rect _bounds(List<BoardElement> elements, double margin) =>
    elements.map((e) => e.bounds).reduce((a, b) => a.expandToInclude(b)).inflate(margin);

Future<ui.Image> _render(
  Iterable<BoardElement> elements,
  DecodedImages images,
  Rect rect,
  double scale,
  Color background,
) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..scale(scale)
    ..translate(-rect.left, -rect.top)
    ..drawRect(rect, Paint()..color = background);
  for (final e in elements) {
    paintElement(canvas, e, images: images);
  }
  final picture = recorder.endRecording();
  final image = picture.toImage(
    math.max(1, (rect.width * scale).ceil()),
    math.max(1, (rect.height * scale).ceil()),
  );
  picture.dispose();
  return image;
}

/// The pixels of [image] without their alpha, or null when all of them are
/// [background].
Future<Uint8List?> _rgb(ui.Image image, Color background) async {
  final data = (await image.toByteData())!;
  final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final rgb = Uint8List(rgba.length ~/ 4 * 3);
  final r = (background.r * 255).round(), g = (background.g * 255).round();
  final b = (background.b * 255).round();
  var blank = true;
  for (var i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    rgb[j] = rgba[i];
    rgb[j + 1] = rgba[i + 1];
    rgb[j + 2] = rgba[i + 2];
    blank = blank && rgba[i] == r && rgba[i + 1] == g && rgba[i + 2] == b;
  }
  return blank ? null : rgb;
}
