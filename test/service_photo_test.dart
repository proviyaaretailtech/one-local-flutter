import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinii_pos/catalogue/item_photo.dart';
import 'package:vinii_pos/service/catalogue_screen.dart';
import 'package:vinii_pos/service/service_api.dart';

import 'service_screens_test.dart' show FakeRpc, serviceDetail, show;

// A service has a photo (founder, 2 Nov 2026: "add photo options"), through the store's own photo tools: camera, gallery, background
// removal, and the upload that puts the link on the service once it is saved.

// a 1×1 PNG
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakePhotos extends ItemPhotoService {
  final log = <String>[];
  @override
  Future<ItemPhoto?> pick() async {
    log.add('pick');
    return ItemPhoto(bytes: _png, contentType: 'image/png');
  }

  @override
  Future<ItemPhoto?> capture(BuildContext context) async {
    log.add('camera');
    return ItemPhoto(bytes: _png, contentType: 'image/png');
  }

  @override
  Future<ItemPhoto> removeBackground(ItemPhoto photo, {String? bgColor}) async {
    log.add('cutout $bgColor');
    return ItemPhoto(bytes: _png, contentType: 'image/png', backgroundRemoved: true);
  }

  @override
  Future<void> attach(String itemId, ItemPhoto photo) async => log.add('attach $itemId');
  @override
  Future<void> remove(String itemId) async => log.add('remove $itemId');
}

Future<void> _tap(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Add service: Camera or Gallery, Remove background, and the photo goes on the service once it is saved', (t) async {
    final s = FakeRpc({'svc_service_save': (_) => serviceDetail()});
    final photos = _FakePhotos();
    await show(t, ServiceEditScreen(api: s.api, photos: photos));
    await t.pumpAndSettle();
    expect(find.text('Photo'), findsOneWidget);
    expect(find.text('Add a photo so customers see the service.'), findsOneWidget);
    expect(find.byKey(const ValueKey('photo-remove')), findsNothing);

    await _tap(t, 'photo-gallery');
    expect(find.text('Customers see this photo on the service.'), findsOneWidget);
    await _tap(t, 'photo-cutout');
    expect(photos.log, ['pick', 'cutout FFFFFF']);
    expect(find.byKey(const ValueKey('photo-cutout')), findsNothing, reason: 'already cut out');

    await t.enterText(find.byKey(const ValueKey('field-Name')), 'Precision haircut');
    await t.enterText(find.byKey(const ValueKey('field-Price (₹, before GST)')), '600');
    await t.ensureVisible(find.text('Save service'));
    await t.tap(find.text('Save service'));
    await t.pumpAndSettle();
    expect(s.of('svc_service_save'), hasLength(1));
    expect(photos.log.last, 'attach s1', reason: 'on the saved service');
  });

  testWidgets('Edit service: the saved photo shows; Remove takes it off when the service is saved', (t) async {
    final s = FakeRpc({'svc_service_save': (_) => serviceDetail()});
    final photos = _FakePhotos();
    final d = serviceDetail()..['image_url'] = 'http://img.test/haircut.png';
    await show(t, ServiceEditScreen(api: s.api, detail: ServiceDetail(d), photos: photos));
    await t.pumpAndSettle();
    expect(find.text('Customers see this photo on the service.'), findsOneWidget);
    await _tap(t, 'photo-remove');
    expect(find.text('Add a photo so customers see the service.'), findsOneWidget);
    await t.ensureVisible(find.text('Save service'));
    await t.tap(find.text('Save service'));
    await t.pumpAndSettle();
    expect(photos.log, ['remove s1']);
  });
}
