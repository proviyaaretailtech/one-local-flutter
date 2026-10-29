import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinii_pos/onboarding/document_picker.dart';
import 'package:vinii_pos/orders/order_screen.dart';
import 'package:vinii_pos/orders/order_widgets.dart' show DarkCta;
import 'package:vinii_pos/orders/orders_api.dart';
import 'package:vinii_pos/orders/pack_order_screen.dart';
import 'package:vinii_pos/ui/theme.dart';

import 'helpers.dart';
import 'order_fixtures.dart';

// Packing an online order in one place (founder, 29 Oct 2026): tick each item as it goes in the bag, a photo of the packed bag (or why
// there is none), then "Mark packed"; the order shows four simple steps and the packed photo afterwards.

http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

final _png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');

/// A fake server: the order starts at [start]; each move answers the next stage.
class Fake {
  Fake(this.start, {this.photoRequired = true, this.online = false, this.refusePack = false});
  final String start;
  final bool photoRequired, online, refusePack;
  final requests = <http.Request>[];
  late Map<String, dynamic> current = view(start, version: 3, photoRequired: photoRequired, online: online);

  Iterable<String> get calls => requests.map((r) => r.method == 'PUT' ? 'PUT' : r.url.path.endsWith('/act') ? 'act:${jsonDecode(r.body)['action']}' : r.url.path.split('/').last);
  /// The calls that change something (opening the photo link afterwards is left out).
  List<String> get moves => [for (final c in calls) if (c != 'pos_packed_photo_link') c];
  Map<String, dynamic> body(String fn) => jsonDecode(requests.lastWhere((r) => r.url.path.endsWith('/$fn')).body) as Map<String, dynamic>;
  List<Map<String, dynamic>> acts() => [for (final r in requests.where((r) => r.url.path.endsWith('/act'))) jsonDecode(r.body) as Map<String, dynamic>];

  late final api = OrdersApi(
    baseUrl: 'http://pos.test',
    accessToken: () => 't',
    client: MockClient((r) async {
      requests.add(r);
      if (r.method == 'PUT') return http.Response('', 200);
      final path = r.url.path;
      if (path.endsWith('/pos_packed_photo_slot')) return ok({'path': 'org/orders/o/x.jpg', 'upload_url': 'http://up.test/x', 'max_bytes': 1});
      if (path.endsWith('/pos_packed_photo_save')) {
        final b = jsonDecode(r.body) as Map<String, dynamic>;
        return ok({'id': 'ph1', 'has_photo': b['path'] != null, 'skip_reason': b['skip_reason'], 'at': '2026-10-29T10:00:00Z'});
      }
      if (path.endsWith('/pos_packed_photo_link')) return ok({'url': 'http://img.test/p.jpg', 'expires_in': 600});
      if (path.endsWith('/act')) {
        final a = (jsonDecode(r.body) as Map)['action'];
        if (a == 'pack' && refusePack) return http.Response(jsonEncode({'detail': 'Add a photo of the packed order first.', 'code': 'photo_needed'}), 409, headers: {'content-type': 'application/json'});
        final next = switch (a) { 'pick' => 'picked', 'pack' || 'online_ready' => 'ready', 'accept' => 'preparing', _ => start };
        final v = current['version'] as int;
        current = view(next, version: v + 1, photoRequired: photoRequired, online: online,
            photo: next == 'ready' ? {'id': 'ph1', 'has_photo': true, 'skip_reason': null, 'at': '2026-10-29T10:00:00Z'} : null);
        return ok(current);
      }
      return ok(current); // GET the order
    }),
  );
}

Future<void> openOrder(WidgetTester t, Fake f) async {
  ignoreOverflow();
  t.view.physicalSize = const Size(780, 4000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: posTheme(), home: OrderScreen(api: f.api, orderId: orderId)));
  await t.pumpAndSettle();
}

Future<void> tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pumpAndSettle();
}

bool enabled(WidgetTester t, String key) =>
    t.widget<DarkCta>(find.byKey(ValueKey(key))).onPressed != null;

