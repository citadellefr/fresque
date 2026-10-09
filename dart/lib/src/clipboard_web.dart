import 'dart:js_interop';
import 'dart:typed_data';

/// Listens to what the page copies, cuts and pastes, until the function it
/// returns is called. [onCopy] says whether it took the copy: the clipboard
/// then drops the picture it may hold, so that a later paste is not that
/// picture. [onPaste] is given the picture pasted, null when there is none.
void Function()? watchClipboard({
  required bool Function({required bool cut}) onCopy,
  required void Function(Future<Uint8List>? image) onPaste,
}) {
  JSFunction copying({required bool cut}) => (_ClipboardEvent event) {
    if (!onCopy(cut: cut)) return;
    event.clipboardData?.setData('application/x-fresque', '1');
    event.preventDefault();
  }.toJS;

  final listeners = {
    'copy': copying(cut: false),
    'cut': copying(cut: true),
    'paste': (_ClipboardEvent event) {
      onPaste(_image(event.clipboardData)?.arrayBuffer().toDart.then((b) => b.toDart.asUint8List()));
    }.toJS,
  };
  listeners.forEach((type, listener) => _document.addEventListener(type, listener));
  return () => listeners.forEach((type, listener) => _document.removeEventListener(type, listener));
}

_File? _image(_DataTransfer? data) {
  final items = data?.items;
  if (items == null) return null;
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item.kind == 'file' && item.type.startsWith('image/')) return item.getAsFile();
  }
  return null;
}

@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external void addEventListener(String type, JSFunction listener);

  external void removeEventListener(String type, JSFunction listener);
}

extension type _ClipboardEvent._(JSObject _) implements JSObject {
  external _DataTransfer? get clipboardData;

  external void preventDefault();
}

extension type _DataTransfer._(JSObject _) implements JSObject {
  external _Items get items;

  external void setData(String format, String data);
}

extension type _Items._(JSObject _) implements JSObject {
  external int get length;

  external _Item operator [](int index);
}

extension type _Item._(JSObject _) implements JSObject {
  external String get kind;

  external String get type;

  external _File? getAsFile();
}

extension type _File._(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> arrayBuffer();
}
