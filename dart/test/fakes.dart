import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fresque/fresque.dart';
import 'package:trame/trame.dart';

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
  int saved = 0,
  bool readOnly = false,
  String epoch = 'e0',
  List<Map<String, Object?>> peers = const [],
}) => {
  't': 'hello',
  'sid': sid,
  'id': 'me',
  'name': 'Me',
  'epoch': epoch,
  'v': 0,
  'saved': saved,
  'ro': readOnly,
  'peers': peers,
};

/// The change that creates an element, as the hub writes it.
Map<String, Object?> created(BoardElement e) => {
  'o': 'new',
  'id': e.id,
  't': elementType,
  'k': zKey(e.z),
  'a': e.attributes,
};

/// The element a client's edit creates.
BoardElement sentElement(Map<String, Object?> change) =>
    BoardElement.fromJson({...(change['a']! as Map<String, Object?>), 'id': change['id'], 'z': zOf('${change['k']}')})!;

/// What the hub answers to a client that asks for the board: all of it.
Map<String, Object?> doc(Iterable<BoardElement> elements, {int version = 0, int ack = 0}) => {
  't': 'doc',
  'v': version,
  'ack': ack,
  'd': [for (final e in elements) created(e)],
};

/// An edit of somebody else, as the hub relays it.
Map<String, Object?> op(List<Map<String, Object?>> changes, {int sid = 2, required int version}) => {
  't': 'op',
  'sid': sid,
  'v': version,
  'd': changes,
};

/// A board over a document of its own, for the tests of how it is drawn
/// rather than of how it travels.
class TestBoard extends Board {
  TestBoard._(this._tree) : super(() => _tree);

  factory TestBoard([Iterable<BoardElement> elements = const []]) =>
      TestBoard._(Tree())..edit([...elements], const []);

  final Tree _tree;

  /// Puts elements, giving an element of the same id its new look, and deletes.
  void edit(List<BoardElement> put, List<String> delete) {
    final changes = <Change>[
      for (final e in put) ...[
        if (_tree[e.id] != null) Change.delete(e.id),
        Change.create(Node(id: e.id, type: elementType, key: zKey(e.z), attributes: e.attributes)),
      ],
      for (final id in delete)
        if (_tree[id] != null) Change.delete(id),
    ];
    final edit = Edit(changes);
    _tree.apply(edit);
    follow(edit);
  }
}

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
