import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/barcodes/barcodes_api.dart';
import 'package:vinii_pos/home/home_nav.dart';
import 'package:vinii_pos/media/media_api.dart';
import 'package:vinii_pos/media/product_photos_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';

// The product media pool (founder, 30 Oct 2026): Store Media Pool → offered to the Master Media Pool → approved into the Standard Data pool,
// which other stores may use. Nothing is shared unless the store offers it.

const _own = 'https://x.test/item-images/org1/items/i1/a.png';

class _Server {
  _Server({this.admin = false});
  final bool admin;
  final calls = <(String, Map<String, dynamic>)>[];
  String status = 'none';

  late final client = MockClient((r) async {
    final fn = r.url.pathSegments.last;
    final b = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
    calls.add((fn, b));
    http.Response ok(Object v) => http.Response(jsonEncode(v), 200, headers: {'content-type': 'application/json'});
    final pool = {'pool_id': 'p1', 'image_url': _own, 'name': 'Aashirvaad Atta 5kg', 'brand': 'Aashirvaad', 'product_category': 'Staples', 'store_category': 'Retail', 'status': status, 'use_count': 2, 'store_name': 'Sharma General Store'};
    switch (fn) {
      case 'media_store_pool':
        return ok({
          'items': [
            {'menu_item_id': 'i1', 'name': 'Aashirvaad Atta 5kg', 'image_url': _own, 'own': true, 'pool': status == 'none' ? null : pool, 'from_standard': false},
            {'menu_item_id': 'i2', 'name': 'Tata Salt 1kg', 'image_url': 'https://cdn.test/salt.png', 'own': false, 'pool': null, 'from_standard': true},
          ],
          'counts': {'photos': 2, 'offered': status == 'submitted' ? 1 : 0, 'approved': 0},
          'is_admin': admin,
        });
      case 'media_offer':
        status = 'submitted';
        return ok(pool..['status'] = 'submitted');
      case 'media_withdraw':
        status = 'withdrawn';
        return ok(pool..['status'] = 'withdrawn');
      case 'media_standard_search':
        return ok({'items': [pool..['status'] = 'approved']});
      case 'media_use':
        return ok({'menu_item_id': b['menu_item_id'], 'image_url': _own, 'replaced_url': null});
      case 'media_admin_queue':
        return ok({'items': [pool..['status'] = 'submitted'], 'groups': []});
      case 'media_admin_decide':
        return ok(pool..['status'] = b['decision'] == 'approve' ? 'approved' : 'rejected');
      case 'bc_list':
        return ok({'items': [{'menu_item_id': 'i9', 'name': 'Atta Loose', 'sku': 'AT', 'price': 50, 'image_url': null}], 'counts': {}});
    }
    return http.Response('{"detail":"unexpected $fn"}', 404);
  });

  MediaApi get api => MediaApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: client);
  BarcodesApi get items => BarcodesApi(baseUrl: 'http://pos.test', accessToken: () => 't', client: client);
  List<Map<String, dynamic>> sent(String fn) => [for (final (f, b) in calls) if (f == fn) b];
}

Future<void> open(WidgetTester t, _Server s) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 2400);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: ProductPhotosScreen(api: s.api, items: s.items)));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(ValueKey(key)));
  await t.pumpAndSettle();
}

void main() {
  tearDown(HomeNav.reset);

  testWidgets('My photos: only the store\'s own photo can be offered; once offered it waits for review and can be taken back', (t) async {
    final s = _Server();
    await open(t, s);
    expect(find.text('Only your store'), findsOneWidget);
    expect(find.text('From the Standard pool'), findsOneWidget);
    expect(find.byKey(const ValueKey('offer-i2')), findsNothing); // not the store's own photo
    expect(find.byKey(const ValueKey('photos-tab-review')), findsNothing); // stores do not review
    await tapKey(t, 'offer-i1');
    await t.tap(find.text('Offer it'));
    await t.pumpAndSettle();
    expect(s.sent('media_offer').single, {'menu_item_id': 'i1'});
    expect(find.text('Waiting for review'), findsOneWidget);
    await tapKey(t, 'withdraw-i1');
    expect(s.sent('media_withdraw').single, {'pool_id': 'p1'});
  });

  testWidgets('Standard photos: approved ones only, and Use puts one on a chosen item', (t) async {
    final s = _Server();
    await open(t, s);
    await tapKey(t, 'photos-tab-standard');
    expect(find.text('Aashirvaad · Staples'), findsOneWidget);
    expect(find.text('Retail · used by 2'), findsOneWidget);
    await tapKey(t, 'use-p1');
    await tapKey(t, 'photo-item-i9');
    expect(s.sent('media_use').single, {'pool_id': 'p1', 'menu_item_id': 'i9'});
    expect(find.text('Photo put on Atta Loose.'), findsOneWidget);
  });

  testWidgets('OneLocal reviews the Master Media Pool grouped by store category and brand; a rejection needs a reason', (t) async {
    final s = _Server(admin: true);
    await open(t, s);
    await tapKey(t, 'photos-tab-review');
    expect(find.text('Retail › Aashirvaad · 1'), findsOneWidget);
    await tapKey(t, 'reject-p1');
    await tapKey(t, 'reject-confirm'); // empty reason: nothing is sent
    expect(s.sent('media_admin_decide'), isEmpty);
    await tapKey(t, 'approve-p1');
    expect(s.sent('media_admin_decide').single, {'pool_id': 'p1', 'decision': 'approve'});
    expect(find.text('Aashirvaad Atta 5kg is in the Standard pool now.'), findsOneWidget);
  });

  testWidgets('from an item: the best-matching Standard photos, one tap puts it on the item', (t) async {
    final s = _Server();
    String? got;
    await t.pumpWidget(MaterialApp(
      theme: posTheme(),
      home: Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () async => got = await pickStandardPhoto(c, s.api, itemId: 'i9', itemName: 'Atta Loose'), child: const Text('go')))),
    ));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(s.sent('media_standard_search').single, {'menu_item_id': 'i9'});
    await t.tap(find.byKey(const ValueKey('standard-for-p1')));
    await t.pumpAndSettle();
    expect(got, _own);
  });
}
