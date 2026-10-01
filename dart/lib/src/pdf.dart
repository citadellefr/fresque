import 'dart:convert';
import 'dart:typed_data';

/// A PDF whose pages are each covered by one opaque picture, kept lossless.
class PdfPictures {
  PdfPictures() {
    _write('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n');
  }

  static const _catalog = 1, _pages = 2;

  final _out = BytesBuilder(copy: false);
  final _offsets = <int, int>{};
  final _kids = <int>[];
  var _next = 3;

  int get pageCount => _kids.length;

  /// Adds a page of [width] by [height] points, covered by a picture of
  /// [columns] by [rows] pixels: [deflated] holds three bytes for each, row by
  /// row from the top, compressed with zlib.
  void addPage(double width, double height, int columns, int rows, Uint8List deflated) {
    final w = _number(width), h = _number(height);
    final image = _object(
      '<< /Type /XObject /Subtype /Image /Width $columns /Height $rows '
      '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode',
      deflated,
    );
    final content = _object('<<', latin1.encode('q $w 0 0 $h 0 0 cm /P Do Q'));
    _kids.add(
      _object(
        '<< /Type /Page /Parent $_pages 0 R /MediaBox [0 0 $w $h] '
        '/Resources << /XObject << /P $image 0 R >> >> /Contents $content 0 R >>',
      ),
    );
  }

  Uint8List close() {
    final kids = _kids.map((k) => '$k 0 R').join(' ');
    _object('<< /Type /Pages /Kids [$kids] /Count ${_kids.length} >>', null, _pages);
    _object('<< /Type /Catalog /Pages $_pages 0 R >>', null, _catalog);
    final xref = _out.length;
    final table = StringBuffer('xref\n0 $_next\n0000000000 65535 f \n');
    for (var i = 1; i < _next; i++) {
      table.write('${_offsets[i].toString().padLeft(10, '0')} 00000 n \n');
    }
    _write('${table}trailer\n<< /Size $_next /Root $_catalog 0 R >>\nstartxref\n$xref\n%%EOF\n');
    return _out.takeBytes();
  }

  int _object(String dictionary, [Uint8List? stream, int? number]) {
    final n = number ?? _next++;
    _offsets[n] = _out.length;
    if (stream == null) {
      _write('$n 0 obj\n$dictionary\nendobj\n');
    } else {
      _write('$n 0 obj\n$dictionary /Length ${stream.length} >>\nstream\n');
      _out.add(stream);
      _write('\nendstream\nendobj\n');
    }
    return n;
  }

  void _write(String s) => _out.add(latin1.encode(s));

  static String _number(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}
