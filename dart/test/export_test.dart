import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/fresque.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<String> pdfOf(List<BoardElement> elements, {double pixelRatio = 1}) async {
    final bytes = await exportPdf(Board()..reset(elements, 0), pixelRatio: pixelRatio);
    return latin1.decode(bytes!);
  }

  int pages(String pdf) => RegExp(r'/Type /Page ').allMatches(pdf).length;

  test('an empty board has no PDF', () async {
    expect(await exportPdf(Board()), isNull);
  });

  test('a small drawing fits on one portrait page', () async {
    final pdf = await pdfOf([rect('a')]);
    expect(pdf, startsWith('%PDF-1.4'));
    expect(pages(pdf), 1);
    expect(pdf, contains('/MediaBox [0 0 595.50 842.25]'));
  });

  test('a wide drawing is cut into landscape pages at full resolution', () async {
    final pdf = await pdfOf([rect('a'), rect('b', x: 2000)], pixelRatio: 2);
    expect(pages(pdf), 2);
    expect(pdf, contains('/MediaBox [0 0 842.25 595.50]'));
    expect(pdf, contains('/Width 2246 /Height 1588'));
  });

  test('skips the pages left blank', () async {
    final pdf = await pdfOf([rect('a'), rect('b', x: 5000)]);
    expect(pdf, contains('/Count 2'));
  });

  test('the cross-reference table points at each object', () async {
    final bytes = latin1.encode(await pdfOf([rect('a'), rect('b', x: 2000)]));
    final pdf = latin1.decode(bytes);
    final start = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(pdf)!.group(1)!);
    expect(pdf.substring(start), startsWith('xref\n0 '));
    final offsets = RegExp(r'(\d{10}) 00000 n ').allMatches(pdf.substring(start)).toList();
    expect(offsets, isNotEmpty);
    for (final (i, m) in offsets.indexed) {
      expect(pdf.substring(int.parse(m.group(1)!)), startsWith('${i + 1} 0 obj'));
    }
  });

  test('the picture keeps the drawing without loss', () async {
    final pdf = await pdfOf([rect('a')]);
    final header = RegExp(r'/Width (\d+) /Height (\d+) .*?/Length (\d+) >>\nstream\n');
    final m = header.firstMatch(pdf)!;
    final length = int.parse(m.group(3)!);
    final rgb = const ZLibDecoder().decodeBytes(
      latin1.encode(pdf.substring(m.end, m.end + length)),
    );
    final width = int.parse(m.group(1)!), height = int.parse(m.group(2)!);
    expect(rgb.length, width * height * 3);
    expect(rgb.sublist(0, 3), [255, 255, 255]);
    // the page is centred on the drawing: the left side of the square
    final edge = (561 * width + 392) * 3;
    expect(Uint8List.sublistView(rgb, edge, edge + 3), [0, 0, 0]);
  });
}
