import 'dart:typed_data';

/// Null: only a browser tells its page what is copied and pasted, and nothing
/// else here reads a picture from the clipboard.
void Function()? watchClipboard({
  required bool Function({required bool cut}) onCopy,
  required void Function(Future<Uint8List>? image) onPaste,
}) => null;
