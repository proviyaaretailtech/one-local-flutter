import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart' show CameraException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/catalogue/item_photo.dart';
import 'package:vinii_pos/catalogue/photo_capture_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

// a real 1×1 PNG, so Image.memory can draw it
final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

class _Photos extends ItemPhotoService {
  _Photos({this.fail = false});
  final bool fail;
  int picks = 0, cutOuts = 0;
  @override
  Future<ItemPhoto?> pick() async {
    picks++;
    return ItemPhoto(bytes: Uint8List.fromList(_png), contentType: 'image/png');
  }

  @override
  Future<ItemPhoto> removeBackground(ItemPhoto p) async {
    cutOuts++;
    if (fail) throw const ItemPhotoUnavailable('No product was found in the photo. Try again with the product in the middle.');
    return ItemPhoto(bytes: p.bytes, contentType: 'image/png', backgroundRemoved: true);
  }

  @override
  Future<void> attach(String itemId, ItemPhoto p) async {}
  @override
  Future<void> remove(String itemId) async {}
}

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

/// Opens the photo flow from a button and keeps what it returns.
Future<List<ItemPhoto?>> open(WidgetTester t, _Photos photos, {ItemPhoto? initial}) async {
  final got = <ItemPhoto?>[];
  t.view.physicalSize = const Size(780, 1700);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: posTheme(),
    home: Builder(
      builder: (c) => Scaffold(
        body: TextButton(
          onPressed: () async => got.add(await Navigator.of(c).push<ItemPhoto>(MaterialPageRoute(builder: (_) => PhotoCaptureScreen(photos: photos, initial: initial)))),
          child: const Text('go'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('go'));
  await t.pumpAndSettle();
  return got;
}

void main() {
  setUpAll(() async {
    await _font('Inter', 'fonts/Inter.ttf');
    await _font('packages/lucide_icons_flutter/Lucide', 'packages/lucide_icons_flutter/assets/lucide.ttf');
  });
  final realThumb = latestGalleryThumb, realCameras = findCameras;
  setUp(() {
    latestGalleryThumb = () async => null;
    findCameras = () async => throw CameraException('none', 'no camera in tests');
  });
  tearDown(() {
    latestGalleryThumb = realThumb;
    findCameras = realCameras;
  });

  testWidgets('the camera opens first: shutter, gallery corner and switch; no camera says so and the gallery still works', (t) async {
    final photos = _Photos();
    await open(t, photos);
    expect(find.text('Product photo'), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-shutter')), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-gallery')), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-flip')), findsOneWidget);
    expect(find.byKey(const ValueKey('camera-problem')), findsOneWidget); // tests have no camera
    await t.tap(find.byKey(const ValueKey('camera-gallery')));
    await t.pumpAndSettle();
    expect(photos.picks, 1);
    expect(find.text('Clean up the photo'), findsOneWidget); // a gallery photo goes to the same clean-up step
  });

  testWidgets('the latest gallery photo shows in the corner', (t) async {
    latestGalleryThumb = () async => Uint8List.fromList(_png);
    await open(t, _Photos());
    expect(find.descendant(of: find.byKey(const ValueKey('camera-gallery')), matching: find.byType(Image)), findsOneWidget);
  });

  testWidgets('clean-up: remove the background, compare with the original, then use the cut-out', (t) async {
    final photos = _Photos();
    final got = await open(t, photos, initial: ItemPhoto(bytes: Uint8List.fromList(_png), contentType: 'image/png'));
    expect(find.text('Clean up the photo'), findsOneWidget);
    expect(find.text('Use photo'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('photo-remove-bg')));
    await t.pumpAndSettle();
    expect(photos.cutOuts, 1);
    expect(find.text('Background removed'), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-cutout')), findsOneWidget);
    await t.tap(find.text('Original'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('photo-original')), findsOneWidget);
    expect(find.text('Use photo'), findsOneWidget);
    await t.tap(find.text('Cut-out'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('photo-use')));
    await t.pumpAndSettle();
    expect(got.single?.backgroundRemoved, isTrue);
  });

  testWidgets('when the background cannot be removed, the reason shows and the original can still be used', (t) async {
    final photos = _Photos(fail: true);
    final got = await open(t, photos, initial: ItemPhoto(bytes: Uint8List.fromList(_png), contentType: 'image/png'));
    await t.tap(find.byKey(const ValueKey('photo-remove-bg')));
    await t.pumpAndSettle();
    expect(find.text('No product was found in the photo. Try again with the product in the middle.'), findsOneWidget);
    await t.pump(const Duration(seconds: 5)); // the message goes away
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('photo-use')));
    await t.pumpAndSettle();
    expect(got.single?.backgroundRemoved, isFalse);
  });

  testWidgets('Retake goes back to the camera', (t) async {
    await open(t, _Photos(), initial: ItemPhoto(bytes: Uint8List.fromList(_png), contentType: 'image/png'));
    await t.tap(find.byKey(const ValueKey('photo-retake')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('camera-shutter')), findsOneWidget);
  });
}
