import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';
import 'package:image/image.dart' as img;

import 'element.dart';

/// What an image may weigh once prepared: written as a data URL, it stays
/// under the server's default limit of 256 KiB per element.
const maxImageBytes = 180 << 10;

/// Longest side of a prepared image, in pixels.
const maxImageSide = 1600;

/// An image file made ready for a board: [src] is its data URL, [size] the
/// size it is drawn at.
typedef PreparedImage = ({String src, ui.Size size});

/// Keeps [bytes] as they are when they are small enough, and otherwise scales
/// the image down and encodes it again: as JPEG, or as PNG when it has
/// transparency. An SVG is drawn at its own size, from a picture rendered
/// [maxImageSide] pixels long so that it stays sharp when enlarged. Throws a
/// [FormatException] when [bytes] are not an image.
Future<PreparedImage> prepareImage(Uint8List bytes, {int maxBytes = maxImageBytes}) async {
  final svg = _isSvg(bytes);
  final ui.Image image;
  ui.Size? drawn;
  try {
    if (svg) {
      final picture = await vg.loadPicture(SvgBytesLoader(bytes), null);
      drawn = picture.size;
      image = await _rasterize(picture);
    } else {
      image = await _decode(bytes);
    }
  } on Object {
    throw const FormatException('Not an image');
  }
  try {
    final mime = svg ? null : _mime(bytes);
    var side = math.max(image.width, image.height);
    if (mime != null && bytes.length <= maxBytes && side <= maxImageSide) {
      return (
        src: _dataUrl(mime, bytes),
        size: ui.Size(image.width.toDouble(), image.height.toDouble()),
      );
    }
    side = math.min(side, maxImageSide);
    while (side >= 16) {
      final (:mime, :bytes, :size) = await _encode(image, side);
      if (bytes.length <= maxBytes) return (src: _dataUrl(mime, bytes), size: drawn ?? size);
      // the weight follows the area: aim just under the budget
      side = (side * math.min(0.9, 0.95 * math.sqrt(maxBytes / bytes.length))).floor();
    }
    throw const FormatException('Image too large');
  } finally {
    image.dispose();
  }
}

/// Whether [bytes] hold SVG markup: text opening on a tag, an `<svg` one
/// among the first.
bool _isSvg(Uint8List bytes) {
  final head = utf8.decode(bytes.take(1024).toList(), allowMalformed: true).trimLeft();
  return head.startsWith('<') && head.contains('<svg');
}

Future<ui.Image> _rasterize(PictureInfo svg) async {
  try {
    final size = svg.size;
    if (size.isEmpty) throw const FormatException('Empty SVG');
    final k = maxImageSide / size.longestSide;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder)
      ..scale(k)
      ..drawPicture(svg.picture);
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(
        math.max(1, (size.width * k).round()),
        math.max(1, (size.height * k).round()),
      );
    } finally {
      picture.dispose();
    }
  } finally {
    svg.picture.dispose();
  }
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Future<({String mime, Uint8List bytes, ui.Size size})> _encode(ui.Image image, int side) async {
  final k = side / math.max(image.width, image.height);
  final width = math.max(1, (image.width * k).round());
  final height = math.max(1, (image.height * k).round());
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final scaled = await picture.toImage(width, height);
  picture.dispose();
  try {
    final size = ui.Size(width.toDouble(), height.toDouble());
    final rgba = (await scaled.toByteData(format: ui.ImageByteFormat.rawStraightRgba))!;
    if (_opaque(rgba)) {
      final jpeg = img.encodeJpg(
        img.Image.fromBytes(
          width: width,
          height: height,
          bytes: rgba.buffer,
          bytesOffset: rgba.offsetInBytes,
          numChannels: 4,
        ),
        quality: 80,
        chroma: img.JpegChroma.yuv420,
      );
      return (mime: 'image/jpeg', bytes: jpeg, size: size);
    }
    final png = (await scaled.toByteData(format: ui.ImageByteFormat.png))!;
    return (
      mime: 'image/png',
      bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      size: size,
    );
  } finally {
    scaled.dispose();
  }
}

bool _opaque(ByteData rgba) {
  for (var i = 3; i < rgba.lengthInBytes; i += 4) {
    if (rgba.getUint8(i) != 0xFF) return false;
  }
  return true;
}

/// The formats every platform decodes, kept as they are.
String? _mime(Uint8List b) {
  bool starts(List<int> magic, [int at = 0]) {
    if (b.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (b[at + i] != magic[i]) return false;
    }
    return true;
  }

  if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (starts(ascii.encode('GIF8'))) return 'image/gif';
  if (starts(ascii.encode('RIFF')) && starts(ascii.encode('WEBP'), 8)) return 'image/webp';
  return null;
}

String _dataUrl(String mime, Uint8List bytes) => 'data:$mime;base64,${base64Encode(bytes)}';

/// The pictures of image elements, each decoded once while it is on the
/// board. [onDecoded] is told the id of each picture once it is ready.
class DecodedImages {
  DecodedImages({this.onDecoded});

  final void Function(String id)? onDecoded;
  final _entries = <String, _Entry>{};

  /// The picture of [e], or null while it is decoded or when it cannot be.
  ui.Image? operator [](BoardElement e) => _entry(e).image;

  /// Decodes the pictures of [elements] that are not decoded yet.
  Future<void> decodeAll(Iterable<BoardElement> elements) => Future.wait([
    for (final e in elements)
      if (e.kind == ElementKind.image) _entry(e).ready,
  ]);

  void forget(String id) => _entries.remove(id)?.dispose();

  void retainWhere(bool Function(String id) keep) {
    for (final id in _entries.keys.where((id) => !keep(id)).toList()) {
      forget(id);
    }
  }

  void dispose() => retainWhere((_) => false);

  _Entry _entry(BoardElement e) {
    final known = _entries[e.id];
    if (known != null && known.src == e.src) return known;
    known?.dispose();
    final entry = _entries[e.id] = _Entry(e.src);
    entry.ready = _load(e.id, entry);
    return entry;
  }

  Future<void> _load(String id, _Entry entry) async {
    final ui.Image image;
    try {
      image = await _decode(UriData.parse(entry.src).contentAsBytes());
    } on Object {
      return;
    }
    if (_entries[id] != entry) {
      image.dispose();
      return;
    }
    entry.image = image;
    onDecoded?.call(id);
  }
}

class _Entry {
  _Entry(this.src);

  final String src;
  late final Future<void> ready;
  ui.Image? image;

  void dispose() {
    image?.dispose();
    image = null;
  }
}
