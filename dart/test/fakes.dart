import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fresque/fresque.dart';

class FakeTransport implements BoardTransport {
  final _incoming = StreamController<String>();
  final sent = <Map<String, Object?>>[];

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  Stream<String> get messages => _incoming.stream;

  @override
  void send(String data) => sent.add(jsonDecode(data) as Map<String, Object?>);

  @override
  Future<void> close() => _incoming.close();

  void receive(Map<String, Object?> frame) => _incoming.add(jsonEncode(frame));

  Future<void> drop([int? code, String? reason]) {
    closeCode = code;
    closeReason = reason;
    return _incoming.close();
  }

  List<Map<String, Object?>> sentOfType(String type) => [
    for (final frame in sent)
      if (frame['t'] == type) frame,
  ];
}

/// Hands out a new [FakeTransport] per connection.
class FakeServer {
  final transports = <FakeTransport>[];
  final clientIds = <String>[];

  FakeTransport get last => transports.last;

  Future<BoardTransport> connect(String clientId) async {
    clientIds.add(clientId);
    final transport = FakeTransport();
    transports.add(transport);
    return transport;
  }
}

Map<String, Object?> hello({
  int sid = 1,
  int ack = 0,
  int version = 0,
  int saved = 0,
  bool readOnly = false,
  List<Map<String, Object?>> elements = const [],
  List<Map<String, Object?>> peers = const [],
}) => {
  't': 'hello',
  'sid': sid,
  'ack': ack,
  'v': version,
  'saved': saved,
  'ro': readOnly,
  'peers': peers,
  'elements': elements,
};

BoardElement rect(String id, {int z = 1, double x = 0, double y = 0}) => BoardElement(
  id: id,
  kind: ElementKind.rectangle,
  z: z,
  x: x,
  y: y,
  width: 10,
  height: 10,
  color: 0xFF000000,
);

/// A PNG of [width] × [height] pixels of noise, which compresses badly.
Future<Uint8List> noisePng(int width, int height, {bool transparent = false}) async {
  final random = math.Random(1);
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i++) {
    pixels[i] = i % 4 == 3 && !transparent ? 0xFF : random.nextInt(256);
  }
  final decoded = Completer<ui.Image>();
  ui.decodeImageFromPixels(pixels, width, height, ui.PixelFormat.rgba8888, decoded.complete);
  final image = await decoded.future;
  final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  return png.buffer.asUint8List();
}
