import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// [bytes] compressed with zlib, in another isolate.
Future<Uint8List> deflate(Uint8List bytes) =>
    Isolate.run(() => Uint8List.fromList(zlib.encode(bytes)));
