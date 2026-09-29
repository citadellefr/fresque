import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fresque/fresque.dart';
import 'package:fresque/src/images.dart';
import 'package:fresque/src/render.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps a small image as it is', () async {
    final png = await noisePng(8, 6);
    final image = await prepareImage(png);
    expect(image.src, 'data:image/png;base64,${base64Encode(png)}');
    expect(image.size, const ui.Size(8, 6));
  });

  test('scales a heavy photo down to a JPEG within the budget', () async {
    final image = await prepareImage(await noisePng(400, 300), maxBytes: 20000);
    expect(image.src, startsWith('data:image/jpeg;base64,'));
    expect(UriData.parse(image.src).contentAsBytes().length, lessThanOrEqualTo(20000));
    expect(image.size.width, lessThan(400));
    expect(image.size.aspectRatio, closeTo(4 / 3, 0.02));
  });

  test('keeps the transparency of what has some', () async {
    final image = await prepareImage(await noisePng(200, 200, transparent: true), maxBytes: 40000);
    expect(image.src, startsWith('data:image/png;base64,'));
    expect(UriData.parse(image.src).contentAsBytes().length, lessThanOrEqualTo(40000));
  });

  test('bounds the longest side', () async {
    final image = await prepareImage(await noisePng(maxImageSide + 400, 4));
    expect(image.size.width, maxImageSide);
  });

  test('refuses what is not an image', () async {
    await expectLater(prepareImage(utf8.encode('not an image')), throwsFormatException);
  });

  test('a scene draws an image again once it is decoded', () async {
    final image = await prepareImage(await noisePng(8, 8));
    final e = BoardElement(
      id: 'i',
      kind: ElementKind.image,
      z: 1,
      x: 0,
      y: 0,
      width: 8,
      height: 8,
      color: 0xFF000000,
      src: image.src,
    );
    final board = Board()..reset([e], 0);
    final scene = Scene();
    addTearDown(scene.dispose);
    final decoded = Completer<void>();
    scene.addListener(decoded.complete);

    scene
      ..sync(board, const {})
      ..paint(ui.Canvas(ui.PictureRecorder()));
    expect(scene.images[e], isNull);
    await decoded.future;
    expect(scene.images[e]?.width, 8);

    board.edit([], ['i']);
    scene.sync(board, const {});
    expect(scene.drawn, isEmpty);
  });
}