void main() {
  var shots = 0;
  setUp(() {
    shots = 0;
    takePackedPhoto = (_) async {
      shots++;
      return PickedDocument(name: 'packed.jpg', bytes: _png, contentType: 'image/jpeg');
    };
  });

  testWidgets('Pack order: tick the items, take the photo, Mark packed saves the photo, then the items, then packed', (t) async {
    final f = Fake('preparing');
    await openOrder(t, f);
    expect(find.text('Pack'), findsOneWidget); // the steps
    await t.tap(find.text('Pack order'));
    await t.pumpAndSettle();
    expect(find.byType(PackOrderScreen), findsOneWidget);
    expect(enabled(t, 'pack-done'), isFalse);
    expect(find.text('5 items still to tick'), findsOneWidget);
    await tapKey(t, 'pack-item-00000001-0000-0000-0000-000000000000');
    expect(find.text('4 items still to tick'), findsOneWidget);
    await tapKey(t, 'pack-tick-all');
    expect(find.text('Take a photo of the packed bag'), findsOneWidget);
    expect(enabled(t, 'pack-done'), isFalse); // the store asks for a photo
    await tapKey(t, 'pack-photo');
    expect(shots, 1);
    expect(find.byKey(const ValueKey('pack-photo-preview')), findsOneWidget);
    expect(enabled(t, 'pack-done'), isTrue);
    await tapKey(t, 'pack-done');
    expect(f.moves, ['$orderId', 'pos_packed_photo_slot', 'PUT', 'pos_packed_photo_save', 'act:pick', 'act:pack']);
    expect(f.body('pos_packed_photo_slot'), {'order_id': orderId, 'content_type': 'image/jpeg', 'size': _png.length});
    expect(f.body('pos_packed_photo_save'), {'order_id': orderId, 'path': 'org/orders/o/x.jpg'});
    final pick = f.acts().first;
    expect(pick['version'], 3);
    expect((pick['lines'] as List).first, {'order_item_id': '00000001-0000-0000-0000-000000000000', 'qty': 2});
    expect(f.acts().last, {'action': 'pack', 'version': 4});
    // back on the order: ready, with the packed photo
    expect(find.byType(PackOrderScreen), findsNothing);
    expect(find.text('Order Ready'), findsOneWidget);
    expect(find.textContaining('Photo taken'), findsOneWidget);
    expect(f.calls.last, 'pos_packed_photo_link');
  });

  testWidgets('no camera: the reason is saved instead of a photo', (t) async {
    final f = Fake('picked');
    await openOrder(t, f);
    await t.tap(find.text('Pack order'));
    await t.pumpAndSettle();
    expect(find.text('All items ticked').evaluate().isEmpty, isTrue);
    expect(enabled(t, 'pack-done'), isFalse); // already picked: ticked, but no photo yet
    await tapKey(t, 'pack-no-photo');
    await tapKey(t, 'pack-skip-Camera not working');
    await tapKey(t, 'pack-skip-save');
    expect(find.text('No photo: Camera not working'), findsOneWidget);
    await tapKey(t, 'pack-done');
    expect(f.moves, ['$orderId', 'pos_packed_photo_save', 'act:pack']); // picked already: no pick
    expect(f.body('pos_packed_photo_save'), {'order_id': orderId, 'skip_reason': 'Camera not working'});
  });

  testWidgets('a store that does not ask for a photo packs with the items alone', (t) async {
    final f = Fake('preparing', photoRequired: false);
    await openOrder(t, f);
    await t.tap(find.text('Pack order'));
    await t.pumpAndSettle();
    expect(find.text('optional'), findsOneWidget);
    await tapKey(t, 'pack-tick-all');
    expect(enabled(t, 'pack-done'), isTrue);
    await tapKey(t, 'pack-done');
    expect(f.moves, ['$orderId', 'act:pick', 'act:pack']);
  });

  testWidgets('a OneLocal order goes straight to ready after the photo', (t) async {
    final f = Fake('preparing', online: true);
    await openOrder(t, f);
    expect(find.text('Rider'), findsOneWidget);
    await t.tap(find.text('Pack order'));
    await t.pumpAndSettle();
    await tapKey(t, 'pack-tick-all');
    await tapKey(t, 'pack-photo');
    await tapKey(t, 'pack-done');
    expect(f.moves, ['$orderId', 'pos_packed_photo_slot', 'PUT', 'pos_packed_photo_save', 'act:online_ready']);
  });

  testWidgets('a refusal stays on the packing screen with the reason, and the photo is not sent twice', (t) async {
    final f = Fake('picked', refusePack: true);
    await openOrder(t, f);
    await t.tap(find.text('Pack order'));
    await t.pumpAndSettle();
    await tapKey(t, 'pack-photo');
    await tapKey(t, 'pack-done');
    expect(find.byType(PackOrderScreen), findsOneWidget);
    expect(find.text('Add a photo of the packed order first.'), findsOneWidget);
    expect(f.calls.where((c) => c == 'PUT'), hasLength(1));
  });

  testWidgets('an order packed without a photo says why on the order', (t) async {
    final f = Fake('ready')..current = view('ready', photo: {'id': 'ph2', 'has_photo': false, 'skip_reason': 'Camera not working', 'at': '2026-10-29T10:00:00Z'});
    await openOrder(t, f);
    expect(find.text('No photo: Camera not working'), findsOneWidget);
    expect(f.calls.contains('pos_packed_photo_link'), isFalse);
    expect(find.text('Customer collected it'), findsOneWidget);
  });
}
