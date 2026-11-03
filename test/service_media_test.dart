import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/catalogue/item_photo.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/service/catalogue_screen.dart';
import 'package:vinii_pos/service/service_api.dart';
import 'package:vinii_pos/service/service_media.dart';

import 'service_screens_test.dart' show serviceDetail, show;

// Service media (founder, 2 Nov 2026): the store's media manager for services. My photos (offer to OneLocal, take back), Standard media by
// kind of service, and a standard photo for a service, from Media or from the service's own photo card.

const _json = {'content-type': 'application/json; charset=utf-8'};

Map<String, dynamic> _pool(String id, String status, {int uses = 0}) =>
    {'pool_id': id, 'image_url': 'http://img.test/$id.png', 'name': 'Haircut', 'product_category': 'Hair', 'status': status, 'use_count': uses};

class _Fake {
  _Fake({bool standardOk = true})
      : answers = {
          'svc_media_pool': (_) => {
                'kind': standardOk ? 'Beauty & personal care' : 'Events',
                'standard_ok': standardOk,
                'can_edit': true,
                'counts': {'photos': 2, 'offered': 1, 'approved': 0},
                'items': [
                  {'service_id': 'h1', 'name': 'Haircut', 'category': 'Hair', 'type': 'appointment', 'image_url': 'http://img.test/h1.png', 'own': true, 'pool': null},
                  {'service_id': 'f1', 'name': 'Facial', 'category': 'Skin', 'type': 'appointment', 'image_url': 'http://img.test/f1.png', 'own': true, 'pool': _pool('p9', 'submitted')},
                ],
                'without_photo': [
                  {'service_id': 'a1', 'name': 'AC service', 'category': 'Repairs', 'type': 'on_location'},
                ],
              },
          'svc_media_offer': (_) => _pool('p1', 'submitted'),
          'svc_media_withdraw': (_) => _pool('p9', 'withdrawn'),
          'svc_media_standard': (b) => {
                'kind': standardOk ? 'Beauty & personal care' : 'Events',
                'standard_ok': standardOk,
                'filter': b['kind'] ?? 'Beauty & personal care',
                'total': 3,
                'items': [_pool('s1', 'approved', uses: 4)],
                'kinds': [
                  {'kind': 'Beauty & personal care', 'count': 1},
                  {'kind': 'Cleaning', 'count': 2},
                ],
              },
          'svc_media_use': (b) => {'service_id': b['service_id'], 'image_url': 'http://img.test/s1.png'},
          'svc_service_save': (_) => serviceDetail(),
        };
  final Map<String, Object Function(Map<String, dynamic>)> answers;
  final calls = <(String, Map<String, dynamic>)>[];
  late final client = MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final body = r.body.isEmpty ? <String, dynamic>{} : (jsonDecode(r.body) as Map).cast<String, dynamic>();
    calls.add((fn, body));
    return http.Response(jsonEncode(answers[fn]!(body)), 200, headers: _json);
  });
  late final media = ServiceMediaApi(baseUrl: 'http://pos.test', accessToken: () => 'token', client: client);
  late final api = ServiceApi(baseUrl: 'http://pos.test', accessToken: () => 'token', client: client);
  List<Map<String, dynamic>> of(String fn) => calls.where((c) => c.$1 == fn).map((c) => c.$2).toList();
}

class _NoPhotos extends ItemPhotoService {
  @override
  Future<ItemPhoto?> pick() async => null;
  @override
  Future<ItemPhoto> removeBackground(ItemPhoto photo, {String? bgColor}) async => photo;
  @override
  Future<void> attach(String itemId, ItemPhoto photo) async {}
  @override
  Future<void> remove(String itemId) async {}
}

Future<void> _tap(WidgetTester t, Key key) async {
  await t.ensureVisible(find.byKey(key));
  await t.tap(find.byKey(key));
  await t.pumpAndSettle();
}

void main() {
  setUp(() => HomeNav.storeName = 'Demo Services');
  tearDown(HomeNav.reset);

  testWidgets('My photos: each service photo and where it stands; Offer asks first, Take back; services without a photo', (t) async {
    final f = _Fake();
    await show(t, ServiceMediaScreen(api: f.media));
    await t.pumpAndSettle();
    for (final s in ['Media', 'My photos', 'Standard media', '2 photos · 1 waiting · 0 standard', 'Haircut', 'Only your business', 'Facial', 'Waiting for review',
      'Without a photo', 'AC service']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await _tap(t, const ValueKey('offer-h1'));
    expect(find.text('Offer this photo to OneLocal?'), findsOneWidget);
    await _tap(t, const ValueKey('offer-confirm'));
    expect(f.of('svc_media_offer').single, {'service_id': 'h1'});
    await _tap(t, const ValueKey('withdraw-f1'));
    expect(f.of('svc_media_withdraw').single, {'pool_id': 'p9'});

    // a standard photo for a service that has none
    await _tap(t, const ValueKey('standard-for-a1'));
    expect(f.of('svc_media_standard').last, {'kind': 'all', 'service_id': 'a1'});
    await _tap(t, const ValueKey('pick-s1'));
    expect(f.of('svc_media_use').single, {'pool_id': 's1', 'service_id': 'a1'});
  });

  testWidgets('Standard media: the business\'s kind first, every kind, or another kind; a photo goes on a chosen service', (t) async {
    final f = _Fake();
    await show(t, ServiceMediaScreen(api: f.media));
    await t.pumpAndSettle();
    await _tap(t, const ValueKey('media-tab-standard'));
    expect(f.of('svc_media_standard').single, isEmpty, reason: 'this business\'s kind, chosen by the server');
    for (final s in ['Beauty & personal care (yours)', 'All kinds · 3', 'Cleaning · 2', 'Haircut', 'Hair · used by 4']) {
      expect(find.text(s), findsWidgets, reason: s);
    }
    await _tap(t, const ValueKey('kind-Cleaning'));
    expect(f.of('svc_media_standard').last, {'kind': 'Cleaning'});
    await _tap(t, const ValueKey('standard-s1'));
    expect(find.text('Use on which service?'), findsOneWidget);
    await _tap(t, const ValueKey('use-on-a1'));
    expect(f.of('svc_media_use').single, {'pool_id': 's1', 'service_id': 'a1'});
  });

  testWidgets('a kind that shows its own work (events, health, professional) keeps its own photos: no Offer, no standard photos', (t) async {
    final f = _Fake(standardOk: false);
    await show(t, ServiceMediaScreen(api: f.media));
    await t.pumpAndSettle();
    expect(find.text(ownOnlyNote('Events')), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-h1')), findsNothing);
    expect(find.byKey(const ValueKey('standard-for-a1')), findsNothing);
    await _tap(t, const ValueKey('media-tab-standard'));
    expect(find.byKey(const ValueKey('media-own-only')), findsOneWidget);
  });

  testWidgets('Add service: Standard picks an approved photo, which goes on the service when it is saved', (t) async {
    final f = _Fake();
    await show(t, ServiceEditScreen(api: f.api, photos: _NoPhotos(), media: f.media));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('field-Name')), 'Haircut');
    await _tap(t, const ValueKey('photo-standard'));
    expect(f.of('svc_media_standard').single, {'q': 'Haircut', 'kind': 'all'});
    await _tap(t, const ValueKey('pick-s1'));
    expect(find.text('Customers see this photo on the service.'), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('field-Price (₹, before GST)')), '300');
    await t.ensureVisible(find.text('Save service'));
    await t.tap(find.text('Save service'));
    await t.pumpAndSettle();
    expect(f.of('svc_media_use').single, {'pool_id': 's1', 'service_id': 's1'});
  });
}
