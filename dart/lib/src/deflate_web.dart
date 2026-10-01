import 'dart:js_interop';
import 'dart:typed_data';

/// [bytes] compressed with zlib, by the browser.
Future<Uint8List> deflate(Uint8List bytes) async {
  final compressed = _Blob([bytes.toJS].toJS).stream().pipeThrough(_CompressionStream('deflate'));
  final buffer = await _Response(compressed).arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts);

  external _ReadableStream stream();
}

extension type _ReadableStream._(JSObject _) implements JSObject {
  external _ReadableStream pipeThrough(JSObject transform);
}

@JS('CompressionStream')
extension type _CompressionStream._(JSObject _) implements JSObject {
  external factory _CompressionStream(String format);
}

@JS('Response')
extension type _Response._(JSObject _) implements JSObject {
  external factory _Response(_ReadableStream body);

  external JSPromise<JSArrayBuffer> arrayBuffer();
}
